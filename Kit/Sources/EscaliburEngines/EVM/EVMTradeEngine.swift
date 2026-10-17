import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Troca e ordem limite numa rede EVM.
///
/// - **Cotacao**: rodada completa do `TradeAggregator` (Velora, KyberSwap, LI.FI, De¹),
///   cada calldata validada contra a intencao, ranking pelo liquido do garantido, e
///   proposta de divisao entre provedores quando o impacto passa de ~30 bps. Uma divisao
///   so fica se, recotada perna a perna, ainda ganha da melhor cotacao unica.
/// - **Plano**: cada perna e recotada no provedor escolhido e validada de novo; o estado
///   (nonce e baseFee de duas fontes, saldo e allowance, codigo e pin do router, e a
///   simulacao `eth_simulateV1` em duas fontes) vem do `TradeStateReader`; o
///   `TradePlanner` monta a autorizacao exata, quando falta, e a troca.
/// - **Envio**: os bytes assinados, conferidos contra o plano, saem em ordem de nonce. Na
///   Ethereum, pelos relays com protecao de MEV; nas outras redes, pela rota publica.
/// - **Ordem limite**: pela CoW, com autorizacao exata ao VaultRelayer e a ordem assinada
///   em EIP-712. A ordem so vai para a CoW depois que a autorizacao confirma.
///
/// Sem taxa da Escalibur: a tabela de taxas compilada e zero em todo provedor e rede, e o
/// validador recusa calldata com qualquer outra taxa de integrador.
public struct EVMTradeEngine: TradeEngine {
    public let chain: Chain
    let services: EVMTradeServices

    /// `nil` onde a troca nao tem as duas fontes de simulacao que a validacao exige
    /// (docs/seguranca.md 4.9) ou nenhum router na allowlist. Hoje: Avalanche (nenhum RPC
    /// publico implementa `eth_simulateV1` la), X Layer e Celo (Endpoints.tradeSimulation
    /// diz por que).
    public init?(chain: Chain) {
        self.init(chain: chain, services: .live)
    }

    init?(chain: Chain, services: EVMTradeServices) {
        guard EVMEngineSupport.isSupported(chain), (Endpoints.tradeSimulation[chain.id]?.count ?? 0) >= 2,
              !TradeAllowlist.routers(on: chain).isEmpty
        else { return nil }
        self.chain = chain
        self.services = services
    }

    /// A CoW atende Ethereum, Arbitrum, Base, Polygon, BNB Chain, Plasma e Linea entre as
    /// redes com troca.
    public var supportsLimitOrders: Bool { CoWProtocol.supports(chain) }

    public var limitCustodyNote: String {
        guard supportsLimitOrders else { return kitText("Ordens limite ainda não estão disponíveis na \(chain.name).") }
        return kitText("O valor fica na sua carteira até a ordem executar. Para cancelar, toque nela em Ordens abertas, logo abaixo: a carteira envia uma transação que invalida a ordem de vez, com a taxa da rede.")
    }

    // MARK: Cotacao

    public func quote(_ request: TradeRequest) async throws -> TradeQuote {
        do {
            return try await makeQuote(request)
        } catch {
            throw EVMEngineMessages.userFacing(error, .quote, chain: chain)
        }
    }

    func makeQuote(_ request: TradeRequest) async throws -> TradeQuote {
        let context = try EVMTradeContext(request, chain: chain)
        let market = try await EVMTradeMarket.read(context, services: services)
        async let cowRound = cowCandidate(context, market: market)
        let set = await services.aggregator.quote(context.intent, market: market.reference, costs: market.costs)
        let cow = await cowRound

        // Os agregadores: a melhor cotacao ancorada, ou a divisao entre eles.
        var single: (quote: TradeQuote, net: TradeSignedAmount, ranked: [TradeCandidate])?
        var failure: Error = Self.emptyRound(set.failures)
        if !set.ranked.isEmpty {
            do {
                single = try await aggregatorQuote(set, context: context, market: market, request: request)
            } catch {
                failure = error
            }
        }

        // A CoW leva quando garante mais, liquido, que a melhor dos agregadores.
        let anchoredCoW = cow.flatMap { Self.cowAnchored($0, aggregatorExpected: set.ranked.map(\.quote.expectedOut)) ? $0 : nil }
        if let cow = anchoredCoW, single.map({ cow.net > $0.net }) ?? true {
            let ranked = single?.ranked ?? TradeRanking.rank(set.ranked.map(\.quote), costs: market.costs)
            return Self.cowQuote(request, candidate: cow, ranked: ranked)
        }
        guard let single else { throw failure }
        // A CoW perdeu a troca de uma vez, mas a troca em partes dela continua como opcao
        // quando garante mais que a escolhida.
        return single.quote.adding(cow: anchoredCoW)
    }

