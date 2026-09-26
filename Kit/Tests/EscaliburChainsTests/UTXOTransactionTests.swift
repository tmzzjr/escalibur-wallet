import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Serializacao, parse, txid e wtxid contra vetores de outras implementacoes e contra
/// transacoes reais confirmadas. Se um destes quebrar, a conferencia da transacao
/// anterior (a defesa contra provedor mentindo valor) deixa de valer.
@Suite("UTXO transacao")
struct UTXOTransactionTests {
    @Test("Coinbase do bloco genesis: txid conhecido")
    func genesis() throws {
        // Bloco 0 do Bitcoin, a transacao que todo explorador mostra.
        let raw = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"
        let tx = try UTXOTransaction(hex: raw)
        #expect(tx.txid.hex == "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b")
        #expect(tx.wtxid == tx.txid)
        #expect(tx.outputs.first?.value == 5_000_000_000)
        #expect(tx.serialized().hex == raw)
    }

    @Test("tx_valid.json do Bitcoin Core: parse e reserializacao byte a byte")
    func coreValid() throws {
        // Fonte: bitcoin/bitcoin src/test/data/tx_valid.json (Fixtures/utxo/tx-valid-serialized.json).
        let root = try #require(try UTXOFixtures.json("tx-valid-serialized") as? [String: Any])
        let list = try #require(root["transactions"] as? [String])
        #expect(list.count > 80)
        for hex in list {
            let tx = try UTXOTransaction(hex: hex)
            #expect(tx.serialized().hex == hex, "reserializacao diferente: \(hex.prefix(40))")
        }
    }

    @Test("bitcoinjs transaction.json: txid, peso e tamanho virtual, com e sem witness")
    func bitcoinjsValid() throws {
        // Fonte: bitcoinjs/bitcoinjs-lib v5.2.0 test/fixtures/transaction.json, "valid".
        let root = try #require(try UTXOFixtures.json("bitcoinjs-transaction") as? [String: Any])
        let valid = try #require(root["valid"] as? [[String: Any]])
        #expect(valid.count == 20)
        for vector in valid {
            // "whex" vazio ou ausente: transacao sem witness, a forma completa e "hex".
            let witnessHex = (vector["whex"] as? String) ?? ""
            let full = witnessHex.isEmpty ? vector["hex"] as! String : witnessHex
            let tx = try UTXOTransaction(hex: full)
            let name = vector["description"] as! String
            #expect(tx.txid.hex == vector["id"] as? String, "\(name)")
            #expect(tx.weight == vector["weight"] as? Int, "\(name)")
            #expect(tx.virtualSize == vector["virtualSize"] as? Int, "\(name)")
            #expect(tx.serialized().hex == full, "\(name)")
            #expect(tx.serializedWithoutWitness().hex == vector["hex"] as? String, "\(name)")
        }
    }

