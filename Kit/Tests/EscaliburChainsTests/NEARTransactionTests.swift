import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// A transferencia NEAR em Borsh contra duas fontes: o vetor publicado do near-api-js e do
/// wallet-core (a mesma transacao nos dois, `serialize.test.js` e
/// tests/chains/NEAR/SerializationTests.cpp e SignerTests.cpp) e tres transferencias reais
/// aceitas pela rede principal (Fixtures/near), remontadas byte a byte, com o id e a
/// assinatura original conferidos sobre o hash que a carteira calcula.
@Suite("NEAR: transacao")
struct NEARTransactionTests {
    struct Real: Decodable {
        let hash: String
        let signer_id: String
        let public_key: String
        let nonce: UInt64
        let receiver_id: String
        let block_hash: String
        let signature: String
        let deposit: String
        let borsh_hex: String
        let signed_base64: String
    }

    static func reais() throws -> [Real] {
        let url = try #require(Bundle.module.url(forResource: "transferencias-reais", withExtension: "json", subdirectory: "Fixtures/near"))
        return try JSONDecoder().decode([Real].self, from: Data(contentsOf: url))
    }

    static func account(_ text: String) throws -> NEARAccountID {
        guard case .success(let account) = NEARAccountID.parse(text) else { throw NEARBorsh.Failure.nonCanonical }
        return account
    }

    static func base58(_ text: String) throws -> [UInt8] {
        let body = text.hasPrefix("ed25519:") ? String(text.dropFirst(8)) : text
        return try #require(Base58.bitcoin.decode(body))
    }

    static func fields(_ real: Real) throws -> NEARTransferFields {
        NEARTransferFields(
            signer: try account(real.signer_id), publicKey: try base58(real.public_key), nonce: real.nonce,
            receiver: try account(real.receiver_id), blockHash: try base58(real.block_hash),
            deposit: try #require(BigUInt(decimal: real.deposit))
        )
    }

    /// test.near para whatever.near, 1 yocto, nonce 1 (near-api-js e wallet-core).
    static func published() throws -> NEARTransferFields {
        NEARTransferFields(
            signer: try account("test.near"), publicKey: try base58("Anu7LYDfpLtkP7E16LT9imXF694BdQaa9ufVkQiwTQxC"), nonce: 1,
            receiver: try account("whatever.near"), blockHash: try base58("244ZQ9cgj3CQ6bWBdytfrJMuMQ1jdXLFGnr4HhvtCTnM"), deposit: 1
        )
    }

    @Test("Vetor publicado: Borsh, SignedTransaction e hash do near-api-js e do wallet-core")
    func publishedVector() throws {
        let fields = try Self.published()
        #expect(Hex.encode(try fields.serialized()) == "09000000746573742e6e65617200917b3d268d4b58f7fec1b150bd68d69be3ee5d4cc39855e341538465bb77860d01000000000000000d00000077686174657665722e6e6561720fa473fd26901df296be6adc4cc4df34d040efa2435224b6986910e630c2fef6010000000301000000000000000000000000000000")
        #expect(Hex.encode(try fields.hash()) == "eea6e680f3ea51a7f667e9a801d0bfadf66e03d41ed54975b3c6006351461b32")

        // A SignedTransaction do wallet-core (Ed25519 deterministico): a assinatura dela
        // verifica sobre o hash daqui, e a montagem com ela da os mesmos bytes.
        let expected = try #require(Data(base64Encoded: "CQAAAHRlc3QubmVhcgCRez0mjUtY9/7BsVC9aNab4+5dTMOYVeNBU4Rlu3eGDQEAAAAAAAAADQAAAHdoYXRldmVyLm5lYXIPpHP9JpAd8pa+atxMxN800EDvokNSJLaYaRDmMML+9gEAAAADAQAAAAAAAAAAAAAAAAAAAACWmoMzIYbul1Xkg5MlUlgG4Ymj0tK7S0dg6URD6X4cTyLe7vAFmo6XExAO2m4ZFE2n6KDvflObIHCLodjQIb0B"))
        let signature = Array([UInt8](expected).suffix(64))
        #expect(Ed25519.verify(signature: signature, message: try fields.hash(), publicKey: fields.publicKey))
        let transfer = try NEARTransfer(fields: fields, path: DefaultPaths.path(for: .near))
        let signed = try transfer.assemble(with: [ProducedSignature(bytes: signature)])
        #expect(signed.raw == [UInt8](expected))
        #expect(signed.encoded == expected.base64EncodedString())
        #expect(signed.id == Base58.bitcoin.encode(try fields.hash()) && signed.chainID == "near")
    }

