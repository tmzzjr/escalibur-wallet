import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

@Suite("Stellar StrKey, memo e preco")
struct StellarStrKeyTests {

    // MARK: SEP-0023

    // Fonte: github.com/stellar/stellar-protocol, ecosystem/sep-0023.md, "Valid test
    // cases" 1 a 3. O vetor da o `MuxedAccount` binario esperado de cada StrKey.
    static let sep23Key: [UInt8] = [
        0x3f, 0x0c, 0x34, 0xbf, 0x93, 0xad, 0x0d, 0x99, 0x71, 0xd0, 0x4c, 0xcc, 0x90, 0xf7, 0x05, 0x51,
        0x1c, 0x83, 0x8a, 0xad, 0x97, 0x34, 0xa4, 0xa2, 0xfb, 0x0d, 0x7a, 0x03, 0xfc, 0x7f, 0xe8, 0x9a,
    ]

    @Test("SEP-0023: StrKey validas viram o MuxedAccount binario do vetor")
    func sep23Valid() throws {
        let g = "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ"
        let plain = try #require(StellarMuxedAccount(address: g))
        #expect(xdr(plain) == [0x00, 0x00, 0x00, 0x00] + Self.sep23Key)
        #expect(plain.address == g)
        #expect(plain.id == nil)

        let m0 = "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUQ"
        let muxed0 = try #require(StellarMuxedAccount(address: m0))
        // med25519: tipo 0x100, **id primeiro**, depois a chave.
        #expect(xdr(muxed0) == [0x00, 0x00, 0x01, 0x00] + [UInt8](repeating: 0, count: 8) + Self.sep23Key)
        #expect(muxed0.id == 0)
        #expect(muxed0.account.address == g)
        #expect(muxed0.address == m0)

        let mBig = "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLK"
        let muxedBig = try #require(StellarMuxedAccount(address: mBig))
        #expect(muxedBig.id == 9_223_372_036_854_775_808)  // acima do int64 maximo
        #expect(xdr(muxedBig) == [0x00, 0x00, 0x01, 0x00, 0x80, 0, 0, 0, 0, 0, 0, 0] + Self.sep23Key)
        #expect(StellarKey.muxedAddress(publicKey: Self.sep23Key, id: 9_223_372_036_854_775_808) == mBig)

        // O mesmo pelo validador geral de endereco, que a tela de envio usa.
        #expect(Address.validate(mBig, for: .stellar) == .success(Address.Destination(address: g, tag: 9_223_372_036_854_775_808)))
    }

    @Test("SEP-0023: StrKey invalidas sao recusadas")
    func sep23Invalid() {
        // Fonte: sep-0023.md, "Invalid test cases" (o array do fim da secao).
        let invalid = [
            "GAAAAAAAACGC6",
            "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUR",
            "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZA",
            "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUACUSI",
            "G47QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVP2I",
            "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLKA",
            "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAAV75I",
            "M47QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUQ",
            "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUK===",
            "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUO",
            "PA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAQACAQDAQCQMBYIBEFAWDANBYHRAEISCMKBKFQXDAMRUGY4DUPB6IAAAAAAAAPM",
            "PA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAOQCAQDAQCQMBYIBEFAWDANBYHRAEISCMKBKFQXDAMRUGY4Z2PQ",
            "PA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAOQCAQDAQCQMBYIBEFAWDANBYHRAEISCMKBKFQXDAMRUGY4DXFH6",
            "BAAD6DBUX6J22DMZOHIEZTEQ64CVCHEDRKWZONFEUL5Q26QD7R76RGR4TV",
            "BAAT6DBUX6J22DMZOHIEZTEQ64CVCHEDRKWZONFEUL5Q26QD7R76RGXACA",
        ]
        for text in invalid {
            #expect(StellarMuxedAccount(address: text) == nil, "aceitou \(text)")
            #expect(StellarAccountID(address: text) == nil, "aceitou \(text)")
            if case .success = Address.validate(text, for: .stellar) {
                Issue.record("Address.validate aceitou \(text)")
            }
        }
        // Um M nunca passa por conta simples: o id se perderia.
        #expect(StellarAccountID(address: "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUQ") == nil)
        // StrKey e maiuscula; minuscula nao e a mesma grafia.
        #expect(StellarAccountID(address: "ga7qynf7sowq3glr2bgmzehxavirza4kvwltjjfc7mgxua74p7ujvsgz") == nil)
    }

