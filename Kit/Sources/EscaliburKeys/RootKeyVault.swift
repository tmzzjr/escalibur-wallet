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
        /// remover carteira esperam `seconds` (`PINPolicy.biometryLossHold`). No modo
        /// reforcado com "Esperar 24 horas", o cadastro de rostos mudou: tudo menos abrir o
        /// app espera.
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
        /// Modo reforcado sem a trava: nenhum rosto cadastrado no Face ID agora. Nada foi
        /// tentado, contado nem apagado; volta a abrir com um rosto cadastrado.
        case biometryNotEnrolled
        /// Modo reforcado: a chave do rosto que a politica usa sumiu (com a trava, o cadastro
        /// de rostos mudou) e o rk.and nao abre mais. Nada foi apagado; o caminho e restaurar
        /// pelas palavras.
        case hardenedSlotLost
        /// Modo reforcado: a chave do rosto existe e o SE recusou abrir a camada de fora por um
        /// erro que nao vem do Face ID (uma redefinicao do Face ID interrompida, por exemplo).
        /// Nao conta tentativa e nao apaga nada.
        case hardenedFaceKeyFailed
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
        /// O hash do cadastro de rostos que o modo reforcado conhece: o de quando a `kand.bio`
        /// nasceu (ou o de quando a politica passou a valer, na `.continue`). Na `.wait`,
        /// decide quando a vigia nao responde; nas outras, so classifica o erro.
        static let hardenedState = "and.estado"
        /// A espera do `.wait` depois que a vigia viu outro cadastro (`HardenedHold`).
        static let hardenedHold = "and.espera"
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
    ///
    /// Sai em buffer seguro, que quem chama zera; o `Data` que o SE pede so existe dentro
    /// de `withUnsafeData`, zerado na volta. Antes era um `Data` que ninguem zerava, e a
    /// senha do PIN no SE ficava no heap depois do uso (auditoria 4, C7-21).
    static func devicePassword(ap: SecureBytes, salt: [UInt8]) -> SecureBytes {
        let material = ap.withUnsafeBytes { SymmetricKey(data: $0) }
        return secure(HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: SlotFormat.passwordInfo, outputByteCount: 32))
    }

    /// Os bytes de uma chave do CryptoKit num buffer seguro.
    static func secure(_ key: SymmetricKey) -> SecureBytes {
        let out = SecureBytes(capacity: key.bitCount / 8)
        key.withUnsafeBytes { out.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        return out
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
            guard let record = try? readHardened() else { return Set(PINPolicy.lengths) }
            return [Int(record.header.pinLength)]
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
        // nao valem (e a varredura as apaga). Vale a espera do `.wait`.
        guard securityMode != .hardened else {
            try checkHardenedAllowed()
            return
        }
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
        rebaseHardenedHoldLocked()
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
        let password = Self.devicePassword(ap: ap, salt: salt)
        defer { password.wipe() }
        try password.withUnsafeData { try wrapper.createKey(slot, password: $0) }
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
            let password = Self.devicePassword(ap: ap, salt: salt)
            defer { password.wipe() }
            do {
                inner = try password.withUnsafeData { try wrapper.unwrap(blob, slot: Self.wrapSlot(suffix), password: $0) }
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

/// Cabecalho do rk.and, em claro e autenticado como AAD da camada interna (docs/seguranca.md
/// §2.6).
///
/// Formato 4: versao (1) | digitos (1) | chave do PIN (1: 0 = a, 1 = b) | camadas (1) | sal
/// (16) | memoria (4) | passadas (4) | faixas (1) = 29 bytes. As camadas dizem a politica: 1 so
/// a `kand.bio` (`.lock`), 2 so a `kand.qualquer` (`.continue`), 3 as duas (`.wait`).
///
/// Formato 3 (28 bytes, sem o byte das camadas): o de antes das politicas, so a `kand.bio`.
/// Lido como `.lock`, com o AAD dele, e nunca mais gravado.
struct HardenedHeader: Equatable {
    static let version: UInt8 = 4
    static let length = 29
    static let aadInfo = Array("escalibur-wallet/v4/rk.and".utf8)
    static let legacyVersion: UInt8 = 3
    static let legacyLength = 28
    static let legacyAADInfo = Array("escalibur-wallet/v3/rk.and".utf8)
    static let passwordInfo = Data("escalibur-wallet/v3/kand.senha".utf8)
    static let innerInfo = Data("escalibur-wallet/v3/rk.and.interna".utf8)

    var version: UInt8
    var pinLength: UInt8
    var pinKey: WrapSlot
    var faceChange: RootKeyVault.HardenedFaceChange
    var salt: [UInt8]
    var kdf: KDFParameters

    var byteCount: Int { version == Self.legacyVersion ? Self.legacyLength : Self.length }

    var encoded: [UInt8] {
        let key: UInt8 = pinKey == .hardenedPINA ? 0 : 1
        let cost = kdf.memoryKiB.bigEndianByteArray + kdf.passes.bigEndianByteArray + [kdf.lanes]
        if version == Self.legacyVersion { return [version, pinLength, key] + salt + cost }
        return [version, pinLength, key, faceChange.layerCode] + salt + cost
    }

    var aad: Data { Data((version == Self.legacyVersion ? Self.legacyAADInfo : Self.aadInfo) + encoded) }

    /// Um cabecalho novo: sempre no formato 4.
    init(pinLength: UInt8, pinKey: WrapSlot, faceChange: RootKeyVault.HardenedFaceChange, salt: [UInt8], kdf: KDFParameters) {
        self.version = Self.version
        self.pinLength = pinLength
        self.pinKey = pinKey
        self.faceChange = faceChange
        self.salt = salt
        self.kdf = kdf
    }

    /// Le o formato 4 ou o 3. Camadas fora de {1, 2, 3}: nil.
    init?(_ bytes: [UInt8]) {
        guard let first = bytes.first, first == Self.version || first == Self.legacyVersion else { return nil }
        let legacy = first == Self.legacyVersion
        guard bytes.count >= (legacy ? Self.legacyLength : Self.length),
              PINPolicy.lengths.contains(Int(bytes[1])), bytes[2] <= 1 else { return nil }
        let policy: RootKeyVault.HardenedFaceChange
        if legacy {
            policy = .lock
        } else {
            guard let parsed = RootKeyVault.HardenedFaceChange(layerCode: bytes[3]) else { return nil }
            policy = parsed
        }
        let start = legacy ? 3 : 4
        version = first
        pinLength = bytes[1]
        pinKey = bytes[2] == 0 ? .hardenedPINA : .hardenedPINB
        faceChange = policy
        salt = Array(bytes[start..<start + 16])
        let memory = bytes[start + 16..<start + 20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let passes = bytes[start + 20..<start + 24].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        kdf = KDFParameters(memoryKiB: memory, passes: passes, lanes: bytes[start + 24])
    }
}

/// O rk.and inteiro: o cabecalho e, para cada camada de fora da politica, o mesmo miolo
/// (`ECIES_{kand.pin}(0x01 ‖ ChaChaPoly(K_int, RK))`) embrulhado pela chave dela.
///
/// Formato 4: cada camada presente, na ordem `kand.bio`, `kand.qualquer`, como tamanho (2,
/// big-endian) ‖ ECIES. Camadas que nao batem com o corpo (sobra, falta, tamanho zero): o
/// registro nao e este. Formato 3: so o ECIES da `kand.bio`, sem tamanho.
struct HardenedRecord: Equatable {
    var header: HardenedHeader
    var layers: [WrapSlot: Data]

    var encoded: Data {
        var out = Data(header.encoded)
        if header.version == HardenedHeader.legacyVersion {
            out.append(layers[.hardenedBiometry] ?? Data())
            return out
        }
        for slot in header.faceChange.layers {
            let blob = layers[slot] ?? Data()
            out.append(contentsOf: UInt16(clamping: blob.count).bigEndianByteArray)
            out.append(blob)
        }
        return out
    }

    static func parse(_ data: Data) throws -> HardenedRecord {
        let bytes = [UInt8](data)
        guard let header = HardenedHeader(bytes) else { throw RootKeyVault.Failure.storage }
        var rest = bytes[header.byteCount...]
        if header.version == HardenedHeader.legacyVersion {
            guard !rest.isEmpty else { throw RootKeyVault.Failure.storage }
            return HardenedRecord(header: header, layers: [.hardenedBiometry: Data(rest)])
        }
        var layers: [WrapSlot: Data] = [:]
        for slot in header.faceChange.layers {
            guard rest.count >= 2 else { throw RootKeyVault.Failure.storage }
            let size = Int(rest[rest.startIndex]) << 8 | Int(rest[rest.startIndex + 1])
            rest = rest.dropFirst(2)
            guard size > 0, rest.count >= size else { throw RootKeyVault.Failure.storage }
            layers[slot] = Data(rest.prefix(size))
            rest = rest.dropFirst(size)
        }
        guard rest.isEmpty else { throw RootKeyVault.Failure.storage }
        return HardenedRecord(header: header, layers: layers)
    }
}

/// A espera do `.wait` (`and.espera`): o prazo (`HoldRecord`, 25 bytes) e o hash do cadastro
/// de rostos que a comecou. Vencida, so realinha a vigia para esse mesmo cadastro: um rosto
/// cadastrado depois do prazo, sem o app aberto no meio, comeca outra espera em vez de passar
/// pela que ja venceu.
struct HardenedHold: Equatable {
    var hold: HoldRecord
    var state: Data

    var encoded: Data { hold.encoded + state }
    var remaining: TimeInterval { hold.remaining() }

    init(hold: HoldRecord, state: Data) {
        self.hold = hold
        self.state = state
    }

    init?(_ data: Data) {
        guard data.count >= 25, let hold = HoldRecord(Data(data.prefix(25))) else { return nil }
        self.hold = hold
        self.state = Data(data.dropFirst(25))
    }
}

extension RootKeyVault {
    public enum SecurityMode: Sendable, Equatable { case normal, hardened, unknown }

    /// O Face ID visto pelo modo reforcado. So `notEnrolled` e terminal, e so na `.lock`; o
    /// resto volta.
    public enum BiometryStatus: Sendable, Equatable { case ready, lockedOut, notEnrolled, unavailable }

    /// O que o modo reforcado faz quando o cadastro de rostos muda, escolhido pelo dono em
    /// "Quando o Face ID mudar" (docs/seguranca.md §2.6). Contra quem nao sabe o codigo do
    /// iPhone as tres valem igual: cadastrar um rosto pede o codigo.
    public enum HardenedFaceChange: Sendable, Equatable, CaseIterable {
        /// Continuar normal, o padrao: a camada de fora e so a `kand.qualquer`
        /// (`.biometryAny`), e um rosto novo abre tudo com o PIN, na hora. Quem sabe o PIN e
        /// o codigo do iPhone cadastra o proprio rosto e leva tudo.
        case `continue`
        /// Esperar 24 horas: a `kand.qualquer` abre, e a vigia `kand.bio`
        /// (`.biometryCurrentSet`), testada na mesma sessao do rosto, diz se o cadastro
        /// mudou. Mudou: o app abre e mostra o saldo, e o resto espera 24 horas.
        case wait
        /// Bloquear as carteiras: so a `kand.bio`, o comportamento de antes das politicas. Um
        /// rosto novo fecha o cofre de vez, e so as palavras trazem de volta.
        case lock

        /// As camadas de fora, na ordem do corpo do rk.and.
        var layers: [WrapSlot] {
            switch self {
            case .continue: return [.hardenedBiometryAny]
            case .wait: return [.hardenedBiometry, .hardenedBiometryAny]
            case .lock: return [.hardenedBiometry]
            }
        }

        /// A chave que o Face ID da chamada abre.
        var faceKey: WrapSlot { self == .lock ? .hardenedBiometry : .hardenedBiometryAny }

        var layerCode: UInt8 {
            switch self {
            case .lock: return 1
            case .continue: return 2
            case .wait: return 3
            }
        }

        init?(layerCode: UInt8) {
            switch layerCode {
            case 1: self = .lock
            case 2: self = .continue
            case 3: self = .wait
            default: return nil
            }
        }
    }

    /// Para que o cofre reforcado e aberto. Na espera do `.wait`, so abrir o app passa: o
    /// saldo aparece, e o resto espera.
    public enum HardenedUse: Sendable { case openApp, operation }

    /// Todas as chaves do modo reforcado.
    static let hardenedKeys: [WrapSlot] = [.hardenedBiometry, .hardenedBiometryAny, .hardenedPINA, .hardenedPINB]

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

    /// A politica do modo reforcado, do cabecalho do rk.and. Nil fora do reforcado ou com o
    /// cabecalho ilegivel. So le.
    public var hardenedFaceChange: HardenedFaceChange? {
        guard securityMode == .hardened, let record = try? readHardened() else { return nil }
        return record.header.faceChange
    }

    /// Quanto falta da espera do `.wait`, para a tela avisar antes do teclado. Zero sem espera
    /// e fora do reforcado; chaveiro mudo ou registro ilegivel, a espera cheia, nunca zero. So
    /// le.
    public var hardenedHoldRemaining: TimeInterval {
        switch securityMode {
        case .normal: return 0
        case .unknown: return PINPolicy.biometryLossHold
        case .hardened: break
        }
        if let policy = hardenedFaceChange, policy != .wait { return 0 }
        switch store.probe(Account.hardenedHold) {
        case .absent: return 0
        case .unknown: return PINPolicy.biometryLossHold
        case .present:
            guard let data = try? store.read(Account.hardenedHold, context: nil), let hold = HardenedHold(data) else {
                return PINPolicy.biometryLossHold
            }
            return hold.remaining
        }
    }

    /// O que abre o cofre pode comecar agora? Na espera do `.wait`, recusa antes do teclado.
    /// O cofre confere de novo em `unlockHardened`.
    public func checkHardenedAllowed() throws {
        let hold = hardenedHoldRemaining
        guard hold <= 0 else { throw Failure.biometryHold(seconds: hold) }
    }

    /// A senha de aplicativo da chave do PIN do modo reforcado. Como `devicePassword`, sai
    /// em buffer seguro, que quem chama zera.
    static func hardenedPassword(ap: SecureBytes, salt: [UInt8]) -> SecureBytes {
        let material = ap.withUnsafeBytes { SymmetricKey(data: $0) }
        return secure(HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: HardenedHeader.passwordInfo, outputByteCount: 32))
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

    func readHardened() throws -> HardenedRecord {
        let data: Data?
        do { data = try store.read(Account.rootHardened, context: nil) } catch { throw Failure.storage }
        guard let data else { throw Failure.notHardened }
        return try HardenedRecord.parse(data)
    }

    // MARK: Abrir

    /// PIN e rosto, os dois pela criptografia. Uma chamada = uma tentativa = um Face ID = um
    /// PIN avaliado. O contador sobe antes do rosto e so zera com a RK aberta.
    ///
    /// `use` diz para que: so `AppSession.unlock` passa `.openApp`, o unico uso que a espera
    /// do `.wait` deixa passar. Na espera, o resto recusa antes do rosto e sem contar.
    public func unlockHardened(pin: SecureBytes, reason: String, use: HardenedUse = .operation) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        return try openHardenedLocked(pin: pin, reason: reason, use: use).rk
    }

    /// A RK aberta e se o cadastro de rostos e o que o reforcado conhece: na `.lock`, a
    /// `kand.bio` abriu; na `.wait`, a vigia disse "o mesmo" (ou a espera foi cumprida e a
    /// vigia realinhada); na `.continue`, o hash e o gravado quando a politica passou a valer.
    private func openHardenedLocked(pin: SecureBytes, reason: String, use: HardenedUse) throws -> (rk: SecureBytes, sameEnrollment: Bool) {
        switch securityMode {
        case .unknown: throw Failure.storage
        case .normal: throw Failure.notHardened
        case .hardened: break
        }
        sweepHardenedLocked()
        let record = try readHardened()
        let policy = record.header.faceChange
        // Tamanho nao e segredo; PIN fora de forma nunca gasta tentativa.
        guard Self.isWellFormed(pin), pin.count == Int(record.header.pinLength) else { throw Failure.malformedPIN }
        var hold: HardenedHold?
        if policy == .wait { hold = try hardenedHoldLocked() }
        if let hold, hold.remaining > 0, use == .operation { throw Failure.biometryHold(seconds: hold.remaining) }
        try hardenedPreflight(record)

        let attempts = try rebasedAttemptsLocked()
        let waiting = attempts.remaining()
        guard waiting <= 0 else { throw Failure.throttled(seconds: waiting) }
        let next = AttemptRecord.after(failures: attempts.failures + 1)
        do { try store.update(next.encoded, account: Account.attempts) } catch { throw Failure.storage }

        let opened: HardenedOpening
        do {
            opened = try openHardenedRecord(record, pin: pin, reason: reason)
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
            case .hardenedFaceKeyFailed:
                // Nenhum rosto foi recusado e o PIN nem foi avaliado: o contador volta ao de
                // antes. Se nao gravar, a tentativa fica contada (falha para o lado seguro).
                try? store.update(attempts.encoded, account: Account.attempts)
                throw failure
            default:
                throw failure
            }
        }
        defer { opened.middle.wipe() }
        try? store.update(AttemptRecord.zero.encoded, account: Account.attempts)
        recordPINThisBoot()
        // O AAD provou o cabecalho: so agora a varredura pode apagar o que ele diz que sobra.
        sweepHardenedKeysLocked(record.header)
        switch policy {
        case .lock:
            refreshHardenedState()
            return (opened.rk, true)
        case .continue:
            return (opened.rk, hardenedStateMatches)
        case .wait:
            do {
                return (opened.rk, try settleWatchLocked(record, opened: opened, hold: hold, use: use))
            } catch {
                opened.rk.wipe()
                throw error
            }
        }
    }

    /// O que nao depende do PIN nem gasta tentativa: o Face ID utilizavel agora e as chaves
    /// do SE que a chamada usa presentes. A vigia do `.wait` nao entra: ausente, e o que ela
    /// tem a dizer.
    private func hardenedPreflight(_ record: HardenedRecord) throws {
        let policy = record.header.faceChange
        switch hardenedBiometryStatus() {
        case .lockedOut: throw Failure.biometryLockedOut
        case .unavailable: throw Failure.biometryUnavailable
        // Sem rosto cadastrado: com a trava, a kand.bio ja morreu; nas outras, a
        // kand.qualquer volta a abrir com um rosto cadastrado de novo.
        case .notEnrolled: throw policy == .lock ? Failure.hardenedSlotLost : Failure.biometryNotEnrolled
        case .ready: break
        }
        for slot in [policy.faceKey, record.header.pinKey] {
            switch wrapper.probeKey(slot) {
            case .present: continue
            case .absent: throw Failure.hardenedSlotLost
            case .unknown: throw Failure.storage
            }
        }
    }

    /// O que sai de uma abertura: a RK e o miolo, os dois zerados por quem chama, e o que a
    /// vigia do `.wait` viu.
    struct HardenedOpening {
        let rk: SecureBytes
        let middle: SecureBytes
        let watch: WatchVerdict?
    }

    /// A vigia, depois de conferida contra o miolo: abriu o mesmo, a chave nao existe mais, ou
    /// nao se sabe.
    enum WatchVerdict: Equatable { case same, gone, unknown }

    /// rosto (SEP) -> Argon2id -> SE com a senha do PIN -> ChaChaPoly com AAD. Na `.wait`, a
    /// vigia na mesma sessao do rosto, sem segundo Face ID; um miolo diferente nela e um
    /// registro que nao e o gravado. Nao conta nem grava: quem chama decide. Privado: nada
    /// fora do cofre abre "o rosto ja passou".
    private func openHardenedRecord(_ record: HardenedRecord, pin: SecureBytes, reason: String) throws -> HardenedOpening {
        let header = record.header
        let face = header.faceChange.faceKey
        guard let outer = record.layers[face] else { throw Failure.storage }
        let middle: SecureBytes
        var seen: WatchResult?
        do {
            if header.faceChange == .wait, let watch = record.layers[.hardenedBiometry] {
                let pair = try wrapper.unwrap(outer, slot: face, reason: reason, watching: watch, with: .hardenedBiometry)
                middle = pair.0
                seen = pair.1
            } else {
                middle = try wrapper.unwrap(outer, slot: face, reason: reason)
            }
        } catch EnclaveError.failed {
            // O SE recusou por um erro que nao vem do Face ID (nenhum rosto foi recusado): nao
            // conta. A chave que nao existe mais e o cofre perdido.
            if wrapper.probeKey(face) == .absent { throw Failure.hardenedSlotLost }
            throw Failure.hardenedFaceKeyFailed
        } catch {
            // Perdido so com prova: a chave do rosto que o SE ja nao tem. O hash do cadastro
            // diferente com a chave presente pode ser so deriva do sistema e conta como o
            // rosto que nao confirmou (revisao do modo reforcado, M6).
            if wrapper.probeKey(face) == .absent { throw Failure.hardenedSlotLost }
            throw Failure.biometryNotConfirmed(remainingBeforeWipe: nil)
        }
        let watch: WatchVerdict?
        switch seen {
        case .opened(let other)?:
            let equal = Hash.constantTimeEqual(other, middle)
            other.wipe()
            guard equal else {
                middle.wipe()
                throw Failure.storage
            }
            watch = .same
        case .gone?: watch = .gone
        case .unknown?: watch = .unknown
        case nil: watch = nil
        }
        do {
            return HardenedOpening(rk: try openHardenedMiddle(middle, header: header, pin: pin), middle: middle, watch: watch)
        } catch {
            middle.wipe()
            throw error
        }
    }

    private func openHardenedMiddle(_ middle: SecureBytes, header: HardenedHeader, pin: SecureBytes) throws -> SecureBytes {
        let ap: SecureBytes
        do { ap = try KeyDerivation.deriveMasterKey(password: pin, salt: header.salt, parameters: header.kdf) } catch { throw Failure.storage }
        defer { ap.wipe() }
        let password = Self.hardenedPassword(ap: ap, salt: header.salt)
        defer { password.wipe() }
        let inner: SecureBytes
        do {
            inner = try middle.withUnsafeData { body in
                try password.withUnsafeData { try wrapper.unwrap(body, slot: header.pinKey, password: $0) }
            }
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

    /// O que a vigia do `.wait` viu, ja com a RK aberta (PIN e rosto certos).
    ///
    /// - Mesmo cadastro: a vigia abriu o mesmo miolo, ou nao respondeu e o hash e o gravado.
    ///   O hash e regravado, e uma espera vencida termina (um realinhamento que caiu antes de
    ///   apagar a espera).
    /// - Troca: a chave da vigia nao existe mais, ou nao respondeu e o hash e outro (ou falta):
    ///   sem espera, ela comeca, conferida; com a espera correndo, nada muda (so abrir o app
    ///   chega aqui); vencida para o cadastro que a comecou, a vigia realinha; vencida para
    ///   outro, outra espera comeca. Fora de abrir o app, a espera comecada agora recusa.
    ///
    /// Devolve se o cadastro e o conhecido.
    private func settleWatchLocked(_ record: HardenedRecord, opened: HardenedOpening, hold: HardenedHold?, use: HardenedUse) throws -> Bool {
        let now = hardenedDomainState()
        let changed: Bool
        switch opened.watch {
        case .same?:
            changed = false
        case .unknown?:
            let saved = try? store.read(Account.hardenedState, context: nil)
            changed = saved == nil || now == nil || saved != now
        case .gone?, nil:
            changed = true
        }
        if !changed {
            // So a prova do SEP (a vigia abriu o mesmo miolo) regrava o hash e termina uma
            // espera vencida. O hash sozinho nunca encerra espera.
            if opened.watch == .same {
                refreshHardenedState()
                if let hold, hold.remaining <= 0 { try? store.delete(Account.hardenedHold) }
            }
            return true
        }
        if let hold {
            // Sem o hash de agora, nao se sabe para que cadastro a espera vale: correndo, ela
            // fica como esta; vencida, nada abre ate o hash voltar (nem recomeca uma espera de
            // cadastro nenhum).
            guard let now else {
                if hold.remaining > 0 { return false }
                throw Failure.biometryUnavailable
            }
            if hold.remaining > 0 {
                // Outro cadastro no meio da espera (o dono redefiniu o Face ID, ou alguem
                // cadastrou mais um rosto): ela recomeca cheia, para o cadastro de agora, e a
                // faixa diz o prazo certo. So abrir o app chega aqui.
                if hold.state != now { try startHardenedHold(state: now) }
                return false
            }
            if !hold.state.isEmpty, hold.state == now {
                // Uma queda em qualquer passo termina na proxima abertura: a espera vencida
                // continua la, e a vigia continua vendo a troca.
                try? realignWatchLocked(record, middle: opened.middle, state: now)
                return true
            }
        }
        try startHardenedHold(state: now)
        if use == .operation { throw Failure.biometryHold(seconds: PINPolicy.biometryLossHold) }
        return false
    }

    /// A espera venceu para o cadastro que a comecou: a vigia passa a acompanhar o de agora.
    /// Uma `kand.bio` nova, o mesmo miolo embrulhado por ela, o `update` do rk.and conferido
    /// lendo de volta, o hash regravado e a espera apagada, nessa ordem. A `kand.qualquer` e a
    /// camada dela nao sao tocadas: em nenhum passo o registro deixa de abrir.
    private func realignWatchLocked(_ record: HardenedRecord, middle: SecureBytes, state: Data) throws {
        try wrapper.createKey(.hardenedBiometry)
        var updated = record
        updated.layers[.hardenedBiometry] = try wrapper.wrap(middle, slot: .hardenedBiometry)
        let data = updated.encoded
        try? store.update(data, account: Account.rootHardened)
        guard (try? store.read(Account.rootHardened, context: nil)) == data else { throw Failure.storage }
        writeHardenedState(state)
        try? store.delete(Account.hardenedHold)
    }

    /// A espera do `.wait`, lida depois de rebaseada. Nil sem espera; chaveiro mudo recusa.
    private func hardenedHoldLocked() throws -> HardenedHold? {
        switch store.probe(Account.hardenedHold) {
        case .absent: return nil
        case .unknown: throw Failure.storage
        case .present: break
        }
        rebaseHardenedHoldLocked()
        guard let data = try? store.read(Account.hardenedHold, context: nil), let hold = HardenedHold(data) else {
            return HardenedHold(hold: .startingNow(), state: Data())
        }
        return hold
    }

    /// A troca vista agora: a espera comeca cheia, com o hash do cadastro que a comecou, e so
    /// vale se ficou gravada como foi escrita.
    private func startHardenedHold(state: Data?) throws {
        let record = HardenedHold(hold: .startingNow(), state: state ?? Data()).encoded
        if (try? store.update(record, account: Account.hardenedHold)) == nil {
            try? store.add(record, account: Account.hardenedHold, protection: .standard, context: nil)
        }
        guard (try? store.read(Account.hardenedHold, context: nil)) == record else { throw Failure.storage }
    }

    /// Depois de reiniciar, o prazo gravado com o relogio monotonico antigo nao vale mais: a
    /// espera do `.wait` recomeca cheia a partir de agora, para o mesmo cadastro. Ilegivel,
    /// recomeca de cadastro nenhum (vencida, comeca outra).
    func rebaseHardenedHoldLocked() {
        guard store.probe(Account.hardenedHold) == .present else { return }
        let hold = (try? store.read(Account.hardenedHold, context: nil)).flatMap { HardenedHold($0) }
        guard hold == nil || hold?.hold.isFromAnotherBoot == true else { return }
        try? store.update(HardenedHold(hold: .startingNow(), state: hold?.state ?? Data()).encoded, account: Account.hardenedHold)
    }

    /// O hash do cadastro de rostos diferente do gravado. Nunca decide nada sozinho: so a
    /// mensagem do rosto que nao confirmou diz que so as palavras trazem de volta (na trava, se
    /// o cadastro mudou; nas outras, se o Face ID foi redefinido).
    public var hardenedEnrollmentChanged: Bool {
        guard let saved = try? store.read(Account.hardenedState, context: nil), let now = hardenedDomainState() else { return false }
        return saved != now
    }

    /// O hash de agora e o gravado quando a politica passou a valer. Sem um dos dois, nao: na
    /// duvida, conta como troca.
    private var hardenedStateMatches: Bool {
        guard let saved = try? store.read(Account.hardenedState, context: nil), let now = hardenedDomainState() else { return false }
        return saved == now
    }

    /// A `kand.bio` abriu: o cadastro e o de quando a chave nasceu. Um hash diferente era so
    /// deriva do sistema.
    private func refreshHardenedState() {
        guard let now = hardenedDomainState() else { return }
        writeHardenedState(now)
    }

    private func writeHardenedState(_ state: Data) {
        if (try? store.read(Account.hardenedState, context: nil)) == state { return }
        try? store.delete(Account.hardenedState)
        try? store.add(state, account: Account.hardenedState, protection: .standard, context: nil)
    }

    // MARK: Gravar e conferir

    /// Monta o registro com o PIN e a geracao `pinKey` da chave do PIN (criada aqui, no lugar
    /// da que houver nela), e embrulha o mesmo miolo por cada camada de fora de `faceChange`.
    /// As chaves de fora ja existem: quem chama decide quais nascem agora e quais o registro
    /// em vigor ja usa (essas nunca sao recriadas). A `kand.qualquer` embrulha o miolo aqui e
    /// em nenhum outro lugar, e nunca a RK (verificar.sh).
    private func buildHardenedRecord(rk: SecureBytes, pin: SecureBytes, pinKey: WrapSlot, faceChange: HardenedFaceChange) throws -> Data {
        let saltBytes = try SecureBytes.random(count: VaultFormat.saltLength)
        let salt = saltBytes.withUnsafeBytes { Array($0) }
        let kdf = pinParameters
        let ap = try KeyDerivation.deriveMasterKey(password: pin, salt: salt, parameters: kdf)
        defer { ap.wipe() }
        let header = HardenedHeader(pinLength: UInt8(pin.count), pinKey: pinKey, faceChange: faceChange, salt: salt, kdf: kdf)
        let password = Self.hardenedPassword(ap: ap, salt: salt)
        defer { password.wipe() }
        try password.withUnsafeData { try wrapper.createKey(pinKey, password: $0) }
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
        var layers: [WrapSlot: Data] = [:]
        if faceChange.layers.contains(.hardenedBiometry) {
            layers[.hardenedBiometry] = try wrapper.wrap(middle, slot: .hardenedBiometry)
        }
        if faceChange.layers.contains(.hardenedBiometryAny) {
            layers[.hardenedBiometryAny] = try wrapper.wrap(middle, slot: .hardenedBiometryAny)
        }
        return HardenedRecord(header: header, layers: layers).encoded
    }

    /// A prova de que o registro abre com este PIN e este rosto e devolve esta RK; na `.wait`,
    /// tambem que a vigia abre na mesma sessao (ou, sem resposta dela, que o cadastro de agora
    /// e `state`). Nao conta: so roda com a RK ja aberta.
    private func verifyHardened(_ data: Data, pin: SecureBytes, reason: String, matches rk: SecureBytes, state: Data?) throws {
        let record = try HardenedRecord.parse(data)
        let opened = try openHardenedRecord(record, pin: pin, reason: reason)
        defer {
            opened.rk.wipe()
            opened.middle.wipe()
        }
        guard Hash.constantTimeEqual(opened.rk, rk) else { throw Failure.storage }
        switch opened.watch {
        case nil, .same?:
            return
        case .unknown?:
            guard let state, hardenedDomainState() == state else { throw Failure.storage }
        case .gone?:
            throw Failure.storage
        }
    }

    private func discardHardenedLocked() {
        try? store.delete(Account.rootHardened)
        try? store.delete(Account.hardenedState)
        try? store.delete(Account.hardenedHold)
        Self.hardenedKeys.forEach(wrapper.deleteKey)
    }

    /// Leva o que sobrou de uma transicao para o estado que o modo diz. So com respostas
    /// definitivas; com os dois slots, nada (o PIN certo resolve).
    ///
    /// No reforcado, so as sobras do modo normal: as chaves do reforcado dependem do
    /// cabecalho, e o cabecalho em claro so vale depois de autenticado
    /// (`sweepHardenedKeysLocked`). Antes, isto lia o cabecalho sem autenticar, e trocar o
    /// byte das camadas entre 1 e 2 fazia a volta ao app apagar a chave de fora em vigor
    /// (revisao das tres politicas, B3).
    func sweepHardenedLocked() {
        switch securityMode {
        case .hardened:
            for account in [Account.rootByBiometry, Account.biometryState, Account.biometryHold, Account.biometryLost, Account.pinKDF, Account.pinLength,
                            Account.pinKDF + Account.pendingSuffix, Account.pinLength + Account.pendingSuffix] {
                try? store.delete(account)
            }
            [WrapSlot.device, .pin, .pinPending, .biometry].forEach(wrapper.deleteKey)
        case .normal:
            guard store.probe(Account.rootHardened) == .absent else { return }
            Self.hardenedKeys.forEach(wrapper.deleteKey)
            try? store.delete(Account.hardenedState)
            try? store.delete(Account.hardenedHold)
        case .unknown:
            return
        }
    }

    /// O que um cabecalho autenticado diz que sobra: a geracao da chave do PIN que ele nao usa,
    /// as chaves de fora que a politica dele nao usa (`.lock`: a `kand.qualquer`; `.continue`:
    /// a `kand.bio`; `.wait`: nenhuma, nem a `kand.bio` morta, que o realinhamento recria), e a
    /// espera fora da `.wait`. So com `header` provado: depois de uma abertura (o AAD da camada
    /// interna o autentica) ou de um commit que o cofre acabou de gravar e conferir. Antes do
    /// commit de uma troca o cabecalho antigo manda, depois o novo: o registro em vigor nunca
    /// aponta para uma chave que isto apaga.
    private func sweepHardenedKeysLocked(_ header: HardenedHeader) {
        let policy = header.faceChange
        wrapper.deleteKey(header.pinKey == .hardenedPINA ? .hardenedPINB : .hardenedPINA)
        for slot in [WrapSlot.hardenedBiometry, .hardenedBiometryAny] where !policy.layers.contains(slot) {
            wrapper.deleteKey(slot)
        }
        if policy != .wait { try? store.delete(Account.hardenedHold) }
    }

    // MARK: Ligar, desligar, trocar o PIN, trocar a politica

    /// Liga. Uma chamada, sincrona, fora do MainActor: PIN e rosto pelo caminho de hoje,
    /// `check` com a RK (a conferencia das palavras), as chaves de fora de `faceChange`
    /// criadas, o rk.and gravado e aberto de novo com PIN e rosto, e so entao o commit
    /// (apagar o rk.pin).
    ///
    /// `check` roda sob a trava do cofre: nunca pode chamar o `RootKeyVault` (a trava nao e
    /// recursiva). Abrir carteiras pelo `WalletVault` pode.
    public func enableHardened(pin: SecureBytes, reason: String, confirmReason: String, faceChange: HardenedFaceChange = .continue,
                               check: (SecureBytes) throws -> Void) throws {
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
        let committed: HardenedHeader
        do {
            for slot in faceChange.layers { try wrapper.createKey(slot) }
            let record = try buildHardenedRecord(rk: rk, pin: pin, pinKey: .hardenedPINA, faceChange: faceChange)
            try store.add(record, account: Account.rootHardened, protection: .standard, context: nil)
            if let state = stateBefore { try store.add(state, account: Account.hardenedState, protection: .standard, context: nil) }
            // 4. Conferir lendo do chaveiro e abrindo de verdade: segundo Face ID.
            guard let stored = try store.read(Account.rootHardened, context: nil) else { throw Failure.storage }
            try verifyHardened(stored, pin: pin, reason: confirmReason, matches: rk, state: stateBefore)
            guard hardenedDomainState() == stateBefore else { throw Failure.biometryChanged }
            committed = try HardenedRecord.parse(stored).header
        } catch {
            discardHardenedLocked()
            throw error is Failure ? error : Failure.storage
        }
        // 5. Commit. Daqui em diante nada apaga o rk.and por falha.
        try? store.delete(Account.rootByPIN)
        guard store.probe(Account.rootByPIN) == .absent else { throw Failure.storage }
        // 6. Limpeza; se parar no meio, a varredura e a proxima abertura terminam.
        sweepHardenedLocked()
        sweepHardenedKeysLocked(committed)
    }

    /// Desliga: PIN e rosto no rk.and (fora da espera do `.wait`), o slot do PIN gravado e
    /// conferido (a partir dai o modo normal manda), o Face ID religado e conferido (segundo
    /// rosto; se falhar, fica desligado), e o rk.and sai. Devolve se o Face ID voltou.
    ///
    /// O Face ID volta sem a espera do A1 so quando o reforcado reconhece o cadastro: a
    /// `kand.bio` abriu (`.lock`), a vigia disse "o mesmo" (`.wait`), ou o hash e o gravado
    /// (`.continue`). Senao, a marca de perdido e gravada antes do slot do PIN: o
    /// `enableBiometry` comeca a espera ao religar, e sem o Face ID religado o que pede PIN e
    /// rosto recusa ate o dono religar, como numa queda do A1.
    @discardableResult
    public func disableHardened(pin: SecureBytes, reason: String, biometryReason: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let (rk, same) = try openHardenedLocked(pin: pin, reason: reason, use: .operation)
        defer { rk.wipe() }
        if !same {
            if store.probe(Account.biometryLost) != .present {
                try? store.add(Data([1]), account: Account.biometryLost, protection: .standard, context: nil)
            }
            guard store.probe(Account.biometryLost) == .present else { throw Failure.storage }
        }
        do {
            try writePINSlot(rk: rk, pin: pin, kdf: pinParameters, suffix: "")
            try confirm(pin: pin, suffix: "", matches: rk)
        } catch {
            // O rk.pin sai e e conferido antes da chave dele: um rk.pin sem chave tiraria o
            // cofre do reforcado com um slot que nao abre (revisao do modo reforcado).
            if !same { try? store.delete(Account.biometryLost) }
            try? store.delete(Account.rootByPIN)
            guard store.probe(Account.rootByPIN) == .absent else { throw Failure.storage }
            deleteSlot(suffix: "")
            wrapper.deleteKey(.pin)
            throw error is Failure ? error : Failure.storage
        }
        // A conferencia do rosto e a do proprio `enableBiometry`; falhou, fica desligado.
        let restored = (try? enableBiometry(rk: rk, reason: biometryReason)) != nil
        discardHardenedLocked()
        return restored
    }

    /// Troca o PIN no modo reforcado, mantendo a politica e as chaves de fora: a chave do PIN
    /// alterna (a/b), o registro novo e aberto com PIN novo e rosto antes, e o commit e a
    /// troca no lugar do rk.and (atomica). Na espera do `.wait`, recusa.
    public func changeHardenedPIN(currentPIN: SecureBytes, newPIN: SecureBytes, reason: String, confirmReason: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard Self.isWellFormed(newPIN) else { throw Failure.malformedPIN }
        let rk = try openHardenedLocked(pin: currentPIN, reason: reason, use: .operation).rk
        defer { rk.wipe() }
        try replaceHardenedLocked(rk: rk, pin: newPIN, target: nil, confirmReason: confirmReason)
    }

    /// Muda o que acontece quando o Face ID muda. PIN e rosto (uma tentativa contada; na
    /// espera do `.wait`, recusa antes), `check` com a RK so na ida para `.lock` (com a
    /// trava, o papel e o unico caminho de volta: as palavras de cada carteira), o registro
    /// novo montado com a outra geracao da chave do PIN e aberto com o segundo rosto, e o
    /// commit pelo `update` do rk.and. Sair da `.lock` abre pela `kand.bio`: o rosto de agora
    /// prova o mesmo cadastro. A mesma politica nao pede nada.
    ///
    /// `check` roda sob a trava do cofre: nunca pode chamar o `RootKeyVault`.
    public func setHardenedFaceChange(_ target: HardenedFaceChange, pin: SecureBytes, reason: String, confirmReason: String,
                                      check: (SecureBytes) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        switch securityMode {
        case .unknown: throw Failure.storage
        case .normal: throw Failure.notHardened
        case .hardened: break
        }
        guard try readHardened().header.faceChange != target else { return }
        let rk = try openHardenedLocked(pin: pin, reason: reason, use: .operation).rk
        defer { rk.wipe() }
        if target == .lock { try check(rk) }
        try replaceHardenedLocked(rk: rk, pin: pin, target: target, confirmReason: confirmReason)
    }

    /// Troca o rk.and no lugar, com a outra geracao da chave do PIN: a maquina da troca de PIN
    /// (`target` nil, a mesma politica) e da troca de politica.
    ///
    /// As chaves de fora que o registro em vigor ja usa sao reaproveitadas, nunca recriadas;
    /// as que faltam para a politica nova nascem agora. O registro novo e aberto com o PIN e o
    /// rosto (o segundo Face ID, que nao conta tentativa: recusado, volta como cancelado) antes
    /// do commit, que e o `update` do rk.and, e o que ficou gravado decide, nao o retorno do
    /// update. Antes do commit o cabecalho antigo manda, e a varredura so apaga o que nasceu
    /// aqui; depois, o novo, e a varredura apaga a geracao antiga e as chaves de fora que a
    /// politica nova nao usa.
    private func replaceHardenedLocked(rk: SecureBytes, pin: SecureBytes, target: HardenedFaceChange?, confirmReason: String) throws {
        guard let old = try? store.read(Account.rootHardened, context: nil) else { throw Failure.storage }
        let current = try HardenedRecord.parse(old)
        let from = current.header.faceChange
        let to = target ?? from
        let nextKey: WrapSlot = current.header.pinKey == .hardenedPINA ? .hardenedPINB : .hardenedPINA
        let born = to.layers.filter { !from.layers.contains($0) }
        let fresh = [nextKey] + born
        let stateBefore = hardenedDomainState()
        // A vigia que nasce agora acompanha o cadastro de agora; a reaproveitada, o gravado.
        let state: Data? = born.contains(.hardenedBiometry) ? stateBefore : (try? store.read(Account.hardenedState, context: nil)) ?? nil
        wrapper.deleteKey(nextKey)
        let record: Data
        do {
            for slot in born { try wrapper.createKey(slot) }
            record = try buildHardenedRecord(rk: rk, pin: pin, pinKey: nextKey, faceChange: to)
            try verifyHardened(record, pin: pin, reason: confirmReason, matches: rk, state: state)
            if born.contains(.hardenedBiometry) {
                guard hardenedDomainState() == stateBefore else { throw Failure.biometryChanged }
            }
        } catch Failure.biometryNotConfirmed {
            fresh.forEach(wrapper.deleteKey)
            throw Failure.cancelled
        } catch {
            fresh.forEach(wrapper.deleteKey)
            throw error is Failure ? error : Failure.storage
        }
        try? store.update(record, account: Account.rootHardened)
        guard let stored = try? store.read(Account.rootHardened, context: nil) else { throw Failure.storage }
        if stored == record {
            // Uma chave nova sumiu depois do commit: volta o registro antigo, conferido, antes
            // de recusar. Sem isso, o rk.and gravado apontaria para uma chave que nao existe e
            // a varredura apagaria as antigas (segunda revisao do modo reforcado, N2).
            guard fresh.allSatisfy({ wrapper.probeKey($0) == .present }) else {
                try? store.update(old, account: Account.rootHardened)
                guard (try? store.read(Account.rootHardened, context: nil)) == old else { throw Failure.storage }
                fresh.forEach(wrapper.deleteKey)
                throw Failure.storage
            }
            if born.contains(.hardenedBiometry), let stateBefore { writeHardenedState(stateBefore) }
            sweepHardenedLocked()
            if let header = try? HardenedRecord.parse(record).header { sweepHardenedKeysLocked(header) }
        } else if stored == old {
            fresh.forEach(wrapper.deleteKey)
            throw Failure.storage
        } else {
            throw Failure.storage
        }
    }
}
