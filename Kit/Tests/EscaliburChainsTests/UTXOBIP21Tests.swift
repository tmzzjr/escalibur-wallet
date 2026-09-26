import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// URI de pagamento (BIP-21). A URI vem de QR ou link, isto e, de estranho: o parse
/// e estrito, e tudo o que e ambiguo e recusado com o motivo.
@Suite("UTXO BIP-21")
struct UTXOBIP21Tests {
    /// Endereco valido do key_io_valid.json do Core, no lugar do endereco dos
    /// exemplos do BIP-21, que e invalido de proposito.
    static let valid = "1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo"

    @Test("Exemplos do BIP-21 (bitcoin/bips bip-0021.mediawiki)")
    func bipExamples() throws {
        // O endereco dos exemplos tem checksum errado ("intentionally invalid").
        #expect(throws: BIP21URI.Problem.invalidAddress(.badChecksum)) {
            try BIP21URI.parse("bitcoin:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W")
        }
        let plain = try BIP21URI.parse("bitcoin:\(Self.valid)")
        #expect(plain.chain == .bitcoin)
        #expect(plain.destination.address == Self.valid)
        #expect(plain.amount == nil && plain.label == nil && plain.message == nil)

        #expect(try BIP21URI.parse("bitcoin:\(Self.valid)?label=Luke-Jr").label == "Luke-Jr")

        let request = try BIP21URI.parse("bitcoin:\(Self.valid)?amount=20.3&label=Luke-Jr")
        #expect(request.amount == BigUInt(2_030_000_000))
        #expect(request.label == "Luke-Jr")

        let donation = try BIP21URI.parse("bitcoin:\(Self.valid)?amount=50&label=Luke-Jr&message=Donation%20for%20project%20xyz")
        #expect(donation.amount == BigUInt(5_000_000_000))
        #expect(donation.message == "Donation for project xyz")