    /// A melhor troca pelos agregadores, com o liquido do garantido e o ranking.
    func aggregatorQuote(
        _ set: TradeQuoteSet, context: EVMTradeContext, market: EVMTradeMarket, request: TradeRequest
    ) async throws -> (quote: TradeQuote, net: TradeSignedAmount, ranked: [TradeCandidate]) {
        // O minimo ancorado fora do provedor: preco de referencia, ou duas cotacoes e a maior
        // estimativa entre elas. Todas aparecem como alternativa; so as ancoradas podem ser
        // a escolhida.
        let eligible = Set(try TradeValidator.anchored(set.ranked.map(\.quote), market: market.reference).map(\.provider))

        // A autorizacao que ja existe barateia a troca: le a allowance dos spenders que
        // disputam o topo e ranqueia de novo com ela.
        let allowances = await allowances(for: Array(set.ranked.prefix(TradeSplitOptimizer.maxProviders)), context: context)
        let costs = market.costs.with(allowances: allowances)
        let ranked = TradeRanking.rank(set.ranked.map(\.quote), costs: costs)
        guard let best = ranked.first(where: { eligible.contains($0.quote.provider) }) else { throw EVMEngineFailure.noQuote }

        var legs = [EVMTradeLeg(quote: best.quote, shareBps: 10_000)]
        if let gain = market.minimumSplitGain, TradeSplitOptimizer.shouldConsider(best),
           let split = await services.aggregator.proposeSplit(set, market: market.reference, costs: market.costs, minimumGainAbsolute: gain),
           let resolved = await resolve(split, against: best, market: market, costs: costs) {
            legs = resolved
        }
        let quote = EVMTradeQuoteMapping.quote(
            sell: request.sell, buy: request.buy, amountIn: request.amountIn, legs: legs, ranked: ranked, allowances: allowances
        )
        var guaranteed = BigUInt()
        var cost = BigUInt()
        for leg in legs {
            guaranteed = guaranteed + leg.quote.guaranteedOut
            cost = cost + TradeRanking.cost(of: leg.quote, costs: costs).inBuy
        }
        return (quote, .difference(guaranteed, cost), ranked)
    }

    /// Nenhuma cotacao valida: se houve resposta e todas foram recusadas pela validacao, a
    /// tela diz isso; senao, que ninguem cotou.
    static func emptyRound(_ failures: [TradeProvider: TradeProviderError]) -> EVMEngineFailure {
        let answered = failures.values.filter { if case .unsupported = $0 { return false } else { return true } }
        let refused = answered.filter { if case .refused = $0 { return true } else { return false } }
        return !answered.isEmpty && refused.count == answered.count ? .allQuotesRefused : .noQuote
    }

    /// `allowance(dono, spender)` de cada spender, para o ranking e para dizer se falta
    /// autorizar. So exibicao: o plano le de novo, com duas fontes. Leitura que falha conta
    /// como zero, o que so pode fazer a tela pedir uma autorizacao a mais.
    func allowances(for candidates: [TradeCandidate], context: EVMTradeContext) async -> [EVMAddress: BigUInt] {
        guard case .token(let token) = context.sell else { return [:] }
        let spenders = Set(candidates.map(\.quote.spender))
        let chainState = services.chainState
        let chain = self.chain
        let owner = context.account.address
        return await withTaskGroup(of: (EVMAddress, BigUInt?).self) { group in
            for spender in spenders {
                group.addTask {
                    (spender, try? await chainState.token(chain: chain, token: token.contract, owner: owner, spender: spender).allowance)
                }
            }
            var found = [EVMAddress: BigUInt]()
            for await (spender, allowance) in group {
                if let allowance { found[spender] = allowance }
            }
            return found
        }
    }

    /// Recota cada perna da divisao no valor exato. A divisao so fica se todas as pernas
    /// recotam e o liquido somado ainda ganha da melhor cotacao unica pelo minimo exigido
    /// (max(10 bps, US$ 5)); senao, vale a cotacao unica.
    func resolve(_ split: TradeSplitPlan, against single: TradeCandidate, market: EVMTradeMarket, costs: TradeCostModel) async -> [EVMTradeLeg]? {
        let aggregator = services.aggregator
        let legs = split.decision.legs
        let requoted = await withTaskGroup(of: (Int, ValidatedTradeQuote?).self) { group in
            for index in legs.indices {
                group.addTask {
                    guard let intent = try? split.legIntent(index) else { return (index, nil) }
                    let reference = market.reference.portion(intent.amountIn, of: split.intent.amountIn)
                    let quote = try? await aggregator.requote(legs[index].provider, intent: intent, market: reference, gasPriceWei: market.gasPriceWei)
                    return (index, quote)
                }
            }
            var found = [Int: ValidatedTradeQuote]()
            for await (index, quote) in group {
                if let quote { found[index] = quote }
            }
            return found
        }
        guard requoted.count == legs.count, let singleNet = single.netOut.nonNegative else { return nil }
        var guaranteed = BigUInt()
        var cost = BigUInt()
        var chosen = [EVMTradeLeg]()
        for (index, leg) in legs.enumerated() {
            guard let quote = requoted[index] else { return nil }
            guaranteed = guaranteed + quote.guaranteedOut
            cost = cost + TradeRanking.cost(of: quote, costs: costs).inBuy
            chosen.append(EVMTradeLeg(quote: quote, shareBps: leg.shareBps))
        }
        guard let net = guaranteed.subtractingReportingUnderflow(cost), net >= singleNet + split.decision.requiredGain else { return nil }
        return chosen
    }

