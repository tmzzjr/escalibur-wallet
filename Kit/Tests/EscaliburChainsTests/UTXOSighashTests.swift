import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// O digesto que se assina, contra os vetores de referencia e contra assinaturas
/// que a rede ja aceitou. Um digesto errado nao perde dinheiro (a assinatura nao
/// vale), mas um digesto que ignora um campo deixaria o provedor trocar esse campo.
@Suite("UTXO sighash")
struct UTXOSighashTests {
    @Test("Legado: sighash.json do Bitcoin Core (subconjunto de 103 vetores)")
    func coreLegacy() throws {
        // Fonte: bitcoin/bitcoin src/test/data/sighash.json. Formato: tx crua, script,
        // indice, hashType (int32 com sinal) e o resultado em GetHex (bytes invertidos).
        // Os scripts trazem OP_CODESEPARATOR, e os hashTypes cobrem ALL, NONE, SINGLE
        // e ANYONECANPAY, inclusive valores fora dos quatro canonicos.
        let rows = try #require(try UTXOFixtures.json("sighash-subset") as? [[Any]])
        let vectors = rows.dropFirst()
        #expect(vectors.count == 103)
        for row in vectors {
            let tx = try UTXOTransaction(hex: row[0] as! String)
            let script = UTXOFixtures.bytes(row[1] as! String)
            let index = row[2] as! Int
            let hashType = UInt32(bitPattern: Int32(row[3] as! Int))
            let digest = UTXOSighash.legacy(transaction: tx, inputIndex: index, scriptCode: script, hashType: hashType)
            #expect(Hex.encode(digest.reversed()) == row[4] as? String, "vetor \(row[4])")
        }
    }

    @Test("Legado: SIGHASH_SINGLE sem saida correspondente devolve uint256::ONE")
    func singleBug() throws {
        // script/interpreter.cpp: "nOut out of range" devolve uint256::ONE, que na
        // memoria (e na assinatura) e 01 seguido de 31 zeros.
        let tx = try UTXOTransaction(hex: "010000000200000000000000000000000000000000000000000000000000000000000000000000000000ffffffff00000000000000000000000000000000000000000000000000000000000000000000000000ffffffff01e8030000000000000000000000")
        let digest = UTXOSighash.legacy(transaction: tx, inputIndex: 1, scriptCode: [0x00], hashType: UTXOSighash.single)
        #expect(digest == [1] + [UInt8](repeating: 0, count: 31))
        // Com saida correspondente, e digesto de verdade.
        #expect(UTXOSighash.legacy(transaction: tx, inputIndex: 0, scriptCode: [0x00], hashType: UTXOSighash.single) != digest)
    }

