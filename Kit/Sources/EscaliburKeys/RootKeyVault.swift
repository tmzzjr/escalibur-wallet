import CryptoKit
import EscaliburCore
import Foundation
import LocalAuthentication

/// A chave raiz (RK) e os dois caminhos que a destrancam: PIN e biometria.
///
/// ```
/// PIN ─Argon2id─► AP ─┬─(senha de aplicativo)─► item rk.pin
///                     └─HKDF─► K_pin
/// item rk.pin = embrulho(K_dev, ChaChaPoly(K_pin, RK)) ─SE─► ─K_pin─► RK
/// Face ID (decisao no SEP) ─► item rk.bio = embrulho(K_bio, RK) ─SE─► RK
/// ```
///
/// **Nao existe verificador de PIN gravado em lugar nenhum.** O PIN errado e recusado
/// pelo chaveiro, que nao devolve o item sem a senha de aplicativo certa, e de novo
/// pela camada interna, que so abre com a chave derivada do PIN. A camada interna e o
/// que garante o desenho mesmo se a senha de aplicativo for so uma regra de acesso e
/// nao entrar na chave do item: quem copiar o item e conseguir usar o SE deste aparelho
/// ainda precisa do PIN, e cada chute custa um Argon2id de 256 MiB
/// (docs/seguranca.md §2).
public final class RootKeyVault: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case notSetUp
        case alreadySetUp
        case wrongPIN(remainingBeforeWipe: UInt32?)
        case throttled(seconds: TimeInterval)
        /// Nao sao exatamente 6 digitos de 0 a 9.
        case malformedPIN
        case biometryNotEnabled
        /// O cadastro de rostos mudou desde que o Face ID foi ligado: o slot foi
        /// apagado e religar exige o PIN.
        case biometryChanged
        /// O Face ID nao abriu desta vez (cancelou, nao reconheceu, bloqueio do
        /// sistema). O slot continua; o caminho agora e o PIN.
        case cancelled
        /// Apagar apos erros disparou: tudo foi destruido.
        case wiped
        /// O iPhone reiniciou (ou a bateria acabou) desde o ultimo PIN: o Face ID so volta
        /// a valer depois do PIN digitado, como no proprio iPhone.
        case pinRequiredAfterRestart
        case storage
    }

    enum Account {
        static let pinKDF = "pin.kdf"
        static let rootByPIN = "rk.pin"
        static let rootByBiometry = "rk.bio"
        static let biometryState = "bio.estado"
        static let attempts = "pin.tentativas"
        static let wipeAfterErrors = "pin.apagar"
        static let pinBoot = "pin.boot"
        static let pendingSuffix = ".novo"
    }

    /// Camada interna do slot do PIN: versao, nonce (12), RK cifrada (32), tag (16).
    enum Inner {
        static let version: UInt8 = 1
        static let length = 1 + 12 + 32 + 16
        static let info = Data("escalibur-wallet/v1/rk.pin".utf8)
    }

    let store: any SecretStore
    let wrapper: any KeyWrapper
    /// Custo fixo do PIN, so para os testes nao pagarem 256 MiB por chamada.
    private let fixedPINParameters: KDFParameters?
    private let lock = NSLock()

    public convenience init(store: any SecretStore, wrapper: any KeyWrapper) {
        self.init(store: store, wrapper: wrapper, pinParameters: nil)
    }

    init(store: any SecretStore, wrapper: any KeyWrapper, pinParameters: KDFParameters?) {
        self.store = store
        self.wrapper = wrapper
        self.fixedPINParameters = pinParameters
    }

    private var pinParameters: KDFParameters { fixedPINParameters ?? Self.calibratedPINParameters() }

    /// Existe algum slot do PIN? Quando o chaveiro nao consegue responder, a resposta
    /// e "sim": mandar o dono para o cadastro por causa de um erro de leitura e o
    /// caminho que um dia apagaria a chave do aparelho. O cadastro, por sua vez, so
    /// prossegue com um "nao existe" definitivo.
    public var isSetUp: Bool {
        let slots = [Account.rootByPIN, Account.rootByPIN + Account.pendingSuffix].map(store.probe)
        return slots.contains(.present) || slots.contains(.unknown)
    }

    // MARK: Cadastro

    /// Primeiro PIN: cria K_dev, sorteia a RK, grava o slot do PIN e confere lendo de
    /// volta. Devolve a RK aberta, para o chamador derivar a chave de indice e criar a
    /// primeira carteira sem pedir o PIN de novo; quem recebe zera.
    public func setUp(pin: SecureBytes) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        let slots = [Account.rootByPIN, Account.rootByPIN + Account.pendingSuffix, Account.rootByBiometry].map(store.probe)
        guard !slots.contains(.unknown) else { throw Failure.storage }
        guard !slots.contains(.present) else { throw Failure.alreadySetUp }
        guard Self.isWellFormed(pin) else { throw Failure.malformedPIN }

        // Sem nenhum slot da RK, o que sobrou de um cadastro interrompido nao abre
        // nada: a K_dev orfa, o contador e as carteiras cifradas sob uma RK perdida.
        // Apagar aqui e explicito; `createKey` nunca substitui a K_dev sozinho.
        try discardOrphans()

        let rk = try SecureBytes.random(count: 32)
        do {
            try wrapper.createKey(.device)
            try store.add(AttemptRecord.zero.encoded, account: Account.attempts, protection: .standard, context: nil)
            try writePINSlot(rk: rk, pin: pin, kdf: pinParameters, suffix: "")
            try confirm(pin: pin, suffix: "", matches: rk)
            recordPINThisBoot()
        } catch {
            rk.wipe()
            try? discardOrphans()
            throw error
        }
        return rk
    }

    private func discardOrphans() throws {
        wrapper.deleteKey(.device)
        wrapper.deleteKey(.biometry)
        do { try store.deleteAll() } catch { throw Failure.storage }
    }

    // MARK: Destrancar

    /// Destranca pelo PIN. O incremento de tentativa e gravado **antes** da avaliacao;
    /// se a gravacao falhar, a tentativa nao e avaliada (falha fechada).
    ///
    /// Com uma troca de PIN interrompida existem dois slots, e os dois sao tentados na
    /// mesma tentativa. O que abrir decide o desfecho: o antigo desfaz a troca, o novo
    /// a conclui.
    public func unlock(pin: SecureBytes) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        let pendingAccount = Account.rootByPIN + Account.pendingSuffix
        let main = store.probe(Account.rootByPIN)
        let pending = store.probe(pendingAccount)
        guard main != .unknown, pending != .unknown else { throw Failure.storage }
        guard main == .present || pending == .present else { throw Failure.notSetUp }

        let record = try rebasedAttemptsLocked()
        let waiting = record.remaining()
        guard waiting <= 0 else { throw Failure.throttled(seconds: waiting) }

        let next = AttemptRecord.after(failures: record.failures + 1)
        do { try store.update(next.encoded, account: Account.attempts) } catch { throw Failure.storage }

        let candidates = [main == .present ? "" : nil, pending == .present ? Account.pendingSuffix : nil].compactMap { $0 }
        var opened: (rk: SecureBytes, suffix: String)?
        for suffix in candidates where opened == nil {
            do {
                opened = (try readPINSlot(pin: pin, suffix: suffix), suffix)
            } catch Failure.wrongPIN {
                continue
            }
        }

        guard let opened else {
            if let threshold = wipeThreshold, next.failures >= threshold {
                wipeAllLocked()
                throw Failure.wiped
            }
            let left = wipeThreshold.map { $0 - next.failures }
            throw Failure.wrongPIN(remainingBeforeWipe: left)
        }

        // Contador de volta a zero. Se falhar, o dono so espera mais na proxima vez.
        try? store.update(AttemptRecord.zero.encoded, account: Account.attempts)
        recordPINThisBoot()
        if pending == .present {
            if opened.suffix.isEmpty {
                deleteSlot(suffix: Account.pendingSuffix)
            } else {
                try? promotePendingLocked(rk: opened.rk, pin: pin)
            }
        }
        return opened.rk
    }

    /// Destranca pelo Face ID. Bloqueia a thread enquanto o sistema pergunta: chamar
    /// fora do MainActor. O que autoriza e o SEP liberar a chave, nunca um booleano.
    public func unlockWithBiometry(reason: String) throws -> SecureBytes {
        guard pinEnteredThisBoot else { throw Failure.pinRequiredAfterRestart }
        let blob: Data?
        do { blob = try store.read(Account.rootByBiometry, context: nil) } catch { throw Failure.storage }
        guard let blob else { throw Failure.biometryNotEnabled }
        guard wrapper.hasKey(.biometry) else {
            disableBiometry()
            throw Failure.biometryChanged
        }
        let rk: SecureBytes
        do {
            rk = try wrapper.unwrap(blob, slot: .biometry, reason: reason)
        } catch {
            // So um cadastro de rostos diferente do gravado ao ligar, ou a chave que o
            // SEP ja destruiu, apagam o slot. Cancelar, nao reconhecer ou o bloqueio
            // temporario do sistema deixam tudo como esta.
            if biometryEnrollmentChanged || !wrapper.hasKey(.biometry) {
                disableBiometry()
                throw Failure.biometryChanged
            }
            throw Failure.cancelled
        }
        // O contador de PIN nao zera aqui: quem apresenta o rosto do dono a forca nao
        // ganha chutes de PIN de graca a cada Face ID (auditoria 2, B4). So o PIN certo zera.
        return rk
    }

    /// Quanto falta de espera, para a tela de bloqueio mostrar antes do toque. So le.
    public func throttleRemaining() -> TimeInterval {
        (try? readAttempts()?.remaining()) ?? 0
    }

    public func failureCount() -> UInt32 {
        (try? readAttempts()?.failures) ?? 0
    }

    /// Depois de reiniciar, o prazo gravado com o relogio monotonico antigo nao vale
    /// mais: a espera recomeca cheia a partir de agora. Chamado ao abrir e ao voltar
    /// para o app, os unicos pontos que gravam fora de uma tentativa.
    public func rebaseAttempts() {
        lock.lock(); defer { lock.unlock() }
        _ = try? rebasedAttemptsLocked()
    }

    // MARK: Biometria

    /// O PIN foi digitado neste boot? Depois de reiniciar, o Face ID espera o PIN.
    public var pinEnteredThisBoot: Bool {
        let current = PINPolicy.bootSession
        guard current != PINPolicy.unknownBoot, let saved = try? store.read(Account.pinBoot, context: nil) else { return false }
        return [UInt8](saved) == current
    }

    private func recordPINThisBoot() {
        let current = Data(PINPolicy.bootSession)
        if (try? store.update(current, account: Account.pinBoot)) == nil {
            try? store.add(current, account: Account.pinBoot, protection: .standard, context: nil)
        }
    }

    public var isBiometryEnabled: Bool { store.exists(Account.rootByBiometry) && wrapper.hasKey(.biometry) }

    /// Liga o Face ID. Exige a RK aberta, ou seja, o PIN digitado agora.
    public func enableBiometry(rk: SecureBytes) throws {
        try wrapper.createKey(.biometry)
        let blob = try wrapper.wrap(rk, slot: .biometry)
        do {
            try store.delete(Account.rootByBiometry)
            try store.add(blob, account: Account.rootByBiometry, protection: .standard, context: nil)
            try store.delete(Account.biometryState)
            if let state = Self.biometryDomainState() {
                try store.add(state, account: Account.biometryState, protection: .standard, context: nil)
            }
        } catch {
            disableBiometry()
            throw Failure.storage
        }
    }

    /// Desligar so reduz superficie: nao pede nada, e nunca toca o slot do PIN.
    public func disableBiometry() {
        try? store.delete(Account.rootByBiometry)
        try? store.delete(Account.biometryState)
        wrapper.deleteKey(.biometry)
    }

    /// O cadastro de biometria mudou desde que o Face ID foi ligado aqui? Sem estado
    /// gravado ou sem biometria disponivel agora (bloqueio do sistema), a resposta e
    /// "nao se sabe", tratada como "nao mudou": nada e apagado por duvida.
    public var biometryEnrollmentChanged: Bool {
        guard let saved = try? store.read(Account.biometryState, context: nil), let now = Self.biometryDomainState() else {
            return false
        }
        return saved != now
    }

    static func biometryDomainState() -> Data? {
        let context = LAContext()
        defer { context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return nil }
        if #available(iOS 18.0, macOS 15.0, *) {
            return context.domainState.biometry.stateHash
        }
        return context.evaluatedPolicyDomainState
    }

    // MARK: Troca de PIN

    /// Troca atomica. O slot novo e gravado com sufixo e conferido; o ponto sem volta
    /// e apagar o slot antigo. Antes dele, qualquer falha desfaz a troca e o PIN antigo
    /// continua o unico. Depois dele, a troca esta feita: o slot pendente abre com o
    /// PIN novo, e se a promocao a principal falhar aqui, o proximo desbloqueio a
    /// conclui. Em nenhum instante o dono fica sem um slot que abre.
    public func changePIN(rk: SecureBytes, newPIN: SecureBytes) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.isWellFormed(newPIN) else { throw Failure.malformedPIN }
        let pendingAccount = Account.rootByPIN + Account.pendingSuffix
        // Uma troca interrompida se resolve no proximo desbloqueio, nao aqui.
        guard store.probe(Account.rootByPIN) == .present else { throw Failure.storage }
        switch store.probe(pendingAccount) {
        case .unknown: throw Failure.storage
        case .present: deleteSlot(suffix: Account.pendingSuffix)
        case .absent: break
        }

        do {
            try writePINSlot(rk: rk, pin: newPIN, kdf: pinParameters, suffix: Account.pendingSuffix)
            try confirm(pin: newPIN, suffix: Account.pendingSuffix, matches: rk)
            try store.delete(Account.rootByPIN)
        } catch {
            deleteSlot(suffix: Account.pendingSuffix)
            throw error is Failure ? error : Failure.storage
        }
        // Ponto sem volta passado: o PIN antigo nao abre mais nada.
        try? store.delete(Account.pinKDF)
        try? promotePendingLocked(rk: rk, pin: newPIN)
    }

    /// Regrava o slot principal com o PIN que abriu o pendente, confere, e so entao
    /// apaga o pendente.
    private func promotePendingLocked(rk: SecureBytes, pin: SecureBytes) throws {
        if store.probe(Account.rootByPIN) == .present {
            try store.delete(Account.rootByPIN)
        }
        try writePINSlot(rk: rk, pin: pin, kdf: pinParameters, suffix: "")
        try confirm(pin: pin, suffix: "", matches: rk)
        deleteSlot(suffix: Account.pendingSuffix)
    }

    private func deleteSlot(suffix: String) {
        try? store.delete(Account.rootByPIN + suffix)
        try? store.delete(Account.pinKDF + suffix)
    }

    private func confirm(pin: SecureBytes, suffix: String, matches rk: SecureBytes) throws {
        let check = try readPINSlot(pin: pin, suffix: suffix)
        defer { check.wipe() }
        guard Hash.constantTimeEqual(check, rk) else { throw Failure.storage }
    }

    // MARK: Apagar

    /// Quantos PINs errados apagam tudo; nil e nunca. O registro antigo (um byte 1)
    /// valia 10.
    public var wipeThreshold: UInt32? {
        guard let data = try? store.read(Account.wipeAfterErrors, context: nil), data.count == 1 else { return nil }
        let value = UInt32(data[data.startIndex])
        if value == 1 { return 10 }
        return PINPolicy.wipeOptions.contains(value) ? value : nil
    }

    public var wipeAfterErrorsEnabled: Bool { wipeThreshold != nil }

    /// Liga com um dos limites de `PINPolicy.wipeOptions`, ou desliga com nil.
    public func setWipeAfterErrors(_ threshold: UInt32?) throws {
        if let threshold, !PINPolicy.wipeOptions.contains(threshold) { throw Failure.storage }
        do {
            try store.delete(Account.wipeAfterErrors)
            if let threshold {
                try store.add(Data([UInt8(threshold)]), account: Account.wipeAfterErrors, protection: .standard, context: nil)
            }
        } catch {
            throw Failure.storage
        }
    }

    /// Destruicao criptografica: as chaves do SE e os slots da RK primeiro (em
    /// milissegundos todo embrulho vira ruido), depois o resto.
    public func wipeAll() {
        lock.lock(); defer { lock.unlock() }
        wipeAllLocked()
    }

    private func wipeAllLocked() {
        wrapper.deleteKey(.device)
        wrapper.deleteKey(.biometry)
        try? store.delete(Account.rootByPIN)
        try? store.delete(Account.rootByPIN + Account.pendingSuffix)
        try? store.delete(Account.rootByBiometry)
        try? store.deleteAll()
    }

    // MARK: Interno

    private func readAttempts() throws -> AttemptRecord? {
        guard let data = try store.read(Account.attempts, context: nil) else { return nil }
        guard let record = AttemptRecord(data) else { throw Failure.storage }
        return record
    }

    /// O registro atual, com o prazo regravado se ele veio de outro boot. So chamado
    /// de caminhos que ja gravam. Registro ausente com slot presente e recriado: quem
    /// consegue apagar item do chaveiro deste app ja executa codigo aqui dentro, e o
    /// contador nunca foi barreira contra isso.
    private func rebasedAttemptsLocked() throws -> AttemptRecord {
        let current: AttemptRecord?
        do { current = try readAttempts() } catch { throw Failure.storage }
        guard var record = current else {
            do {
                try store.add(AttemptRecord.zero.encoded, account: Account.attempts, protection: .standard, context: nil)
            } catch {
                throw Failure.storage
            }
            return .zero
        }
        if record.isFromAnotherBoot {
            record = AttemptRecord.after(failures: record.failures)
            do { try store.update(record.encoded, account: Account.attempts) } catch { throw Failure.storage }
        }
        return record
    }

    /// Grava um slot do PIN. Pre-condicao: o slot nao existe. O registro de custo e
    /// gravado antes e desfeito se o slot falhar, para nunca sobrar um slot sem custo.
    func writePINSlot(rk: SecureBytes, pin: SecureBytes, kdf: KDFParameters, suffix: String) throws {
        guard store.probe(Account.rootByPIN + suffix) == .absent else { throw Failure.storage }
        let saltBytes = try SecureBytes.random(count: VaultFormat.saltLength)
        let salt = saltBytes.withUnsafeBytes { Array($0) }
        let ap = try KeyDerivation.deriveMasterKey(password: pin, salt: salt, parameters: kdf)
        defer { ap.wipe() }

        let inner = try Self.sealInner(rk, ap: ap, salt: salt)
        defer { inner.wipe() }
        let blob = try wrapper.wrap(inner, slot: .device)

        var kdfRecord = salt
        kdfRecord += kdf.memoryKiB.bigEndianByteArray + kdf.passes.bigEndianByteArray + [kdf.lanes]
        try? store.delete(Account.pinKDF + suffix)
        try store.add(Data(kdfRecord), account: Account.pinKDF + suffix, protection: .standard, context: nil)
        do {
            let context = try store.applicationPasswordContext(ap)
            try store.add(blob, account: Account.rootByPIN + suffix, protection: .applicationPassword, context: context)
        } catch {
            try? store.delete(Account.pinKDF + suffix)
            throw error
        }
    }

    private func readPINSlot(pin: SecureBytes, suffix: String) throws -> SecureBytes {
        guard let record = try store.read(Account.pinKDF + suffix, context: nil), record.count == 25 else {
            throw Failure.storage
        }
        let bytes = [UInt8](record)
        let salt = Array(bytes[0..<16])
        let memory = bytes[16..<20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let passes = bytes[20..<24].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let ap = try KeyDerivation.deriveMasterKey(
            password: pin, salt: salt,
            parameters: KDFParameters(memoryKiB: memory, passes: passes, lanes: bytes[24])
        )
        defer { ap.wipe() }

        let blob: Data?
        do {
            blob = try store.read(Account.rootByPIN + suffix, context: store.applicationPasswordContext(ap))
        } catch StoreError.authenticationFailed {
            throw Failure.wrongPIN(remainingBeforeWipe: nil)
        }
        guard let blob else { throw Failure.notSetUp }
        let inner = try wrapper.unwrap(blob, slot: .device, reason: nil)
        defer { inner.wipe() }
        return try Self.openInner(inner, ap: ap, salt: salt)
    }

    static func innerKey(ap: SecureBytes, salt: [UInt8]) -> SymmetricKey {
        let material = ap.withUnsafeBytes { SymmetricKey(data: $0) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Inner.info, outputByteCount: 32)
    }

    static func sealInner(_ rk: SecureBytes, ap: SecureBytes, salt: [UInt8]) throws -> SecureBytes {
        let key = innerKey(ap: ap, salt: salt)
        let box = try rk.withUnsafeData { try ChaChaPoly.seal($0, using: key, authenticating: Inner.info) }
        let out = SecureBytes(capacity: Inner.length)
        out.append(Inner.version)
        box.combined.withUnsafeBytes { out.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        return out
    }

    /// Falha de autenticacao na camada interna e PIN errado: o chaveiro deixou passar
    /// (senha de aplicativo so como regra de acesso), mas a chave do PIN nao confere.
    static func openInner(_ inner: SecureBytes, ap: SecureBytes, salt: [UInt8]) throws -> SecureBytes {
        guard inner.count == Inner.length else { throw Failure.storage }
        let key = innerKey(ap: ap, salt: salt)
        let parsed: (version: UInt8, box: ChaChaPoly.SealedBox)? = inner.withUnsafeBytes { raw in
            guard let box = try? ChaChaPoly.SealedBox(combined: Data(raw[1...])) else { return nil }
            return (raw[0], box)
        }
        guard let parsed, parsed.version == Inner.version else { throw Failure.storage }
        var plain: Data
        do {
            plain = try ChaChaPoly.open(parsed.box, using: key, authenticating: Inner.info)
        } catch {
            throw Failure.wrongPIN(remainingBeforeWipe: nil)
        }
        let rk = SecureBytes(capacity: 32)
        plain.withUnsafeMutableBytes { raw in
            rk.append(contentsOf: raw.bindMemory(to: UInt8.self).withMemoryRebound(to: UInt8.self) { UnsafeBufferPointer($0) })
            if let base = raw.baseAddress { memset_s(base, raw.count, 0, raw.count) }
        }
        return rk
    }

    /// A forma do PIN (6 digitos), sem deixar copia deles para tras.
    public static func isWellFormed(_ pin: SecureBytes) -> Bool {
        var digits = pin.withUnsafeBytes { raw in raw.map { $0 &- 0x30 } }
        defer { digits.withUnsafeMutableBytes { if let base = $0.baseAddress { memset_s(base, $0.count, 0, $0.count) } } }
        return PINPolicy.isWellFormed(digits)
    }

    /// AP = Argon2id(PIN, 256 MiB, p=2, t ate cerca de 0,8 s). E o custo que o
    /// atacante com execucao de codigo no aparelho paga a cada chute: sem ele, 10^6
    /// PINs sairiam em horas.
    public static func calibratedPINParameters() -> KDFParameters {
        let memory: UInt32 = 256 * 1024
        let lanes: UInt8 = 2
        for passes: UInt32 in [4, 3, 2] {
            let estimate = KDFCalibration.estimatedSeconds(for: KDFParameters(memoryKiB: memory, passes: passes, lanes: lanes))
            if estimate <= 0.8 { return KDFParameters(memoryKiB: memory, passes: passes, lanes: lanes) }
        }
        return KDFParameters(memoryKiB: memory, passes: 2, lanes: lanes)
    }
}