    // MARK: Plano

    public func plan(_ request: TradeRequest, quote: TradeQuote) async throws -> SigningPlan {
        do {
            return try await makePlan(request, quote: quote)
        } catch {
            throw EVMEngineMessages.userFacing(error, .tradePlan, chain: chain)
        }
    }

    func makePlan(_ request: TradeRequest, quote: TradeQuote) async throws -> SigningPlan {
        try await checkUnlistedDecimals([request.sell, request.buy])
        if request.inParts || quote.execution == .order { return try await makeCoWSwapPlan(request, quote: quote) }
        let context = try EVMTradeContext(request, chain: chain)
        let intent = context.intent
        guard quote.sell == request.sell, quote.buy == request.buy, quote.amountIn == request.amountIn else {
            throw EVMEngineFailure.quoteMismatch
        }
        guard quote.expiresAt > .now else { throw EVMEngineFailure.quoteExpired }
        let legs = try Self.legs(of: quote, total: intent.amountIn)

        // Impacto: acima do degrau de bloqueio nao ha plano. No degrau de confirmacao, a
        // tela so chega aqui depois do "sim" do dono para a cotacao que mostrou; se a
        // recotacao passar a exigir confirmacao sem a tela ter mostrado, o plano recusa.
        let level = PriceImpact.level(quote.priceImpactPercent)
        guard level != .blocked else { throw EVMEngineFailure.riskIncreased }
        let riskConfirmed = level == .confirm

        // Recotacao de cada perna no provedor escolhido, validada de novo pelo agregador.
        let market = try await EVMTradeMarket.read(context, services: services)
        do {
            return try await planLegs(legs, request: request, quote: quote, context: context, market: market, riskConfirmed: riskConfirmed)
        } catch let refusal as TradeRefusal where legs.count == 1 && Self.failedInSimulation(refusal) {
            // O provedor escolhido montou uma troca que a simulacao recusou (a De¹ na Base, que
            // promete e nao entrega, visto ao vivo em 17/10/2026). Em vez de parar no erro, as
            // alternativas da mesma rodada, na ordem: cada uma recotada, validada, simulada em
            // duas fontes e presa ao minimo que a tela mostrou. A revisao diz qual executa.
            await services.aggregator.reportFailure(legs[0].provider)
            for alternative in quote.alternatives {
                guard let provider = EVMTradeQuoteMapping.provider(named: alternative.provider), provider != legs[0].provider else { continue }
                if let plan = try? await planLegs([(provider, legs[0].amountIn, 10_000)], request: request, quote: quote, context: context,
                                                  market: market, riskConfirmed: riskConfirmed) {
                    return TradePlanner.rerouted(plan, .simulationFailed(legs[0].provider), to: provider)
                }
            }
            throw refusal
        } catch let failure as EVMSplitSequenceFailure {
            // A divisao nao se sustenta em sequencia (a segunda perna, depois da primeira,
            // receberia menos que o garantido dela). Vale a troca inteira por um provedor so,
            // na ordem do ranking: recotada, validada, simulada e presa ao minimo que a tela
            // mostrou, menos a tolerancia. A revisao diz qual executa.
            for alternative in quote.alternatives {
                guard let provider = EVMTradeQuoteMapping.provider(named: alternative.provider) else { continue }
                if let plan = try? await planLegs([(provider, intent.amountIn, 10_000)], request: request, quote: quote, context: context,
                                                  market: market, riskConfirmed: riskConfirmed) {
                    return TradePlanner.rerouted(plan, .splitInterfered(legs.map(\.provider)), to: provider)
                }
            }
            throw failure.refusal
        }
    }

    /// A divisao que falhou na simulacao em sequencia, com a recusa da perna.
    struct EVMSplitSequenceFailure: Error {
        let refusal: TradeRefusal
    }

    /// A recusa e da simulacao (a troca montada nao faria o que diz), nao da falta dela.
    static func failedInSimulation(_ refusal: TradeRefusal) -> Bool {
        switch refusal {
        case .simulationFailed, .simulationShape, .simulationSpentTooMuch, .simulationReceivedTooLittle,
             .simulationUnexpectedTransfer, .simulationUnexpectedApproval:
            return true
        default:
            return false
        }
    }