    @Test("SEP-0005: a semente S do vetor gera a conta G do vetor")
    func sep5KeyPair() throws {
        // A chave do teste de ponta a ponta. Ed25519 do Core, so no teste.
        let seed = try StellarTestKeys.seed(StellarTestKeys.sep5Secret0)
        let publicKey = try Ed25519.publicKey(of: seed)
        #expect(try StellarAccountID(publicKey: publicKey).address == StellarTestKeys.sep5Account0)
        #expect(try Address.from(publicKey: publicKey, chain: .stellar) == StellarTestKeys.sep5Account0)
    }

    // MARK: Memo

    @Test("Memo: vetores do js-stellar-base (test/unit/memo_test.js)")
    func memoVectors() throws {
        // "returns a value for a correct argument (utf8)": texto de um byte 0xd1.
        #expect(xdr(StellarMemo.text([0xd1])) == [0, 0, 0, 1, 0, 0, 0, 1, 0xd1, 0, 0, 0])
        // UTF-8 de 12 bytes cabe; 29 bytes e 36 bytes (CJK) nao.
        #expect(try StellarMemo.fromText("三代之時") == .text(Array("三代之時".utf8)))
        #expect(throws: StellarMemo.Problem.textTooLong) { try StellarMemo.fromText("12345678901234567890123456789") }
        #expect(throws: StellarMemo.Problem.textTooLong) { try StellarMemo.fromText("三代之時三代之時三代之時") }
        #expect(try StellarMemo.fromText("1234567890123456789012345678") == .text(Array("1234567890123456789012345678".utf8)))

        // Memo ID: uint64 inteiro, estrito.
        #expect(try StellarMemo.fromID("1000") == .id(1000))
        #expect(try StellarMemo.fromID("0") == .id(0))
        #expect(try StellarMemo.fromID("18446744073709551615") == .id(UInt64.max))
        for bad in ["", "test", "-1", "1.5", " 1", "+1", "18446744073709551616"] {
            #expect(throws: StellarMemo.Problem.notAnUnsignedInteger) { try StellarMemo.fromID(bad) }
        }

        // Hash e retorno: exatamente 32 bytes.
        #expect(try StellarMemo.fromHash(hex: String(repeating: "0a", count: 32)) == .hash([UInt8](repeating: 10, count: 32)))
        #expect(throws: StellarMemo.Problem.hashMustBe32Bytes) { try StellarMemo.fromHash(hex: String(repeating: "00", count: 31)) }
        #expect(throws: StellarMemo.Problem.hashMustBe32Bytes) { try StellarMemo.fromHash(hex: String(repeating: "00", count: 33)) }
        #expect(throws: StellarMemo.Problem.hashMustBe32Bytes) { try StellarMemo.fromHash(hex: "test") }
    }

    @Test("Memo: bytes dentro dos envelopes do go-stellar-sdk (TestMemoText, ID, Hash, Return)")
    func memoInsideGoEnvelopes() throws {
        let fixtures = try StellarFixtures.load()
        // Envelope v1 com origem ed25519 e TimeBounds: o memo comeca no byte 72
        // (tipo 4 + conta 36 + taxa 4 + sequence 8 + precondicao 4 + 16).
        let cases: [(String, StellarMemo)] = [
            ("TestMemoText", try StellarMemo.fromText("Twas brillig")),
            ("TestMemoID", .id(314_159)),
            ("TestMemoHash", .hash([0x01] + [UInt8](repeating: 0, count: 31))),
            ("TestMemoReturn", .returnHash([0x01] + [UInt8](repeating: 0, count: 31))),
        ]
        for (name, memo) in cases {
            let raw = try StellarTestKeys.bytes(base64: try #require(fixtures.goStellarSdk[name]).envelope)
            let expected = xdr(memo)
            #expect(Array(raw[72..<72 + expected.count]) == expected, "\(name)")
            // Esses vetores usam BumpSequence, que a carteira nao monta nem aceita.
            #expect(throws: StellarXDRError.unsupported("operacao de tipo 11")) { try StellarEnvelope.decode(raw) }
        }
    }

    // MARK: Preco

    @Test("Preco n/d: vetores de best_r (js-stellar-base test/unit/util/continued_fraction_test.js)")
    func priceVectors() throws {
        // O best_r recebe o decimal; aqui entra a fracao exata que o decimal
        // representa (quantidade recebida / quantidade vendida), e a saida tem de ser
        // a mesma fracao reduzida.
        let vectors: [(String, String)] = [
            ("1,10", "0.1"), ("1,100", "0.01"), ("1,1000", "0.001"),
            ("54301793,100000", "543.017930"), ("31969983,100000", "319.69983"),
            ("93,100", "0.93"), ("1,2", "0.5"), ("173,100", "1.730"),
            ("5333399,6250000", "0.85334384"), ("11,2", "5.5"), ("272783,100000", "2.72783"),
            ("638082,1", "638082.0"), ("36731261,12500000", "2.93850088"), ("1451,25", "58.04"),
            ("8253,200", "41.265"), ("12869,2500", "5.1476"), ("4757,50", "95.14"),
            ("3729,5000", "0.74580"), ("4119,1", "4119.0"),
        ]
        for (expected, decimal) in vectors {
            let (numerator, denominator) = try fraction(decimal)
            let price = try StellarPrice.atLeast(receive: numerator, forSelling: denominator)
            #expect("\(price.n),\(price.d)" == expected, "\(decimal)")
        }
        // ["118,37", 118/37]: a fracao ja e a exata.
        #expect(try StellarPrice.atLeast(receive: 118, forSelling: 37) == StellarPrice(n: 118, d: 37))
        // "throws an error when best rational approximation cannot be found".
        let (tiny, tinyDenominator) = try fraction("0.0000000003")
        #expect(throws: StellarPrice.Problem.notRepresentable) {
            try StellarPrice.atLeast(receive: tiny, forSelling: tinyDenominator)
        }
        #expect(throws: StellarPrice.Problem.notRepresentable) { try StellarPrice.atLeast(receive: 2_147_483_648, forSelling: 1) }
        #expect(throws: StellarPrice.Problem.zero) { try StellarPrice.atLeast(receive: 0, forSelling: 1) }
    }

