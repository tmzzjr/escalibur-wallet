import Foundation
@testable import EscaliburChains
import EscaliburCore

/// Apoio dos testes EVM: fixtures e assinatura com chave de teste conhecida.
///
/// Assinar aqui, no teste, com `Secp256k1` do Core e o que docs/convencoes.md manda
/// para testar de ponta a ponta sem EscaliburKeys. Codigo de producao de
/// EscaliburChains nunca assina.
enum EVMTestSupport {
    static func fixture(_ name: String) throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/evm") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = object as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return root
    }

    static func vectors(_ name: String) throws -> [[String: Any]] {
        (try fixture(name)["vectors"] as? [[String: Any]]) ?? []
    }

    static func privateKey(_ hex: String) -> SecureBytes {
        let key = SecureBytes(capacity: 32)
        key.replaceAll(with: [UInt8](hex: hex)!)
        return key
    }

    static func sign(_ digest: [UInt8], key hex: String) throws -> ProducedSignature {
        let key = privateKey(hex)
        defer { key.wipe() }
        let (compact, recoveryID) = try Secp256k1.signRecoverable(digest: digest, privateKey: key)
        return ProducedSignature(bytes: compact, recoveryID: recoveryID)
    }

    static func account(_ hex: String, path: String = "m/44'/60'/0'/0/0") throws -> EVMAccount {
        let key = privateKey(hex)
        defer { key.wipe() }
        return try EVMAccount(path: DerivationPath(path)!, publicKey: Secp256k1.publicKey(of: key))
    }

    /// Chave de teste fixa, sem valor: a do exemplo da EIP-155.
    static let testKey = "4646464646464646464646464646464646464646464646464646464646464646"

    static func bytes(_ hex: String) -> [UInt8] { [UInt8](hex: hex)! }

    static func big(_ hex: String) -> BigUInt { BigUInt(hex: hex)! }

    static func address(_ text: String) -> EVMAddress { try! EVMAddress(text) }
}
