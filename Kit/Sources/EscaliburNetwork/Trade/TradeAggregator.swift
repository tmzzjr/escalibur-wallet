import EscaliburChains
import EscaliburCore
import Foundation

// O meta-agregador (docs/blockchain.md 3.2).
//
// - Pergunta a todos em paralelo. Prazo mole de 1,5 s: passou dele e ja ha pelo menos
//   uma cotacao valida, devolve o que chegou. Prazo duro de 4 s: devolve de qualquer
//   jeito e cancela o resto.
// - Circuit breaker do `ProviderPool`: 3 falhas seguidas (erro, prazo ou calldata
//   recusada) tiram o provedor por 60 s.
// - Cada resposta passa pela validacao de EscaliburChains/Trade antes de contar.
// - Ranking pelo liquido do garantido decodificado (TradeRanking), com o mesmo preco de
//   gas e a mesma conversao para todos.
// - Cache de 10 s pela intencao exata (a calldata carrega o valor exato, entao nao ha
//   "faixa de valor" reaproveitavel para assinar).

/// O resultado de uma rodada de cotacoes.
public struct TradeQuoteSet: Sendable {
    public let intent: TradeIntent
    /// Validas, do melhor para o pior liquido.
    public let ranked: [TradeCandidate]
    /// Por que cada provedor ficou de fora.
    public let failures: [TradeProvider: TradeProviderError]
    /// Quem nao respondeu ate o prazo (a rodada devolveu antes).
    public let pending: [TradeProvider]
    public let fetchedAt: Date
    /// `false` nas parciais do `updates` (a partir do prazo mole); `true` na ultima.
    public let isFinal: Bool

    public var best: TradeCandidate? { ranked.first }
}