    @Test("Transferencias reais da rede principal: Borsh, id e assinatura original")
    func realTransfers() throws {
        let reais = try Self.reais()
        #expect(reais.count == 3)
        #expect(reais.contains { NEARAccountID.isHex($0.receiver_id, count: 64) })
        for real in reais {
            let fields = try Self.fields(real)
            #expect(Hex.encode(try fields.serialized()) == real.borsh_hex, "\(real.hash)")
            #expect(Base58.bitcoin.encode(try fields.hash()) == real.hash)
            let signature = try Self.base58(real.signature)
            #expect(Ed25519.verify(signature: signature, message: try fields.hash(), publicKey: fields.publicKey))
            #expect(Data(try fields.signed(with: signature)).base64EncodedString() == real.signed_base64)

            let raw = [UInt8](try #require(Data(base64Encoded: real.signed_base64)))
            let parsed = try NEARSignedTransaction.parse(SignedTransaction(chainID: "near", raw: raw, encoded: real.signed_base64, id: real.hash))
            #expect(parsed.fields == fields && parsed.signature == signature)
        }
    }

    @Test("Pedido de assinatura: Ed25519 sobre o SHA-256, com a chave da conta implicita")
    func signingRequest() throws {
        let real = try Self.reais()[0]
        let fields = try Self.fields(real)
        let transfer = try NEARTransfer(fields: fields, path: DefaultPaths.path(for: .near))
        let request = try #require(transfer.signingRequests.first)
        #expect(transfer.signingRequests.count == 1)
        #expect(request.curve == .ed25519 && request.scheme == .ed25519)
        #expect(request.payload == (try fields.hash()) && request.payload.count == 32)
        #expect(request.expectedPublicKey == fields.publicKey && request.path.description == "m/44'/397'/0'")
        #expect(throws: SigningError.wrongSignatureCount) { try transfer.assemble(with: []) }
        #expect(throws: SigningError.malformedSignature) { try transfer.assemble(with: [ProducedSignature(bytes: [UInt8](repeating: 1, count: 64))]) }
        #expect(throws: SigningError.malformedSignature) { try transfer.assemble(with: [ProducedSignature(bytes: try Self.base58(real.signature), recoveryID: 0)]) }
    }

    @Test("Leitura de volta: qualquer byte fora do formato da carteira e recusado")
    func decoderRefusals() throws {
        let real = try Self.reais()[0]
        let raw = [UInt8](try #require(Data(base64Encoded: real.signed_base64)))
        let good = SignedTransaction(chainID: "near", raw: raw, encoded: real.signed_base64, id: real.hash)
        func refused(_ signed: SignedTransaction) -> Bool { (try? NEARSignedTransaction.parse(signed)) == nil }
        func signed(_ bytes: [UInt8], id: String = real.hash) -> SignedTransaction {
            SignedTransaction(chainID: "near", raw: bytes, encoded: Data(bytes).base64EncodedString(), id: id)
        }

        #expect(!refused(good))
        #expect(refused(SignedTransaction(chainID: "polkadot", raw: raw, encoded: real.signed_base64, id: real.hash)))
        #expect(refused(SignedTransaction(chainID: "near", raw: raw, encoded: Data(raw.dropLast()).base64EncodedString(), id: real.hash)))
        #expect(refused(signed(raw, id: "8VhtMYxX6hRaD827eaQcptC7Nw623n8FXuf17CdokwTh")))
        #expect(refused(signed(raw + [0])))
        var badSignature = raw
        badSignature[raw.count - 1] ^= 1
        #expect(refused(signed(badSignature)))
        // Chave secp256k1 (tipo 1) no lugar da Ed25519.
        var otherKey = raw
        otherKey[4 + 64] = 1
        #expect(refused(signed(otherKey)))
        // Duas acoes, ou outra acao (FunctionCall = 2) no lugar da Transfer.
        let fields = try Self.fields(real)
        let actionsAt = try fields.serialized().count - 17 - 4
        var twoActions = raw
        twoActions[actionsAt] = 2
        #expect(refused(signed(twoActions)))
        var functionCall = raw
        functionCall[actionsAt + 4] = 2
        #expect(refused(signed(functionCall)))
        // A carteira so assina da conta implicita: signer com nome e recusado.
        let named = try Self.published()
        #expect((try? NEARSignedTransaction.decode(try named.signed(with: [UInt8](repeating: 0, count: 64)))) == nil)
    }

    @Test("u128 do deposito: o maior valor cabe, acima dele nao")
    func depositWidth() throws {
        var fields = try Self.published()
        let max = BigUInt(bigEndian: [UInt8](repeating: 0xFF, count: 16))
        fields = NEARTransferFields(signer: fields.signer, publicKey: fields.publicKey, nonce: 1, receiver: fields.receiver, blockHash: fields.blockHash, deposit: max)
        #expect(Array(try fields.serialized().suffix(16)) == [UInt8](repeating: 0xFF, count: 16))
        let over = NEARTransferFields(signer: fields.signer, publicKey: fields.publicKey, nonce: 1, receiver: fields.receiver, blockHash: fields.blockHash, deposit: max + 1)
        #expect(throws: NEARBorsh.Failure.nonCanonical) { try over.serialized() }
    }
}
