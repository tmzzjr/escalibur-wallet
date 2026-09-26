import EscaliburCore
import Foundation

// Divisao entre provedores (docs/blockchain.md 3.3): "se um provedor so tem X, combinar
// 2 ou 3".
//
// Quando vale: o impacto de preco da melhor cotacao unica passa de ~30 bps. Entao a rede
// cota os 3 melhores em 25, 50, 75 e 100% do valor, e aqui:
//
//  1. cada provedor vira uma curva do garantido (minOut decodificado) por fracao,
//     interpolada linearmente a partir de (0, 0), com custo fixo por perna (gas da troca
//     e approve se faltar), cobrado so se a perna existe;
//  2. um DP em passos de 5%: best[k][s] = max_a best[k-1][s-a] + f_k(a) - c_k*[a > 0];
//  3. a divisao so e aceita se ganhar pelo menos max(10 bps, US$ 5) liquido sobre a
//     melhor cotacao unica.
//
// Liquidez correlacionada: agregadores diferentes batem nos mesmos pools, e a perna 1
// move o preco da perna 2. Por isso so entram juntas curvas com `routeSources`
// conhecidas e disjuntas (rota opaca nunca divide), e a perna 2 e recotada depois de a
// perna 1 confirmar, com minOut proprio.
//
// Na EVM nao ha atomicidade (sem router proprio, sem 7702): sao N transacoes
// independentes, e o plano diz isso antes de comecar.

public struct TradeSplitCurve: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        /// Fracao do valor total, em bps (2500 = 25%).
        public let shareBps: Int
        /// O garantido decodificado da cotacao nessa fracao, em unidades do comprado.
        public let out: BigUInt

        public init(shareBps: Int, out: BigUInt) {
            self.shareBps = shareBps
            self.out = out
        }
    }

    public let provider: TradeProvider
    public let points: [Point]
    /// Gas da troca e approve se faltar, em unidades do comprado.
    public let fixedCost: BigUInt
    /// `nil` = rota opaca: nunca divide com ninguem.
    public let routeSources: Set<String>?

    public init(provider: TradeProvider, points: [Point], fixedCost: BigUInt, routeSources: Set<String>?) {
        self.provider = provider
        self.points = points.filter { $0.shareBps > 0 && $0.shareBps <= 10_000 }.sorted { $0.shareBps < $1.shareBps }
        self.fixedCost = fixedCost
        self.routeSources = routeSources.map { Set($0.map { $0.lowercased() }) }
    }

    /// O garantido numa fracao qualquer, por interpolacao linear entre os pontos (e a
    /// origem). Fora dos pontos medidos a curva nao extrapola: sem o ponto de 100%, nao
    /// ha valor para 100%.
    func out(atBps share: Int) -> BigUInt? {
        guard share > 0 else { return 0 }
        var lowShare = 0
        var lowOut = BigUInt()
        for point in points {
            if point.shareBps == share { return point.out }
            if point.shareBps > share {
                let span = BigUInt(point.shareBps - lowShare)
                let offset = BigUInt(share - lowShare)
                if point.out >= lowOut {
                    return lowOut + (point.out - lowOut) * offset / span
                }
                return lowOut - (lowOut - point.out) * offset / span
            }
            lowShare = point.shareBps
            lowOut = point.out
        }
        return nil
    }

    /// O liquido de uma perna nessa fracao: garantido menos o custo fixo. `nil` se a
    /// perna da prejuizo (custa mais do que entrega) ou se a fracao nao tem valor.
    func net(atBps share: Int) -> BigUInt? {
        guard share > 0 else { return 0 }
        guard let out = out(atBps: share) else { return nil }
        return out.subtractingReportingUnderflow(fixedCost)
    }
}

public struct TradeSplitDecision: Sendable, Equatable {
    public struct Leg: Sendable, Equatable {
        public let provider: TradeProvider
        public let shareBps: Int
        public let amountIn: BigUInt
        /// O liquido que a curva previu para esta perna.
        public let expectedNet: BigUInt
    }

    public let legs: [Leg]
    public let splitNet: BigUInt
    public let singleNet: BigUInt
    public let singleProvider: TradeProvider?
    /// Quanto a divisao ganha sobre a melhor cotacao unica.
    public let gain: BigUInt
    /// O ganho minimo que foi exigido: max(10 bps, US$ 5).
    public let requiredGain: BigUInt
    public let accepted: Bool
}

