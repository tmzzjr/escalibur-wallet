import CryptoKit
import EscaliburCore
import Foundation
import LocalAuthentication

/// A chave raiz (RK) e os dois caminhos que a destrancam: PIN e biometria.
///
/// ```
/// PIN ─Argon2id─► AP ─┬─(senha de aplicativo do item)─► item rk.pin
///                     ├─HKDF─► senha da chave do PIN no SE
///                     └─HKDF─► K_pin
/// item rk.pin = embrulho(chave do PIN no SE, ChaChaPoly(K_pin, RK)) ─SE+senha─► ─K_pin─► RK
/// Face ID (decisao no SEP) ─► item rk.bio = embrulho(K_bio, RK) ─SE─► RK
/// ```
///
/// Formato 2 do slot (auditoria 3, A1): a chave do SE que embrulha o slot tem senha de
/// aplicativo derivada do PIN, entao o SE so desembrulha com o PIN certo. Quem tirar uma
/// copia do slot nao consegue mais testar PINs fora do aparelho depois de uma unica
/// chamada ao SE: cada chute passa pelo SE deste iPhone, mais um Argon2id. O formato 1
/// (chave do aparelho sem senha) migra no primeiro PIN certo.
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
        /// Nao sao 4 nem 6 digitos de 0 a 9.
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
        /// O Face ID caiu ou foi religado ha pouco: ver as palavras, lacrar o envelope e
        /// remover carteira esperam `seconds` (`PINPolicy.biometryLossHold`).
        case biometryHold(seconds: TimeInterval)
        /// O Face ID caiu sem o dono pedir e ainda nao foi religado: o que pede PIN e rosto
        /// fica recusado ate religar (e a espera conta a partir dai). Nunca volta sozinho a
        /// pedir so o PIN.
        case biometryRequired
        /// O Face ID nao esta disponivel agora (tirado do app, Espelhamento do iPhone, falha
        /// passageira do sistema). Nada e apagado; o que pede PIN e rosto recusa.
        case biometryUnavailable
        case storage
        /// Modo reforcado ligado: o caminho e `unlockHardened`, nunca o PIN so nem o rosto so.
        case hardenedModeActive
        case notHardened
        /// Modo reforcado: o rosto nao confirmou. Contou como tentativa.
        case biometryNotConfirmed(remainingBeforeWipe: UInt32?)
        /// O Face ID esta bloqueado pelo sistema (5 erros): nada foi tentado nem contado.
        case biometryLockedOut
        /// Modo reforcado: o cadastro de rostos mudou (ou a chave do SE sumiu) e o rk.and nao
        /// abre mais. Nada foi apagado; o caminho e restaurar pelas palavras.
        case hardenedSlotLost
        case hardenedBlocked(HardenedBlocker)
    }

    /// O que impede ligar o modo reforcado agora.
    public enum HardenedBlocker: Sendable, Equatable { case biometryOff, changePending, legacySlot, biometryUnavailable }

    enum Account {
        static let pinKDF = "pin.kdf"
        /// Quantos digitos tem o PIN do slot (1 byte), para a tela saber quando o PIN
        /// acabou sem gastar tentativa. Sem o item, 6: o tamanho de antes da escolha.
        static let pinLength = "pin.digitos"
        static let rootByPIN = "rk.pin"
        static let rootByBiometry = "rk.bio"
        static let biometryState = "bio.estado"
        /// O prazo da espera depois que o Face ID caiu ou foi religado (`HoldRecord`).
        static let biometryHold = "bio.espera"
        /// O Face ID caiu sem o dono pedir e ainda nao foi religado (1 byte). Sem prazo: so
        /// um `enableBiometry` que confere o rosto tira a marca.
        static let biometryLost = "bio.perdido"
        static let attempts = "pin.tentativas"
        static let wipeAfterErrors = "pin.apagar"
        static let pinBoot = "pin.boot"
        static let pendingSuffix = ".novo"
        /// Modo reforcado: o slot unico, PIN e rosto em camadas (docs/seguranca.md §2.6).
        static let rootHardened = "rk.and"
        /// O hash do cadastro de rostos ao ligar o modo reforcado: so classifica o erro.
        static let hardenedState = "and.estado"
    }

    /// O registro de custo do slot: sal (16), memoria (4), passadas (4), faixas (1) e, no
    /// formato 2, a versao (1).
    enum SlotFormat {
        static let legacyLength = 25
        static let version: UInt8 = 2
        static let length = 26
        static let passwordInfo = Data("escalibur-wallet/v2/kpin.senha".utf8)
    }

    /// A chave do SE de cada slot do PIN no formato 2.
    static func wrapSlot(_ suffix: String) -> WrapSlot { suffix.isEmpty ? .pin : .pinPending }

    /// A senha de aplicativo da chave do PIN no SE: derivada do AP, separada da chave da
    /// camada interna pelo `info`.
    static func devicePassword(ap: SecureBytes, salt: [UInt8]) -> Data {
        let material = ap.withUnsafeBytes { SymmetricKey(data: $0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: SlotFormat.passwordInfo, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// Camada interna do slot do PIN: versao, nonce (12), RK cifrada (32), tag (16).
    enum Inner {
        static let version: UInt8 = 1
        static let length = 1 + 12 + 32 + 16
        static let info = Data("escalibur-wallet/v1/rk.pin".utf8)
    }

    let store: any SecretStore
    let wrapper: any KeyWrapper
    /// O Face ID deste iPhone agora. Trocavel so nos testes, que rodam num Mac sem ele.
    var biometryAvailability: @Sendable () -> BiometryAvailability = { RootKeyVault.systemBiometryAvailability() }
    /// O Face ID para o modo reforcado e o hash do cadastro. Trocaveis so nos testes.
    var hardenedBiometryStatus: @Sendable () -> BiometryStatus = { RootKeyVault.systemBiometryStatus() }
    var hardenedDomainState: @Sendable () -> Data? = { RootKeyVault.biometryDomainState() }
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
        let slots = [Account.rootByPIN, Account.rootByPIN + Account.pendingSuffix, Account.rootHardened].map(store.probe)
        return slots.contains(.present) || slots.contains(.unknown)
    }

    // MARK: Cadastro

    /// Primeiro PIN: cria K_dev, sorteia a RK, grava o slot do PIN e confere lendo de
    /// volta. Devolve a RK aberta, para o chamador derivar a chave de indice e criar a
    /// primeira carteira sem pedir o PIN de novo; quem recebe zera.
    public func setUp(pin: SecureBytes) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        let slots = [Account.rootByPIN, Account.rootByPIN + Account.pendingSuffix, Account.rootByBiometry, Account.rootHardened].map(store.probe)
        guard !slots.contains(.unknown) else { throw Failure.storage }
        guard !slots.contains(.present) else { throw Failure.alreadySetUp }
        guard Self.isWellFormed(pin) else { throw Failure.malformedPIN }

        // Sem nenhum slot da RK, o que sobrou de um cadastro interrompido nao abre
        // nada: a K_dev orfa, o contador e as carteiras cifradas sob uma RK perdida.
        // Apagar aqui e explicito; `createKey` nunca substitui a K_dev sozinho.
        try discardOrphans()

        let rk = try SecureBytes.random(count: 32)
        do {
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
        WrapSlot.allCases.forEach(wrapper.deleteKey)
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
        return try unlockLocked(pin: pin)
    }

    private func unlockLocked(pin: SecureBytes) throws -> SecureBytes {
        switch securityMode {
        case .hardened: throw Failure.hardenedModeActive
        case .unknown: throw Failure.storage
        case .normal: break
        }
        let pendingAccount = Account.rootByPIN + Account.pendingSuffix
        let main = store.probe(Account.rootByPIN)
        let pending = store.probe(pendingAccount)
        guard main != .unknown, pending != .unknown else { throw Failure.storage }
        guard main == .present || pending == .present else { throw Failure.notSetUp }

        // PIN sem forma (envio duplo com o buffer vazio) nunca gasta tentativa.
        guard Self.isWellFormed(pin) else { throw Failure.malformedPIN }
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
        // Um rk.and ao lado do rk.pin e uma transicao que nao chegou ao fim (ligar
        // interrompido antes do commit, ou desligar interrompido depois do rk.pin gravado).
        // O PIN acabou de provar o slot do modo normal: o rk.and sai.
        if store.probe(Account.rootHardened) == .present { discardHardenedLocked() }
        if pending == .present {
            if opened.suffix.isEmpty {
                deleteSlot(suffix: Account.pendingSuffix)
            } else {
                try? promotePendingLocked(rk: opened.rk, pin: pin)
            }
        }
        // Slot no formato 1: passa para o 2 agora que o PIN certo esta na mao. Falha aqui
        // nao tranca ninguem: antes do ponto sem volta o slot antigo continua o unico.
        if slotVersion(suffix: "") == 1 {
            try? migrateLocked(rk: opened.rk, pin: pin)
        } else {
            dropLegacyKeyIfDone()
        }
        return opened.rk
    }

    /// Com o principal no formato 2 e nenhuma troca pendente, a chave do aparelho antiga
    /// nao abre mais nada: sai.
    private func dropLegacyKeyIfDone() {
        guard slotVersion(suffix: "") == 2, store.probe(Account.rootByPIN + Account.pendingSuffix) == .absent,
              wrapper.hasKey(.device) else { return }
        wrapper.deleteKey(.device)
    }

    /// O formato do slot principal do PIN (1 ou 2), para a tela e os testes. So le.
    public var pinSlotFormat: Int? { slotVersion(suffix: "") }

    /// Quantos digitos pode ter o PIN que abre: o tamanho de cada slot que existe. Quase
    /// sempre um so; dois quando uma troca entre tamanhos diferentes foi interrompida antes
    /// do ponto sem volta (o PIN antigo desfaz, o novo conclui, e a tela aceita os dois).
    /// Sem o registro, 6 (slot de antes da escolha). Chaveiro mudo ou registro estranho:
    /// os dois tamanhos, nunca um chute, para a tela nao gastar tentativa fechando no
    /// tamanho errado. Nao e segredo (o iPhone tambem mostra quantos pontos o codigo tem).
    /// So le.
    public var pinLengths: Set<Int> {
        switch securityMode {
        case .unknown: return Set(PINPolicy.lengths)
        case .hardened:
            guard let (header, _) = try? readHardened() else { return Set(PINPolicy.lengths) }
            return [Int(header.pinLength)]
        case .normal: break
        }
        var lengths = Set<Int>()
        for suffix in ["", Account.pendingSuffix] {
            switch store.probe(Account.rootByPIN + suffix) {
            case .absent: continue
            case .unknown: return Set(PINPolicy.lengths)
            case .present:
                guard let length = slotLength(suffix: suffix) else { return Set(PINPolicy.lengths) }
                lengths.insert(length)
            }
        }
        return lengths.isEmpty ? [PINPolicy.digits] : lengths
    }

    private func slotLength(suffix: String) -> Int? {
        switch store.probe(Account.pinLength + suffix) {
        case .absent: return PINPolicy.digits
        case .unknown: return nil
        case .present:
            guard let data = try? store.read(Account.pinLength + suffix, context: nil), data.count == 1,
                  PINPolicy.lengths.contains(Int(data[0])) else { return nil }
            return Int(data[0])
        }
    }

    /// O formato do slot: 1 (chave do aparelho sem senha), 2 (chave do PIN com senha) ou
    /// nil (sem slot, registro ilegivel).
    func slotVersion(suffix: String) -> Int? {
        guard let record = try? store.read(Account.pinKDF + suffix, context: nil) else { return nil }
        if record.count == SlotFormat.legacyLength { return 1 }
        if record.count == SlotFormat.length, record.last == SlotFormat.version { return 2 }
        return nil
    }

    /// Formato 1 para 2 com o mesmo PIN, pelo mesmo caminho atomico da troca de PIN: o
    /// slot novo e gravado e conferido como pendente, o antigo so sai depois, e a chave
    /// do aparelho antiga so e apagada com o principal novo conferido.
    private func migrateLocked(rk: SecureBytes, pin: SecureBytes) throws {
        try replacePINLocked(rk: rk, newPIN: pin)
        dropLegacyKeyIfDone()
    }

    /// Destranca pelo Face ID. Bloqueia a thread enquanto o sistema pergunta: chamar
    /// fora do MainActor. O que autoriza e o SEP liberar a chave, nunca um booleano.
    public func unlockWithBiometry(reason: String) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        return try unlockWithBiometryLocked(reason: reason)
    }

    /// Sob a trava: uma varredura do modo reforcado rodando ao lado de uma troca de PIN
    /// apagaria a geracao nova da chave do PIN (revisao do modo reforcado, M2). No
    /// reforcado so recusa; quem varre e `rebaseAttempts` e `unlockHardened`, sob a trava.
    private func unlockWithBiometryLocked(reason: String) throws -> SecureBytes {
        switch securityMode {
        case .hardened: throw Failure.hardenedModeActive
        case .unknown: throw Failure.storage
        case .normal: break
        }
        guard pinEnteredThisBoot else { throw Failure.pinRequiredAfterRestart }
        let blob: Data?
        do { blob = try store.read(Account.rootByBiometry, context: nil) } catch { throw Failure.storage }
        guard let blob else { throw Failure.biometryNotEnabled }
        guard wrapper.hasKey(.biometry) else {
            try biometryLost()
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
                try biometryLost()
                throw Failure.biometryChanged
            }
            throw Failure.cancelled
        }
        // O contador de PIN nao zera aqui: quem apresenta o rosto do dono a forca nao
        // ganha chutes de PIN de graca a cada Face ID (auditoria 2, B4). So o PIN certo zera.
        // A ancora do boot acompanha a oscilacao do kern.boottime: ainda e o mesmo boot
        // (conferido acima), so com o instante lido agora.
        recordPINThisBoot()
        return rk
    }

    /// A1: o que entrega ou destroi a carteira inteira (ver as palavras, lacrar o
    /// envelope, remover, desligar o Face ID) pede o PIN e, com o Face ID ligado, o rosto
    /// tambem. Quem viu o PIN e pegou o iPhone nao leva a frase; quem apresenta o rosto do
    /// dono a forca tambem nao. Sem o Face ID ligado, so o PIN.
    ///
    /// O PIN vem primeiro e conta tentativa como em `unlock`; o rosto e decidido no SEP,
    /// pelo slot da biometria, e as duas chaves raiz tem de ser a mesma. Nenhum dos dois
    /// caminhos cai para o codigo do iPhone.
    ///
    /// O Face ID que cai sem o dono pedir (cadastro de rostos mudou, Face ID tirado do app
    /// ou do iPhone) apaga o slot e comeca a espera de `PINPolicy.biometryLossHold`:
    /// durante ela, isto recusa antes de pedir qualquer coisa, mesmo com um Face ID
    /// religado. Sem a espera, o ladrao que viu o codigo do iPhone cadastrava o proprio
    /// rosto e passava com o PIN so. Chaveiro mudo recusa: nunca vira "Face ID desligado".
    public func unlockWithPINAndBiometry(pin: SecureBytes, reason: String) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        return try unlockWithPINAndBiometryLocked(pin: pin, reason: reason)
    }

    private func unlockWithPINAndBiometryLocked(pin: SecureBytes, reason: String) throws -> SecureBytes {
        try checkPINAndBiometryAllowed()
        let slot = store.probe(Account.rootByBiometry)
        guard slot != .unknown else { throw Failure.storage }

        let rk = try unlockLocked(pin: pin)
        guard slot == .present else { return rk }
        do {
            // Face ID indisponivel agora nao e Face ID perdido: nada e apagado, e isto recusa
            // (revisao do A1: uma falha passageira, ou o Espelhamento, derrubava o slot).
            if biometryAvailability() == .gone { throw Failure.biometryUnavailable }
            let check = try unlockWithBiometryLocked(reason: reason)
            defer { check.wipe() }
            guard Hash.constantTimeEqual(check, rk) else { throw Failure.storage }
            return rk
        } catch {
            rk.wipe()
            throw error
        }
    }

    /// Quanto falta da espera do A1, para a tela avisar antes de pedir o PIN. Chaveiro mudo
    /// ou registro ilegivel: a espera cheia, nunca zero. So le.
    public var biometryHoldRemaining: TimeInterval {
        (try? biometryHoldRemainingChecked()) ?? PINPolicy.biometryLossHold
    }

    /// O que pede PIN e rosto pode ser tentado agora? Recusa na espera, e com o Face ID
    /// perdido e nao religado. Para a tela perguntar antes do PIN e da voz; o cofre confere
    /// de novo em `unlockWithPINAndBiometry`.
    public func checkPINAndBiometryAllowed() throws {
        // No reforcado nao existe slot do rosto do modo normal: a espera e a marca do A1
        // nao valem (e a varredura as apaga).
        guard securityMode != .hardened else { return }
        let hold = try biometryHoldRemainingChecked()
        guard hold <= 0 else { throw Failure.biometryHold(seconds: hold) }
        switch store.probe(Account.biometryLost) {
        case .unknown: throw Failure.storage
        case .present: throw Failure.biometryRequired
        case .absent: break
        }
    }

    /// A espera que falta. Vencida, o registro sai. Ilegivel vale a espera cheia, e a
    /// abertura do app o regrava a partir de agora (`rebaseHoldLocked`).
    private func biometryHoldRemainingChecked() throws -> TimeInterval {
        switch store.probe(Account.biometryHold) {
        case .absent: return 0
        case .unknown: throw Failure.storage
        case .present:
            guard let data = try? store.read(Account.biometryHold, context: nil), let record = HoldRecord(data) else {
                return PINPolicy.biometryLossHold
            }
            let remaining = record.remaining()
            if remaining <= 0 { try? store.delete(Account.biometryHold) }
            return remaining
        }
    }

    /// O Face ID caiu sem o dono pedir: a espera e a marca de perdido sao gravadas
    /// primeiro, e so entao o slot sai. Se uma delas nao gravar, o slot fica: o rosto
    /// continua sem abrir, e o que pede PIN e rosto continua travado, em vez de passar com
    /// o PIN so.
    private func biometryLost() throws {
        try startHold()
        if store.probe(Account.biometryLost) != .present {
            try? store.add(Data([1]), account: Account.biometryLost, protection: .standard, context: nil)
        }
        guard store.probe(Account.biometryLost) == .present else { throw Failure.storage }
        dropBiometrySlot()
    }

    private func startHold() throws {
        let record = HoldRecord.startingNow().encoded
        if (try? store.update(record, account: Account.biometryHold)) == nil {
            try? store.add(record, account: Account.biometryHold, protection: .standard, context: nil)
        }
        guard store.probe(Account.biometryHold) == .present else { throw Failure.storage }
    }

    /// Depois de reiniciar, o prazo da espera gravado com o relogio monotonico antigo nao
    /// vale mais: recomeca cheio a partir de agora, como o das tentativas. Registro
    /// ilegivel tambem.
    private func rebaseHoldLocked() {
        guard store.probe(Account.biometryHold) == .present else { return }
        let record = (try? store.read(Account.biometryHold, context: nil)).flatMap { HoldRecord($0) }
        guard record == nil || record?.isFromAnotherBoot == true else { return }
        try? store.update(HoldRecord.startingNow().encoded, account: Account.biometryHold)
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
        rebaseHoldLocked()
        sweepHardenedLocked()
        // O slot do rosto sem a chave do SE (cadastro de rostos trocado): a queda conta a
        // partir de quando o app a ve, nao de quando alguem resolve usar o Face ID.
        if securityMode == .normal, store.probe(Account.rootByBiometry) == .present, !wrapper.hasKey(.biometry) { try? biometryLost() }
    }

    // MARK: Biometria

    /// O PIN foi digitado neste boot? Depois de reiniciar, o Face ID espera o PIN.
    public var pinEnteredThisBoot: Bool {
        guard let saved = try? store.read(Account.pinBoot, context: nil) else { return false }
        return PINPolicy.pinRecordValid([UInt8](saved), boot: PINPolicy.bootSession, uptime: PINPolicy.uptime)
    }

    private func recordPINThisBoot() {
        let current = Data(PINPolicy.pinRecord(boot: PINPolicy.bootSession, uptime: PINPolicy.uptime))
        if (try? store.update(current, account: Account.pinBoot)) == nil {
            try? store.add(current, account: Account.pinBoot, protection: .standard, context: nil)
        }
    }

    /// O slot do rosto existe (ou o chaveiro nao sabe dizer). A chave do SE pode ter
    /// sumido: e o primeiro uso do Face ID que descobre e comeca a espera. Antes era
    /// "slot e chave", e com a chave invalidada por um rosto novo o app mostrava o Face ID
    /// desligado, e religar sobrescrevia o slot do dono sem espera (revisao do A1).
    public var isBiometryEnabled: Bool { securityMode != .hardened && store.probe(Account.rootByBiometry) != .absent }

    /// Liga o Face ID e confere na hora: o slot novo tem de abrir com o rosto e devolver a
    /// mesma RK. Exige a RK aberta, ou seja, o PIN digitado agora.
    ///
    /// Religar por cima de um slot que existe conta como queda, e religar depois de uma
    /// queda comeca a espera do A1 a partir de agora: quem cadastrou o proprio rosto no
    /// iPhone nao ve a frase na hora so por ligar o Face ID com o PIN. O primeiro Face ID
    /// de um cofre que nunca o teve nao espera: antes dele, o PIN ja abria tudo.
    public func enableBiometry(rk: SecureBytes, reason: String = "") throws {
        guard securityMode == .normal else { throw Failure.hardenedModeActive }
        let slot = store.probe(Account.rootByBiometry)
        let lost = store.probe(Account.biometryLost)
        guard slot != .unknown, lost != .unknown else { throw Failure.storage }
        if slot == .present { try biometryLost() }
        let restarted = slot == .present || lost == .present

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
            dropBiometrySlot()
            throw Failure.storage
        }
        // A conferencia: sem ela o dono descobriria que o atalho nao funciona no dia em que
        // precisasse. Falhou, o slot novo sai, e a marca de perdido (se havia) fica.
        do {
            let check = try wrapper.unwrap(blob, slot: .biometry, reason: reason)
            defer { check.wipe() }
            guard Hash.constantTimeEqual(check, rk) else { throw Failure.storage }
        } catch {
            dropBiometrySlot()
            throw error is Failure ? error : Failure.cancelled
        }
        // Religar depois de uma queda: a espera comeca e a marca sai, nessa ordem e
        // conferidas. Se uma das duas falhar, o slot novo sai e a marca fica: o dono tenta
        // de novo, em vez de ficar com o Face ID ligado e o que pede os dois recusado para
        // sempre (segunda revisao do A1).
        if restarted {
            do {
                try startHold()
                try? store.delete(Account.biometryLost)
                guard store.probe(Account.biometryLost) == .absent else { throw Failure.storage }
            } catch {
                dropBiometrySlot()
                throw Failure.storage
            }
        }
    }

    /// Desliga o Face ID pelo dono: pede o PIN e o rosto (A1), porque com ele desligado o
    /// que pedia os dois passa a pedir so o PIN. Nunca toca o slot do PIN.
    public func disableBiometry(pin: SecureBytes, reason: String) throws {
        let rk = try unlockWithPINAndBiometry(pin: pin, reason: reason)
        rk.wipe()
        dropBiometrySlot()
    }

    /// Tira o slot do rosto e a chave dele, sem pedir nada: so por dentro do cofre (queda,
    /// ligar que nao conferiu, desligar depois do PIN e do rosto).
    func dropBiometrySlot() {
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

    /// O Face ID deste iPhone visto pelo app agora: sem rosto cadastrado ou tirado do app
    /// (`gone`), ou presente, inclusive no bloqueio temporario do sistema e em qualquer
    /// motivo que nao se sabe: nada e apagado por duvida.
    public enum BiometryAvailability: Sendable { case available, gone }

    static func systemBiometryAvailability() -> BiometryAvailability {
        let context = LAContext()
        defer { context.invalidate() }
        var error: NSError?
        guard !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error), let error,
              error.domain == LAError.errorDomain else { return .available }
        switch LAError.Code(rawValue: error.code) {
        case .biometryNotEnrolled?, .biometryNotAvailable?: return .gone
        default: return .available
        }
    }

    // MARK: Troca de PIN

    /// Troca atomica. O slot novo e gravado com sufixo e conferido; o ponto sem volta
    /// e apagar o slot antigo. Antes dele, qualquer falha desfaz a troca e o PIN antigo
    /// continua o unico. Depois dele, a troca esta feita: o slot pendente abre com o
    /// PIN novo, e se a promocao a principal falhar aqui, o proximo desbloqueio a
    /// conclui. Em nenhum instante o dono fica sem um slot que abre.
    public func changePIN(rk: SecureBytes, newPIN: SecureBytes) throws {
        lock.lock(); defer { lock.unlock() }
        try replacePINLocked(rk: rk, newPIN: newPIN)
        dropLegacyKeyIfDone()
    }

    private func replacePINLocked(rk: SecureBytes, newPIN: SecureBytes) throws {
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
        try? store.delete(Account.pinLength)
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
        try? store.delete(Account.pinLength + suffix)
        // A chave do SE do slot pendente vai junto; a do principal, nunca aqui: so a
        // gravacao de um principal novo a substitui.
        if !suffix.isEmpty { wrapper.deleteKey(.pinPending) }
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
        WrapSlot.allCases.forEach(wrapper.deleteKey)
        try? store.delete(Account.rootHardened)
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
        // Formato 2: a chave do SE deste slot so desembrulha com a senha derivada do PIN.
        let slot = Self.wrapSlot(suffix)
        try wrapper.createKey(slot, password: Self.devicePassword(ap: ap, salt: salt))
        let blob: Data
        do {
            blob = try wrapper.wrap(inner, slot: slot)
        } catch {
            wrapper.deleteKey(slot)
            throw error
        }

        var kdfRecord = salt
        kdfRecord += kdf.memoryKiB.bigEndianByteArray + kdf.passes.bigEndianByteArray + [kdf.lanes]
        kdfRecord.append(SlotFormat.version)
        try? store.delete(Account.pinKDF + suffix)
        try? store.delete(Account.pinLength + suffix)
        do {
            // O tamanho vai antes do slot e sai junto se ele falhar: nunca existe um slot
            // de 4 digitos que a tela trate como de 6.
            try store.add(Data([UInt8(pin.count)]), account: Account.pinLength + suffix, protection: .standard, context: nil)
            try store.add(Data(kdfRecord), account: Account.pinKDF + suffix, protection: .standard, context: nil)
            let context = try store.applicationPasswordContext(ap)
            try store.add(blob, account: Account.rootByPIN + suffix, protection: .applicationPassword, context: context)
        } catch {
            try? store.delete(Account.pinKDF + suffix)
            try? store.delete(Account.pinLength + suffix)
            wrapper.deleteKey(slot)
            throw error
        }
    }

    /// So para os testes da migracao: grava um slot no formato 1 (chave do aparelho sem
    /// senha), como as versoes anteriores gravavam.
    func writeLegacyPINSlot(rk: SecureBytes, pin: SecureBytes, kdf: KDFParameters) throws {
        if !wrapper.hasKey(.device) { try wrapper.createKey(.device) }
        let saltBytes = try SecureBytes.random(count: VaultFormat.saltLength)
        let salt = saltBytes.withUnsafeBytes { Array($0) }
        let ap = try KeyDerivation.deriveMasterKey(password: pin, salt: salt, parameters: kdf)
        defer { ap.wipe() }
        let inner = try Self.sealInner(rk, ap: ap, salt: salt)
        defer { inner.wipe() }
        let blob = try wrapper.wrap(inner, slot: .device)
        var kdfRecord = salt
        kdfRecord += kdf.memoryKiB.bigEndianByteArray + kdf.passes.bigEndianByteArray + [kdf.lanes]
        try store.add(Data(kdfRecord), account: Account.pinKDF, protection: .standard, context: nil)
        try store.add(blob, account: Account.rootByPIN, protection: .applicationPassword, context: store.applicationPasswordContext(ap))
        if store.probe(Account.attempts) == .absent {
            try store.add(AttemptRecord.zero.encoded, account: Account.attempts, protection: .standard, context: nil)
        }
    }

    private func readPINSlot(pin: SecureBytes, suffix: String) throws -> SecureBytes {
        guard let record = try store.read(Account.pinKDF + suffix, context: nil),
              record.count == SlotFormat.legacyLength || (record.count == SlotFormat.length && record.last == SlotFormat.version)
        else {
            throw Failure.storage
        }
        let version = record.count == SlotFormat.length ? 2 : 1
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
        let inner: SecureBytes
        if version == 2 {
            do {
                inner = try wrapper.unwrap(blob, slot: Self.wrapSlot(suffix), password: Self.devicePassword(ap: ap, salt: salt))
            } catch EnclaveError.wrongPassword {
                throw Failure.wrongPIN(remainingBeforeWipe: nil)
            }
        } else {
            inner = try wrapper.unwrap(blob, slot: .device, reason: nil)
        }
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

    /// A forma do PIN (4 ou 6 digitos), sem deixar copia deles para tras.
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

// MARK: - Modo reforcado

/// Cabecalho do rk.and, em claro e autenticado como AAD da camada interna.
/// versao (1) | digitos (1) | chave do PIN (1: 0 = a, 1 = b) | sal (16) | memoria (4) |
/// passadas (4) | faixas (1) = 28 bytes.
struct HardenedHeader: Equatable {
    static let version: UInt8 = 3
    static let length = 28
    static let aadInfo = Array("escalibur-wallet/v3/rk.and".utf8)
    static let passwordInfo = Data("escalibur-wallet/v3/kand.senha".utf8)
    static let innerInfo = Data("escalibur-wallet/v3/rk.and.interna".utf8)

    var pinLength: UInt8
    var pinKey: WrapSlot
    var salt: [UInt8]
    var kdf: KDFParameters

    var encoded: [UInt8] {
        [Self.version, pinLength, pinKey == .hardenedPINA ? 0 : 1] + salt
            + kdf.memoryKiB.bigEndianByteArray + kdf.passes.bigEndianByteArray + [kdf.lanes]
    }

    var aad: Data { Data(Self.aadInfo + encoded) }

    init(pinLength: UInt8, pinKey: WrapSlot, salt: [UInt8], kdf: KDFParameters) {
        self.pinLength = pinLength
        self.pinKey = pinKey
        self.salt = salt
        self.kdf = kdf
    }

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= Self.length, bytes[0] == Self.version,
              PINPolicy.lengths.contains(Int(bytes[1])), bytes[2] <= 1 else { return nil }
        pinLength = bytes[1]
        pinKey = bytes[2] == 0 ? .hardenedPINA : .hardenedPINB
        salt = Array(bytes[3..<19])
        let memory = bytes[19..<23].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let passes = bytes[23..<27].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        kdf = KDFParameters(memoryKiB: memory, passes: passes, lanes: bytes[27])
    }
}

