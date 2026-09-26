import CryptoKit
import EscaliburCore
import EscaliburKeys
import Foundation
import LocalAuthentication
import Security

/// Os objetos do modulo de chaves, montados uma vez.
///
/// No aparelho, o embrulho e sempre o Secure Enclave, sem alternativa: se ele nao
/// existir, a carteira nao cria nem importa nada. No simulador, que nao tem SE, um
/// embrulho em software persistido no chaveiro do simulador toma o lugar. Esse
/// caminho so compila para simulador (`targetEnvironment(simulator)`).
enum KeyServices {
    static let store = KeychainStore()

    static let wrapper: any KeyWrapper = {
        #if targetEnvironment(simulator)
        return SimulatorWrapper()
        #else
        return SecureEnclaveWrapper()
        #endif
    }()

    static let root = RootKeyVault(store: store, wrapper: wrapper)
    static let wallets = WalletVault(store: store)

    /// O aparelho pode guardar carteira? Precisa de codigo configurado e de SE.
    static var deviceIsEligible: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) && SecureEnclaveWrapper.isAvailable
        #endif
    }

    static var biometryAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// O item do chaveiro sobrevive a desinstalacao do app. Na primeira abertura
    /// depois de instalar, se o marcador nao existe e ha itens, eles sao apagados:
    /// "apagar o app apaga as carteiras" passa a ser verdade, e reinstalar para zerar
    /// o contador de tentativas destroi o que se queria atacar.
    static func firstLaunchCleanup() {
        let marker = "instalacao.marcada"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        root.wipeAll()
        MetadataStore.deleteFile()
        UserDefaults.standard.set(true, forKey: marker)
    }
}

#if targetEnvironment(simulator)
/// Embrulho em software com as chaves P-256 no chaveiro do simulador. Existe so
/// porque o simulador nao tem Secure Enclave; nunca compila para aparelho.
final class SimulatorWrapper: KeyWrapper, @unchecked Sendable {
    private let store = KeychainStore()

    private func key(_ slot: WrapSlot) -> P256.KeyAgreement.PrivateKey? {
        guard let raw = try? store.read("sim.\(slot.rawValue)", context: nil) else { return nil }
        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    func createKey(_ slot: WrapSlot) throws {
        deleteKey(slot)
        try store.add(P256.KeyAgreement.PrivateKey().rawRepresentation, account: "sim.\(slot.rawValue)", protection: .standard, context: nil)
    }

    func hasKey(_ slot: WrapSlot) -> Bool { key(slot) != nil }

    func deleteKey(_ slot: WrapSlot) { try? store.delete("sim.\(slot.rawValue)") }

    func wrap(_ secret: SecureBytes, slot: WrapSlot) throws -> Data {
        guard let key = key(slot) else { throw EnclaveError.keyMissing }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let symmetric = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("wrap".utf8), outputByteCount: 32)
        let sealed = try secret.withUnsafeData { try ChaChaPoly.seal($0, using: symmetric) }
        return ephemeral.publicKey.x963Representation + sealed.combined
    }

    func unwrap(_ blob: Data, slot: WrapSlot, reason: String?) throws -> SecureBytes {
        guard let key = key(slot) else { throw slot == .biometry ? EnclaveError.biometryChanged : EnclaveError.keyMissing }
        if slot == .biometry {
            // O Face ID simulado (Features > Face ID no simulador) decide aqui.
            let context = LAContext()
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var allowed = false
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason ?? "Destravar") { ok, _ in
                allowed = ok
                semaphore.signal()
            }
            semaphore.wait()
            guard allowed else { throw EnclaveError.cancelled }
        }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: blob.prefix(65))
        let symmetric = try key.sharedSecretFromKeyAgreement(with: ephemeral)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("wrap".utf8), outputByteCount: 32)
        var plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob.dropFirst(65)), using: symmetric)
        let out = SecureBytes(capacity: max(plain.count, 1))
        plain.withUnsafeMutableBytes { raw in
            out.append(contentsOf: raw.bindMemory(to: UInt8.self).withMemoryRebound(to: UInt8.self) { UnsafeBufferPointer($0) })
            if let base = raw.baseAddress { memset_s(base, raw.count, 0, raw.count) }
        }
        return out
    }
}
#endif