public enum TradeSplitOptimizer {
    /// Impacto a partir do qual vale a pena cotar em fracoes.
    public static let triggerImpactBps = 30
    public static let stepBps = 500
    /// As fracoes que a rede cota para montar as curvas.
    public static let sampleShares = [2_500, 5_000, 7_500, 10_000]
    public static let minimumGainBps = 10
    public static let maxProviders = 3

    /// Vale cotar em fracoes?
    public static func shouldConsider(_ best: TradeCandidate) -> Bool {
        (best.quote.assessment.priceImpactBps ?? 0) > triggerImpactBps
    }

    /// `minimumGainAbsolute`: US$ 5 em unidades do token comprado, calculado pelo
    /// chamador com o mesmo oraculo do resto.
    public static func optimize(curves: [TradeSplitCurve], amountIn: BigUInt, minimumGainAbsolute: BigUInt) -> TradeSplitDecision {
        let curves = Array(curves.prefix(maxProviders))
        let steps = 10_000 / stepBps

        // A melhor unica: 100% num provedor, com o seu custo fixo.
        var singleNet = BigUInt()
        var singleProvider: TradeProvider?
        for curve in curves {
            if let net = curve.net(atBps: 10_000), singleProvider == nil || net > singleNet {
                singleNet = net
                singleProvider = curve.provider
            }
        }

        // DP em cada subconjunto de 2 ou mais curvas com rotas disjuntas.
        var best: (net: BigUInt, allocation: [(TradeSplitCurve, Int)])?
        for subset in subsets(curves) where subset.count >= 2 && disjoint(subset) {
            guard let (net, allocation) = dynamicProgram(subset, steps: steps) else { continue }
            let legs = allocation.filter { $0.1 > 0 }
            guard legs.count >= 2 else { continue }
            if best == nil || net > best!.net { best = (net, legs) }
        }

        let bpsGain = singleNet * BigUInt(minimumGainBps) / TradeConstants.basisPoints
        let required = max(bpsGain, minimumGainAbsolute)
        guard let chosen = best, chosen.net > singleNet, chosen.net - singleNet >= required else {
            return TradeSplitDecision(legs: [], splitNet: best?.net ?? 0, singleNet: singleNet, singleProvider: singleProvider,
                                      gain: best.map { $0.net > singleNet ? $0.net - singleNet : 0 } ?? 0,
                                      requiredGain: required, accepted: false)
        }

        // Valores de cada perna: a fracao do total, e a ultima fica com o resto para a
        // soma bater exatamente com o valor vendido.
        var legs = [TradeSplitDecision.Leg]()
        var assigned = BigUInt()
        for (index, entry) in chosen.allocation.enumerated() {
            let share = entry.1 * stepBps
            let amount = index == chosen.allocation.count - 1
                ? amountIn - assigned
                : amountIn * BigUInt(share) / TradeConstants.basisPoints
            assigned = assigned + amount
            legs.append(.init(provider: entry.0.provider, shareBps: share, amountIn: amount,
                              expectedNet: entry.0.net(atBps: share) ?? 0))
        }
        return TradeSplitDecision(legs: legs, splitNet: chosen.net, singleNet: singleNet, singleProvider: singleProvider,
                                  gain: chosen.net - singleNet, requiredGain: required, accepted: true)
    }

    /// best[k][s] = max_a best[k-1][s-a] + net_k(a). Devolve o liquido total e quantos
    /// passos cada curva leva.
    static func dynamicProgram(_ curves: [TradeSplitCurve], steps: Int) -> (BigUInt, [(TradeSplitCurve, Int)])? {
        // table[s] = (liquido, alocacao) usando as curvas ja vistas, somando s passos.
        var table: [(BigUInt, [Int])?] = Array(repeating: nil, count: steps + 1)
        table[0] = (0, [])
        for curve in curves {
            var next: [(BigUInt, [Int])?] = Array(repeating: nil, count: steps + 1)
            for used in 0...steps {
                guard let (value, allocation) = table[used] else { continue }
                for take in 0...(steps - used) {
                    guard let net = curve.net(atBps: take * stepBps) else { continue }
                    let total = value + net
                    if let current = next[used + take], current.0 >= total { continue }
                    next[used + take] = (total, allocation + [take])
                }
            }
            table = next
        }
        guard let (net, allocation) = table[steps] else { return nil }
        return (net, zip(curves, allocation).map { ($0, $1) })
    }