    @Test("Transacoes reais (BTC, LTC, DOGE): txid, peso e tamanho")
    func realTransactions() throws {
        // Fonte: mempool.space e api.blockcypher.com (ver Fixtures/utxo/real-transactions.json).
        let root = try #require(try UTXOFixtures.json("real-transactions") as? [String: Any])
        let list = try #require(root["transactions"] as? [[String: Any]])
        #expect(list.count == 10)
        for vector in list {
            let hex = vector["hex"] as! String
            let tx = try UTXOTransaction(hex: hex)
            let txid = vector["txid"] as! String
            #expect(tx.txid.hex == txid)
            #expect(tx.serialized().hex == hex)
            #expect(tx.serialized().count == vector["size"] as? Int)
            if let weight = vector["weight"] as? Int { #expect(tx.weight == weight, "\(txid)") }
            // Com witness, o wtxid difere do txid; sem, e o mesmo.
            #expect((tx.wtxid == tx.txid) == !tx.hasWitness)
        }
    }

    @Test("BIP-143: txid e wtxid das transacoes assinadas dos exemplos")
    func bip143Ids() throws {
        // Transacoes assinadas do BIP-143 (bitcoin/bips bip-0143.mediawiki). Os ids
        // foram calculados por hashlib do Python sobre os mesmos bytes, uma
        // implementacao independente desta.
        let native = try UTXOTransaction(hex: UTXOBIP143Vectors.nativeSigned)
        #expect(native.txid.hex == "e8151a2af31c368a35053ddd4bdb285a8595c769a3ad83e0fa02314a602d4609")
        #expect(native.wtxid.hex == "c36c38370907df2324d9ce9d149d191192f338b37665a82e78e76a12c909b762")
        #expect(native.weight == 1042)
        // A primeira entrada (P2PK) nao tem witness: a pilha vazia precisa ir para o fio.
        #expect(native.inputs[0].witness.isEmpty)
        #expect(native.serialized().hex == UTXOBIP143Vectors.nativeSigned)

        let nested = try UTXOTransaction(hex: UTXOBIP143Vectors.nestedSigned)
        #expect(nested.txid.hex == "ef48d9d0f595052e0f8cdcf825f7a5e50b6a388a81f206f3f4846e5ecd7a0c23")
        #expect(nested.wtxid.hex == "680f483b2bf6c5dcbf111e69e885ba248a41a5e92070cfb0afec3cfc49a9fabb")
        // O txid e o da serializacao sem witness, que e a transacao nao assinada com o
        // scriptSig do P2SH.
        #expect(nested.serializedWithoutWitness().count < nested.serialized().count)
    }

    @Test("Parse recusa o que o no recusa")
    func strictParse() throws {
        let good = try UTXOTransaction(hex: UTXOBIP143Vectors.nestedSigned)
        let raw = good.serialized()

        // Byte a mais no fim.
        #expect(throws: UTXOTransaction.ParseError.trailingBytes) { try UTXOTransaction(parsing: raw + [0]) }
        // Truncada em qualquer ponto.
        for cut in [1, 5, 40, raw.count / 2, raw.count - 1] {
            #expect(throws: (any Error).self) { try UTXOTransaction(parsing: Array(raw.prefix(cut))) }
        }
        // Flag de witness desconhecida (0x02).
        var badFlag = raw
        badFlag[5] = 0x02
        #expect(throws: UTXOTransaction.ParseError.unknownWitnessFlag) { try UTXOTransaction(parsing: badFlag) }
        // Witness declarada e toda vazia: "Superfluous witness record" no Core.
        var empty = good
        empty.inputs[0].witness = []
        var forged = [UInt8](raw.prefix(4)) + [0x00, 0x01] + Array(empty.serializedWithoutWitness().dropFirst(4).dropLast(4)) + [0x00] + Array(raw.suffix(4))
        #expect(throws: UTXOTransaction.ParseError.superfluousWitness) { try UTXOTransaction(parsing: forged) }
        // CompactSize nao canonico: 1 entrada escrita como fd 01 00.
        let legacy = try UTXOTransaction(hex: "0100000001ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000006b483045022100a3b254e1c10b5d039f36c05f323995d6e5a367d98dd78a13d5bbc3991b35720e022022fccea3897d594de0689601fbd486588d5bfa6915be2386db0397ee9a6e80b601210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798ffffffff0110270000000000001976a914aa4d7985c57e011a8b3dd8e0e5a73aaef41629c588ac00000000")
        forged = legacy.serialized()
        forged.replaceSubrange(4..<5, with: [0xFD, 0x01, 0x00])
        #expect(throws: UTXOTransaction.ParseError.nonCanonicalCompactSize) { try UTXOTransaction(parsing: forged) }
        // Contagem de entradas maior que os bytes que existem.
        forged = legacy.serialized()
        forged.replaceSubrange(4..<5, with: [0xFD, 0xFF, 0xFF])
        #expect(throws: UTXOTransaction.ParseError.truncated) { try UTXOTransaction(parsing: forged) }
        // Zero entradas sem flag de witness.
        #expect(throws: UTXOTransaction.ParseError.noInputs) {
            try UTXOTransaction(parsing: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        }
    }

    @Test("Transacao anterior: o txid prova o valor")
    func previousTransaction() throws {
        let root = try #require(try UTXOFixtures.json("real-transactions") as? [String: Any])
        let list = try #require(root["transactions"] as? [[String: Any]])
        for vector in list {
            let tx = try UTXOTransaction(hex: vector["hex"] as! String)
            let previous = vector["previous"] as! [String]
            for (index, prevHex) in previous.enumerated() {
                let outpoint = tx.inputs[index].outpoint
                let raw = UTXOFixtures.bytes(prevHex)
                let output = try UTXOPreviousOutput.verify(previousTransaction: raw, outpoint: outpoint)
                let parsed = try UTXOTransaction(parsing: raw)
                #expect(output == parsed.outputs[Int(outpoint.vout)])

                // O provedor aumenta o valor em 1 unidade: o txid muda e a moeda cai.
                var inflated = parsed
                inflated.outputs[Int(outpoint.vout)].value += 1
                #expect(throws: UTXOPlanError.previousTransactionMismatch(outpoint)) {
                    try UTXOPreviousOutput.verify(previousTransaction: inflated.serialized(), outpoint: outpoint)
                }
                // Indice de saida que nao existe.
                let beyond = UTXOOutpoint(txid: outpoint.txid, vout: UInt32(parsed.outputs.count))
                #expect(throws: UTXOPlanError.outputIndexOutOfRange(beyond)) {
                    try UTXOPreviousOutput.verify(previousTransaction: raw, outpoint: beyond)
                }
                // Lixo no lugar da transacao.
                #expect(throws: UTXOPlanError.previousTransactionMalformed(outpoint)) {
                    try UTXOPreviousOutput.verify(previousTransaction: Array(raw.dropLast()), outpoint: outpoint)
                }
            }
        }
    }

    @Test("txid: texto de explorador e ordem dos bytes")
    func txidOrder() throws {
        let id = try #require(UTXOTxID(hex: "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"))
        #expect(id.bytes.first == 0x3B)
        #expect(id.hex == "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b")
        #expect(UTXOTxID(hex: "4a5e") == nil)
        #expect(UTXOTxID(hex: "0x" + String(repeating: "0", count: 62)) == nil)
        #expect(UTXOTxID(hex: String(repeating: "g", count: 64)) == nil)
    }
}

