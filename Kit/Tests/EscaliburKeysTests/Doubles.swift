import CryptoKit
import EscaliburCore
import Foundation
import LocalAuthentication
import Testing
@testable import EscaliburKeys

/// Armazenamento em memoria. Simula a recusa por senha de aplicativo comparando a
/// credencial, o que o chaveiro real faz por dentro. `enforcesApplicationPassword`
/// desligado simula o pior caso: a senha de aplicativo ser so uma regra de acesso que
/// quem executa codigo no aparelho contorna. `unknown` simula o chaveiro que nao
/// consegue responder.
final class MemoryStore: SecretStore, @unchecked Sendable {
    private var items: [String: (Data, ItemProtection, Data?)] = [:]
    private let lock = NSLock()
    /// Credencial usada pela proxima leitura ou gravacao com senha de aplicativo.
    var pendingCredential: Data?
    var enforcesApplicationPassword = true
    var unknown: Set<String> = []
    /// Contas cuja exclusao ou alteracao falha (disco cheio, chaveiro mudo).
    var failDeleting: Set<String> = []
    var failUpdating: Set<String> = []
    /// Contas cuja gravacao de um item novo falha.
    var failAdding: Set<String> = []

    func protection(_ account: String) -> ItemProtection? {
        lock.lock(); defer { lock.unlock() }
        return items[account]?.1
    }

    func read(_ account: String, context: LAContext?) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if unknown.contains(account) { throw StoreError.unexpected(errSecInteractionNotAllowed) }
        guard let (data, protection, credential) = items[account] else { return nil }
        if enforcesApplicationPassword, protection == .applicationPassword, credential != pendingCredential {
            throw StoreError.authenticationFailed
        }
        return data
    }

    func add(_ data: Data, account: String, protection: ItemProtection, context: LAContext?) throws {
        lock.lock(); defer { lock.unlock() }
        if failAdding.contains(account) { throw StoreError.unexpected(errSecIO) }
        guard items[account] == nil else { throw StoreError.unexpected(errSecDuplicateItem) }
        items[account] = (data, protection, protection == .applicationPassword ? pendingCredential : nil)
    }

    /// Chamado depois de cada alteracao gravada: o que acontece entre o update e a leitura de
    /// volta.
    var onUpdate: ((String) -> Void)?

    func update(_ data: Data, account: String) throws {
        lock.lock()
        if failUpdating.contains(account) { lock.unlock(); throw StoreError.unexpected(errSecIO) }
        guard let existing = items[account] else { lock.unlock(); throw StoreError.unexpected(errSecItemNotFound) }
        items[account] = (data, existing.1, existing.2)
        let hook = onUpdate
        lock.unlock()
        hook?(account)
    }

    func delete(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failDeleting.contains(account) { throw StoreError.unexpected(errSecIO) }
        items[account] = nil
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }

    func exists(_ account: String) -> Bool { probe(account) == .present }

    func probe(_ account: String) -> ItemState {
        lock.lock(); defer { lock.unlock() }
        if unknown.contains(account) { return .unknown }
        return items[account] != nil ? .present : .absent
    }

    func applicationPasswordContext(_ password: SecureBytes) throws -> LAContext? {
        lock.lock(); defer { lock.unlock() }
        pendingCredential = password.withUnsafeBytes { Data($0) }
        return nil
    }

    /// O conteudo cru de um item, como o veria quem copiasse o chaveiro.
    func raw(_ account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[account]?.0
    }
}

/// Embrulho em software no lugar do Secure Enclave. `refuseBiometry` simula o Face ID
/// recusado (cancelar, rosto nao reconhecido, bloqueio temporario do sistema).
final class SoftwareWrapper: KeyWrapper, @unchecked Sendable {
    private var keys: [WrapSlot: P256.KeyAgreement.PrivateKey] = [:]
    /// A senha de aplicativo de cada chave do PIN, conferida no desembrulho como o SE faz.
    private var passwords: [WrapSlot: Data] = [:]
    private let lock = NSLock()
    var refuseBiometry = false
    /// Recusa o rosto so nestes slots (a segunda confirmacao de uma transicao).
    var refuseSlots: Set<WrapSlot> = []
    /// Quantas vezes cada chave foi usada para abrir: no slot biometrico, quantas vezes
    /// o Face ID apareceu.
    private(set) var unwrapCount: [WrapSlot: Int] = [:]
    var unknownKeys: Set<WrapSlot> = []
    /// Recusa o rosto a partir da enesima abertura deste slot (a confirmacao, nao a
    /// autorizacao).
    var refuseFrom: (slot: WrapSlot, count: Int)?
    /// Quantas vezes o Face ID apareceu, em qualquer chave biometrica. A vigia, aberta na
    /// mesma sessao, nao conta.
    private(set) var faces = 0
    /// Recusa o rosto a partir do enesimo Face ID (contado em `faces`).
    var refuseFaceFrom: Int?
    /// A vigia nao responde na mesma sessao: o contexto que nao serve para a outra chave.
    var watchUnknown = false
    /// Chaves cuja exclusao nao acontece: a queda antes da limpeza.
    var failDeletingKeys: Set<WrapSlot> = []
    /// O SE recusa abrir com estas chaves por um erro que nao vem do Face ID (a chave que
    /// existe e nao serve, como depois de uma redefinicao do Face ID interrompida).
    var failSlots: Set<WrapSlot> = []

