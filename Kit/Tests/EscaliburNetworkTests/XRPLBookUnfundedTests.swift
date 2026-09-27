import EscaliburChains
import Foundation
import Testing
@testable import EscaliburNetwork

/// O livro do RLUSD em 27/09/2026 tinha uma oferta cujo dono nao tinha mais RLUSD: o
/// servidor a devolve com `taker_gets_funded` zero. Ela sai da cotacao; o livro fica.
@Suite("Livro do XRP Ledger com oferta sem fundos")
struct XRPLBookUnfundedTests {
    static let rlusd = #"{"currency":"524C555344000000000000000000000000000000","issuer":"rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De","value":"%@"}"#

    func book(_ offers: [String]) throws -> StrictJSON {
        let text = #"{"ledger_index":107279886,"offers":["# + offers.joined(separator: ",") + "]}"
        return try StrictJSON.parse(Data(text.utf8))
    }

    func offer(gets: String, pays: String, fundedGets: String? = nil) -> String {
        var text = #"{"TakerGets":"# + String(format: Self.rlusd, gets) + #","TakerPays":"\#(pays)""#
        if let fundedGets {
            text += #","taker_gets_funded":"# + String(format: Self.rlusd, fundedGets) + #","taker_pays_funded":"0""#
        }
        return text + "}"
    }

    var gets: XRPLBookAsset {
        get throws { .issued(currency: try XRPLCurrency(code: "524C555344000000000000000000000000000000"), issuer: "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De") }
    }

    @Test("Oferta sem fundos sai, as outras ficam")
    func skipsUnfunded() throws {
        let parsed = try XRPLReader.parseBook(try book([
            offer(gets: "1.1", pays: "722979"),
            offer(gets: "0.78161512", pays: "520000", fundedGets: "0"),
            offer(gets: "1802.2215818", pays: "1199000000"),
        ]), gets: try gets, pays: .xrp, ledger: 107279886)
        #expect(parsed.count == 2)
    }

    @Test("Zero no valor da propria oferta continua recusado")
    func zeroOwnAmountRefused() throws {
        #expect(throws: ReaderError.self) {
            try XRPLReader.parseBook(try book([offer(gets: "0", pays: "520000")]), gets: try gets, pays: .xrp, ledger: 107279886)
        }
    }
}
