import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// Os motores da Stellar contra a Horizon real (SDF e LOBSTR), so com ESCALIBUR_REDE=1.
/// A conta e publica e movimentada; nada e assinado nem transmitido.
@Suite("Motores Stellar ao vivo", .enabled(if: EngineFixture.live), .serialized)
struct StellarEngineLiveTests {
    static let memoRequired = "GDQP2KPQGKIHYJGXNUIYOMHARUARCA7DJT5FO2FFOOKY3B2WSQHG4W37"

    @Test("Envio de ponta a ponta para destino com SEP-29, e troca XLM por USDC ate o plano")
    func endToEnd() async throws {
        let engine = StellarSendEngine()
        let destination = try await engine.destination(Self.memoRequired, chain: .stellar)
        #expect(destination.exists && destination.requiresTag)

        let request = SendRequest(
            walletID: UUID(), chain: .stellar, asset: .native(.stellar), account: TestAccounts.stellar,
            destination: Self.memoRequired, tag: "12345", amount: 10_000_000, sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
        let spendable = try await engine.spendable(request)
        #expect(spendable.amount > 10_000_000)
        let plan = try await engine.plan(request)
        #expect(plan.review.recipient == Self.memoRequired)
        #expect(plan.review.recipientTag == "12345")

        let trade = StellarTradeEngine()
        let usdc = try #require(TokenRegistry.tokens.first { $0.chainID == "stellar" && $0.symbol == "USDC" })
        let tradeRequest = TradeRequest(
            walletID: UUID(), chain: .stellar, account: TestAccounts.stellar, sell: .native(.stellar), buy: usdc,
            amountIn: 1_000_000_000, slippageBasisPoints: 100
        )
        let quote = try await trade.quote(tradeRequest)
        #expect(quote.minimumOut > 0 && quote.minimumOut < quote.expectedOut)
        let swap = try await trade.plan(tradeRequest, quote: quote)
        #expect(StellarTradeEngine.swap(in: swap)?.destMin == quote.minimumOut)
    }
}