    static func subsets(_ curves: [TradeSplitCurve]) -> [[TradeSplitCurve]] {
        guard !curves.isEmpty else { return [] }
        return (1..<(1 << curves.count)).map { mask in
            curves.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
        }
    }

    /// Rotas conhecidas e sem pool, DEX ou provedor em comum.
    static func disjoint(_ curves: [TradeSplitCurve]) -> Bool {
        var seen = Set<String>()
        for curve in curves {
            guard let sources = curve.routeSources, !sources.isEmpty else { return false }
            guard seen.isDisjoint(with: sources) else { return false }
            seen.formUnion(sources)
        }
        return true
    }
}

/// A troca dividida em etapas: o que a tela mostra antes de comecar, e a intencao de
/// cada perna. Cada perna vira um `SigningPlan` proprio, montado na hora (a perna 2 so
/// depois da perna 1 confirmar, com cotacao e minOut novos).
public struct TradeSplitPlan: Sendable, Equatable {
    public let intent: TradeIntent
    public let decision: TradeSplitDecision
    /// A visao geral: N transacoes independentes e o que acontece se uma falhar.
    public let review: PlanReview

    public init(intent: TradeIntent, decision: TradeSplitDecision) throws {
        guard decision.accepted, decision.legs.count >= 2 else { throw TradeRefusal.malformed("divisao nao aceita") }
        let total = decision.legs.reduce(BigUInt()) { $0 + $1.amountIn }
        guard total == intent.amountIn else { throw TradeRefusal.amountInMismatch(expected: intent.amountIn, found: total) }
        self.intent = intent
        self.decision = decision
        self.review = Self.overview(intent: intent, decision: decision)
    }

    public var legCount: Int { decision.legs.count }

    /// A intencao da perna `index`, com o valor exato dela.
    public func legIntent(_ index: Int) throws -> TradeIntent {
        guard decision.legs.indices.contains(index) else { throw TradeRefusal.malformed("perna") }
        return try intent.withAmount(decision.legs[index].amountIn)
    }

    public func step(_ index: Int) -> TradeSplitStep {
        TradeSplitStep(index: index, count: decision.legs.count, shareBps: decision.legs[index].shareBps)
    }

    static func overview(intent: TradeIntent, decision: TradeSplitDecision) -> PlanReview {
        let parts = decision.legs.map { "\(TradeText.percent(bps: $0.shareBps)) pela \($0.provider.displayName)" }
        let first = decision.legs[0]
        let rest = decision.legs.dropFirst().map { TradeText.percent(bps: $0.shareBps) }.joined(separator: " e ")
        var lines: [PlanReview.Line] = [
            .init("Rede", intent.chain.name),
            .init("Sai", TradeText.amount(intent.amountIn, intent.sell)),
            .init("Divisão", parts.joined(separator: ", ")),
            .init("Transações", "\(decision.legs.count) trocas independentes, uma depois da outra, mais as autorizações exatas que faltarem"),
            .init("Ordem", "Cada etapa é recotada só depois que a anterior confirmar, com o seu próprio mínimo garantido"),
            .init("Se uma etapa falhar", "Você fica com cerca de \(TradeText.percent(bps: first.shareBps)) em \(intent.buy.symbol) e \(rest) em \(intent.sell.symbol). Não existe desfazer: perde só a taxa de rede da etapa que falhou, e o app oferece recotar o restante."),
            .init("Ganho estimado", "\(TradeText.amount(decision.gain, intent.buy)) sobre a melhor cotação única, já descontada a taxa de rede extra"),
            .init("Taxa da Escalibur", "Sem taxa da Escalibur"),
        ]
        if let single = decision.singleProvider {
            lines.append(.init("Alternativa", "Tudo pela \(single.displayName) numa transação só"))
        }
        return PlanReview(
            kind: .swap,
            title: "Trocar \(TradeText.amount(intent.amountIn, intent.sell)) por \(intent.buy.symbol) em \(decision.legs.count) etapas",
            lines: lines, warnings: [], transactionCount: decision.legs.count
        )
    }
}