    /// Recota e planeja as pernas: o garantido novo preso ao que a tela mostrou, e uma perna
    /// depois da outra.
    func planLegs(
        _ legs: [(provider: TradeProvider, amountIn: BigUInt, shareBps: Int)], request: TradeRequest, quote: TradeQuote,
        context: EVMTradeContext, market: EVMTradeMarket, riskConfirmed: Bool
    ) async throws -> SigningPlan {
        let intent = context.intent
        let requoted = try await requote(legs, intent: intent, market: market)

        // O garantido novo nao pode ter caido abaixo do que a tela mostrou por mais que a
        // tolerancia do dono: isso seria outra troca, nao a que ele revisou. Sem preco de
        // referencia agora, a recotacao de um provedor so nao tem ancora de fora: o
        // garantido tem de ser pelo menos o minimo que a tela mostrou, ancorado na rodada.
        let guaranteed = requoted.reduce(BigUInt()) { $0 + $1.quote.guaranteedOut }
        let floor = market.reference.oracleOut == nil ? quote.minimumOut : intent.minimumOut(forExpected: quote.minimumOut)
        guard guaranteed >= floor else { throw EVMEngineFailure.priceMoved }

        // Uma perna depois da outra: nonce, saldo nativo e saldo do token vendido seguem de
        // uma para a proxima, porque todas vao ser assinadas agora e executadas em sequencia.
        // Cada plano leva o instante em que foi montado, depois da recotacao e da leitura:
        // o prazo de 60 s conta dali, e a cotacao recem-validada nunca parece "do futuro".
        // O nonce de cada perna: a fila local do app e, depois da primeira, as transacoes
        // das pernas anteriores, que entram na conta como em transito.
        var plans = [SigningPlan]()
        var nextNonce: UInt64?
        var plannedAhead: UInt64 = 0
        var spentNative = BigUInt()
        var spentSell = BigUInt()
        var simulationLegs = [TradeSimulationLeg]()
        for (index, leg) in requoted.enumerated() {
            let fetched = try await services.chainState.read(for: leg.quote, localNextNonce: nextNonce ?? request.nonceQueue?.nextNonce)
            simulationLegs.append(TradeSimulationLeg(
                quote: leg.quote,
                request: TradePlanner.simulationRequest(for: leg.quote, currentAllowance: fetched.sellToken?.allowance, permit2: fetched.permit2)
            ))
            let read = fetched.replacingNetwork(fetched.network.applying(request.nonceQueue, plannedNext: nextNonce, plannedAhead: plannedAhead))
            let state = Self.remaining(read, spentNative: spentNative, spentSell: spentSell)
            let step = requoted.count > 1 ? TradeSplitStep(index: index, count: requoted.count, shareBps: leg.shareBps) : nil
            let plan = try TradePlanner.planSwap(
                walletID: request.walletID, account: context.account, quote: leg.quote, state: state,
                riskConfirmed: riskConfirmed, split: step
            )
            let transactions = plan.transactions.compactMap { $0 as? EVMTransaction }
            guard transactions.count == plan.transactions.count, let last = transactions.last else { throw EVMEngineFailure.batchMismatch }
            nextNonce = last.nonce + 1
            plannedAhead += UInt64(transactions.count)
            spentNative = spentNative + Self.maximumNativeCost(transactions, state: state)
            if !intent.sell.isNative { spentSell = spentSell + leg.quote.intent.amountIn }
            plans.append(plan)
        }
        let warning: [PlanReview.Warning] = Self.sandwichExposed(chain) ? [.publicMempool] : []
        guard plans.count > 1 else { return plans[0].addingWarnings(warning) }

        // Cada perna passou pela simulacao sozinha; agora todas em sequencia, num bloco so,
        // como vao executar (`TradeSimulationSequence`). Uma perna que nao se sustenta depois
        // das anteriores derruba a divisao.
        do {
            let simulations = try await services.chainState.simulateSequence(simulationLegs)
            try TradeSimulationSequence.verify(simulations, legs: simulationLegs)
        } catch let refusal as TradeRefusal where Self.failedInSimulation(refusal) {
            throw EVMSplitSequenceFailure(refusal: refusal)
        }
        // A revisao da divisao e escrita pelo compositor de EscaliburChains, a partir das
        // pernas e das cotacoes validadas; o motor nao escreve titulo nem linha.
        return try TradePlanner.combineSplit(plans, quotes: requoted.map(\.quote)).addingWarnings(warning)
    }

    /// Token fora da lista (o que a carteira tem, ou a moeda adicionada): as casas que a
    /// tela usou para o valor tem de ser as da rede agora, em dois provedores. O minimo
    /// garantido e em unidades cruas e nao depende delas; o valor digitado e o que a tela
    /// mostra, sim.
    func checkUnlistedDecimals(_ assets: [Asset]) async throws {
        for asset in assets where asset.origin != nil {
            guard case .token(let contract) = asset.kind, let address = try? EVMAddress(contract) else { continue }
            let onChain = try await services.reader.tokenDecimals(chain: chain, contract: address)
            guard onChain == asset.decimals else { throw EVMEngineFailure.unlistedDecimalsChanged }
        }
    }