        #expect(throws: BIP21URI.Problem.unsupportedRequiredParameter("req-somethingyoudontunderstand")) {
            try BIP21URI.parse("bitcoin:\(Self.valid)?req-somethingyoudontunderstand=50&req-somethingelseyoudontget=999")
        }
        let future = try BIP21URI.parse("bitcoin:\(Self.valid)?somethingyoudontunderstand=50&somethingelseyoudontget=999")
        #expect(future.destination.address == Self.valid)
    }

    @Test("Esquema sem caixa, QR em maiusculas, Lightning ignorado")
    func schemeAndCase() throws {
        let upper = try BIP21URI.parse("BITCOIN:BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4?amount=0.001")
        #expect(upper.destination.address == "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
        #expect(upper.amount == BigUInt(100_000))
        let unified = try BIP21URI.parse("bitcoin:bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4?amount=0.00001&lightning=lnbc10u1p3pj257pp5yztkwjcz5ftl5laxkav23zmzekaw37zk6kmv80pk4xaev5qhtz7qdpdwd3xger9wd5kwm36yprx7u3qd36kucmgyp282etnv3shjcqzpgxqyz5vqsp5usyc4lk9chsfp53kvcnvq456ganh60d89reykdngsmtj6yw3nhvq9qyyssqjcewm5cjwz4a6rfjx77c490yced6pemk0upkxhy89cmm7sct66k8gneanwykzgdrwrfje69h9u5u0w57rrcsysas7gadwmzxc8c6t0spjazup6")
        #expect(unified.amount == BigUInt(1_000))
        #expect(throws: BIP21URI.Problem.unknownScheme) { try BIP21URI.parse("ethereum:0x9858EfFD232B4033E47d90003D41EC34EcaEda94") }
        #expect(throws: BIP21URI.Problem.unknownScheme) { try BIP21URI.parse(Self.valid) }
        #expect(throws: BIP21URI.Problem.malformed) { try BIP21URI.parse("bitcoin:?lightning=lnbc1") }
        #expect(throws: BIP21URI.Problem.malformed) { try BIP21URI.parse("bitcoin://\(Self.valid)") }
    }

    @Test("Litecoin e Dogecoin, e a rede da URI contra a da tela")
    func otherChains() throws {
        let ltc = try BIP21URI.parse("litecoin:ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh?amount=1.5", expected: .litecoin)
        #expect(ltc.chain == .litecoin)
        #expect(ltc.amount == BigUInt(150_000_000))
        let doge = try BIP21URI.parse("dogecoin:DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC?amount=100")
        #expect(doge.chain == .dogecoin)
        #expect(doge.amount == BigUInt(10_000_000_000))
        // URI de Litecoin aberta na tela de Bitcoin: recusa, sem trocar de rede sozinha.
        #expect(throws: BIP21URI.Problem.wrongChain(.litecoin)) {
            try BIP21URI.parse("litecoin:ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh", expected: .bitcoin)
        }
        // Esquema de Bitcoin com endereco de Litecoin.
        #expect(throws: BIP21URI.Problem.invalidAddress(.otherNetwork(.litecoin))) {
            try BIP21URI.parse("bitcoin:ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh")
        }
    }

    @Test("amount estrito: ponto decimal, ate 8 casas, maior que zero, ate o MAX_MONEY")
    func amounts() throws {
        #expect(try BIP21URI.parse("bitcoin:\(Self.valid)?amount=.5").amount == BigUInt(50_000_000))
        #expect(try BIP21URI.parse("bitcoin:\(Self.valid)?amount=5.").amount == BigUInt(500_000_000))
        #expect(try BIP21URI.parse("bitcoin:\(Self.valid)?amount=0.00000001").amount == BigUInt(1))
        #expect(try BIP21URI.parse("bitcoin:\(Self.valid)?amount=21000000").amount == BigUInt(21_000_000) * 100_000_000)
        for bad in ["1,5", "1e3", "-1", "+1", "0", "0.0", "0.000000001", "", "1.2.3", " 1", "21000001", "%31", "0x10", "١"] {
            #expect(throws: BIP21URI.Problem.invalidAmount, "amount=\(bad)") {
                try BIP21URI.parse("bitcoin:\(Self.valid)?amount=\(bad)")
            }
        }
    }

    @Test("Recusas: repetido, segundo endereco, tamanho, codificacao e texto que engana")
    func refusals() throws {
        #expect(throws: BIP21URI.Problem.duplicateParameter("amount")) {
            try BIP21URI.parse("bitcoin:\(Self.valid)?amount=1&amount=2")
        }
        #expect(throws: BIP21URI.Problem.malformed) {
            try BIP21URI.parse("bitcoin:\(Self.valid)?address=bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
        }
        #expect(throws: BIP21URI.Problem.malformed) { try BIP21URI.parse("bitcoin:\(Self.valid)?amount=1&&label=a") }
        #expect(throws: BIP21URI.Problem.malformed) { try BIP21URI.parse("bitcoin:\(Self.valid)?amount=1#frag") }
        #expect(throws: BIP21URI.Problem.tooLong) {
            try BIP21URI.parse("bitcoin:\(Self.valid)?x=" + String(repeating: "a", count: BIP21URI.maxLength))
        }
        // U+202E (RIGHT-TO-LEFT OVERRIDE) inverte o que a tela mostra.
        #expect(throws: BIP21URI.Problem.invalidEncoding) { try BIP21URI.parse("bitcoin:\(Self.valid)?label=abc%E2%80%AEdef") }
        #expect(throws: BIP21URI.Problem.invalidEncoding) { try BIP21URI.parse("bitcoin:\(Self.valid)?label=a%0Ab") }
        #expect(throws: BIP21URI.Problem.invalidEncoding) { try BIP21URI.parse("bitcoin:\(Self.valid)?label=%G1") }
        #expect(throws: BIP21URI.Problem.invalidEncoding) { try BIP21URI.parse("bitcoin:\(Self.valid)?label=%FF") }
        #expect(throws: BIP21URI.Problem.invalidEncoding) { try BIP21URI.parse("bitcoin:\(Self.valid)?message=%E2") }
        #expect(throws: BIP21URI.Problem.parameterTooLong("label")) {
            try BIP21URI.parse("bitcoin:\(Self.valid)?label=" + String(repeating: "a", count: BIP21URI.maxTextLength + 1))
        }
        // "+" e literal no RFC 3986; acento em UTF-8 decodifica.
        #expect(try BIP21URI.parse("bitcoin:\(Self.valid)?label=a+b").label == "a+b")
        #expect(try BIP21URI.parse("bitcoin:\(Self.valid)?label=Jo%C3%A3o").label == "João")
    }
}
