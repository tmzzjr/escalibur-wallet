import CryptoKit
import EscaliburCore
import Foundation
import LocalAuthentication

/// A chave raiz (RK) e os dois caminhos que a destrancam: PIN e biometria.
///
/// ```
/// PIN ─Argon2id─► AP ─(senha de aplicativo)─► item rk.pin = embrulho(K_dev, RK) ─SE─► RK
/// Face ID (decisao no SEP) ─────────────────► item rk.bio = embrulho(K_bio, RK) ─SE─► RK
/// ```
///
/// **Nao existe verificador de PIN gravado em lugar nenhum.** O PIN errado e recusado
/// pelo proprio chaveiro, que nao devolve o item sem a senha de aplicativo certa. Nao
/// ha comparacao no codigo do app, entao nao ha oraculo de tempo, e nada extraido do
/// aparelho permite testar PINs fora dele (docs/seguranca.md §2).
public final class RootKeyVault: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case notSetUp
        case alreadySetUp
        case wrongPIN(remainingBeforeWipe: UInt32?)
        case throttled(seconds: TimeInterval)
        case blockedPIN
        case biometryNotEnabled
        case biometryChanged
        case cancelled
        /// Apagar apos erros disparou: tudo foi destruido.
        case wiped
        case storage
    }

    enum Account {
        static let pinKDF = "pin.kdf"
        static let rootByPIN = "rk.pin"
        static let rootByBiometry = "rk.bio"
        static let biometryState = "bio.estado"
        static let attempts = "pin.tentativas"
        static let wipeAfterErrors = "pin.apagar"
        static let pendingSuffix = ".novo"
    }

    let store: any SecretStore
    let wrapper: any KeyWrapper
    private let lock = NSLock()

    public init(store: any SecretStore, wrapper: any KeyWrapper) {
        self.store = store
        self.wrapper = wrapper
    }

    public var isSetUp: Bool {
        store.exists(Account.rootByPIN) || store.exists(Account.rootByPIN + Account.pendingSuffix)
    }

    // MARK: Cadastro

    /// Primeiro PIN: cria K_dev, sorteia a RK, grava o embrulho sob o PIN.
    /// Devolve a RK aberta, para o chamador derivar a chave de indice e criar a
    /// primeira carteira sem pedir o PIN de novo; quem recebe zera.
    public func setUp(pin: SecureBytes, kdf: KDFParameters? = nil) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        guard !isSetUp else { throw Failure.alreadySetUp }
        guard !PINPolicy.isBlocked(pin.withUnsafeBytes { $0.map { $0 &- 0x30 } }) else { throw Failure.blockedPIN }

        try wrapper.createKey(.device)
        let rk = try SecureBytes.random(count: 32)
        do {
            try writePINSlot(rk: rk, pin: pin, kdf: kdf ?? Self.calibratedPINParameters(), suffix: "")
            try store.add(AttemptRecord.zero.encoded, account: Account.attempts, protection: .standard, context: nil)
        } catch {
            rk.wipe()
            throw error
        }
        return rk
    }

    // MARK: Destrancar

    /// Destranca pela PIN. O incremento de tentativa e gravado **antes** da avaliacao;
    /// se a gravacao falhar, a tentativa nao e avaliada (falha fechada).
    public func unlock(pin: SecureBytes) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        guard isSetUp else { throw Failure.notSetUp }

        var record = try currentAttempts()
        let waiting = record.remaining()
        guard waiting <= 0 else { throw Failure.throttled(seconds: waiting) }

        let next = AttemptRecord.after(failures: record.failures + 1)
        do { try store.update(next.encoded, account: Account.attempts) } catch { throw Failure.storage }

        do {
            // Troca de PIN interrompida: o principal sumiu e o pendente ficou.
            let suffix = store.exists(Account.rootByPIN) ? "" : Account.pendingSuffix
            let rk = try readPINSlot(pin: pin, suffix: suffix)
            record = .zero
            try? store.update(record.encoded, account: Account.attempts)
            return rk
        } catch Failure.wrongPIN {
            if wipeAfterErrorsEnabled, next.failures >= PINPolicy.wipeThreshold {
                wipeAllLocked()
                throw Failure.wiped
            }
            let left = wipeAfterErrorsEnabled ? PINPolicy.wipeThreshold - next.failures : nil
            throw Failure.wrongPIN(remainingBeforeWipe: left)
        }
    }

    /// Destranca pelo Face ID. Bloqueia a thread enquanto o sistema pergunta: chamar
    /// fora do MainActor. O que autoriza e o SEP liberar a chave, nunca um booleano.
    public func unlockWithBiometry(reason: String) throws -> SecureBytes {
        guard let blob = try store.read(Account.rootByBiometry, context: nil), wrapper.hasKey(.biometry) else {
            throw Failure.biometryNotEnabled
        }
        do {
            return try wrapper.unwrap(blob, slot: .biometry, reason: reason)
        } catch EnclaveError.cancelled {
            throw Failure.cancelled
        } catch {
            // O cadastro de rostos mudou: o SEP invalidou K_bio. Apagar o slot em vez
            // de tentar de novo; religar exige o PIN. O ladrao que cadastra o proprio
            // rosto so destroi o atalho.
            disableBiometry()
            throw Failure.biometryChanged
        }
    }

    /// Quanto falta de espera, para a tela de bloqueio mostrar antes do toque.
    public func throttleRemaining() -> TimeInterval {
        (try? currentAttempts().remaining()) ?? 0
    }

    public func failureCount() -> UInt32 {
        (try? currentAttempts().failures) ?? 0
    }

    // MARK: Biometria

    public var isBiometryEnabled: Bool { store.exists(Account.rootByBiometry) && wrapper.hasKey(.biometry) }

    /// Liga o Face ID. Exige a RK aberta, ou seja, o PIN digitado agora.
    public func enableBiometry(rk: SecureBytes) throws {
        try wrapper.createKey(.biometry)
        let blob = try wrapper.wrap(rk, slot: .biometry)
        try? store.delete(Account.rootByBiometry)
        try store.add(blob, account: Account.rootByBiometry, protection: .standard, context: nil)
        if let state = Self.biometryDomainState() {
            try? store.delete(Account.biometryState)
            try? store.add(state, account: Account.biometryState, protection: .standard, context: nil)
        }
    }

    /// Desligar so reduz superficie: nao pede nada, e nunca toca o slot do PIN.
    public func disableBiometry() {
        try? store.delete(Account.rootByBiometry)
        try? store.delete(Account.biometryState)
        wrapper.deleteKey(.biometry)
    }

    /// O cadastro de biometria mudou desde que o Face ID foi ligado aqui?
    public var biometryEnrollmentChanged: Bool {
        guard let saved = try? store.read(Account.biometryState, context: nil), let now = Self.biometryDomainState() else {
            return false
        }
        return saved != now
    }

    static func biometryDomainState() -> Data? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return nil }
        if #available(iOS 18.0, macOS 15.0, *) {
            return context.domainState.biometry.stateHash
        }
        return context.evaluatedPolicyDomainState
    }

    // MARK: Troca de PIN

    /// Duas fases: grava o slot novo com sufixo, confere lendo de volta, e so entao
    /// substitui o principal. Se o app morrer no meio, o slot pendente continua valido
    /// e a leitura o encontra: o dono nunca fica sem caminho de volta.
    public func changePIN(rk: SecureBytes, newPIN: SecureBytes) throws {
        lock.lock(); defer { lock.unlock() }
        guard !PINPolicy.isBlocked(newPIN.withUnsafeBytes { $0.map { $0 &- 0x30 } }) else { throw Failure.blockedPIN }
        let pending = Account.pendingSuffix
        let kdf = Self.calibratedPINParameters()
        try? store.delete(Account.rootByPIN + pending)
        try? store.delete(Account.pinKDF + pending)
        try writePINSlot(rk: rk, pin: newPIN, kdf: kdf, suffix: pending)
        try confirm(pin: newPIN, suffix: pending, matches: rk)

        try store.delete(Account.rootByPIN)
        try store.delete(Account.pinKDF)
        try writePINSlot(rk: rk, pin: newPIN, kdf: kdf, suffix: "")
        try confirm(pin: newPIN, suffix: "", matches: rk)
        try? store.delete(Account.rootByPIN + pending)
        try? store.delete(Account.pinKDF + pending)
    }

    private func confirm(pin: SecureBytes, suffix: String, matches rk: SecureBytes) throws {
        let check = try readPINSlot(pin: pin, suffix: suffix)
        defer { check.wipe() }
        let same = check.withUnsafeBytes { a in rk.withUnsafeBytes { b in Hash.constantTimeEqual(Array(a), Array(b)) } }
        guard same else { throw Failure.storage }
    }

    // MARK: Apagar

    public var wipeAfterErrorsEnabled: Bool {
        (try? store.read(Account.wipeAfterErrors, context: nil)) == Data([1])
    }

    public func setWipeAfterErrors(_ enabled: Bool) throws {
        try? store.delete(Account.wipeAfterErrors)
        if enabled { try store.add(Data([1]), account: Account.wipeAfterErrors, protection: .standard, context: nil) }
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
        try? store.delete(Account.rootByBiometry)
        try? store.deleteAll()
    }

    // MARK: Interno

    private func currentAttempts() throws -> AttemptRecord {
        guard let data = try store.read(Account.attempts, context: nil), var record = AttemptRecord(data) else {
            throw Failure.storage
        }
        // O aparelho reiniciou desde o ultimo erro: o relogio monotonico recomecou do
        // zero. Recomeca a espera cheia agora, em vez de travar por dias ou de zerar.
        if record.failures > 0, record.bootTime != PINPolicy.bootTime {
            record = AttemptRecord.after(failures: record.failures)
            try? store.update(record.encoded, account: Account.attempts)
        }
        return record
    }

    private func writePINSlot(rk: SecureBytes, pin: SecureBytes, kdf: KDFParameters, suffix: String) throws {
        let salt = try SecureBytes.random(count: VaultFormat.saltLength).withUnsafeBytes { Array($0) }
        var kdfRecord = salt
        kdfRecord += kdf.memoryKiB.bigEndianByteArray + kdf.passes.bigEndianByteArray + [kdf.lanes]
        try store.add(Data(kdfRecord), account: Account.pinKDF + suffix, protection: .standard, context: nil)
        let ap = try KeyDerivation.deriveMasterKey(password: pin, salt: salt, parameters: kdf)
        defer { ap.wipe() }
        let blob = try wrapper.wrap(rk, slot: .device)
        try store.add(blob, account: Account.rootByPIN + suffix, protection: .applicationPassword, context: store.applicationPasswordContext(ap))
    }

    private func derivePIN(_ pin: SecureBytes, suffix: String) throws -> SecureBytes {
        guard let record = try store.read(Account.pinKDF + suffix, context: nil), record.count == 25 else {
            throw Failure.notSetUp
        }
        let bytes = [UInt8](record)
        let salt = Array(bytes[0..<16])
        let memory = bytes[16..<20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let passes = bytes[20..<24].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return try KeyDerivation.deriveMasterKey(
            password: pin, salt: salt,
            parameters: KDFParameters(memoryKiB: memory, passes: passes, lanes: bytes[24])
        )
    }

    private func readPINSlot(pin: SecureBytes, suffix: String) throws -> SecureBytes {
        let ap = try derivePIN(pin, suffix: suffix)
        defer { ap.wipe() }
        let blob: Data?
        do {
            blob = try store.read(Account.rootByPIN + suffix, context: store.applicationPasswordContext(ap))
        } catch StoreError.authenticationFailed {
            throw Failure.wrongPIN(remainingBeforeWipe: nil)
        }
        guard let blob else { throw Failure.notSetUp }
        return try wrapper.unwrap(blob, slot: .device, reason: nil)
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
