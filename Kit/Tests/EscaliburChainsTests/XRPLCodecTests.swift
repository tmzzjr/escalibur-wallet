import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// O codec binario do XRP Ledger contra os vetores do ripple-binary-codec.
///
/// Fontes (XRPLF/xrpl.js, commit 5c41405eb361350abc2c615491c74bb3ea6b583d):
/// - packages/ripple-binary-codec/src/enums/definitions.json
/// - packages/ripple-binary-codec/test/fixtures/data-driven-tests.json
/// - packages/ripple-binary-codec/test/fixtures/codec-fixtures.json
/// - packages/ripple-binary-codec/test/fixtures/delivermin-tx.json (+ -binary.json)
/// - packages/ripple-binary-codec/test/signing-data-encoding.test.ts
/// Os subconjuntos guardados em Fixtures/xrpl dizem de onde vieram e o SHA-256 do
/// arquivo original.
@Suite("XRPL codec")
struct XRPLCodecTests {

    @Test("Definicoes compiladas batem com o definitions.json oficial")
    func definitions() throws {
        let official = Dictionary(uniqueKeysWithValues: (XRPLFixtures.definitions["FIELDS"] as! [[Any]]).map {
            ($0[0] as! String, $0[1] as! [String: Any])
        })
        let typeNames: [XRPLType: String] = [
            .uint16: "UInt16", .uint32: "UInt32", .uint64: "UInt64", .hash128: "Hash128", .hash256: "Hash256",
            .amount: "Amount", .blob: "Blob", .accountID: "AccountID", .stObject: "STObject", .stArray: "STArray",
            .uint8: "UInt8", .hash160: "Hash160", .pathSet: "PathSet",
        ]
        for type in XRPLType.allCases {
            let name = try #require(typeNames[type])
            #expect(XRPLFixtures.typeCodes[name] == Int(type.rawValue), "tipo \(name)")
        }
        #expect(XRPLField.all.count == Set(XRPLField.all.map(\.name)).count)
        for field in XRPLField.all {
            let info = try #require(official[field.name], "campo \(field.name) fora do oficial")
            #expect(info["type"] as? String == typeNames[field.type], "\(field.name): tipo")
            #expect(info["nth"] as? Int == Int(field.nth), "\(field.name): nth")
            #expect(info["isVLEncoded"] as? Bool == field.isVLEncoded, "\(field.name): isVLEncoded")
            #expect(info["isSerialized"] as? Bool == field.isSerialized, "\(field.name): isSerialized")
            #expect(info["isSigningField"] as? Bool == field.isSigningField, "\(field.name): isSigningField")
        }

        let txTypes = XRPLFixtures.definitions["TRANSACTION_TYPES"] as! [String: Int]
        #expect(txTypes["Payment"] == Int(XRPLTransactionType.payment.rawValue))
        #expect(txTypes["OfferCreate"] == Int(XRPLTransactionType.offerCreate.rawValue))
        #expect(txTypes["OfferCancel"] == Int(XRPLTransactionType.offerCancel.rawValue))
        #expect(txTypes["TrustSet"] == Int(XRPLTransactionType.trustSet.rawValue))
        // Os tipos recusados (docs/seguranca.md §4.1) nao tem caso no enum.
        let built = Set(XRPLTransactionType.allCases.map { Int($0.rawValue) })
        for refused in ["SetRegularKey", "SignerListSet", "AccountSet", "AccountDelete"] {
            let code = try #require(txTypes[refused])
            #expect(!built.contains(code), "\(refused) nao pode ser montado")
        }
        #expect(XRPLTransactionType.allCases.count == 4)

        let flags = XRPLFixtures.definitions["TRANSACTION_FLAGS"] as! [String: [String: Int]]
        #expect(flags["universal"]?["tfFullyCanonicalSig"] == Int(XRPLTransactionFlags.fullyCanonicalSig))
        #expect(flags["Payment"]?["tfPartialPayment"] == Int(XRPLTransactionFlags.partialPayment))
        #expect(flags["TrustSet"]?["tfSetNoRipple"] == Int(XRPLTransactionFlags.setNoRipple))
        #expect(flags["OfferCreate"]?["tfPassive"] == Int(XRPLTransactionFlags.passive))
        #expect(flags["OfferCreate"]?["tfImmediateOrCancel"] == Int(XRPLTransactionFlags.immediateOrCancel))
        #expect(flags["OfferCreate"]?["tfFillOrKill"] == Int(XRPLTransactionFlags.fillOrKill))
        #expect(flags["OfferCreate"]?["tfSell"] == Int(XRPLTransactionFlags.sell))
        let account = XRPLFixtures.definitions["ACCOUNT_ROOT_FLAGS"] as! [String: Int]
        #expect(account["lsfRequireDestTag"] == Int(XRPLAccountFlags.requireDestTag))
        #expect(account["lsfDisallowXRP"] == Int(XRPLAccountFlags.disallowXRP))
        #expect(account["lsfDepositAuth"] == Int(XRPLAccountFlags.depositAuth))
        #expect(account["lsfDisableMaster"] == Int(XRPLAccountFlags.disableMaster))
    }

