@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// A troca e a ordem limite na DEX do XRP Ledger, com o livro gravado.
///
/// A lista curada da carteira ainda nao tem token do XRP Ledger; aqui o RLUSD entra como
/// lista curada de teste (emissor conferido por gateway_balances, ver o LEIA-ME).
@Suite("Troca no XRP Ledger com respostas gravadas")
struct XRPLTradeTests {
    typealias N = XRPLTestNetwork

    static let rlusd = Asset(
        chainID: "xrpl", kind: .issued(code: "524C555344000000000000000000000000000000", issuer: "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"),
        symbol: "RLUSD", name: "Ripple USD", decimals: 6, coingeckoID: nil, isStablecoin: true
    )
    static let xrp = Asset.native(.xrpl)

    static func engine(_ fake: FakeRPC) throws -> XRPLTradeEngine {
        try #require(XRPLTradeEngine(reader: N.reader(fake), tokens: [rlusd]))
    }

    static func request(sell: Asset = xrp, buy: Asset = rlusd, amount: BigUInt = 10_000_000, bps: Int = 50) -> TradeRequest {
        TradeRequest(walletID: UUID(), chain: .xrpl, account: TestAccounts.xrpl, sell: sell, buy: buy, amountIn: amount, slippageBasisPoints: bps)
    }

    static func offer(_ plan: SigningPlan) throws -> (XRPLTransaction, XRPLOfferCreate) {
        let transaction = try #require(plan.transactions.last as? XRPLTransaction)
        guard case .offerCreate(let offer) = transaction.body else { throw EngineFixture.Missing(name: "OfferCreate") }
        return (transaction, offer)
    }

    @Test("Sem token curado nao ha troca, e o registro segue a lista da carteira")
    func registry() {
        #expect(XRPLTradeEngine(reader: N.reader(FakeRPC()), tokens: []) == nil)
        #expect((EngineRegistry.xrplTrade(.xrpl) == nil) == XRPLEngineSupport.registryAssets.isEmpty)
    }

    @Test("Cotacao pelo livro: ofertas do melhor preco para o pior, minimo pela tolerancia")
    func quote() async throws {
        let quote = try await Self.engine(try N.fake()).quote(Self.request())
        // 10 XRP a uns 0,6445 XRP por RLUSD: pouco mais de 15,5 RLUSD.
        #expect((15_400_000...15_600_000).contains(quote.expectedOut))
        #expect(quote.minimumOut == TradeMath.minimumOut(quote.expectedOut, slippageBasisPoints: 50))
        let impact = try #require(quote.priceImpactPercent)
        #expect(impact >= 0 && impact < 1)
        #expect(!quote.needsApproval && quote.legs.first?.provider == XRPLTradeEngine.provider)
    }

    @Test("Livro que nao cobre o valor: recusa em vez de cotar pela metade")
    func thinBook() async throws {
        await #expect(throws: SendEngineError.self) {
            _ = try await Self.engine(try N.fake()).quote(Self.request(amount: 1_000_000_000_000))
        }
    }

    @Test("Plano sem linha de confianca: TrustSet e depois a oferta tudo ou nada, em Sequences seguidas")
    func planWithTrustline() async throws {
        let engine = try Self.engine(try N.fake())
        let request = Self.request()
        let quote = try await engine.quote(request)
        let plan = try await engine.plan(request, quote: quote)
        #expect(plan.review.kind == .swap && plan.review.transactionCount == 2)
        #expect(plan.review.title == "Trocar 10 XRP por RLUSD")
        #expect(plan.review.lines.first?.label == "Transações")

        let trust = try #require(plan.transactions.first as? XRPLTransaction)
        guard case .trustSet(let line) = trust.body else { Issue.record("esperava TrustSet primeiro"); return }
        #expect(line.limit.currency.code == "524C555344000000000000000000000000000000")
        let (transaction, offer) = try Self.offer(plan)
        #expect(trust.sequence == 568_912 && transaction.sequence == 568_913)
        #expect(offer.options == [.sell, .fillOrKill])
        #expect(offer.takerGets == .xrp(drops: 10_000_000))
        let minimum = try XRPLDecimal(XRPLUnits.decimalText(quote.minimumOut, decimals: 6))
        guard case .issued(let pays) = offer.takerPays else { Issue.record("esperava RLUSD"); return }
        #expect(pays.value == minimum && pays.issuerAddress == "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De")
    }

    @Test("Vender RLUSD sem ter a linha: recusa com o saldo do token")
    func sellWithoutBalance() async throws {
        let engine = try Self.engine(try N.fake())
        let request = Self.request(sell: Self.rlusd, buy: Self.xrp, amount: 5_000_000)
        let quote = try await engine.quote(request)
        await #expect(throws: SendEngineError.message("Saldo de RLUSD insuficiente para esta ordem.")) {
            _ = try await engine.plan(request, quote: quote)
        }
    }

    @Test("Ordem limite: a oferta fica no livro so com tfSell, com Expiration, e abre a linha antes")
    func limitOrder() async throws {
        let before = Date()
        let plan = try await Self.engine(try N.fake()).planLimitOrder(LimitOrderRequest(
            walletID: UUID(), chain: .xrpl, account: TestAccounts.xrpl, sell: Self.xrp, buy: Self.rlusd,
            amountIn: 5_000_000, minimumOut: 8_000_000, validFor: 86_400
        ))
        #expect(plan.review.kind == .limitOrder && plan.transactions.count == 2)
        let (_, offer) = try Self.offer(plan)
        #expect(offer.options == [.sell])
        let expiration = try #require(offer.expiration)
        let expected = try #require(XRPLPlanner.rippleTime(before.addingTimeInterval(86_400)))
        #expect(expiration >= expected && expiration <= expected + 5)
    }

    @Test("Transmissao em ordem: a oferta so sai se a linha de confianca foi aceita")
    func submitInOrder() async throws {
        let engine = try Self.engine(try N.fake())
        let request = Self.request()
        let plan = try await engine.plan(request, quote: try await engine.quote(request))
        let signed = try plan.transactions.map(N.signed)

        let fine = try N.fake(submit: { params in
            let blob = params["tx_blob"] as? String ?? ""
            let id = signed.first { $0.encoded == blob }?.id ?? ""
            return N.submitted("tesSUCCESS", hash: id)
        })
        #expect(try await Self.engine(fine).submit(signed, plan: plan) == signed.map(\.id))

        let failed = try N.fake(submit: { _ in N.submitted("tecNO_LINE_INSUF_RESERVE", hash: signed[0].id) })
        await #expect(throws: SendEngineError.self) { _ = try await Self.engine(failed).submit(signed, plan: plan) }
        #expect(failed.calls.filter { $0.method == "submit" }.count == 1)
    }
}