    @Test("bitcoinjs transaction.json: hashForSignature e hashForWitnessV0")
    func bitcoinjs() throws {
        // Fonte: bitcoinjs/bitcoinjs-lib v5.2.0 test/fixtures/transaction.json. Os
        // hashForWitnessV0 sao os do BIP-143, inclusive os seis tipos de sighash do
        // exemplo P2SH-P2WSH 6 de 6.
        let root = try #require(try UTXOFixtures.json("bitcoinjs-transaction") as? [String: Any])
        for vector in try #require(root["hashForSignature"] as? [[String: Any]]) {
            let tx = try UTXOTransaction(hex: vector["txHex"] as! String)
            let digest = UTXOSighash.legacy(
                transaction: tx, inputIndex: vector["inIndex"] as! Int,
                scriptCode: try UTXOFixtures.asm(vector["script"] as! String), hashType: UInt32(vector["type"] as! Int)
            )
            #expect(digest.hex == vector["hash"] as? String)
        }
        let witness = try #require(root["hashForWitnessV0"] as? [[String: Any]])
        #expect(witness.count == 8)
        for vector in witness {
            let tx = try UTXOTransaction(hex: vector["txHex"] as! String)
            let digest = UTXOSighash.segwitV0(
                transaction: tx, inputIndex: vector["inIndex"] as! Int,
                scriptCode: try UTXOFixtures.asm(vector["script"] as! String),
                amount: UInt64(vector["value"] as! Int), hashType: UInt32(vector["type"] as! Int)
            )
            #expect(digest.hex == vector["hash"] as? String, "\(vector["description"] ?? "")")
        }
    }

    @Test("BIP-143, exemplo native P2WPKH: digestos intermediarios, sighash e as duas assinaturas")
    func bip143Native() throws {
        let tx = try UTXOTransaction(hex: UTXOBIP143Vectors.nativeUnsigned)
        let parts = UTXOSighash.bip143Parts(tx, inputIndex: 1, hashType: UTXOSighash.all)
        #expect(parts.hashPrevouts.hex == "96b827c8483d4e9b96712b6713a7b68d6e8003a781feba36c31143470b4efd37")
        #expect(parts.hashSequence.hex == "52b0a642eea2fb7ae638c36f6252b6750293dbe574a806984b8e4d8548339a3b")
        #expect(parts.hashOutputs.hex == "863ef3e1a92afbfdb97f31ad0fc7683ee943e9abcf2501590ff8f6551f47e5e5")

        let pub1 = UTXOFixtures.bytes(UTXOBIP143Vectors.nativePub1)
        let key1 = UTXOFixtures.key(UTXOBIP143Vectors.nativeKey1)
        #expect(try Secp256k1.publicKey(of: key1) == pub1)
        let digest1 = UTXOSighash.segwitV0(
            transaction: tx, inputIndex: 1, scriptCode: UTXOScript.p2pkh(Hash.hash160(pub1)),
            amount: 600_000_000, hashType: UTXOSighash.all
        )
        #expect(digest1.hex == "c37af31116d1b27caf68aae9e3ac82f1477929014d5b917657d0eb49478cb670")
        // RFC 6979 e deterministico: a assinatura do BIP sai igual, byte a byte.
        #expect(try Secp256k1.signDER(digest: digest1, privateKey: key1).hex
                == "304402203609e17b84f6a7d30c80bfa610b5b4542f32a8a0d5447a12fb1366d7f01cc44a0220573a954c4518331561406f90300e8f3358f51928d43c212a8caed02de67eebee")

        // A primeira entrada e P2PK legado: o digesto legado com o scriptPubKey dela
        // reproduz a outra assinatura do exemplo.
        let digest0 = UTXOSighash.legacy(transaction: tx, inputIndex: 0, scriptCode: UTXOFixtures.bytes(UTXOBIP143Vectors.nativeScript0), hashType: UTXOSighash.all)
        let key0 = UTXOFixtures.key(UTXOBIP143Vectors.nativeKey0)
        let sig0 = try Secp256k1.signDER(digest: digest0, privateKey: key0)
        #expect(sig0.hex == "30450221008b9d1dc26ba6a9cb62127b02742fa9d754cd3bebf337f7a55d114c8e5cdd30be022040529b194ba3f9281a99f2b1c0a19c0489bc22ede944ccf4ecbab4cc618ef3ed")

        // Com as duas, a transacao assinada do BIP sai identica.
        var signed = tx
        signed.inputs[0].scriptSig = UTXOScript.push(sig0 + [0x01])
        signed.inputs[1].witness = [try Secp256k1.signDER(digest: digest1, privateKey: key1) + [0x01], pub1]
        #expect(signed.serialized().hex == UTXOBIP143Vectors.nativeSigned)
    }

    @Test("BIP-143, exemplo P2SH-P2WPKH: digestos intermediarios e sighash")
    func bip143Nested() throws {
        let tx = try UTXOTransaction(hex: UTXOBIP143Vectors.nestedUnsigned)
        let parts = UTXOSighash.bip143Parts(tx, inputIndex: 0, hashType: UTXOSighash.all)
        #expect(parts.hashPrevouts.hex == "b0287b4a252ac05af83d2dcef00ba313af78a3e9c329afa216eb3aa2a7b4613a")
        #expect(parts.hashSequence.hex == "18606b350cd8bf565266bc352f0caddcf01e8fa789dd8a15386327cf8cabe198")
        #expect(parts.hashOutputs.hex == "de984f44532e2173ca0d64314fcefe6d30da6f8cf27bafa706da61df8a226c83")
        let pub = UTXOFixtures.bytes(UTXOBIP143Vectors.nestedPub)
        let digest = UTXOSighash.segwitV0(
            transaction: tx, inputIndex: 0, scriptCode: UTXOScript.p2pkh(Hash.hash160(pub)),
            amount: 1_000_000_000, hashType: UTXOSighash.all
        )
        #expect(digest.hex == "64f3b0f4dd2bb3aa1ce8566d220cc74dda9df97d8490cc81d89d735c92e59fb6")
        // O scriptPubKey do exemplo e o P2SH do redeemScript 0014{hash160(pub)}.
        #expect(UTXOInputKind.p2shP2wpkh.scriptPubKey(publicKey: pub).hex == "a9144733f37cf4db86fbc2efed2500b4f4e49f31202387")
    }

    @Test("Assinaturas reais aceitas pela rede conferem com o digesto local (BTC, LTC, DOGE)")
    func realSignatures() throws {
        // Transacoes confirmadas (Fixtures/utxo/real-transactions.json). Para cada
        // entrada P2WPKH, P2SH-P2WPKH ou P2PKH: tira valor e script da transacao
        // anterior conferida, calcula o digesto e verifica a assinatura que esta no
        // bloco. Se o digesto divergisse em um bit, nenhuma verificaria.
        let root = try #require(try UTXOFixtures.json("real-transactions") as? [String: Any])
        var verified = [String: Int]()
        for vector in try #require(root["transactions"] as? [[String: Any]]) {
            let tx = try UTXOTransaction(hex: vector["hex"] as! String)
            let chain = vector["chain"] as! String
            for (index, prevHex) in (vector["previous"] as! [String]).enumerated() {
                let input = tx.inputs[index]
                let spent = try UTXOPreviousOutput.verify(previousTransaction: UTXOFixtures.bytes(prevHex), outpoint: input.outpoint)
                let (type, program) = try #require(UTXOScript.classify(spent.scriptPubKey))
                let signature: [UInt8]
                let pub: [UInt8]
                let digest: [UInt8]
                switch type {
                case .p2wpkh:
                    try #require(input.witness.count == 2)
                    (signature, pub) = (input.witness[0], input.witness[1])
                    #expect(Hash.hash160(pub) == program)
                    digest = UTXOSighash.segwitV0(transaction: tx, inputIndex: index, scriptCode: UTXOScript.p2pkh(program),
                                                  amount: spent.value, hashType: UInt32(signature.last!))
                case .p2sh:
                    try #require(input.witness.count == 2)
                    (signature, pub) = (input.witness[0], input.witness[1])
                    #expect(UTXOInputKind.p2shP2wpkh.scriptPubKey(publicKey: pub) == spent.scriptPubKey)
                    digest = UTXOSighash.segwitV0(transaction: tx, inputIndex: index, scriptCode: UTXOScript.p2pkh(Hash.hash160(pub)),
                                                  amount: spent.value, hashType: UInt32(signature.last!))
                case .p2pkh:
                    let pushes = try Self.pushes(input.scriptSig)
                    try #require(pushes.count == 2)
                    (signature, pub) = (pushes[0], pushes[1])
                    #expect(Hash.hash160(pub) == program)
                    digest = UTXOSighash.legacy(transaction: tx, inputIndex: index, scriptCode: spent.scriptPubKey,
                                                hashType: UInt32(signature.last!))
                default:
                    Issue.record("tipo inesperado \(type)")
                    continue
                }
                let der = Array(signature.dropLast())
                #expect(UTXOSigning.isStrictDER(der))
                #expect(Secp256k1.verifyDER(signature: der, digest: digest, publicKey: pub), "\(chain) \(tx.txid) entrada \(index)")
                verified[chain, default: 0] += 1
            }
        }
        #expect(verified == ["bitcoin": 7, "litecoin": 2, "dogecoin": 3])
    }

    @Test("DER estrito (BIP-66)")
    func strictDER() throws {
        let good = UTXOFixtures.bytes("304402203609e17b84f6a7d30c80bfa610b5b4542f32a8a0d5447a12fb1366d7f01cc44a0220573a954c4518331561406f90300e8f3358f51928d43c212a8caed02de67eebee")
        #expect(UTXOSigning.isStrictDER(good))
        var bad = good; bad[0] = 0x31
        #expect(!UTXOSigning.isStrictDER(bad))
        bad = good; bad[1] = 0x45
        #expect(!UTXOSigning.isStrictDER(bad))
        // R com zero a esquerda desnecessario.
        let padded = [0x30, 0x45, 0x02, 0x21, 0x00] + Array(good[4..<36]) + Array(good[36...])
        #expect(!UTXOSigning.isStrictDER(padded))
        // R negativo (bit alto sem o zero).
        bad = good; bad[4] = 0x80
        #expect(!UTXOSigning.isStrictDER(bad))
        #expect(!UTXOSigning.isStrictDER(Array(good.dropLast())))
        #expect(!UTXOSigning.isStrictDER(good + [0x01]))
    }

    /// Os pushes de um scriptSig simples (so push direto de ate 75 bytes).
    static func pushes(_ script: [UInt8]) throws -> [[UInt8]] {
        var out = [[UInt8]]()
        var i = 0
        while i < script.count {
            let n = Int(script[i])
            try #require(n > 0 && n < 0x4C && i + 1 + n <= script.count)
            out.append(Array(script[(i + 1)..<(i + 1 + n)]))
            i += 1 + n
        }
        return out
    }
}
