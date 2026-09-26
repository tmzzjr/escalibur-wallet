import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// O DP de divisao com curvas sinteticas, e o ranking liquido pelo garantido.
@Suite("Troca: divisao e ranking")
struct TradeSplitTests {
    typealias S = TradeTestSupport
    typealias P = TradeSplitCurve.Point

    /// Uma curva concava de pool com liquidez finita: out(x) = k * x / (x + L), em
    /// unidades inteiras, amostrada nas fracoes que a rede cota.
    static func curve(_ provider: TradeProvider, depth: UInt64, rate: UInt64, cost: BigUInt, sources: Set<String>?) -> TradeSplitCurve {
        let total: UInt64 = 1_000_000
        let points = TradeSplitOptimizer.sampleShares.map { share -> P in
            let x = total * UInt64(share) / 10_000
            let out = BigUInt(rate) * BigUInt(x) * BigUInt(depth) / BigUInt(x + depth)
            return P(shareBps: share, out: out)
        }
        return TradeSplitCurve(provider: provider, points: points, fixedCost: cost, routeSources: sources)
    }

    @Test("Duas liquidezes rasas e disjuntas: dividir ganha, e as pernas somam o valor exato")
    func splitWins() {
        let a = Self.curve(.velora, depth: 1_000_000, rate: 1_000, cost: 1_000, sources: ["pool-a"])
        let b = Self.curve(.kyberSwap, depth: 1_000_000, rate: 1_000, cost: 1_000, sources: ["pool-b"])
        let decision = TradeSplitOptimizer.optimize(curves: [a, b], amountIn: 1_000_001, minimumGainAbsolute: 10)
        #expect(decision.accepted)
        #expect(decision.legs.count == 2)
        #expect(decision.legs.map(\.shareBps) == [5_000, 5_000])
        #expect(decision.legs.reduce(BigUInt()) { $0 + $1.amountIn } == 1_000_001)
        // Metade em cada: 2 * (500 * 1e6 * 1e6/1.5e6) - custos = 666.666.666 - 2.000; unica: 500.000.000 - 1.000.
        #expect(decision.singleNet == 499_999_000)
        #expect(decision.splitNet == 666_664_666)
        #expect(decision.gain == decision.splitNet - decision.singleNet)
    }

    @Test("Liquidez desigual: o DP da mais a quem tem mais fundo, em passos de 5%")
    func unevenDepth() {
        let deep = Self.curve(.velora, depth: 3_000_000, rate: 1_000, cost: 1_000, sources: ["deep"])
        let shallow = Self.curve(.kyberSwap, depth: 500_000, rate: 1_000, cost: 1_000, sources: ["shallow"])
        let decision = TradeSplitOptimizer.optimize(curves: [deep, shallow], amountIn: 1_000_000, minimumGainAbsolute: 0)
        #expect(decision.accepted)
        let share = Dictionary(uniqueKeysWithValues: decision.legs.map { ($0.provider, $0.shareBps) })
        #expect((share[.velora] ?? 0) > (share[.kyberSwap] ?? 0))
        #expect(decision.legs.allSatisfy { $0.shareBps % TradeSplitOptimizer.stepBps == 0 })
        #expect(decision.legs.reduce(0) { $0 + $1.shareBps } == 10_000)
    }

    @Test("Tres provedores: usa os tres quando cada um tem pouca liquidez")
    func threeWay() {
        let curves = [
            Self.curve(.velora, depth: 400_000, rate: 1_000, cost: 100, sources: ["a"]),
            Self.curve(.kyberSwap, depth: 400_000, rate: 1_000, cost: 100, sources: ["b"]),
            Self.curve(.de1, depth: 400_000, rate: 1_000, cost: 100, sources: ["c"]),
        ]
        let decision = TradeSplitOptimizer.optimize(curves: curves, amountIn: 900_000, minimumGainAbsolute: 0)
        #expect(decision.accepted)
        #expect(decision.legs.count == 3)
        #expect(decision.legs.reduce(BigUInt()) { $0 + $1.amountIn } == 900_000)
    }

