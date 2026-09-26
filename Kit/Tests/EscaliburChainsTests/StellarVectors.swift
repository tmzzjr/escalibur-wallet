import EscaliburCore
import Foundation
@testable import EscaliburChains

// Vetores e chaves de teste da Stellar, compartilhados pelas suites Stellar*.
//
// Fixtures/stellar/vetores.json guarda, com a fonte de cada um:
// - js-stellar-base (github.com/stellar/js-stellar-base, commit 6ad55f78):
//   test/unit/transaction_envelope_test.js e test/unit/transaction_builder_test.js;
// - go-stellar-sdk (github.com/stellar/go-stellar-sdk, commit 7092f4b1), o sucessor
//   oficial de stellar/go: txnbuild/transaction_test.go e change_trust_test.go,
//   transacoes montadas de entradas conhecidas e assinadas com Ed25519
//   deterministico, entao o envelope inteiro e reproduzivel byte a byte;
// - rede principal: transacoes aceitas pela rede, lidas de
//   horizon.stellar.org/transactions/{hash}; o hash e o id que a rede atribuiu.

struct StellarFixtures: Decodable {
    struct JSVector: Decodable {
        let nome: String
        let arquivo: String
        let teste: String
        let rede: String
        let hash: String?
        let envelope: String
    }

    struct Refused: Decodable {
        let nome: String
        let arquivo: String
        let teste: String
        let envelope: String
        let motivo: String
    }

    struct GoVector: Decodable {
        let arquivo: String
        let rede: String
        let envelope: String
    }

    struct Muxed: Decodable {
        let strkey: String
        let id: String
        let base: String
    }

    struct Mainnet: Decodable {
        let nome: String
        let hash: String
        let envelope: String
        let muxedDestino: Muxed?
        let nota: String?
    }

    let jsStellarBase: [JSVector]
    let jsStellarBaseRecusados: [Refused]
    let goStellarSdk: [String: GoVector]
    let mainnet: [Mainnet]

    struct Missing: Error {}

    static func load() throws -> StellarFixtures {
        guard let url = Bundle.module.url(forResource: "vetores", withExtension: "json", subdirectory: "Fixtures/stellar") else {
            throw Missing()
        }
        return try JSONDecoder().decode(StellarFixtures.self, from: Data(contentsOf: url))
    }
}

enum StellarTestKeys {
    /// Passphrase da testnet, so para os vetores do go-stellar-sdk, que foram
    /// gerados nela. Nunca aparece em codigo de producao.
    static let testnetPassphrase = "Test SDF Network ; September 2015"
    static let testnetID = Hash.sha256(Array(testnetPassphrase.utf8))

    /// SEP-0005, Test 1 (github.com/stellar/stellar-protocol, ecosystem/sep-0005.md):
    /// "illness spike retreat truth genius clock brain pass fit cave bargain toe".
    static let sep5Account0 = "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"
    static let sep5Secret0 = "SBGWSG6BTNCKCOB3DIFBGCVMUPQFYPA2G4O34RMTB343OYPXU5DJDVMN"
    static let sep5Account1 = "GBAW5XGWORWVFE2XTJYDTLDHXTY2Q2MO73HYCGB3XMFMQ562Q2W2GJQX"
    static let sep5Account2 = "GAY5PRAHJ2HIYBYCLZXTHID6SPVELOOYH2LBPH3LD4RUMXUW3DOYTLXW"

    /// go-stellar-sdk txnbuild/helpers_test.go: newKeypair0, 1 e 2.
    static let goSecret0 = "SBPQUZ6G4FZNWFHKUWC5BEYWF6R52E3SEP7R3GWYSM2XTKGF5LNTWW4R"
    static let goAccount0 = "GDQNY3PBOJOKYZSRMK2S7LHHGWZIUISD4QORETLMXEWXBI7KFZZMKTL3"
    static let goSecret1 = "SBMSVD4KKELKGZXHBUQTIROWUAPQASDX7KEJITARP4VMZ6KLUHOGPTYW"
    static let goAccount1 = "GAS4V4O2B7DW5T7IQRPEEVCRXMDZESKISR7DVIGKZQYYV3OSQ5SH5LVP"
    static let goSecret2 = "SBZVMB74Z76QZ3ZOY7UTDFYKMEGKW5XFJEB6PFKBF4UYSSWHG4EDH7PY"
    static let goAccount2 = "GB7BDSZU2Y27LYNLALKKALB52WS2IZWYBDGY6EQBLEED3TJOCVMZRH7H"

    /// A semente Ed25519 de 32 bytes de um `S...`, em buffer seguro, so no teste.
    static func seed(_ secret: String) throws -> SecureBytes {
        guard let raw = StellarKey.decode(secret, version: StellarKey.seedVersion), raw.count == 32 else {
            throw StellarXDRError.invalidAccount
        }
        let buffer = SecureBytes(capacity: 32)
        buffer.replaceAll(with: raw)
        return buffer
    }

    static func account(_ address: String) throws -> StellarAccountID {
        guard let account = StellarAccountID(address: address) else { throw StellarXDRError.invalidAccount }
        return account
    }

    static func muxed(_ address: String) throws -> StellarMuxedAccount {
        guard let account = StellarMuxedAccount(address: address) else { throw StellarXDRError.invalidAccount }
        return account
    }

    static func bytes(base64: String) throws -> [UInt8] {
        guard let data = Data(base64Encoded: base64) else { throw StellarXDRError.invalidBase64 }
        return Array(data)
    }
}