    /// O que o SEP faz quando o cadastro de rostos muda: as chaves `.biometryCurrentSet`
    /// deixam de existir. A `.biometryAny` (`kand.qualquer`) continua.
    func invalidateBiometry() {
        lock.lock(); defer { lock.unlock() }
        for slot in WrapSlot.allCases where slot.followsEnrollment { keys[slot] = nil }
    }

    func unwrap(_ blob: Data, slot: WrapSlot, reason: String, watching watch: Data, with watchSlot: WrapSlot) throws -> (SecureBytes, WatchResult) {
        let opened = try unwrap(blob, slot: slot, reason: reason)
        lock.lock(); defer { lock.unlock() }
        if watchUnknown { return (opened, .unknown) }
        guard let key = keys[watchSlot] else { return (opened, .gone) }
        unwrapCount[watchSlot, default: 0] += 1
        // A chave existe mas nao abre esta camada (outra geracao): o SE devolveria um erro
        // que nao se classifica.
        guard let plain = try? Self.open(watch, key: key) else { return (opened, .unknown) }
        return (opened, .opened(plain))
    }

    func probeKey(_ slot: WrapSlot) -> ItemState {
        lock.lock(); defer { lock.unlock() }
        if unknownKeys.contains(slot) { return .unknown }
        return keys[slot] != nil ? .present : .absent
    }
    /// Faz a criacao da chave deste slot falhar (para o teste da migracao interrompida).
    var failCreating: WrapSlot?

    func createKey(_ slot: WrapSlot, password: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if slot == failCreating { throw EnclaveError.unavailable }
        keys[slot] = P256.KeyAgreement.PrivateKey()
        passwords[slot] = password
    }

    func unwrap(_ blob: Data, slot: WrapSlot, password: Data) throws -> SecureBytes {
        lock.lock()
        guard keys[slot] != nil else { lock.unlock(); throw EnclaveError.keyMissing }
        guard passwords[slot] == password else { lock.unlock(); throw EnclaveError.wrongPassword }
        lock.unlock()
        return try unwrap(blob, slot: slot, reason: nil)
    }

    func password(_ slot: WrapSlot) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return passwords[slot]
    }

    func createKey(_ slot: WrapSlot) throws {
        lock.lock(); defer { lock.unlock() }
        if slot == .device, keys[.device] != nil { throw EnclaveError.failed("chave do aparelho ja existe") }
        keys[slot] = P256.KeyAgreement.PrivateKey()
    }

    func hasKey(_ slot: WrapSlot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys[slot] != nil
    }

    func deleteKey(_ slot: WrapSlot) {
        lock.lock(); defer { lock.unlock() }
        if failDeletingKeys.contains(slot) { return }
        keys[slot] = nil
        passwords[slot] = nil
    }

    func wrap(_ secret: SecureBytes, slot: WrapSlot) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[slot] else { throw EnclaveError.keyMissing }
        // A invariante da kand.qualquer, vigiada em todo teste: ela so embrulha o miolo, o ECIES
        // de uma kand.pin, nunca a RK nem outra coisa (o verificar.sh so ve o literal).
        if slot == .hardenedBiometryAny {
            let isMiddle = [WrapSlot.hardenedPINA, .hardenedPINB].contains { pinSlot in
                guard let pinKey = keys[pinSlot] else { return false }
                return secret.withUnsafeData { (try? Self.open($0, key: pinKey)) != nil }
            }
            guard secret.count > 32, isMiddle else {
                Issue.record("a kand.qualquer embrulhou algo que nao e o miolo da kand.pin (\(secret.count) bytes)")
                throw EnclaveError.failed("kand.qualquer so embrulha o miolo")
            }
        }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("wrap".utf8), outputByteCount: 32)
        let sealed = try secret.withUnsafeData { try ChaChaPoly.seal($0, using: symmetric) }
        return ephemeral.publicKey.x963Representation + sealed.combined
    }

    func unwrap(_ blob: Data, slot: WrapSlot, reason: String?) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[slot] else { throw EnclaveError.keyMissing }
        unwrapCount[slot, default: 0] += 1
        if slot.usesBiometry, reason != nil { faces += 1 }
        if failSlots.contains(slot) { throw EnclaveError.failed("desembrulho") }
        if slot.usesBiometry, refuseBiometry || refuseSlots.contains(slot) { throw EnclaveError.cancelled }
        if slot.usesBiometry, let refuseFaceFrom, faces >= refuseFaceFrom { throw EnclaveError.cancelled }
        if let refuseFrom, refuseFrom.slot == slot, unwrapCount[slot, default: 0] >= refuseFrom.count { throw EnclaveError.cancelled }
        return try Self.open(blob, key: key)
    }

    private static func open(_ blob: Data, key: P256.KeyAgreement.PrivateKey) throws -> SecureBytes {
        guard blob.count > 65 else { throw EnclaveError.failed("embrulho curto") }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: blob.prefix(65))
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("wrap".utf8), outputByteCount: 32)
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob.dropFirst(65)), using: symmetric)
        return SecureBytes.consuming(plain as CFData)
    }
}
