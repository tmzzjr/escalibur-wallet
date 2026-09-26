import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Apoio dos testes UTXO: fixtures, chaves de teste e um montador de ASM minimo.
///
/// A assinatura aqui usa o `Secp256k1` do Core direto, com chaves publicadas em
/// vetores (nunca em codigo de producao de EscaliburChains, que nao assina).
enum UTXOFixtures {
    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/utxo"))
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url(name)))
    }

    static func bytes(_ hex: String) -> [UInt8] { [UInt8](hex: hex)! }

    /// Chave privada de teste num buffer seguro, como o assinador faria.
    static func key(_ hex: String) -> SecureBytes {
        let key = SecureBytes(capacity: 32)
        key.replaceAll(with: bytes(hex))
        return key
    }

    /// WIF comprimido (prefixo 0x80, sufixo 0x01) para os 32 bytes da chave.
    static func wif(_ text: String) throws -> SecureBytes {
        let payload = try #require(Base58.bitcoin.decodeCheck(text))
        try #require(payload.count == 34 && payload[0] == 0x80 && payload[33] == 0x01)
        let key = SecureBytes(capacity: 32)
        key.replaceAll(with: Array(payload[1..<33]))
        return key
    }

    static func sign(_ digest: [UInt8], with key: SecureBytes) throws -> ProducedSignature {
        ProducedSignature(bytes: try Secp256k1.signDER(digest: digest, privateKey: key))
    }

    /// ASM das fixtures do bitcoinjs: so os opcodes que aparecem nelas.
    static func asm(_ text: String) throws -> [UInt8] {
        var opcodes: [String: UInt8] = [
            "OP_0": 0x00, "OP_DUP": 0x76, "OP_HASH160": 0xA9, "OP_EQUALVERIFY": 0x88,
            "OP_CHECKSIG": 0xAC, "OP_EQUAL": 0x87, "OP_CHECKMULTISIG": 0xAE, "OP_CODESEPARATOR": 0xAB,
        ]
        for n in 1...16 { opcodes["OP_\(n)"] = 0x50 + UInt8(n) }
        var out = [UInt8]()
        for token in text.split(separator: " ") {
            if let op = opcodes[String(token)] {
                out.append(op)
            } else {
                let data = try #require([UInt8](hex: String(token)))
                out += UTXOScript.push(data)
            }
        }
        return out
    }

    static let hardened = DerivationPath.hardened
    static func path(_ purpose: UInt32, _ coin: UInt32, _ account: UInt32 = 0, _ chain: UInt32, _ index: UInt32) -> DerivationPath {
        DerivationPath(components: [hardened(purpose), hardened(coin), hardened(account), chain, index])
    }
}