    @Test("Cabecalho de campo: fields_tests do data-driven-tests.json")
    func fieldHeaders() throws {
        let cases = try XRPLFixtures.json("data-driven-tests")["fields_tests"] as! [[String: Any]]
        #expect(cases.count == 123)
        for item in cases {
            let header = XRPLBinary.fieldHeader(type: UInt16(item["type"] as! Int), nth: UInt16(item["nth_of_type"] as! Int))
            #expect(XRPLFixtures.hex(header) == item["expected_hex"] as? String, "\(item["name"]!)")
        }
    }

    @Test("Prefixo de tamanho nos limites de 1, 2 e 3 bytes (xrpl.org, Binary Format, Length Prefixing)")
    func lengthPrefix() throws {
        #expect(try XRPLBinary.lengthPrefix(0) == [0x00])
        #expect(try XRPLBinary.lengthPrefix(192) == [0xC0])
        #expect(try XRPLBinary.lengthPrefix(193) == [0xC1, 0x00])
        #expect(try XRPLBinary.lengthPrefix(12_480) == [0xF0, 0xFF])
        #expect(try XRPLBinary.lengthPrefix(12_481) == [0xF1, 0x00, 0x00])
        #expect(try XRPLBinary.lengthPrefix(918_744) == [0xFE, 0xD4, 0x17])
        #expect(throws: XRPLCodecError.valueTooLong(918_745)) { try XRPLBinary.lengthPrefix(918_745) }
    }

