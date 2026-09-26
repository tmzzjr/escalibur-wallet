import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// De ponta a ponta: o que `UTXOSignableTransaction` pede para assinar, assinado com
/// a chave publicada no vetor, montado por `assemble`, tem de sair identico a
/// transacao assinada do vetor. ECDSA com RFC 6979 e deterministico, entao a
/// comparacao e byte a byte.
@Suite("UTXO assinatura")
struct UTXOSigningTests {
    @Test("BIP-143 P2SH-P2WPKH: pedido, assinatura e transacao montada identicos ao BIP")
    func bip143Nested() throws {
        let pub = UTXOFixtures.bytes(UTXOBIP143Vectors.nestedPub)
        let path = UTXOFixtures.path(49, 0, 0, 0, 0)
        let signable = try UTXOSignableTransaction(
            chain: .bitcoin, unsigned: UTXOTransaction(hex: UTXOBIP143Vectors.nestedUnsigned),
            spends: [UTXOSpend(kind: .p2shP2wpkh, path: path, publicKey: pub, value: 1_000_000_000)]
        )
        let request = try #require(signable.signingRequests.first)
        #expect(signable.signingRequests.count == 1)
        #expect(request.payload.hex == "64f3b0f4dd2bb3aa1ce8566d220cc74dda9df97d8490cc81d89d735c92e59fb6")
        #expect(request.scheme == .ecdsaDER)
        #expect(request.curve == .secp256k1)
        #expect(request.expectedPublicKey == pub)
        #expect(request.path == path)

        let signature = try UTXOFixtures.sign(request.payload, with: UTXOFixtures.key(UTXOBIP143Vectors.nestedKey))
        let signed = try signable.assemble(with: [signature])
        #expect(signed.encoded == UTXOBIP143Vectors.nestedSigned)
        #expect(signed.raw.hex == UTXOBIP143Vectors.nestedSigned)
        #expect(signed.id == "ef48d9d0f595052e0f8cdcf825f7a5e50b6a388a81f206f3f4846e5ecd7a0c23")
        #expect(signed.chainID == "bitcoin")
    }

    @Test("bitcoinjs transaction_builder.json: P2PKH, P2WPKH e P2SH-P2WPKH reproduzidos")
    func bitcoinjsBuilder() throws {
        // Fonte: bitcoinjs/bitcoinjs-lib v5.2.0 test/fixtures/transaction_builder.json,
        // "valid.build". Assinaturas RFC 6979 sem low-R, como as do libsecp256k1.
        let root = try #require(try UTXOFixtures.json("bitcoinjs-transaction-builder") as? [String: Any])
        let vectors = try #require(root["vectors"] as? [[String: Any]])
        #expect(vectors.count == 7)
        for vector in vectors {
            let name = vector["description"] as! String
            var inputs = [UTXOTxIn]()
            var spends = [UTXOSpend]()
            var keys = [SecureBytes]()
            for input in vector["inputs"] as! [[String: Any]] {
                let txid = try #require(UTXOTxID(hex: input["txId"] as! String))
                let sequence = (input["sequence"] as? Int).map { UInt32($0) } ?? 0xFFFF_FFFF
                inputs.append(UTXOTxIn(outpoint: UTXOOutpoint(txid: txid, vout: UInt32(input["vout"] as! Int)), sequence: sequence))
                let sign = (input["signs"] as! [[String: Any]])[0]
                let key = try UTXOFixtures.wif(sign["keyPair"] as! String)
                let kind: UTXOInputKind
                switch sign["prevOutScriptType"] as! String {
                case "p2pkh": kind = .p2pkh
                case "p2wpkh": kind = .p2wpkh
                case "p2sh-p2wpkh": kind = .p2shP2wpkh
                default: Issue.record("tipo inesperado em \(name)"); continue
                }
                keys.append(key)
                spends.append(UTXOSpend(
                    kind: kind, path: UTXOFixtures.path(kind.purpose, 0, 0, 0, UInt32(spends.count)),
                    publicKey: try Secp256k1.publicKey(of: key), value: UInt64((sign["value"] as? Int) ?? 0)
                ))
            }
            let outputs = try (vector["outputs"] as! [[String: Any]]).map {
                UTXOTxOut(value: UInt64($0["value"] as! Int), scriptPubKey: try UTXOFixtures.asm($0["script"] as! String))
            }
            let unsigned = UTXOTransaction(
                version: UInt32((vector["version"] as? Int) ?? 1), inputs: inputs, outputs: outputs,
                lockTime: UInt32((vector["locktime"] as? Int) ?? 0)
            )
            let signable = try UTXOSignableTransaction(chain: .bitcoin, unsigned: unsigned, spends: spends)
            let signatures = try zip(signable.signingRequests, keys).map { try UTXOFixtures.sign($0.payload, with: $1) }
            let signed = try signable.assemble(with: signatures)
            #expect(signed.encoded == vector["txHex"] as? String, "\(name)")
        }
    }

