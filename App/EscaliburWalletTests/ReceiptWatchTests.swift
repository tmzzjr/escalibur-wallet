import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburWallet

/// O aviso de recebimento: o que conta como entrada e o texto da notificacao.
struct ReceiptWatchTests {
    let account = ReceiptWatchFile.Account(chainID: "tron", addresses: ["TXYZ"])
    let usdt = TokenRegistry.tokens.first { $0.chainID == "tron" && $0.symbol == "USDT" }!

    func balance(trx: BigUInt, usdt amount: BigUInt?) -> ChainBalance {
        var holdings = [Holding(asset: .native(.tron), amount: trx)]
        if let amount { holdings.append(Holding(asset: usdt, amount: amount)) }
        return ChainBalance(chainID: "tron", holdings: holdings, accountExists: true, unknownTokenCount: 0, fetchedAt: .now)
    }

    @Test func firstReadOnlyMarksTheBase() {
        var seen: [String: ReceiptWatchFile.Seen] = [:]
        let events = ReceiptWatchCenter.compare([(account, balance(trx: 5_000_000, usdt: 100_000_000))], seen: &seen)
        #expect(events.isEmpty)
        #expect(seen.count == 2)
    }

    @Test func increaseNotifiesDecreaseDoesNot() {
        var seen: [String: ReceiptWatchFile.Seen] = [:]
        _ = ReceiptWatchCenter.compare([(account, balance(trx: 5_000_000, usdt: 100_000_000))], seen: &seen)
        let up = ReceiptWatchCenter.compare([(account, balance(trx: 4_000_000, usdt: 150_000_000))], seen: &seen)
        let plain = up.map { ReceiptEvent(chainID: $0.chainID, symbol: $0.symbol, decimals: $0.decimals, amount: $0.amount) }
        #expect(plain == [ReceiptEvent(chainID: "tron", symbol: "USDT", decimals: 6, amount: 50_000_000)])
        // O widget passa a mostrar a moeda que chegou: o evento leva o id da lista curada.
        #expect(up.first?.coingeckoID == "tether")
    }

    /// Enviado inteiro e recebido de novo, menos que antes: avisa.
    @Test func emptiedThenReceivedAgain() {
        var seen: [String: ReceiptWatchFile.Seen] = [:]
        _ = ReceiptWatchCenter.compare([(account, balance(trx: 5_000_000, usdt: 100_000_000))], seen: &seen)
        _ = ReceiptWatchCenter.compare([(account, balance(trx: 5_000_000, usdt: nil))], seen: &seen)
        let again = ReceiptWatchCenter.compare([(account, balance(trx: 5_000_000, usdt: 20_000_000))], seen: &seen)
        #expect(again.map(\.amount) == [20_000_000])
    }

    @Test func text() {
        let text = ReceiptText.describe(ReceiptEvent(chainID: "tron", symbol: "USDT", decimals: 6, amount: 50_000_000))
        #expect(text.title == "Recebeu 50 USDT")
        #expect(text.body == "Na Tron. O saldo novo já está na carteira.")
    }
}
