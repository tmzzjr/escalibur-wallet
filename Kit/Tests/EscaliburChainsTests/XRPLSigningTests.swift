import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Assinatura de ponta a ponta contra transacoes assinadas dos testes do xrpl.js.
///
/// Fonte: XRPLF/xrpl.js, packages/xrpl/test/wallet/index.test.ts ("sign ...") e
/// packages/xrpl/test/fixtures/{requests,responses}/sign.json, commit 5c41405.
/// O ripple-keypairs assina com RFC 6979 e low-S, como o libsecp256k1, entao a mesma
/// chave da a mesma assinatura: o tx_blob e o hash tem de bater byte a byte.
@Suite("XRPL assinatura")
struct XRPLSigningTests {
    static func vectors() throws -> [[String: Any]] {
        try XRPLFixtures.json("signing-vectors")["signed"] as! [[String: Any]]
    }

    static func vector(_ title: String) throws -> [String: Any] {
        try #require(try vectors().first { ($0["teste"] as! String).contains(title) })
    }

    @Test("Family seed do teste do xrpl.js da a chave publicada (ripple-keypairs)")
    func familySeedKeys() throws {
        let keys = try XRPLFixtures.json("signing-vectors")["keys"] as! [[String: String]]
        for key in keys {
            let privateKey = try XRPLTestKeys.privateKey(familySeed: key["secret"]!)
            // O ripple-keypairs escreve a chave privada com um 00 na frente.
            #expect("00" + XRPLTestKeys.hex(privateKey) == key["privateKey"])
            #expect(XRPLFixtures.hex(try Secp256k1.publicKey(of: privateKey)) == key["publicKey"])
        }
    }