    /// As pernas da cotacao mostrada: provedor conhecido, sem repeticao, valores que
    /// somam exatamente o total.
    static func legs(of quote: TradeQuote, total: BigUInt) throws -> [(provider: TradeProvider, amountIn: BigUInt, shareBps: Int)] {
        guard !quote.legs.isEmpty, quote.legs.count <= TradeSplitOptimizer.maxProviders else { throw EVMEngineFailure.quoteMismatch }
        var out = [(provider: TradeProvider, amountIn: BigUInt, shareBps: Int)]()
        var sum = BigUInt()
        for leg in quote.legs {
            guard let provider = EVMTradeQuoteMapping.provider(named: leg.provider), !leg.amountIn.isZero,
                  !out.contains(where: { $0.provider == provider }) else { throw EVMEngineFailure.quoteMismatch }
            sum = sum + leg.amountIn
            let share = (leg.amountIn * BigUInt(10_000) / total).uint64.map(Int.init) ?? 0
            out.append((provider, leg.amountIn, share))
        }
        guard sum == total else { throw EVMEngineFailure.quoteMismatch }
        return out
    }

    func requote(
        _ legs: [(provider: TradeProvider, amountIn: BigUInt, shareBps: Int)], intent: TradeIntent, market: EVMTradeMarket
    ) async throws -> [EVMTradeLeg] {
        let aggregator = services.aggregator
        return try await withThrowingTaskGroup(of: (Int, ValidatedTradeQuote).self) { group in
            for (index, leg) in legs.enumerated() {
                let legIntent = legs.count == 1 ? intent : try intent.withAmount(leg.amountIn)
                group.addTask {
                    (index, try await aggregator.requote(leg.provider, intent: legIntent, market: market.reference.portion(leg.amountIn, of: intent.amountIn),
                                                         gasPriceWei: market.gasPriceWei))
                }
            }
            var found = [Int: ValidatedTradeQuote]()
            for try await (index, quote) in group { found[index] = quote }
            return try legs.indices.map { index in
                guard let quote = found[index] else { throw EVMEngineFailure.quoteMismatch }
                return EVMTradeLeg(quote: quote, shareBps: legs[index].shareBps)
            }
        }
    }

    /// O estado de uma perna com o que as pernas anteriores ja comprometem: o saldo nativo
    /// menos a taxa maxima e o valor delas, e o saldo do token vendido menos o que elas
    /// vendem. O planejador recusa se o que sobra nao cobre esta perna.
    static func remaining(_ state: TradeChainState, spentNative: BigUInt, spentSell: BigUInt) -> TradeChainState {
        guard !spentNative.isZero || !spentSell.isZero else { return state }
        let network = state.network
        let adjusted = EVMNetworkState(
            chain: network.chain, pendingNonces: network.pendingNonces, localNextNonce: network.localNextNonce,
            localPendingCount: network.localPendingCount, baseFeePerGas: network.baseFeePerGas, priorityFees: network.priorityFees, gasEstimate: network.gasEstimate,
            l1DataFee: network.l1DataFee, nativeBalance: network.nativeBalance.subtractingReportingUnderflow(spentNative) ?? 0,
            destinationHasCode: network.destinationHasCode
        )
        let token = state.sellToken.map {
            EVMTokenState(contractHasCode: $0.contractHasCode, balance: $0.balance.subtractingReportingUnderflow(spentSell) ?? 0, allowance: $0.allowance)
        }
        return TradeChainState(
            network: adjusted, sellToken: token, routerHasCode: state.routerHasCode, routerPin: state.routerPin,
            simulations: state.simulations, approveL1DataFee: state.approveL1DataFee, swapL1DataFee: state.swapL1DataFee,
            approveL1Gas: state.approveL1Gas, swapL1Gas: state.swapL1Gas,
            permit2: state.permit2, permit2L1DataFee: state.permit2L1DataFee, permit2L1Gas: state.permit2L1Gas
        )
    }

    /// O maximo que as transacoes de uma perna tiram do saldo nativo: gas maximo, valor e
    /// taxa L1 de cada uma (a autorizacao antes, a troca por ultimo).
    static func maximumNativeCost(_ transactions: [EVMTransaction], state: TradeChainState) -> BigUInt {
        var total = BigUInt()
        for (index, transaction) in transactions.enumerated() {
            let l1 = index == transactions.count - 1 ? state.swapL1DataFee
                : (transaction.to == EIP712ValidatedMessage.permit2 ? state.permit2L1DataFee : state.approveL1DataFee)
            total = total + transaction.maxExecutionCost + transaction.value + (l1 ?? 0)
        }
        return total
    }

    // MARK: Ordem limite

    public func planLimitOrder(_ request: LimitOrderRequest) async throws -> SigningPlan {
        do {
            return try await makeLimitOrder(request).signingPlan
        } catch {
            throw EVMEngineMessages.userFacing(error, .limitOrder, chain: chain)
        }
    }

