import CryptoKit
import EscaliburCore
import Foundation
import LocalAuthentication
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
        guard items[account] == nil else { throw StoreError.unexpected(errSecDuplicateItem) }
        items[account] = (data, protection, protection == .applicationPassword ? pendingCredential : nil)
    }

    func update(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let existing = items[account] else { throw StoreError.unexpected(errSecItemNotFound) }
        items[account] = (data, existing.1, existing.2)
    }

    func delete(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
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
    private let lock = NSLock()
    var refuseBiometry = false

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
        keys[slot] = nil
    }

    func wrap(_ secret: SecureBytes, slot: WrapSlot) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[slot] else { throw EnclaveError.keyMissing }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("wrap".utf8), outputByteCount: 32)
        let sealed = try secret.withUnsafeData { try ChaChaPoly.seal($0, using: symmetric) }
        return ephemeral.publicKey.x963Representation + sealed.combined
    }

    func unwrap(_ blob: Data, slot: WrapSlot, reason: String?) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[slot] else { throw EnclaveError.keyMissing }
        if slot == .biometry, refuseBiometry { throw EnclaveError.cancelled }
        guard blob.count > 65 else { throw EnclaveError.failed("embrulho curto") }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: blob.prefix(65))
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("wrap".utf8), outputByteCount: 32)
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob.dropFirst(65)), using: symmetric)
        return SecureBytes.consuming(plain as CFData)
    }
}