    @Test("Codec + digesto + secp256k1: os dez vetores assinados do xrpl.js")
    func signedVectors() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == 10)
        for vector in vectors {
            let key = try XRPLTestKeys.privateKey(familySeed: vector["secret"] as! String)
            var json = vector["tx_json"] as! [String: Any]
            json["SigningPubKey"] = XRPLFixtures.hex(try Secp256k1.publicKey(of: key))
            var object = try XRPLFixtures.object(json)
            let digest = Hash.sha512Half(XRPLHashPrefix.transactionSign + (try object.serialized(signingFieldsOnly: true)))
            try object.set(.txnSignature, .blob(try Secp256k1.signDER(digest: digest, privateKey: key)))
            let blob = try object.serialized()
            #expect(XRPLFixtures.hex(blob) == vector["tx_blob"] as? String, "\(vector["teste"]!)")
            #expect(XRPLFixtures.hex(Hash.sha512Half(XRPLHashPrefix.transactionID + blob)) == vector["hash"] as? String)
        }
    }

    @Test("Tipado: Payment com SourceTag, DestinationTag e Memos bate com o xrpl.js ('lowercase hex data in memo')")
    func typedMemoPayment() throws {
        // O unico vetor assinado do xrpl.js cuja Account e a da propria chave: a carteira
        // so assina pela conta da chave, entao so ele da para montar pelo tipo e
        // comparar byte a byte. Os outros tem Account de outra conta (assinatura com
        // chave regular) e sao conferidos pelo codec no teste anterior e abaixo.
        let vector = try Self.vector("sign with lowercase hex data in memo")
        let key = try XRPLTestKeys.privateKey(familySeed: vector["secret"] as! String)
        let signer = try XRPLTestKeys.signer(key)
        let json = vector["tx_json"] as! [String: Any]
        #expect(signer.address == json["Account"] as? String)

        let payment = try XRPLPayment(destination: json["Destination"] as! String, amount: .xrp(drops: 10_000_000), destinationTag: 9999)
        let memo = try XRPLMemo(
            type: Array(hex: "687474703a2f2f6578616d706c652e636f6d2f6d656d6f2f67656e65726963")!,
            data: Array(hex: "72656e74")!
        )
        let transaction = try XRPLTransaction(
            signer: signer, body: .payment(payment), fee: 12, sequence: 12, lastLedgerSequence: 14_000_999,
            sourceTag: 8888, memos: [memo]
        )
        let signed = try XRPLTestKeys.sign(transaction, with: key)
        #expect(signed.encoded == vector["tx_blob"] as? String)
        #expect(signed.id == vector["hash"] as? String)
        #expect(signed.chainID == "xrpl")
        #expect(signed.raw == Array(hex: vector["tx_blob"] as! String))
    }

    @Test("Tipado = codec sobre o JSON oficial: XRP, tokens, codigo minusculo e simbolos, pagamento parcial")
    func typedMatchesCodec() throws {
        let key = try XRPLTestKeys.privateKey(familySeed: "ss1x3KLrSvfg7irFc1D929WXZ7z9H")
        let signer = try XRPLTestKeys.signer(key)
        let titles = [
            "sign with a prepared payment", "sign succeeds with source.amount/destination.minAmount",
            "lowercase standard currency code signs successfully", "sign succeeds with standard currency code with symbols",
            "sign handles non-XRP amount with a trailing zero", "sign handles non-XRP amount with trailing zeros",
        ]
        for title in titles {
            var json = try Self.vector(title)["tx_json"] as! [String: Any]
            // A Account dos vetores e de outra conta; aqui ela vira a da chave, que e o
            // que o tipo sempre poe.
            json["Account"] = signer.address
            json["SigningPubKey"] = XRPLFixtures.hex(signer.publicKey)

            let partial = (json["Flags"] as! Int) & Int(XRPLTransactionFlags.partialPayment) != 0
            let payment = try XRPLPayment(
                destination: json["Destination"] as! String,
                amount: try XRPLAmount.fromJSON(json["Amount"]!),
                sendMax: try json["SendMax"].map(XRPLAmount.fromJSON),
                deliverMin: try json["DeliverMin"].map(XRPLAmount.fromJSON),
                partialPayment: partial
            )
            let transaction = try XRPLTransaction(
                signer: signer, body: .payment(payment), fee: 12, sequence: UInt32(json["Sequence"] as! Int),
                lastLedgerSequence: UInt32(json["LastLedgerSequence"] as! Int)
            )
            #expect(Int(transaction.flags) == json["Flags"] as? Int, "\(title)")

            var object = try XRPLFixtures.object(json)
            #expect(transaction.signingPayload == XRPLHashPrefix.transactionSign + (try object.serialized(signingFieldsOnly: true)), "\(title)")
            let signed = try XRPLTestKeys.sign(transaction, with: key)
            try object.set(.txnSignature, .blob(try Secp256k1.signDER(digest: transaction.signingDigest, privateKey: key)))
            #expect(signed.raw == (try object.serialized()), "\(title)")
        }
    }

    @Test("O pedido de assinatura e o digesto local, com a chave esperada")
    func signingRequest() throws {
        let signer = try XRPLTestKeys.signer()
        let payment = try XRPLPayment(destination: "rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe", amount: .xrp(drops: 1_000_000))
        let transaction = try XRPLTransaction(signer: signer, body: .payment(payment), fee: 12, sequence: 5, lastLedgerSequence: 100)
        let request = try #require(transaction.signingRequests.first)
        #expect(transaction.signingRequests.count == 1)
        #expect(request.curve == .secp256k1 && request.scheme == .ecdsaDER)
        #expect(request.payload == Hash.sha512Half(transaction.signingPayload))
        #expect(transaction.signingPayload.prefix(4) == [0x53, 0x54, 0x58, 0x00])
        #expect(request.expectedPublicKey == signer.publicKey)
        #expect(request.path.description == "m/44'/144'/0'/0/0")
    }

    @Test("assemble recusa contagem errada, assinatura de outra chave, high-S e DER torto")
    func assembleRejects() throws {
        let signer = try XRPLTestKeys.signer()
        let payment = try XRPLPayment(destination: "rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe", amount: .xrp(drops: 1_000_000))
        let transaction = try XRPLTransaction(signer: signer, body: .payment(payment), fee: 12, sequence: 5, lastLedgerSequence: 100)
        let good = try Secp256k1.signDER(digest: transaction.signingDigest, privateKey: XRPLTestKeys.plannerKey)

        #expect(throws: SigningError.wrongSignatureCount) { try transaction.assemble(with: []) }
        #expect(throws: SigningError.wrongSignatureCount) {
            try transaction.assemble(with: [ProducedSignature(bytes: good), ProducedSignature(bytes: good)])
        }
        let other = XRPLTestKeys.secure([UInt8](repeating: 0x42, count: 32))
        let foreign = try Secp256k1.signDER(digest: transaction.signingDigest, privateKey: other)
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [ProducedSignature(bytes: foreign)]) }
        let elsewhere = try Secp256k1.signDER(digest: Hash.sha256([UInt8]([1])), privateKey: XRPLTestKeys.plannerKey)
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [ProducedSignature(bytes: elsewhere)]) }
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [ProducedSignature(bytes: Self.highS(good))]) }
        #expect(throws: SigningError.malformedSignature) {
            try transaction.assemble(with: [ProducedSignature(bytes: Array(good.dropLast()))])
        }
        let signed = try transaction.assemble(with: [ProducedSignature(bytes: good)])
        #expect(signed.id.count == 64 && signed.id == signed.id.uppercased())
    }

    /// A mesma assinatura com s trocado por n - s: valida na curva, mas maleavel. O
    /// rippled recusa desde a RequireFullyCanonicalSig, e o assemble tambem.
    static func highS(_ der: [UInt8]) -> [UInt8] {
        let rLength = Int(der[3])
        let r = Array(der[4..<(4 + rLength)])
        let sStart = 4 + rLength + 2
        let s = BigUInt(bigEndian: der[sStart...])
        let n = BigUInt(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")!
        var high = (n - s).bigEndianBytes
        if high[0] & 0x80 != 0 { high.insert(0, at: 0) }
        let body = [0x02, UInt8(r.count)] + r + [0x02, UInt8(high.count)] + high
        return [0x30, UInt8(body.count)] + body
    }

    @Test("NetworkID so entra acima de 1024")
    func networkID() throws {
        let signer = try XRPLTestKeys.signer()
        let payment = try XRPLPayment(destination: "rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe", amount: .xrp(drops: 1_000_000))
        for (id, present) in [(UInt32(0), false), (1, false), (1024, false), (1025, true), (21_338, true)] {
            let transaction = try XRPLTransaction(
                signer: signer, body: .payment(payment), fee: 12, sequence: 5, lastLedgerSequence: 100, networkID: id
            )
            #expect((transaction.unsigned[.networkID] != nil) == present, "NetworkID \(id)")
            // NetworkID e o UInt32 de ordinal 1: vem antes de Flags (ordinal 2).
            if present {
                #expect(XRPLFixtures.hex(transaction.unsignedBlob).hasPrefix("12000021" + XRPLFixtures.hex(id.bigEndianByteArray) + "2280000000"))
            }
        }
    }

    @Test("Regras de montagem do rippled: parcial, DeliverMin, redundante, oferta, memo")
    func buildRules() throws {
        let signer = try XRPLTestKeys.signer()
        let usd = try XRPLCurrency(code: "USD")
        let issuer = "rvYAfWj5gh67oV6fW32ZzP3Aw4Eubs59B"
        let tenUSD = XRPLAmount.issued(try XRPLIssuedAmount(value: XRPLDecimal("10"), currency: usd, issuer: issuer))
        let dest = "rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe"

        #expect(throws: XRPLTransactionError.nonPositiveAmount) { try XRPLPayment(destination: dest, amount: .xrp(drops: 0)) }
        #expect(throws: XRPLTransactionError.xrpToXRPPartialPayment) {
            try XRPLPayment(destination: dest, amount: .xrp(drops: 5), partialPayment: true)
        }
        #expect(throws: XRPLTransactionError.xrpToXRPWithSendMax) {
            try XRPLPayment(destination: dest, amount: .xrp(drops: 5), sendMax: .xrp(drops: 6))
        }
        #expect(throws: XRPLTransactionError.deliverMinRequiresPartialPayment) {
            try XRPLPayment(destination: dest, amount: tenUSD, sendMax: .xrp(drops: 6), deliverMin: tenUSD)
        }
        let elevenUSD = XRPLAmount.issued(try XRPLIssuedAmount(value: XRPLDecimal("11"), currency: usd, issuer: issuer))
        #expect(throws: XRPLTransactionError.deliverMinMismatch) {
            try XRPLPayment(destination: dest, amount: tenUSD, sendMax: .xrp(drops: 6), deliverMin: elevenUSD, partialPayment: true)
        }
        let negative = XRPLAmount.issued(try XRPLIssuedAmount(value: XRPLDecimal("-1"), currency: usd, issuer: issuer))
        #expect(throws: XRPLTransactionError.negativeAmount) { try XRPLPayment(destination: dest, amount: negative) }

        let toSelf = try XRPLPayment(destination: signer.address, amount: .xrp(drops: 5))
        #expect(throws: XRPLTransactionError.redundant) {
            try XRPLTransaction(signer: signer, body: .payment(toSelf), fee: 12, sequence: 1, lastLedgerSequence: 10)
        }

        #expect(throws: XRPLTransactionError.conflictingOfferFlags) {
            try XRPLOfferCreate(takerGets: .xrp(drops: 5), takerPays: tenUSD, expiration: nil, options: [.immediateOrCancel, .fillOrKill])
        }
        #expect(throws: XRPLTransactionError.conflictingOfferFlags) {
            try XRPLOfferCreate(takerGets: .xrp(drops: 5), takerPays: tenUSD, expiration: nil, options: XRPLOfferOptions(rawValue: 0x0010_0000))
        }
        #expect(throws: XRPLTransactionError.xrpForXRPOffer) {
            try XRPLOfferCreate(takerGets: .xrp(drops: 5), takerPays: .xrp(drops: 6), expiration: nil, options: [])
        }
        #expect(throws: XRPLTransactionError.redundant) {
            try XRPLOfferCreate(takerGets: tenUSD, takerPays: elevenUSD, expiration: nil, options: [])
        }

        #expect(throws: XRPLTransactionError.invalidMemo) { try XRPLMemo(type: Array("tipo com espaço".utf8)) }
        #expect(throws: XRPLTransactionError.invalidMemo) { try XRPLMemo() }
        let big = try XRPLMemo.text(String(repeating: "a", count: 1_100))
        let payment = try XRPLPayment(destination: dest, amount: .xrp(drops: 5))
        #expect(throws: XRPLTransactionError.memosTooLarge) {
            try XRPLTransaction(signer: signer, body: .payment(payment), fee: 12, sequence: 1, lastLedgerSequence: 10, memos: [big])
        }
        #expect(throws: XRPLTransactionError.invalidFee) {
            try XRPLTransaction(signer: signer, body: .payment(payment), fee: 0, sequence: 1, lastLedgerSequence: 10)
        }
        for bad in [[0x04] + [UInt8](repeating: 1, count: 32), [0x02] + [UInt8](repeating: 0xFF, count: 32), [0x02, 0x03]] {
            #expect(throws: XRPLTransactionError.invalidPublicKey) {
                try XRPLSigner(path: DefaultPaths.path(for: .xrpl), publicKey: bad)
            }
        }
    }
}