    func makeLimitOrder(_ request: LimitOrderRequest) async throws -> CoWLimitOrderPlan {
        guard request.chain.id == chain.id else { throw EVMEngineFailure.wrongChain }
        guard supportsLimitOrders else { throw EVMEngineFailure.limitOrdersUnavailable }
        let account = try EVMEngineSupport.account(request.account, chain: chain)
        let sell = try EVMEngineSupport.resolve(request.sell, on: chain, allowUnlisted: true).tradeAsset(on: chain)
        let buy = try EVMEngineSupport.resolve(request.buy, on: chain, allowUnlisted: true).tradeAsset(on: chain)
        try await checkUnlistedDecimals([request.sell, request.buy])
        guard !request.minimumOut.isZero else { throw CoWRefusal.zeroBuyAmount }
        guard !request.amountIn.isZero else { throw TradeRefusal.zeroAmount }

        // O minimo que o dono calculou vai direto na ordem assinada: ela recebe exatamente
        // esse minimo, nem um wei a menos, por menor que seja o preco.
        // Sem prazo pedido ("ate cancelar"): a CoW exige um, e vale o maximo pratico dela.
        let intent = try CoWLimitOrderIntent(owner: account.address, sell: sell, buy: buy, sellAmount: request.amountIn,
                                             buyAmount: request.minimumOut, validFor: request.validFor ?? CoWProtocol.untilCancelledValidity)
        guard intent.buyAmount == request.minimumOut, let sellToken = intent.orderSellToken else {
            throw EVMEngineFailure.limitPriceNotRepresentable
        }

        // Varias ordens abertas para o mesmo token (pedido do dono, 14/10/2026): a
        // autorizacao ao VaultRelayer fica exatamente na soma delas, a soma tem de caber no
        // saldo, e a revisao diz que ha outras ordens e o total autorizado. Assinar essa
        // revisao e o "sim" do dono (docs/seguranca.md 4.5). A lista vem so da API da CoW
        // (o livro nao esta na cadeia); o teto na cadeia e a autorizacao (auditoria 2, B4).
        let open = try await services.cow.openSellTotal(owner: account.address, sellToken: sellToken.contract, chain: chain)

        let read = try await services.chainState.readCoW(intent: intent, openOrdersSellTotal: open, localNextNonce: request.nonceQueue?.nextNonce)
        let state = CoWChainState(
            network: read.network.applying(request.nonceQueue), sellToken: read.sellToken, wrapGasEstimate: read.wrapGasEstimate,
            wrapL1DataFee: read.wrapL1DataFee, openOrdersSellTotal: read.openOrdersSellTotal
        )
        // O prazo do plano e o validTo da ordem contam de agora, depois das leituras.
        let now = Date()
        let plan = try CoWPlanner.planLimitOrder(walletID: request.walletID, account: account, intent: intent, state: state,
                                                 stackingConfirmed: true, now: now)
        await services.pendingOrders.store(plan, now: now)
        return plan
    }

    // MARK: Envio

    /// Troca: devolve os ids das transacoes, calculados aqui, em ordem de nonce. Ordem
    /// limite: devolve o UID da ordem, conferido contra o calculado no plano.
    public func submit(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String] {
        do {
            guard plan.chain.id == chain.id else { throw EVMEngineFailure.wrongChain }
            switch plan.review.kind {
            case .swap:
                // A troca pela CoW e uma ordem assinada: vai como a ordem limite.
                if plan.transactions.last is EIP712ValidatedMessage { return [try await submitLimitOrder(signed, plan: plan)] }
                return try await submitSwap(signed, plan: plan)
            case .limitOrder: return [try await submitLimitOrder(signed, plan: plan)]
            case .cancelOrder: return try await submitCancellation(signed, plan: plan)
            default: throw EVMEngineFailure.batchMismatch
            }
        } catch {
            throw EVMEngineMessages.userFacing(error, .submit, chain: chain)
        }
    }

    /// Redes onde a troca vai para uma fila que robos leem antes do bloco. Na Ethereum ela
    /// vai direto aos construtores (`mevProtected`); nas L2 de sequenciador unico (Arbitrum,
    /// Base, Optimism, Unichain, Linea, e Celo e X Layer desde que passaram ao OP Stack)
    /// nao ha fila publica para ler. Nas demais, a revisao diz que nao ha protecao
    /// (auditoria 4, M2). A CoW, ordem em leilao, nao passa por aqui.
    static let privateOrderflowChainIDs: Set<UInt64> = [1, 42161, 8453, 10, 130, 59144, 42220, 196]

    static func sandwichExposed(_ chain: Chain) -> Bool {
        guard let id = chain.evmChainID else { return false }
        return !privateOrderflowChainIDs.contains(id)
    }

    func submitSwap(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String] {
        let transactions = plan.transactions.compactMap { $0 as? EVMTransaction }
        guard transactions.count == plan.transactions.count else { throw EVMEngineFailure.batchMismatch }
        let ordered = try EVMEngineSupport.pairs(signed, transactions)
        // Na Ethereum a troca vai direto aos construtores de bloco: no mempool publico um
        // robo veria a ordem e faria sanduiche dentro da tolerancia (docs/seguranca.md 4.3).
        let route: EVMBroadcastRoute = chain.evmChainID == 1 ? .mevProtected : .publicMempool
        return try await EVMEngineSupport.broadcast(ordered, chain: chain, route: route, reader: services.reader)
    }