/// Os exemplos do BIP-143 (bitcoin/bips, bip-0143.mediawiki).
enum UTXOBIP143Vectors {
    static let nativeUnsigned = "0100000002fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f0000000000eeffffffef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac11000000"
    static let nativeSigned = "01000000000102fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f00000000494830450221008b9d1dc26ba6a9cb62127b02742fa9d754cd3bebf337f7a55d114c8e5cdd30be022040529b194ba3f9281a99f2b1c0a19c0489bc22ede944ccf4ecbab4cc618ef3ed01eeffffffef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac000247304402203609e17b84f6a7d30c80bfa610b5b4542f32a8a0d5447a12fb1366d7f01cc44a0220573a954c4518331561406f90300e8f3358f51928d43c212a8caed02de67eebee0121025476c2e83188368da1ff3e292e7acafcdb3566bb0ad253f62fc70f07aeee635711000000"
    static let nativeKey0 = "bbc27228ddcb9209d7fd6f36b02f7dfa6252af40bb2f1cbc7a557da8027ff866"
    static let nativeScript0 = "2103c9f4836b9a4f77fc0d81f7bcb01b7f1b35916864b9476c241ce9fc198bd25432ac"
    static let nativeKey1 = "619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9"
    static let nativePub1 = "025476c2e83188368da1ff3e292e7acafcdb3566bb0ad253f62fc70f07aeee6357"

    static let nestedUnsigned = "0100000001db6b1b20aa0fd7b23880be2ecbd4a98130974cf4748fb66092ac4d3ceb1a54770100000000feffffff02b8b4eb0b000000001976a914a457b684d7f0d539a46a45bbc043f35b59d0d96388ac0008af2f000000001976a914fd270b1ee6abcaea97fea7ad0402e8bd8ad6d77c88ac92040000"
    static let nestedSigned = "01000000000101db6b1b20aa0fd7b23880be2ecbd4a98130974cf4748fb66092ac4d3ceb1a5477010000001716001479091972186c449eb1ded22b78e40d009bdf0089feffffff02b8b4eb0b000000001976a914a457b684d7f0d539a46a45bbc043f35b59d0d96388ac0008af2f000000001976a914fd270b1ee6abcaea97fea7ad0402e8bd8ad6d77c88ac02473044022047ac8e878352d3ebbde1c94ce3a10d057c24175747116f8288e5d794d12d482f0220217f36a485cae903c713331d877c1f64677e3622ad4010726870540656fe9dcb012103ad1d8e89212f0b92c74d23bb710c00662ad1470198ac48c43f7d6f93a2a2687392040000"
    static let nestedKey = "eb696a065ef48a2192da5b28b694f87544b30fae8327c4510137a922f32c6dcf"
    static let nestedPub = "03ad1d8e89212f0b92c74d23bb710c00662ad1470198ac48c43f7d6f93a2a26873"
}