    @Test("Amount: values_tests do data-driven-tests.json (XRP e normalizacao de token)")
    func amountValues() throws {
        let cases = try XRPLFixtures.json("data-driven-tests")["values_tests"] as! [[String: Any]]
        #expect(cases.count == 32)
        for item in cases where item["type"] as? String == "Amount" {
            let input = item["test_json"]!
            if let expected = item["expected_hex"] as? String {
                let amount = try XRPLAmount.fromJSON(input)
                #expect(XRPLFixtures.hex(try amount.serialized()) == expected, "\(input)")
                if case .issued(let issued) = amount, !issued.value.isZero,
                   let mantissa = item["mantissa"] as? String, let exponent = item["exponent"] as? Int {
                    #expect(issued.value.mantissa == UInt64(mantissa, radix: 16), "\(input) mantissa")
                    #expect(issued.value.exponent == exponent, "\(input) expoente")
                    #expect(issued.value.isNegative == (item["is_negative"] as? Bool ?? false))
                }
            } else {
                #expect(item["error"] != nil)
                #expect(throws: (any Error).self, "\(input) deveria falhar") {
                    let amount = try XRPLAmount.fromJSON(input)
                    _ = try amount.serialized()
                }
            }
        }
    }

    @Test("Transacoes inteiras: whole_objects do data-driven-tests.json, campo a campo")
    func wholeObjects() throws {
        let cases = try XRPLFixtures.json("data-driven-tests")["whole_objects"] as! [[String: Any]]
        #expect(cases.count == 18)
        for item in cases {
            let json = item["tx_json"] as! [String: Any]
            let object = try XRPLFixtures.object(json)
            #expect(XRPLFixtures.hex(try object.serialized()) == item["blob_with_no_signing"] as? String, "\(json["TransactionType"]!)")
            for entry in item["fields"] as! [[Any]] {
                let name = entry[0] as! String
                let info = entry[1] as! [String: Any]
                let field = try #require(XRPLFixtures.fields[name])
                #expect(XRPLFixtures.hex(field.header) == info["field_header"] as? String, "\(name): cabecalho")
                let value = try #require(object[field])
                var expected = (info["vl_length"] as? String ?? "") + (info["binary"] as! [String]).joined()
                // O vetor guarda o STArray sem o marcador de fim (0xF1); o blob inteiro tem.
                if field.type == .stArray { expected += "F1" }
                #expect(XRPLFixtures.hex(try XRPLBinary.encode(value, field: field)) == expected, "\(name): valor")
            }
        }
    }

    @Test("Objetos do ledger e transacoes do codec-fixtures.json")
    func codecFixtures() throws {
        let fixtures = try XRPLFixtures.json("codec-fixtures")
        let entries = (fixtures["accountState"] as! [[String: Any]]) + (fixtures["transactions"] as! [[String: Any]])
        #expect(entries.count == 195)
        for entry in entries {
            let json = entry["json"] as! [String: Any]
            let object = try XRPLFixtures.object(json)
            #expect(XRPLFixtures.hex(try object.serialized()) == entry["binary"] as? String,
                    "\(json["LedgerEntryType"] ?? json["TransactionType"] ?? "?")")
        }
    }

    @Test("Payment real com DeliverMin: bytes, id e assinatura conferem (delivermin-tx.json)")
    func deliverMin() throws {
        let fixture = try XRPLFixtures.json("delivermin-and-signing")
        let tx = fixture["tx"] as! [String: Any]
        var fields = tx
        fields.removeValue(forKey: "hash")
        let object = try XRPLFixtures.object(fields)
        let blob = try object.serialized()
        #expect(XRPLFixtures.hex(blob) == fixture["binary"] as? String)
        #expect(XRPLFixtures.hex(Hash.sha512Half(XRPLHashPrefix.transactionID + blob)) == fixture["hash"] as? String)

        // A assinatura da rede principal verifica contra o digesto calculado aqui:
        // prefixo STX, campos de assinatura sem a TxnSignature, SHA512Half.
        let digest = Hash.sha512Half(XRPLHashPrefix.transactionSign + (try object.serialized(signingFieldsOnly: true)))
        let signature = try #require(Array(hex: tx["TxnSignature"] as! String))
        let publicKey = try #require(Array(hex: tx["SigningPubKey"] as! String))
        #expect(Secp256k1.verifyDER(signature: signature, digest: digest, publicKey: publicKey))
    }

    @Test("Mensagem de assinatura: STX\\0 e so campos de assinatura (signing-data-encoding.test.ts)")
    func signingEncoding() throws {
        let fixture = try XRPLFixtures.json("delivermin-and-signing")["signing_encoding"] as! [String: Any]
        let object = try XRPLFixtures.object(fixture["tx_json"] as! [String: Any])
        let payload = XRPLHashPrefix.transactionSign + (try object.serialized(signingFieldsOnly: true))
        #expect(XRPLFixtures.hex(payload) == fixture["expected"] as? String)
    }

    @Test("Codigo de moeda: 3 letras, 160 bits, e o que a carteira recusa")
    func currency() throws {
        let usd = try XRPLCurrency(code: "USD")
        #expect(XRPLFixtures.hex(usd.bytes) == "0000000000000000000000005553440000000000")
        #expect(usd.isoCode == "USD" && usd.displayCode == "USD")
        // xrpl.js wallet/index.test.ts: "***" e o hex no formato padrao sao o mesmo codigo.
        #expect(try XRPLCurrency(code: "0000000000000000000000002A2A2A0000000000") == XRPLCurrency(code: "***"))
        // Codigo de 160 bits com texto: SOLO.
        let solo = try XRPLCurrency(code: "534F4C4F00000000000000000000000000000000")
        #expect(solo.isoCode == nil && solo.displayCode == "SOLO")
        #expect(solo.code == "534F4C4F00000000000000000000000000000000")

        // XRP nao e token: nenhuma caixa, nenhuma forma.
        for text in ["XRP", "xrp", "Xrp", "0000000000000000000000005852500000000000", "0000000000000000000000007872700000000000",
                     "0000000000000000000000000000000000000000"] {
            #expect(throws: XRPLCodecError.invalidCurrency(text)) { try XRPLCurrency(code: text) }
        }
        // Fora do conjunto de caracteres do rippled, tamanho errado, hex com 0x00 fora
        // do formato padrao.
        for text in [":::", "US", "USDT", "US D", "0000000000000000000000000000000000000001", "ZZ00000000000000000000000000000000000000"] {
            #expect(throws: XRPLCodecError.self) { try XRPLCurrency(code: text) }
        }
    }

    @Test("Decimal de token: normaliza, recusa mais de 16 digitos e expoente fora da faixa")
    func decimal() throws {
        #expect(try XRPLDecimal("4.2").decimalString == "4.2")
        #expect(try XRPLDecimal("123.000").decimalString == "123")
        #expect(try XRPLDecimal("0.00012").decimalString == "0.00012")
        #expect(try XRPLDecimal("1e-7").decimalString == "0.0000001")
        #expect(try XRPLDecimal("-0").isZero)
        #expect(try XRPLDecimal("0.1248548562296331").decimalString == "0.1248548562296331")
        #expect(try XRPLDecimal("9999999999999999e80").decimalString.count == 96)
        let one = try XRPLDecimal("1")
        #expect(one.mantissa == 1_000_000_000_000_000 && one.exponent == -15)
        for bad in ["", "-", ".", "1.2.3", " 1", "1 ", "1e", "1e+", "0x10", "1,5", "12345678901234567", "1e96", "1e-97", "+1"] {
            #expect(throws: XRPLCodecError.self, "\(bad)") { try XRPLDecimal(bad) }
        }
    }

    @Test("Objeto recusa campo repetido e valor de outro tipo")
    func objectRules() throws {
        var object = XRPLObject()
        try object.set(.sequence, .uint32(1))
        #expect(throws: XRPLCodecError.duplicateField("Sequence")) { try object.set(.sequence, .uint32(2)) }
        #expect(throws: XRPLCodecError.typeMismatch(field: "Fee")) { try object.set(.fee, .uint32(10)) }
        var bad = XRPLObject()
        try bad.set(.account, .accountID([1, 2, 3]))
        #expect(throws: XRPLCodecError.invalidLength(field: "Account")) { try bad.serialized() }
        #expect(throws: XRPLCodecError.self) { try XRPLAmount.xrp(drops: XRPLAmount.maxDrops + 1).serialized() }
    }

    @Test("Tipos sem vetor na fixture: UInt8, Hash128, UInt64 e Hash160 em big-endian e tamanho fixo")
    func otherTypes() throws {
        let emailHash = XRPLField("EmailHash", .hash128, 1)
        let tickSize = XRPLField("TickSize", .uint8, 16)
        let ownerNode = XRPLField("OwnerNode", .uint64, 4)
        let takerPaysCurrency = XRPLField("TakerPaysCurrency", .hash160, 1)
        var object = XRPLObject()
        try object.set(tickSize, .uint8(5))
        try object.set(emailHash, .hash128([UInt8](repeating: 0xAB, count: 16)))
        try object.set(ownerNode, .uint64(0x0102_0304_0506_0708))
        try object.set(takerPaysCurrency, .hash160([UInt8](repeating: 0x11, count: 20)))
        // Ordem: UInt64 (3), Hash128 (4), UInt8 (16), Hash160 (17). TickSize tem tipo e
        // ordinal acima de 15, entao o cabecalho tem 3 bytes.
        let expected = "340102030405060708" + "41" + String(repeating: "AB", count: 16) + "001010" + "05"
            + "0111" + String(repeating: "11", count: 20)
        #expect(XRPLFixtures.hex(try object.serialized()) == expected)
    }
}
