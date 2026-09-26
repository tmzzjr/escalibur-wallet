import EscaliburChains
import EscaliburCore
import Foundation
import Testing

/// Utilidades dos testes da TON: fixtures e chaves de teste.
///
/// Chaves privadas aqui sao as dos vetores publicos (trustwallet/wallet-core). Assinar
/// com elas no teste e o que docs/convencoes.md manda: Ed25519 do Core no proprio
/// teste, nunca em codigo de producao de EscaliburChains.
enum TONTestSupport {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ton"))
        return try Data(contentsOf: url)
    }

    static func seed(_ hex: String) throws -> SecureBytes {
        let bytes = try #require([UInt8](hex: hex))
        let seed = SecureBytes(capacity: 32)
        seed.replaceAll(with: bytes)
        return seed
    }

    static func publicKey(seed hex: String) throws -> [UInt8] {
        let seed = try seed(hex)
        defer { seed.wipe() }
        return try Ed25519.publicKey(of: seed)
    }

    static func sign(_ message: [UInt8], seed hex: String) throws -> [UInt8] {
        let seed = try seed(hex)
        defer { seed.wipe() }
        return try Ed25519.sign(message, seed: seed)
    }

    static func address(_ text: String) throws -> TONAddress {
        switch TONAddress.parse(text) {
        case .success(let parsed): return parsed.address
        case .failure(let problem): throw problem
        }
    }

    static func boc(base64 text: String) throws -> TONCell {
        try TONBOC.parseRoot(base64: text)
    }

    /// SLIP-10 Ed25519 (so indices endurecidos), escrito aqui para o teste de frase
    /// nao depender de EscaliburKeys: HMAC-SHA512 com "ed25519 seed", depois
    /// `0x00 || chave || indice` com o chain code.
    static func slip10(seed: [UInt8], path: DerivationPath) -> [UInt8] {
        var i = Hash.hmacSHA512(key: Array("ed25519 seed".utf8), data: seed)
        var key = Array(i.prefix(32))
        var chain = Array(i.suffix(32))
        for index in path.components {
            i = Hash.hmacSHA512(key: chain, data: [0x00] + key + index.bigEndianByteArray)
            key = Array(i.prefix(32))
            chain = Array(i.suffix(32))
        }
        return key
    }
}

// MARK: Formato dos fixtures

struct TONCoreVectors: Decodable {
    struct Wallet: Decodable {
        struct V4: Decodable { let raw, bounceable, nonBounceable: String }
        struct V5: Decodable { let raw, nonBounceable: String }
        let seed, publicKey: String
        let v4r2: V4
        let v5r1: V5
    }
    struct StateInitBOC: Decodable { let hash, crc, plain, indexed: String }
    struct Comment: Decodable { let text, hash, boc: String }
    struct JettonTransfer: Decodable {
        let queryId, amount, destination, responseDestination, forwardTon, comment, hash, boc: String
    }
    let wallets: [Wallet]
    let stateInitBoc: StateInitBOC
    let comments: [Comment]
    let jettonTransferWithComment: JettonTransfer

    static func load() throws -> TONCoreVectors {
        try JSONDecoder().decode(TONCoreVectors.self, from: TONTestSupport.fixture("ton-core-vectors"))
    }
}

struct TrustWalletVectors: Decodable {
    struct Jetton: Decodable { let queryId, amount, destination, responseDestination, forwardTon: String }
    struct Message: Decodable {
        let to, amount: String
        let bounce: Bool
        let comment: String?
        let jetton: Jetton?
    }
    struct Vector: Decodable {
        let source, privateKey, version: String
        let seqno: UInt32
        let validUntil: UInt32
        let deploy: Bool
        let mode: UInt8
        let messages: [Message]
        let boc, hash: String
    }
    let vectors: [Vector]

    static func load() throws -> [Vector] {
        try JSONDecoder().decode(TrustWalletVectors.self, from: TONTestSupport.fixture("trustwallet-sign-vectors")).vectors
    }
}