    @Test("Preco n/d: aproximacao sempre para cima, a melhor dentro do limite")
    func priceUpperApproximation() throws {
        // Com limite pequeno da para conferir contra forca bruta: para cada d, o menor
        // n com n/d >= p/q e ceil(p*d/q); a resposta tem de ser o minimo de todos.
        let cases: [(UInt64, UInt64)] = [(355, 113), (1_000_003, 999_983), (2, 3), (999_999, 1_000_000), (7, 1_234_567), (31_415_926, 10_000_000)]
        let limit: UInt64 = 997
        for (p, q) in cases {
            guard let (n, d) = StellarPrice.bestUpperApproximation(BigUInt(p), BigUInt(q), limit: BigUInt(limit)) else {
                // So pode faltar resposta quando nem n = limit cobre p/q com d = 1.
                #expect(p > limit * q)
                continue
            }
            #expect(n <= BigUInt(limit) && d <= BigUInt(limit) && !d.isZero)
            #expect(n * BigUInt(q) >= BigUInt(p) * d, "\(p)/\(q) ficou abaixo")
            var best: (UInt64, UInt64)?
            for den in 1...limit {
                let num = (p * den + q - 1) / q
                guard num <= limit else { continue }
                if let current = best, num * current.1 >= current.0 * den { continue }
                best = (num, den)
            }
            let bruteForce = try #require(best)
            // Mesma fracao (podem diferir so por fator comum, que nao existe aqui).
            #expect(n * BigUInt(bruteForce.1) == BigUInt(bruteForce.0) * d, "\(p)/\(q): \(n)/\(d) contra \(bruteForce)")
        }

        // Com o limite real (int32): quantidades de stroops que nao reduzem.
        let price = try StellarPrice.atLeast(receive: 123_456_789_012, forSelling: 98_765_432_109)
        #expect(BigUInt(UInt64(price.n)) * 98_765_432_109 >= BigUInt(123_456_789_012) * BigUInt(UInt64(price.d)))
    }

    // MARK: Auxiliares

    private func xdr(_ account: StellarMuxedAccount) -> [UInt8] {
        var writer = StellarXDRWriter()
        account.encode(to: &writer)
        return writer.bytes
    }

    private func xdr(_ memo: StellarMemo) -> [UInt8] {
        var writer = StellarXDRWriter()
        memo.encode(to: &writer)
        return writer.bytes
    }

    /// "543.017930" -> (543017930, 1000000), exato.
    private func fraction(_ decimal: String) throws -> (BigUInt, BigUInt) {
        let parts = decimal.split(separator: ".", omittingEmptySubsequences: false)
        let fractional = parts.count > 1 ? String(parts[1]) : ""
        let numerator = try #require(BigUInt(decimal: String(parts[0]) + fractional))
        return (numerator, BigUInt.power(of: 10, fractional.count))
    }
}