    @Test("Mesmos pools, rota opaca ou ganho abaixo do minimo: nao divide")
    func refusals() {
        let a = Self.curve(.velora, depth: 1_000_000, rate: 1_000, cost: 1_000, sources: ["pool-x", "a"])
        let b = Self.curve(.kyberSwap, depth: 1_000_000, rate: 1_000, cost: 1_000, sources: ["pool-x"])
        #expect(!TradeSplitOptimizer.optimize(curves: [a, b], amountIn: 1_000_000, minimumGainAbsolute: 0).accepted)

        let opaque = Self.curve(.lifi, depth: 1_000_000, rate: 1_000, cost: 1_000, sources: nil)
        #expect(!TradeSplitOptimizer.optimize(curves: [a, opaque], amountIn: 1_000_000, minimumGainAbsolute: 0).accepted)

        // Liquidez funda: a curva e quase reta, dividir so paga gas a mais.
        let deepA = Self.curve(.velora, depth: 1_000_000_000_000, rate: 1_000, cost: 5_000, sources: ["a"])
        let deepB = Self.curve(.kyberSwap, depth: 1_000_000_000_000, rate: 1_000, cost: 5_000, sources: ["b"])
        let flat = TradeSplitOptimizer.optimize(curves: [deepA, deepB], amountIn: 1_000_000, minimumGainAbsolute: 0)
        #expect(!flat.accepted)
        #expect(flat.legs.isEmpty)

        // Ganho real, mas abaixo de US$ 5 (aqui, 10^9 unidades).
        let c = Self.curve(.velora, depth: 1_000_000, rate: 1_000, cost: 1_000, sources: ["c"])
        let d = Self.curve(.kyberSwap, depth: 1_000_000, rate: 1_000, cost: 1_000, sources: ["d"])
        let small = TradeSplitOptimizer.optimize(curves: [c, d], amountIn: 1_000_000, minimumGainAbsolute: 1_000_000_000)
        #expect(!small.accepted)
        #expect(small.requiredGain == 1_000_000_000)
    }

    @Test("O minimo de 10 bps vale quando passa dos US$ 5")
    func bpsThreshold() {
        // Ganho de ~0,2% sobre a unica: aceita com 10 bps, recusa se o piso absoluto for maior.
        let a = Self.curve(.velora, depth: 200_000_000, rate: 1_000, cost: 0, sources: ["a"])
        let b = Self.curve(.kyberSwap, depth: 200_000_000, rate: 1_000, cost: 0, sources: ["b"])
        let decision = TradeSplitOptimizer.optimize(curves: [a, b], amountIn: 1_000_000, minimumGainAbsolute: 0)
        #expect(decision.requiredGain == decision.singleNet * 10 / 10_000)
        #expect(decision.gain * 10_000 / decision.singleNet < 100)
    }

    @Test("Interpolacao entre os pontos cotados, com a origem")
    func interpolation() {
        let curve = TradeSplitCurve(provider: .velora, points: [P(shareBps: 5_000, out: 500), P(shareBps: 10_000, out: 900)],
                                    fixedCost: 100, routeSources: ["x"])
        #expect(curve.out(atBps: 2_500) == 250)
        #expect(curve.out(atBps: 7_500) == 700)
        #expect(curve.net(atBps: 10_000) == 800)
        #expect(curve.net(atBps: 0) == 0)
        // Custo maior que o garantido: perna sem valor.
        #expect(curve.net(atBps: 500) == nil)
        let partial = TradeSplitCurve(provider: .velora, points: [P(shareBps: 5_000, out: 500)], fixedCost: 0, routeSources: nil)
        #expect(partial.out(atBps: 7_500) == nil)
    }