    /// Transmite a autorizacao (e o embrulho do nativo), espera confirmar, registra o
    /// appData e envia a ordem assinada. A CoW recusa ordem sem saldo e allowance.
    func submitLimitOrder(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> String {
        guard let order = await services.pendingOrders.take(plan.id) else { throw EVMEngineFailure.pendingOrderMissing }
        guard order.signingPlan.transactions.count == plan.transactions.count, signed.count == plan.transactions.count,
              plan.transactions.last is EIP712ValidatedMessage, let signature = signed.last
        else { throw EVMEngineFailure.batchMismatch }
        let prerequisites = plan.transactions.dropLast().compactMap { $0 as? EVMTransaction }
        guard prerequisites.count == order.prerequisiteCount else { throw EVMEngineFailure.batchMismatch }
        if !prerequisites.isEmpty {
            let ordered = try EVMEngineSupport.pairs(Array(signed.dropLast()), prerequisites)
            let ids = try await EVMEngineSupport.broadcast(ordered, chain: chain, route: .publicMempool, reader: services.reader)
            for id in ids { try await waitForConfirmation(id) }
        }
        try await services.cow.registerAppData(order.appData, chain: chain)
        let uid = try await services.cow.submit(order, signature: signature)
        guard uid == order.uid else { throw CoWClientError.uidMismatch }
        return Hex.encode(uid, prefix: true)
    }

    func waitForConfirmation(_ id: String) async throws {
        let policy = services.confirmation
        for attempt in 0..<policy.attempts {
            if attempt > 0 { try await Task.sleep(for: policy.interval) }
            switch try? await services.reader.status(of: id, chain: chain) {
            case .confirmed?: return
            case .failed?: throw EVMEngineFailure.prerequisiteFailed
            case .pending?, .notFound?, nil: continue
            }
        }
        throw EVMEngineFailure.prerequisiteTimedOut
    }

    // MARK: Ordens abertas

    /// As ordens abertas do dono na CoW, a unica fonte do livro de ordens: cada uma com o
    /// UID conferido, o que falta vender e o minimo pelo preco gravado. Cancela pela CoW
    /// (gratis, sem garantia) ou na cadeia (garantido, com taxa).
    public func openOrders(account: DerivedAccount) async throws -> [OpenOrder] {
        do {
            guard supportsLimitOrders else { throw EVMEngineFailure.limitOrdersUnavailable }
            let owner = try EVMEngineSupport.account(account, chain: chain)
            let orders = try await services.cow.openOrders(owner: owner.address, chain: chain, now: Date())
            return orders.map(Self.openOrder(chain: chain))
        } catch {
            throw EVMEngineMessages.userFacing(error, .cancellation, chain: chain)
        }
    }

    static func openOrder(chain: Chain) -> (CoWOrderStatus) -> OpenOrder {
        { status in
            let remaining = status.remainingSellAmount
            // O minimo pelo que falta: a mesma razao da ordem assinada, para cima.
            let minimum = status.sellAmount.isZero ? BigUInt()
                : (status.buyAmount * remaining + status.sellAmount - BigUInt(1)) / status.sellAmount
            return OpenOrder(
                id: Hex.encode(status.uid, prefix: true), chain: chain,
                sellAssetID: assetID(status.sellToken, chain: chain), buyAssetID: assetID(status.buyToken, chain: chain),
                remainingSell: remaining, minimumBuy: minimum,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(status.validTo)), sources: 1,
                cancellations: [.offchain, .onchain], totalSell: status.sellAmount, receivedBuy: status.executedBuyAmount,
                createdAt: status.creationDate
            )
        }
    }

    /// O `Asset.id` de um token da ordem: a sentinela da CoW e o nativo; o resto, o token
    /// da lista (ou rede e contrato, fora dela).
    static func assetID(_ token: EVMAddress, chain: Chain) -> String {
        if token == CoWProtocol.buyNativeToken { return Asset.native(chain).id }
        return TokenRegistry.find(chainID: chain.id, contract: token.checksummed)?.id ?? "\(chain.id):\(token.checksummed)"
    }