public actor TradeAggregator {
    public static let softDeadline: Duration = .milliseconds(1_500)
    public static let hardDeadline: Duration = .seconds(4)
    static let cacheLifetime: TimeInterval = 10

    let sources: [any TradeQuoteSource]
    let pool: ProviderPool
    private var cache: [String: TradeQuoteSet] = [:]

    public static func defaultSources(client: HTTPClient = .shared) -> [any TradeQuoteSource] {
        [VeloraClient(client: client), KyberSwapClient(client: client), LiFiClient(client: client), De1Client(client: client)]
    }

    public init(sources: [any TradeQuoteSource] = TradeAggregator.defaultSources()) {
        self.sources = sources
        self.pool = ProviderPool(sources.map { Self.poolEntry($0.provider) })
    }

    // MARK: Cotacao

    /// Uma rodada completa: todos os provedores que atendem a rede, em paralelo, ate
    /// todos responderem ou o prazo duro. Para a tela, `updates` entrega parciais a
    /// partir do prazo mole.
    public func quote(
        _ intent: TradeIntent, market: TradeMarketReference = .none, costs: TradeCostModel,
        providers: Set<TradeProvider>? = nil, softDeadline: Duration = TradeAggregator.softDeadline,
        hardDeadline: Duration = TradeAggregator.hardDeadline, useCache: Bool = true
    ) async -> TradeQuoteSet {
        await run(intent, market: market, costs: costs, providers: providers, soft: softDeadline, hard: hardDeadline,
                  useCache: useCache, onSnapshot: nil)
    }

    /// A mesma rodada, em partes: a primeira no prazo mole (se ja ha cotacao valida), uma
    /// a cada resposta que chega depois, e a final (`isFinal`) quando todos responderam
    /// ou o prazo duro passou.
    public nonisolated func updates(
        _ intent: TradeIntent, market: TradeMarketReference = .none, costs: TradeCostModel,
        providers: Set<TradeProvider>? = nil
    ) -> AsyncStream<TradeQuoteSet> {
        AsyncStream { continuation in
            let task = Task {
                let final = await self.run(intent, market: market, costs: costs, providers: providers, soft: Self.softDeadline,
                                           hard: Self.hardDeadline, useCache: true) { continuation.yield($0) }
                continuation.yield(final)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func run(
        _ intent: TradeIntent, market: TradeMarketReference, costs: TradeCostModel, providers: Set<TradeProvider>?,
        soft: Duration, hard: Duration, useCache: Bool, onSnapshot: (@Sendable (TradeQuoteSet) -> Void)?
    ) async -> TradeQuoteSet {
        let key = Self.cacheKey(intent, providers)
        if useCache, let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime {
            return TradeQuoteSet(intent: intent, ranked: TradeRanking.rank(cached.ranked.map(\.quote), costs: costs),
                                 failures: cached.failures, pending: cached.pending, fetchedAt: cached.fetchedAt, isFinal: true)
        }

        let live = Set(await pool.available().map(\.name))
        var failures = [TradeProvider: TradeProviderError]()
        var active = [any TradeQuoteSource]()
        for source in sources where providers?.contains(source.provider) ?? true {
            guard TradeAllowlist.router(for: source.provider, on: intent.chain) != nil else {
                failures[source.provider] = .unsupported(source.provider)
                continue
            }
            guard live.contains(source.provider.rawValue) else {
                failures[source.provider] = .benched(source.provider)
                continue
            }
            active.append(source)
        }

        let request = TradeQuoteRequest(intent: intent, gasPriceWei: costs.gasPriceWei)
        let activeProviders = active.map(\.provider)
        let initialFailures = failures
        var progress: Progress?
        if let onSnapshot {
            progress = { results in
                onSnapshot(Self.assemble(intent, results, active: activeProviders, failures: initialFailures, costs: costs, isFinal: false))
            }
        }
        let outcomes = await Self.fanOut(active, request: request, market: market, soft: soft, hard: hard, waitForAll: true, onProgress: progress)
        for (provider, result) in outcomes {
            switch result {
            case .success: await pool.reportSuccess(Self.poolEntry(provider))
            // "Sem rota" e "nao atende" nao sao falha do provedor.
            case .failure(.noRoute), .failure(.unsupported): break
            case .failure: await pool.reportFailure(Self.poolEntry(provider))
            }
        }
        let set = Self.assemble(intent, outcomes, active: activeProviders, failures: failures, costs: costs, isFinal: true)
        for provider in set.pending { await pool.reportFailure(Self.poolEntry(provider)) }
        if !set.ranked.isEmpty { cache[key] = set }
        return set
    }

    static func assemble(
        _ intent: TradeIntent, _ outcomes: [Outcome],
        active: [TradeProvider], failures initial: [TradeProvider: TradeProviderError], costs: TradeCostModel, isFinal: Bool
    ) -> TradeQuoteSet {
        var failures = initial
        var valid = [ValidatedTradeQuote]()
        for (provider, result) in outcomes {
            switch result {
            case .success(let quote): valid.append(quote)
            case .failure(let error): failures[provider] = error
            }
        }
        let answered = Set(outcomes.map(\.0))
        let pending = active.filter { !answered.contains($0) }
        if isFinal { for provider in pending { failures[provider] = .timedOut(provider) } }
        return TradeQuoteSet(intent: intent, ranked: TradeRanking.rank(valid, costs: costs), failures: failures,
                             pending: pending, fetchedAt: Date(), isFinal: isFinal)
    }

    /// Recota um provedor so: a escolhida do dono ou a perna de uma divisao, na hora de
    /// planejar. Aqui nao ha disputa para esperar, entao o prazo e o de uma cotacao
    /// (docs/seguranca.md 5.1), e nao o prazo duro da rodada.
    public static let requoteDeadline: Duration = .seconds(10)

    public func requote(_ provider: TradeProvider, intent: TradeIntent, market: TradeMarketReference = .none,
                        gasPriceWei: BigUInt, deadline: Duration = TradeAggregator.requoteDeadline) async throws -> ValidatedTradeQuote {
        guard let source = sources.first(where: { $0.provider == provider }) else { throw TradeProviderError.unsupported(provider) }
        let outcomes = await Self.fanOut([source], request: TradeQuoteRequest(intent: intent, gasPriceWei: gasPriceWei), market: market,
                                         soft: deadline, hard: deadline, waitForAll: true, onProgress: nil)
        guard let (_, result) = outcomes.first else { throw TradeProviderError.timedOut(provider) }
        return try result.get()
    }

    /// A entrada do circuit breaker: o nome e o do provedor, a URL e a de Endpoints.trade.
    /// Todo provedor tem entrada; o teste "cada provedor tem endereco" confere.
    static func poolEntry(_ provider: TradeProvider) -> ProviderPool.Provider {
        guard let entry = Endpoints.trade[provider.rawValue] else {
            preconditionFailure("provedor de troca sem entrada em Endpoints.trade: \(provider.rawValue)")
        }
        return entry
    }

    static func cacheKey(_ intent: TradeIntent, _ providers: Set<TradeProvider>?) -> String {
        [intent.chain.id, "\(intent.sell)", "\(intent.buy)", intent.amountIn.decimalString, "\(intent.slippageBps)",
         intent.owner.checksummed, providers.map { $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "*"].joined(separator: "|")
    }

    typealias Outcome = (TradeProvider, Result<ValidatedTradeQuote, TradeProviderError>)
    typealias Progress = @Sendable ([Outcome]) -> Void

    private enum Event: Sendable {
        case result(TradeProvider, Result<ValidatedTradeQuote, TradeProviderError>)
        case soft
        case hard
    }

    /// Pergunta e valida em paralelo, respeitando os dois prazos. Com `waitForAll`, so
    /// para quando todos responderam ou no prazo duro, e avisa `onProgress` a partir do
    /// prazo mole; sem, devolve no prazo mole se ja houver cotacao valida.
    static func fanOut(
        _ sources: [any TradeQuoteSource], request: TradeQuoteRequest, market: TradeMarketReference,
        soft: Duration, hard: Duration, waitForAll: Bool,
        onProgress: Progress?
    ) async -> [Outcome] {
        guard !sources.isEmpty else { return [] }
        return await withTaskGroup(of: Event.self) { group in
            for source in sources {
                group.addTask { .result(source.provider, await fetch(source, request: request, market: market)) }
            }
            group.addTask { try? await Task.sleep(for: soft); return .soft }
            group.addTask { try? await Task.sleep(for: hard); return .hard }

            var results = [Outcome]()
            var softPassed = false
            func hasValid() -> Bool {
                results.contains { if case .success = $0.1 { return true } else { return false } }
            }
            for await event in group {
                switch event {
                case .result(let provider, let result):
                    results.append((provider, result))
                    if results.count == sources.count {
                        group.cancelAll()
                        return results
                    }
                    if softPassed, hasValid() {
                        if !waitForAll { group.cancelAll(); return results }
                        onProgress?(results)
                    }
                case .soft:
                    softPassed = true
                    if hasValid() {
                        if !waitForAll { group.cancelAll(); return results }
                        onProgress?(results)
                    }
                case .hard:
                    group.cancelAll()
                    return results
                }
            }
            return results
        }
    }

    static func fetch(_ source: any TradeQuoteSource, request: TradeQuoteRequest, market: TradeMarketReference) async -> Result<ValidatedTradeQuote, TradeProviderError> {
        do {
            let proposal = try await source.propose(request)
            guard proposal.provider == source.provider else { return .failure(.badResponse(source.provider, "provedor")) }
            return .success(try TradeValidator.validate(proposal, intent: request.intent, market: market))
        } catch let error as TradeProviderError {
            return .failure(error)
        } catch let refusal as TradeRefusal {
            return .failure(.refused(source.provider, refusal))
        } catch let failure as HTTPClient.Failure {
            return .failure(.http(source.provider, failure))
        } catch is CancellationError {
            return .failure(.timedOut(source.provider))
        } catch {
            return .failure(.badResponse(source.provider, String(describing: type(of: error))))
        }
    }

    // MARK: Divisao

    /// Quando a melhor cotacao unica tem impacto acima de ~30 bps: cota os 3 melhores
    /// provedores de rota conhecida em 25, 50 e 75% (o 100% ja existe), monta as curvas e
    /// roda o DP. `minimumGainAbsolute` e US$ 5 em unidades do token comprado.
    /// Devolve o plano de varias etapas, ou `nil` se dividir nao compensa.
    public func proposeSplit(
        _ set: TradeQuoteSet, market: TradeMarketReference = .none, costs: TradeCostModel,
        minimumGainAbsolute: BigUInt, force: Bool = false
    ) async -> TradeSplitPlan? {
        guard let best = set.best, force || TradeSplitOptimizer.shouldConsider(best) else { return nil }
        // Rota opaca nunca divide, entao nem vale gastar cota com ela.
        let candidates = Array(set.ranked.filter { $0.quote.routeSources != nil }.prefix(TradeSplitOptimizer.maxProviders))
        guard candidates.count >= 2 else { return nil }
        let intent = set.intent
        let shares = TradeSplitOptimizer.sampleShares.filter { $0 < 10_000 }

        var curves = [TradeSplitCurve]()
        await withTaskGroup(of: (TradeProvider, Int, ValidatedTradeQuote?).self) { group in
            for candidate in candidates {
                guard let source = sources.first(where: { $0.provider == candidate.quote.provider }) else { continue }
                for share in shares {
                    guard let partial = try? intent.withAmount(intent.amountIn * BigUInt(share) / BigUInt(10_000)) else { continue }
                    let request = TradeQuoteRequest(intent: partial, gasPriceWei: costs.gasPriceWei)
                    group.addTask {
                        let outcome = await Self.fanOut([source], request: request, market: .none, soft: Self.hardDeadline,
                                                        hard: Self.hardDeadline, waitForAll: true, onProgress: nil)
                        return (source.provider, share, try? outcome.first?.1.get())
                    }
                }
            }
            var points = [TradeProvider: [TradeSplitCurve.Point]]()
            var routeSources = [TradeProvider: Set<String>]()
            for await (provider, share, quote) in group {
                guard let quote else { continue }
                points[provider, default: []].append(.init(shareBps: share, out: quote.guaranteedOut))
                routeSources[provider, default: []].formUnion(quote.routeSources ?? [])
            }
            for candidate in candidates {
                let provider = candidate.quote.provider
                // Curva incompleta (uma fracao falhou) fica de fora: interpolar por cima de
                // um buraco inventaria liquidez.
                guard let measured = points[provider], measured.count == shares.count,
                      let sources = candidate.quote.routeSources
                else { continue }
                curves.append(TradeSplitCurve(
                    provider: provider, points: measured + [.init(shareBps: 10_000, out: candidate.quote.guaranteedOut)],
                    fixedCost: candidate.costInBuy, routeSources: sources.union(routeSources[provider] ?? [])
                ))
            }
        }
        let decision = TradeSplitOptimizer.optimize(curves: curves, amountIn: intent.amountIn, minimumGainAbsolute: minimumGainAbsolute)
        return decision.accepted ? try? TradeSplitPlan(intent: intent, decision: decision) : nil
    }
}