    @Test("Plano de varias etapas: revisao diz N transacoes independentes e o que acontece se uma falhar")
    func splitPlan() throws {
        let intent = try S.baseIntent()
        let a = Self.curve(.velora, depth: 1_000_000, rate: 1_000, cost: 1_000, sources: ["pool-a"])
        let b = Self.curve(.kyberSwap, depth: 1_000_000, rate: 1_000, cost: 1_000, sources: ["pool-b"])
        let decision = TradeSplitOptimizer.optimize(curves: [a, b], amountIn: intent.amountIn, minimumGainAbsolute: 0)
        let plan = try TradeSplitPlan(intent: intent, decision: decision)
        #expect(plan.review.title == "Trocar 100\u{00A0}USDC por ETH em 2 etapas")
        #expect(plan.review.transactionCount == 2)
        let lines = Dictionary(uniqueKeysWithValues: plan.review.lines.map { ($0.label, $0.value) })
        #expect(lines["Divisão"] == "50% pela Velora, 50% pela KyberSwap")
        #expect(lines["Transações"]?.hasPrefix("2 trocas independentes") == true)
        #expect(lines["Ordem"]?.contains("só depois que a anterior confirmar") == true)
        #expect(lines["Se uma etapa falhar"] == "Você fica com cerca de 50% em ETH e 50% em USDC. Não existe desfazer: perde só a taxa de rede da etapa que falhou, e o app oferece recotar o restante.")
        #expect(lines["Taxa da Escalibur"] == "Sem taxa da Escalibur")
        let leg0 = try plan.legIntent(0)
        let leg1 = try plan.legIntent(1)
        #expect(leg0.amountIn + leg1.amountIn == intent.amountIn)
        #expect(leg0.slippageBps == intent.slippageBps)
        #expect(plan.step(1) == TradeSplitStep(index: 1, count: 2, shareBps: 5_000))
        // Decisao recusada nao vira plano.
        #expect(throws: TradeRefusal.self) {
            try TradeSplitPlan(intent: intent, decision: TradeSplitOptimizer.optimize(curves: [a], amountIn: intent.amountIn, minimumGainAbsolute: 0))
        }
    }

    // MARK: Ranking

    @Test("Ranking pelo garantido decodificado, nunca pelo estimado anunciado")
    func rankingUsesGuaranteed() throws {
        let intent = try S.baseIntent()
        let kyber = try TradeValidator.validate(S.proposal(.kyberSwap, "kyber-base-usdc-eth-build"), intent: intent, now: S.recordedAt)
        let velora = try TradeValidator.validate(S.proposal(.velora, "velora-base-usdc-eth"), intent: intent, now: S.recordedAt)
        let lifi = try TradeValidator.validate(S.proposal(.lifi, "lifi-base-usdc-eth"), intent: intent, now: S.recordedAt)
        let de1 = try TradeValidator.validate(S.proposal(.de1, "de1-base-usdc-eth"), intent: intent, now: S.recordedAt)
        let ranked = TradeRanking.rank([lifi, de1, kyber, velora], costs: .free)
        let guaranteed = ranked.map(\.quote.guaranteedOut)
        #expect(guaranteed == guaranteed.sorted(by: >))
        #expect(ranked.first?.netOut == TradeSignedAmount(ranked.first!.quote.guaranteedOut))

        // Um provedor que anuncia estimado enorme e garantido baixo fica atras.
        let lowGuaranteed = [kyber, velora].min { $0.guaranteedOut < $1.guaranteedOut }!
        let highGuaranteed = [kyber, velora].max { $0.guaranteedOut < $1.guaranteedOut }!
        #expect(lowGuaranteed.expectedOut > 0)
        let order = TradeRanking.rank([lowGuaranteed, highGuaranteed], costs: .free).map(\.quote.provider)
        #expect(order.first == highGuaranteed.provider)
    }

    @Test("Custos iguais para todos: gas pelo mesmo preco, approval so para quem precisa")
    func rankingCosts() throws {
        let intent = try S.baseIntent()
        let kyber = try TradeValidator.validate(S.proposal(.kyberSwap, "kyber-base-usdc-eth-build"), intent: intent, now: S.recordedAt)
        let velora = try TradeValidator.validate(S.proposal(.velora, "velora-base-usdc-eth"), intent: intent, now: S.recordedAt)
        // 1 gwei; comprado e nativo (ETH), conversao 1:1.
        let base = TradeCostModel(gasPriceWei: 1_000_000_000, l1FeePerTransactionWei: 1_000, nativeToBuy: .identity, approveGas: 50_000)
        let (cost, approval) = TradeRanking.cost(of: kyber, costs: base)
        #expect(approval)
        let gas = BigUInt(min(max(kyber.gasEstimate!, 80_000), 5_000_000))
        #expect(cost == gas * 1_000_000_000 + 1_000 + BigUInt(50_000) * 1_000_000_000 + 1_000)
        // Com allowance para a Kyber, so a Velora paga approval.
        let withAllowance = TradeCostModel(gasPriceWei: 1_000_000_000, nativeToBuy: .identity, approveGas: 50_000,
                                           allowances: [kyber.spender: 1_000_000_000])
        let ranked = TradeRanking.rank([kyber, velora], costs: withAllowance)
        #expect(ranked.first { $0.quote.provider == .kyberSwap }?.needsApproval == false)
        #expect(ranked.first { $0.quote.provider == .velora }?.needsApproval == true)
        // Gas absurdo deixa o liquido negativo e a cotacao vai para o fim.
        let absurd = TradeCostModel(gasPriceWei: BigUInt(decimal: "1000000000000000")!, nativeToBuy: .identity)
        #expect(TradeRanking.rank([kyber], costs: absurd).first?.netOut.isNegative == true)
    }

    @Test("Conversao nativo -> comprado pelo oraculo: exata")
    func nativeRate() {
        // ETH a US$ 2.500, USDC a US$ 1: 1 wei = 2.500 * 10^6 / 10^18 unidades de USDC.
        let rate = TradeRate.nativeToBuy(chain: .base, buy: .token(S.baseUSDC), nativePriceUSD: "2500", buyPriceUSD: "1")!
        #expect(rate.apply(BigUInt(decimal: "1000000000000000000")!) == 2_500_000_000)
        #expect(TradeRate.nativeToBuy(chain: .base, buy: .native(.base), nativePriceUSD: "1", buyPriceUSD: "1") == .identity)
    }
}