    /// Fora da cadeia: o `OrderCancellations` da CoW. Na cadeia: `invalidateOrder(uid)`,
    /// com o gas da chamada exata e o nonce de duas fontes.
    public func planCancel(
        _ order: OpenOrder, walletID: UUID, account: DerivedAccount, via: OpenOrder.Cancellation, nonceQueue: PendingNonceQueue?
    ) async throws -> SigningPlan {
        switch via {
        case .offchain:
            return try planLimitOrderCancellation(walletID: walletID, account: account, orderUIDs: [order.id])
        case .onchain:
            do {
                guard supportsLimitOrders, order.chain.id == chain.id else { throw EVMEngineFailure.limitOrdersUnavailable }
                let owner = try EVMEngineSupport.account(account, chain: chain)
                guard order.id.hasPrefix("0x"), let uid = Hex.decode(order.id), uid.count == CoWProtocol.uidLength else {
                    throw EVMEngineFailure.invalidOrderReference
                }
                let state = try await services.chainState.readCancellation(
                    chain: chain, owner: owner.address, uid: uid, localNextNonce: nonceQueue?.nextNonce
                ).applying(nonceQueue)
                return try CoWPlanner.planOnchainCancellation(walletID: walletID, account: owner, chain: chain, uid: uid, state: state)
            } catch {
                throw EVMEngineMessages.userFacing(error, .cancellation, chain: chain)
            }
        }
    }

    /// O cancelamento assinado: o fora da cadeia vai a CoW e devolve os UIDs; o da cadeia
    /// e transmitido pela rota publica e devolve o id da transacao.
    func submitCancellation(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String] {
        if plan.transactions.first is EIP712ValidatedMessage {
            try await submitLimitOrderCancellation(signed, plan: plan)
            guard let message = plan.transactions.first as? EIP712ValidatedMessage,
                  case .array(let items)? = message.typedData.message["orderUids"]
            else { throw EVMEngineFailure.batchMismatch }
            return items.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
        }
        let transactions = plan.transactions.compactMap { $0 as? EVMTransaction }
        guard transactions.count == 1, plan.transactions.count == 1, transactions[0].to == CoWProtocol.settlement else {
            throw EVMEngineFailure.batchMismatch
        }
        let ordered = try EVMEngineSupport.pairs(signed, transactions)
        return try await EVMEngineSupport.broadcast(ordered, chain: chain, route: .publicMempool, reader: services.reader)
    }

    // MARK: Cancelamento fora da cadeia

    /// Plano de cancelamento das ordens limite pela API da CoW: `OrderCancellations`
    /// assinado em EIP-712, sem taxa de rede. Nao e garantido: se um solver ja estiver
    /// liquidando, a ordem ainda pode executar (a revisao diz isso). O cancelamento
    /// garantido e `invalidateOrder` na cadeia (`CoWPlanner.planOnchainCancellation`).
    ///
    /// `orderUIDs` sao os UIDs em hex com `0x`, como `submit` devolve.
    public func planLimitOrderCancellation(walletID: UUID, account: DerivedAccount, orderUIDs: [String]) throws -> SigningPlan {
        do {
            guard supportsLimitOrders else { throw EVMEngineFailure.limitOrdersUnavailable }
            let owner = try EVMEngineSupport.account(account, chain: chain)
            let uids = try orderUIDs.map { text -> [UInt8] in
                guard text.hasPrefix("0x"), let bytes = Hex.decode(text), bytes.count == CoWProtocol.uidLength else {
                    throw EVMEngineFailure.invalidOrderReference
                }
                return bytes
            }
            return try CoWPlanner.planOffchainCancellation(walletID: walletID, account: owner, chain: chain, uids: uids)
        } catch {
            throw EVMEngineMessages.userFacing(error, .cancellation, chain: chain)
        }
    }

    /// Envia o cancelamento assinado a CoW. Os UIDs e o dono saem do proprio plano, e o
    /// cliente confere a assinatura contra o digesto recalculado antes de enviar.
    public func submitLimitOrderCancellation(_ signed: [SignedTransaction], plan: SigningPlan) async throws {
        do {
            guard plan.chain.id == chain.id, plan.review.kind == .cancelOrder, plan.transactions.count == 1, signed.count == 1,
                  let message = plan.transactions.first as? EIP712ValidatedMessage,
                  message.typedData.primaryType == "OrderCancellations",
                  case .array(let items)? = message.typedData.message["orderUids"]
            else { throw EVMEngineFailure.batchMismatch }
            let uids = try items.map { item -> [UInt8] in
                guard case .string(let text) = item, let bytes = Hex.decode(text), bytes.count == CoWProtocol.uidLength else {
                    throw EVMEngineFailure.invalidOrderReference
                }
                return bytes
            }
            try await services.cow.cancel(uids: uids, chain: chain, owner: message.account.address, signature: signed[0])
        } catch {
            throw EVMEngineMessages.userFacing(error, .cancellation, chain: chain)
        }
    }
}

extension TradeChainState {
    /// O mesmo estado com outro estado de rede (a fila local aplicada).
    func replacingNetwork(_ network: EVMNetworkState) -> TradeChainState {
        TradeChainState(
            network: network, sellToken: sellToken, routerHasCode: routerHasCode, routerPin: routerPin, simulations: simulations,
            approveL1DataFee: approveL1DataFee, swapL1DataFee: swapL1DataFee, approveL1Gas: approveL1Gas, swapL1Gas: swapL1Gas,
            permit2: permit2, permit2L1DataFee: permit2L1DataFee, permit2L1Gas: permit2L1Gas
        )
    }
}
