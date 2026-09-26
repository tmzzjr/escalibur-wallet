import CryptoKit
import EscaliburCore
import Foundation
import LocalAuthentication
import Security

/// Chaves de hardware que embrulham a chave raiz (RK).
///
/// Duas chaves P-256 no Secure Enclave:
/// - `K_dev`: so `.privateKeyUsage`. Embrulha a RK para o caminho do PIN. Nao pede
///   presenca, porque quem pede o PIN e o item de chaveiro com senha de aplicativo.
/// - `K_bio`: `.privateKeyUsage` + `.biometryCurrentSet`. Embrulha a RK para o
///   caminho do Face ID. A decisao de liberar e do SEP, nao de um booleano no app, e
///   cadastrar um rosto novo destroi a chave em vez de abri-la.
///
/// Nenhum embrulho abre fora deste aparelho: a parte privada nunca sai do SE.
public protocol KeyWrapper: Sendable {
    func createKey(_ slot: WrapSlot) throws
    func hasKey(_ slot: WrapSlot) -> Bool
    func deleteKey(_ slot: WrapSlot)
    func wrap(_ secret: SecureBytes, slot: WrapSlot) throws -> Data
    /// Abre um embrulho. No slot biometrico, o sistema mostra o Face ID com
    /// `reason`; a chamada bloqueia a thread ate a decisao, entao nunca no MainActor.
    func unwrap(_ blob: Data, slot: WrapSlot, reason: String?) throws -> SecureBytes
}

public enum WrapSlot: String, Sendable, CaseIterable {
    case device = "kdev"
    case biometry = "kbio"
}

public enum EnclaveError: Error, Equatable, Sendable {
    case unavailable
    case keyMissing
    /// O cadastro de biometria mudou desde que a chave foi criada: o SEP invalidou
    /// `K_bio`. O caminho de volta e o PIN.
    case biometryChanged
    case cancelled
    case failed(String)
}

/// O Secure Enclave de verdade.
public final class SecureEnclaveWrapper: KeyWrapper, @unchecked Sendable {
    private static let tagPrefix = "com.thomazjr.escalibur.wallet."
    private static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    public init() {}

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    private func tag(_ slot: WrapSlot) -> Data { Data((Self.tagPrefix + slot.rawValue).utf8) }

    public func createKey(_ slot: WrapSlot) throws {
        deleteKey(slot)
        let flags: SecAccessControlCreateFlags = slot == .device
            ? [.privateKeyUsage]
            : [.privateKeyUsage, .biometryCurrentSet]
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, KeychainStore.accessibility, flags, &error) else {
            throw EnclaveError.failed("controle de acesso")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag(slot),
                kSecAttrAccessControl as String: access,
            ],
        ]
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
            throw EnclaveError.unavailable
        }
    }

    public func hasKey(_ slot: WrapSlot) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        return (try? privateKey(slot, context: context)) != nil
    }

    public func deleteKey(_ slot: WrapSlot) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(slot),
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func privateKey(_ slot: WrapSlot, context: LAContext?) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(slot),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { throw EnclaveError.keyMissing }
        return item as! SecKey  // swiftlint:disable:this force_cast
    }

    public func wrap(_ secret: SecureBytes, slot: WrapSlot) throws -> Data {
        let key = try privateKey(slot, context: nil)
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw EnclaveError.keyMissing }
        var error: Unmanaged<CFError>?
        let blob = secret.withUnsafeData { plain in
            SecKeyCreateEncryptedData(publicKey, Self.algorithm, plain as CFData, &error)
        }
        guard let blob else { throw EnclaveError.failed("embrulho") }
        return blob as Data
    }

    public func unwrap(_ blob: Data, slot: WrapSlot, reason: String?) throws -> SecureBytes {
        let context = LAContext()
        // Nenhum reuso de autenticacao: cada assinatura pede presenca nova.
        context.touchIDAuthenticationAllowableReuseDuration = 0
        if let reason { context.localizedReason = reason } else { context.interactionNotAllowed = true }
        let key: SecKey
        do {
            key = try privateKey(slot, context: context)
        } catch {
            throw slot == .biometry ? EnclaveError.biometryChanged : EnclaveError.keyMissing
        }
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, Self.algorithm, blob as CFData, &error) else {
            let code = (error?.takeRetainedValue() as Error?).map { ($0 as NSError).code } ?? 0
            if code == Int(errSecUserCanceled) || code == LAError.userCancel.rawValue || code == LAError.appCancel.rawValue {
                throw EnclaveError.cancelled
            }
            throw slot == .biometry ? EnclaveError.biometryChanged : EnclaveError.failed("desembrulho")
        }
        return SecureBytes.consuming(plain)
    }
}

/// Embrulho em software, para os testes no Mac e para o simulador, que nao tem
/// Secure Enclave. So existe fora de compilacao para aparelho: verificar.sh recusa
/// qualquer uso dele que nao esteja atras de `targetEnvironment(simulator)` ou em teste.
public final class SoftwareWrapper: KeyWrapper, @unchecked Sendable {
    private var keys: [WrapSlot: P256.KeyAgreement.PrivateKey] = [:]
    private let lock = NSLock()

    public init() {}

    public func createKey(_ slot: WrapSlot) throws {
        lock.lock(); defer { lock.unlock() }
        keys[slot] = P256.KeyAgreement.PrivateKey()
    }

    public func hasKey(_ slot: WrapSlot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys[slot] != nil
    }

    public func deleteKey(_ slot: WrapSlot) {
        lock.lock(); defer { lock.unlock() }
        keys[slot] = nil
    }

    public func wrap(_ secret: SecureBytes, slot: WrapSlot) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[slot] else { throw EnclaveError.keyMissing }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("wrap".utf8), outputByteCount: 32)
        let sealed = try secret.withUnsafeData { try ChaChaPoly.seal($0, using: symmetric) }
        return ephemeral.publicKey.x963Representation + sealed.combined
    }

    public func unwrap(_ blob: Data, slot: WrapSlot, reason: String?) throws -> SecureBytes {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[slot] else { throw slot == .biometry ? EnclaveError.biometryChanged : EnclaveError.keyMissing }
        guard blob.count > 65 else { throw EnclaveError.failed("embrulho curto") }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: blob.prefix(65))
        let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("wrap".utf8), outputByteCount: 32)
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob.dropFirst(65)), using: symmetric)
        return SecureBytes.consuming(plain as CFData)
    }
}

extension SecureBytes {
    /// Copia de um `CFData` que acabou de sair de uma API do sistema para o buffer
    /// seguro, e apaga a origem. O `CFData` e imutavel pela API, mas a memoria e do
    /// processo: zerar e o que encurta a janela do segredo em claro.
    static func consuming(_ data: CFData) -> SecureBytes {
        let length = CFDataGetLength(data)
        let out = SecureBytes(capacity: max(length, 1))
        if let pointer = CFDataGetBytePtr(data), length > 0 {
            out.append(contentsOf: UnsafeBufferPointer(start: pointer, count: length))
            memset_s(UnsafeMutableRawPointer(mutating: pointer), length, 0, length)
        }
        return out
    }
}
