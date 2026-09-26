import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// Os motores do XRP Ledger contra os servidores reais, so com ESCALIBUR_REDE=1. A conta
/// rEb8TK3g... e publica, com a chave publica conhecida; nada e assinado nem transmitido.
@Suite("Motores XRP Ledger ao vivo", .enabled(if: EngineFixture.live), .serialized)
struct XRPLEngineLiveTests {
    typealias N = XRPLTestNetwork

    @Test("Envio de ponta a ponta com tag, destino com RequireDest, e cotacao do livro RLUSD em dois servidores")
    func endToEnd() async throws {
        let engine = XRPLSendEngine()
        let tagged = try await engine.destination(N.exchange, chain: .xrpl)
        #expect(tagged.exists && tagged.requiresTag)

        let request = SendRequest(
            walletID: UUID(), chain: .xrpl, asset: .native(.xrpl), account: TestAccounts.xrpl, destination: N.plain,
            tag: "7", amount: 1_000, sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
        let spendable = try await engine.spendable(request)
        #expect(spendable.amount > 1_000)
        let plan = try await engine.plan(request)
        #expect(plan.review.recipient == N.plain)
        #expect(plan.review.recipientTag == "7")

        let trade = try #require(XRPLTradeEngine(tokens: [XRPLTradeTests.rlusd]))
        let quote = try await trade.quote(TradeRequest(
            walletID: UUID(), chain: .xrpl, account: TestAccounts.xrpl, sell: .native(.xrpl), buy: XRPLTradeTests.rlusd,
            amountIn: 1_000_000, slippageBasisPoints: 100
        ))
        #expect(quote.minimumOut > 0 && quote.minimumOut < quote.expectedOut)
    }
}