    @Test("Montagem recusa assinatura errada, em forma errada ou em numero errado")
    func assembleRejects() throws {
        let pub = UTXOFixtures.bytes(UTXOBIP143Vectors.nestedPub)
        let signable = try UTXOSignableTransaction(
            chain: .bitcoin, unsigned: UTXOTransaction(hex: UTXOBIP143Vectors.nestedUnsigned),
            spends: [UTXOSpend(kind: .p2shP2wpkh, path: UTXOFixtures.path(49, 0, 0, 0, 0), publicKey: pub, value: 1_000_000_000)]
        )
        let key = UTXOFixtures.key(UTXOBIP143Vectors.nestedKey)
        let good = try UTXOFixtures.sign(signable.signingRequests[0].payload, with: key)

        #expect(throws: SigningError.wrongSignatureCount) { try signable.assemble(with: []) }
        #expect(throws: SigningError.wrongSignatureCount) { try signable.assemble(with: [good, good]) }

        // Assinatura valida, mas de outro digesto (outro valor de entrada).
        let otherDigest = UTXOSighash.segwitV0(
            transaction: signable.unsigned, inputIndex: 0, scriptCode: UTXOScript.p2pkh(Hash.hash160(pub)),
            amount: 999_999_999, hashType: UTXOSighash.all
        )
        let wrong = try UTXOFixtures.sign(otherDigest, with: key)
        #expect(throws: SigningError.malformedSignature) { try signable.assemble(with: [wrong]) }

        // Assinatura de outra chave sobre o digesto certo.
        let stranger = try UTXOFixtures.sign(signable.signingRequests[0].payload, with: UTXOFixtures.key(UTXOBIP143Vectors.nativeKey1))
        #expect(throws: SigningError.malformedSignature) { try signable.assemble(with: [stranger]) }

        // A mesma assinatura com S alto (n - s): valida em matematica, recusada pela rede.
        let highS = try Self.withHighS(good.bytes)
        #expect(UTXOSigning.isStrictDER(highS))
        #expect(throws: SigningError.malformedSignature) { try signable.assemble(with: [ProducedSignature(bytes: highS)]) }

        // Com byte de sighash colado (o assinador devolve so o DER).
        #expect(throws: SigningError.malformedSignature) { try signable.assemble(with: [ProducedSignature(bytes: good.bytes + [0x01])]) }
        #expect(throws: SigningError.malformedSignature) { try signable.assemble(with: [ProducedSignature(bytes: [0x30, 0x00])]) }
    }

    @Test("Dogecoin nao tem segwit: entrada P2WPKH e recusada na construcao")
    func dogecoinNoSegwit() throws {
        let pub = UTXOFixtures.bytes(UTXOBIP143Vectors.nestedPub)
        #expect(throws: UTXOSignableTransaction.BuildError.segwitNotSupported) {
            try UTXOSignableTransaction(
                chain: .dogecoin, unsigned: UTXOTransaction(hex: UTXOBIP143Vectors.nestedUnsigned),
                spends: [UTXOSpend(kind: .p2wpkh, path: UTXOFixtures.path(84, 3, 0, 0, 0), publicKey: pub, value: 1)]
            )
        }
        #expect(throws: UTXOSignableTransaction.BuildError.invalidPublicKey) {
            try UTXOSignableTransaction(
                chain: .dogecoin, unsigned: UTXOTransaction(hex: UTXOBIP143Vectors.nestedUnsigned),
                spends: [UTXOSpend(kind: .p2pkh, path: UTXOFixtures.path(44, 3, 0, 0, 0), publicKey: [0x02] + [UInt8](repeating: 0, count: 32), value: 1)]
            )
        }
    }

    /// Troca S por n - S num DER.
    static func withHighS(_ der: [UInt8]) throws -> [UInt8] {
        let n = BigUInt(hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")!
        let lenR = Int(der[3])
        let r = Array(der[4..<(4 + lenR)])
        let s = BigUInt(bigEndian: der[(6 + lenR)...])
        var high = (n - s).bigEndianBytes
        if high[0] & 0x80 != 0 { high = [0] + high }
        let body = [0x02, UInt8(r.count)] + r + [0x02, UInt8(high.count)] + high
        return [0x30, UInt8(body.count)] + body
    }
}