extension RootKeyVault {
    public enum SecurityMode: Sendable, Equatable { case normal, hardened, unknown }

    /// O Face ID visto pelo modo reforcado. So `notEnrolled` e terminal; o resto volta.
    public enum BiometryStatus: Sendable, Equatable { case ready, lockedOut, notEnrolled, unavailable }

    static func systemBiometryStatus() -> BiometryStatus {
        let context = LAContext()
        defer { context.invalidate() }
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return .ready }
        guard let error, error.domain == LAError.errorDomain else { return .ready }
        switch LAError.Code(rawValue: error.code) {
        case .biometryLockout?: return .lockedOut
        case .biometryNotEnrolled?: return .notEnrolled
        case .biometryNotAvailable?: return .unavailable
        default: return .ready  // o SEP decide; nada e recusado nem apagado por duvida
        }
    }

    /// Reforcado so com o rk.and presente e nenhum slot do PIN: o commit de ligar e
    /// apagar o rk.pin. Com os dois, a transicao nao terminou e o modo normal manda.
    public var securityMode: SecurityMode {
        let probes = [Account.rootHardened, Account.rootByPIN, Account.rootByPIN + Account.pendingSuffix].map(store.probe)
        if probes.contains(.unknown) { return .unknown }
        return probes[0] == .present && probes[1] == .absent && probes[2] == .absent ? .hardened : .normal
    }

    /// Sobrou alguma coisa de uma instalacao (slot, chave do SE)? Para a limpeza de
    /// reinstalacao, sem o app conhecer nomes de conta.
    public var hasResidue: Bool {
        let accounts = [Account.rootByPIN, Account.rootByPIN + Account.pendingSuffix, Account.rootByBiometry, Account.rootHardened]
        return accounts.map(store.probe).contains { $0 != .absent } || WrapSlot.allCases.contains { wrapper.probeKey($0) != .absent }
    }

    static func hardenedPassword(ap: SecureBytes, salt: [UInt8]) -> Data {
        let material = ap.withUnsafeBytes { SymmetricKey(data: $0) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: HardenedHeader.passwordInfo, outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    static func sealHardenedInner(_ rk: SecureBytes, ap: SecureBytes, header: HardenedHeader) throws -> SecureBytes {
        let material = ap.withUnsafeBytes { SymmetricKey(data: $0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: header.salt, info: HardenedHeader.innerInfo, outputByteCount: 32)
        let box = try rk.withUnsafeData { try ChaChaPoly.seal($0, using: key, authenticating: header.aad) }
        let out = SecureBytes(capacity: Inner.length)
        out.append(Inner.version)
        box.combined.withUnsafeBytes { out.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        return out
    }

    static func openHardenedInner(_ inner: SecureBytes, ap: SecureBytes, header: HardenedHeader) throws -> SecureBytes {
        guard inner.count == Inner.length else { throw Failure.storage }
        let material = ap.withUnsafeBytes { SymmetricKey(data: $0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: header.salt, info: HardenedHeader.innerInfo, outputByteCount: 32)
        let parsed: (UInt8, ChaChaPoly.SealedBox)? = inner.withUnsafeBytes { raw in
            guard let box = try? ChaChaPoly.SealedBox(combined: Data(raw[1...])) else { return nil }
            return (raw[0], box)
        }
        guard let parsed, parsed.0 == Inner.version else { throw Failure.storage }
        var plain: Data
        do { plain = try ChaChaPoly.open(parsed.1, using: key, authenticating: header.aad) } catch { throw Failure.wrongPIN(remainingBeforeWipe: nil) }
        let rk = SecureBytes(capacity: 32)
        plain.withUnsafeMutableBytes { raw in
            rk.append(contentsOf: UnsafeBufferPointer(raw.bindMemory(to: UInt8.self)))
            if let base = raw.baseAddress { memset_s(base, raw.count, 0, raw.count) }
        }
        return rk
    }

    func readHardened() throws -> (HardenedHeader, Data) {
        let data: Data?
        do { data = try store.read(Account.rootHardened, context: nil) } catch { throw Failure.storage }
        guard let data else { throw Failure.notHardened }
        return try Self.parseHardened(data)
    }

    static func parseHardened(_ data: Data) throws -> (HardenedHeader, Data) {
        guard let header = HardenedHeader([UInt8](data.prefix(HardenedHeader.length))), data.count > HardenedHeader.length else {
            throw Failure.storage
        }
        return (header, Data(data.dropFirst(HardenedHeader.length)))
    }

    // MARK: Abrir

    /// PIN e rosto, os dois pela criptografia. Uma chamada = uma tentativa = um Face ID
    /// = um PIN avaliado. O contador sobe antes do rosto e so zera com a RK aberta.
    public func unlockHardened(pin: SecureBytes, reason: String) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        return try unlockHardenedLocked(pin: pin, reason: reason)
    }

    private func unlockHardenedLocked(pin: SecureBytes, reason: String) throws -> SecureBytes {
        switch securityMode {
        case .unknown: throw Failure.storage
        case .normal: throw Failure.notHardened
        case .hardened: break
        }
        sweepHardenedLocked()
        let (header, body) = try readHardened()
        // Tamanho nao e segredo; PIN fora de forma nunca gasta tentativa.
        guard Self.isWellFormed(pin), pin.count == Int(header.pinLength) else { throw Failure.malformedPIN }
        try hardenedPreflight(header)

        let record = try rebasedAttemptsLocked()
        let waiting = record.remaining()
        guard waiting <= 0 else { throw Failure.throttled(seconds: waiting) }
        let next = AttemptRecord.after(failures: record.failures + 1)
        do { try store.update(next.encoded, account: Account.attempts) } catch { throw Failure.storage }

        let rk: SecureBytes
        do {
            rk = try openHardenedBody(body, header: header, pin: pin, reason: reason)
        } catch let failure as Failure {
            switch failure {
            case .wrongPIN, .biometryNotConfirmed:
                if let threshold = wipeThreshold, next.failures >= threshold {
                    wipeAllLocked()
                    throw Failure.wiped
                }
                let left = wipeThreshold.map { $0 - next.failures }
                if case .wrongPIN = failure { throw Failure.wrongPIN(remainingBeforeWipe: left) }
                throw Failure.biometryNotConfirmed(remainingBeforeWipe: left)
            default:
                throw failure
            }
        }
        try? store.update(AttemptRecord.zero.encoded, account: Account.attempts)
        recordPINThisBoot()
        refreshHardenedState()
        return rk
    }

    /// O que nao depende do PIN nem gasta tentativa: o Face ID utilizavel agora e as
    /// duas chaves do SE presentes.
    private func hardenedPreflight(_ header: HardenedHeader) throws {
        switch hardenedBiometryStatus() {
        case .lockedOut: throw Failure.biometryLockedOut
        case .unavailable: throw Failure.biometryUnavailable
        case .notEnrolled: throw Failure.hardenedSlotLost
        case .ready: break
        }
        for slot in [WrapSlot.hardenedBiometry, header.pinKey] {
            switch wrapper.probeKey(slot) {
            case .present: continue
            case .absent: throw Failure.hardenedSlotLost
            case .unknown: throw Failure.storage
            }
        }
    }

    /// rosto (SEP) -> Argon2id -> SE com a senha do PIN -> ChaChaPoly com AAD. Nao conta
    /// nem grava: quem chama decide. Privado: nada fora do cofre abre "o rosto ja passou".
    private func openHardenedBody(_ body: Data, header: HardenedHeader, pin: SecureBytes, reason: String) throws -> SecureBytes {
        let middle: SecureBytes
        do {
            middle = try wrapper.unwrap(body, slot: .hardenedBiometry, reason: reason)
        } catch {
            // Perdido so com prova: a chave do rosto que o SE ja nao tem. O hash do cadastro
            // diferente com a chave presente pode ser so deriva do sistema e conta como o
            // rosto que nao confirmou (revisao do modo reforcado, M6).
            if wrapper.probeKey(.hardenedBiometry) == .absent { throw Failure.hardenedSlotLost }
            throw Failure.biometryNotConfirmed(remainingBeforeWipe: nil)
        }
        defer { middle.wipe() }
        let ap: SecureBytes
        do { ap = try KeyDerivation.deriveMasterKey(password: pin, salt: header.salt, parameters: header.kdf) } catch { throw Failure.storage }
        defer { ap.wipe() }
        let inner: SecureBytes
        do {
            inner = try middle.withUnsafeData { try wrapper.unwrap($0, slot: header.pinKey, password: Self.hardenedPassword(ap: ap, salt: header.salt)) }
        } catch EnclaveError.wrongPassword {
            throw Failure.wrongPIN(remainingBeforeWipe: nil)
        } catch EnclaveError.keyMissing {
            // O wrapper diz "sem chave" para qualquer falha da busca: perdido so se o SE
            // confirmar que ela nao existe.
            throw wrapper.probeKey(header.pinKey) == .absent ? Failure.hardenedSlotLost : Failure.storage
        } catch {
            throw Failure.storage
        }
        defer { inner.wipe() }
        return try Self.openHardenedInner(inner, ap: ap, header: header)
    }

    /// O hash do cadastro de rostos diferente do gravado ao ligar. Nunca decide nada: so
    /// a mensagem do rosto que nao confirmou diz que, se o cadastro mudou, so as palavras
    /// trazem de volta.
    public var hardenedEnrollmentChanged: Bool {
        guard let saved = try? store.read(Account.hardenedState, context: nil), let now = hardenedDomainState() else { return false }
        return saved != now
    }

    /// O SEP abriu: o cadastro e o mesmo de quando a chave nasceu. Um hash diferente era
    /// so deriva do sistema.
    private func refreshHardenedState() {
        guard let now = hardenedDomainState() else { return }
        if (try? store.read(Account.hardenedState, context: nil)) == now { return }
        try? store.delete(Account.hardenedState)
        try? store.add(now, account: Account.hardenedState, protection: .standard, context: nil)
    }

    // MARK: Gravar e conferir

    private func buildHardenedRecord(rk: SecureBytes, pin: SecureBytes, pinKey: WrapSlot) throws -> Data {
        let saltBytes = try SecureBytes.random(count: VaultFormat.saltLength)
        let salt = saltBytes.withUnsafeBytes { Array($0) }
        let kdf = pinParameters
        let ap = try KeyDerivation.deriveMasterKey(password: pin, salt: salt, parameters: kdf)
        defer { ap.wipe() }
        let header = HardenedHeader(pinLength: UInt8(pin.count), pinKey: pinKey, salt: salt, kdf: kdf)
        try wrapper.createKey(pinKey, password: Self.hardenedPassword(ap: ap, salt: salt))
        let inner = try Self.sealHardenedInner(rk, ap: ap, header: header)
        defer { inner.wipe() }
        var middleData = try wrapper.wrap(inner, slot: pinKey)
        let middle = SecureBytes(capacity: middleData.count)
        middleData.withUnsafeMutableBytes { raw in
            middle.append(contentsOf: raw.bindMemory(to: UInt8.self).withMemoryRebound(to: UInt8.self) { UnsafeBufferPointer($0) })
            // O miolo e o "rosto ja passou": nao fica num Data solto.
            if let base = raw.baseAddress { memset_s(base, raw.count, 0, raw.count) }
        }
        defer { middle.wipe() }
        let body = try wrapper.wrap(middle, slot: .hardenedBiometry)
        return Data(header.encoded) + body
    }

    /// A prova de que o registro abre com este PIN e este rosto e devolve esta RK. Nao
    /// conta: so roda com a RK ja aberta.
    private func verifyHardened(_ record: Data, pin: SecureBytes, reason: String, matches rk: SecureBytes) throws {
        let (header, body) = try Self.parseHardened(record)
        let check = try openHardenedBody(body, header: header, pin: pin, reason: reason)
        defer { check.wipe() }
        guard Hash.constantTimeEqual(check, rk) else { throw Failure.storage }
    }

    private func discardHardenedLocked() {
        try? store.delete(Account.rootHardened)
        try? store.delete(Account.hardenedState)
        [WrapSlot.hardenedBiometry, .hardenedPINA, .hardenedPINB].forEach(wrapper.deleteKey)
    }

    /// Leva o que sobrou de uma transicao para o estado que o modo diz. So com respostas
    /// definitivas; com os dois slots, nada (o PIN certo resolve).
    func sweepHardenedLocked() {
        switch securityMode {
        case .hardened:
            for account in [Account.rootByBiometry, Account.biometryState, Account.biometryHold, Account.biometryLost, Account.pinKDF, Account.pinLength,
                            Account.pinKDF + Account.pendingSuffix, Account.pinLength + Account.pendingSuffix] {
                try? store.delete(account)
            }
            [WrapSlot.device, .pin, .pinPending, .biometry].forEach(wrapper.deleteKey)
            if let (header, _) = try? readHardened() {
                wrapper.deleteKey(header.pinKey == .hardenedPINA ? .hardenedPINB : .hardenedPINA)
            }
        case .normal:
            guard store.probe(Account.rootHardened) == .absent else { return }
            [WrapSlot.hardenedBiometry, .hardenedPINA, .hardenedPINB].forEach(wrapper.deleteKey)
            try? store.delete(Account.hardenedState)
        case .unknown:
            return
        }
    }

    // MARK: Ligar, desligar, trocar o PIN

    /// Liga. Uma chamada, sincrona, fora do MainActor: PIN e rosto pelo caminho de hoje,
    /// `check` com a RK (a conferencia das palavras), o rk.and gravado e aberto de novo com
    /// PIN e rosto, e so entao o commit (apagar o rk.pin).
    ///
    /// `check` roda sob a trava do cofre: nunca pode chamar o `RootKeyVault` (a trava nao e
    /// recursiva). Abrir carteiras pelo `WalletVault` pode.
    public func enableHardened(pin: SecureBytes, reason: String, confirmReason: String, check: (SecureBytes) throws -> Void = { _ in }) throws {
        lock.lock(); defer { lock.unlock() }
        switch securityMode {
        case .hardened: throw Failure.hardenedModeActive
        case .unknown: throw Failure.storage
        case .normal: break
        }
        guard slotVersion(suffix: "") == 2 else { throw Failure.hardenedBlocked(.legacySlot) }
        switch store.probe(Account.rootByPIN + Account.pendingSuffix) {
        case .absent: break
        case .present: throw Failure.hardenedBlocked(.changePending)
        case .unknown: throw Failure.storage
        }
        guard store.probe(Account.rootByBiometry) == .present, wrapper.probeKey(.biometry) == .present else {
            throw Failure.hardenedBlocked(.biometryOff)
        }
        let hold = try biometryHoldRemainingChecked()
        guard hold <= 0 else { throw Failure.biometryHold(seconds: hold) }
        guard hardenedBiometryStatus() == .ready else { throw Failure.hardenedBlocked(.biometryUnavailable) }
        let stateBefore = hardenedDomainState()

        // 1. PIN e o rosto do slot de hoje (A1): prova que o cadastro e o de quando o Face
        //    ID foi ligado, e conta tentativa como sempre.
        let rk = try unlockWithPINAndBiometryLocked(pin: pin, reason: reason)
        defer { rk.wipe() }
        try check(rk)
        // 2. Sobras de uma ativacao interrompida: so agora, com o slot do PIN provado vivo.
        discardHardenedLocked()
        // 3. Chaves novas e o registro.
        do {
            try wrapper.createKey(.hardenedBiometry)
            let record = try buildHardenedRecord(rk: rk, pin: pin, pinKey: .hardenedPINA)
            try store.add(record, account: Account.rootHardened, protection: .standard, context: nil)
            if let state = stateBefore { try store.add(state, account: Account.hardenedState, protection: .standard, context: nil) }
            // 4. Conferir lendo do chaveiro e abrindo de verdade: segundo Face ID.
            guard let stored = try store.read(Account.rootHardened, context: nil) else { throw Failure.storage }
            try verifyHardened(stored, pin: pin, reason: confirmReason, matches: rk)
            guard hardenedDomainState() == stateBefore else { throw Failure.biometryChanged }
        } catch {
            discardHardenedLocked()
            throw error is Failure ? error : Failure.storage
        }
        // 5. Commit. Daqui em diante nada apaga o rk.and por falha.
        try? store.delete(Account.rootByPIN)
        guard store.probe(Account.rootByPIN) == .absent else { throw Failure.storage }
        // 6. Limpeza; se parar no meio, a varredura termina.
        sweepHardenedLocked()
    }

    /// Desliga: PIN e rosto no rk.and, o slot do PIN gravado e conferido (a partir dai o
    /// modo normal manda), o Face ID religado e conferido (segundo rosto; se falhar, fica
    /// desligado), e o rk.and sai. Devolve se o Face ID voltou.
    @discardableResult
    public func disableHardened(pin: SecureBytes, reason: String, biometryReason: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let rk = try unlockHardenedLocked(pin: pin, reason: reason)
        defer { rk.wipe() }
        do {
            try writePINSlot(rk: rk, pin: pin, kdf: pinParameters, suffix: "")
            try confirm(pin: pin, suffix: "", matches: rk)
        } catch {
            // O rk.pin sai e e conferido antes da chave dele: um rk.pin sem chave tiraria o
            // cofre do reforcado com um slot que nao abre (revisao do modo reforcado).
            try? store.delete(Account.rootByPIN)
            guard store.probe(Account.rootByPIN) == .absent else { throw Failure.storage }
            deleteSlot(suffix: "")
            wrapper.deleteKey(.pin)
            throw error is Failure ? error : Failure.storage
        }
        // O Face ID volta com o mesmo cadastro, provado agora pela kand.bio: sem espera. A
        // conferencia do rosto e a do proprio `enableBiometry`; falhou, fica desligado.
        let restored = (try? enableBiometry(rk: rk, reason: biometryReason)) != nil
        discardHardenedLocked()
        return restored
    }

    /// Troca o PIN no modo reforcado. Sem slot pendente: a chave do PIN alterna (a/b), o
    /// registro novo e aberto com PIN novo e rosto antes, e o commit e a troca no lugar
    /// do rk.and (atomica). A chave antiga so sai com o registro novo lido de volta.
    public func changeHardenedPIN(currentPIN: SecureBytes, newPIN: SecureBytes, reason: String, confirmReason: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.isWellFormed(newPIN) else { throw Failure.malformedPIN }
        let rk = try unlockHardenedLocked(pin: currentPIN, reason: reason)
        defer { rk.wipe() }
        guard let old = try? store.read(Account.rootHardened, context: nil) else { throw Failure.storage }
        let (oldHeader, _) = try Self.parseHardened(old)
        let nextKey: WrapSlot = oldHeader.pinKey == .hardenedPINA ? .hardenedPINB : .hardenedPINA
        wrapper.deleteKey(nextKey)
        let record: Data
        do {
            record = try buildHardenedRecord(rk: rk, pin: newPIN, pinKey: nextKey)
            try verifyHardened(record, pin: newPIN, reason: confirmReason, matches: rk)
        } catch Failure.biometryNotConfirmed {
            // O rosto da conferencia nao conta tentativa: so a abertura conta.
            wrapper.deleteKey(nextKey)
            throw Failure.cancelled
        } catch {
            wrapper.deleteKey(nextKey)
            throw error is Failure ? error : Failure.storage
        }
        try? store.update(record, account: Account.rootHardened)
        // O que ficou gravado decide, nao o retorno do update.
        guard let stored = try? store.read(Account.rootHardened, context: nil) else { throw Failure.storage }
        if stored == record {
            // A chave nova sumiu depois do commit: volta o registro antigo, conferido, antes
            // de recusar. Sem isso, o rk.and gravado apontaria para uma chave que nao existe e
            // a varredura apagaria a antiga (segunda revisao do modo reforcado, N2).
            guard wrapper.probeKey(nextKey) == .present else {
                try? store.update(old, account: Account.rootHardened)
                guard (try? store.read(Account.rootHardened, context: nil)) == old else { throw Failure.storage }
                wrapper.deleteKey(nextKey)
                throw Failure.storage
            }
            wrapper.deleteKey(oldHeader.pinKey)
        } else if stored == old {
            wrapper.deleteKey(nextKey)
            throw Failure.storage
        } else {
            throw Failure.storage
        }
    }
}
