import EscaliburChains
import EscaliburCore
import EscaliburKeys
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
    /// (docs/seguranca.md 4.9). Hoje so a Avalanche: nenhum RPC publico implementa
    /// `eth_simulateV1` la.
    public init?(chain: Chain) {
        self.init(chain: chain, services: .live)
    }

    init?(chain: Chain, services: EVMTradeServices) {
        guard EVMEngineSupport.isSupported(chain), (Endpoints.tradeSimulation[chain.id]?.count ?? 0) >= 2 else { return nil }
        self.chain = chain
        self.services = services
    }

    /// A CoW atende todas as redes da troca menos a OP.
    public var supportsLimitOrders: Bool { CoWProtocol.supports(chain) }

    public var limitCustodyNote: String {
        guard supportsLimitOrders else { return "Ordens limite ainda não estão disponíveis na \(chain.name)." }
        return "O valor fica na sua carteira até a ordem executar. Você pode cancelar a qualquer momento."
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
        let set = await services.aggregator.quote(context.intent, market: market.reference, costs: market.costs)
        guard !set.ranked.isEmpty else { throw Self.emptyRound(set.failures) }

        // A autorizacao que ja existe barateia a troca: le a allowance dos spenders que
        // disputam o topo e ranqueia de novo com ela.
        let allowances = await allowances(for: Array(set.ranked.prefix(TradeSplitOptimizer.maxProviders)), context: context)
        let costs = market.costs.with(allowances: allowances)
        let ranked = TradeRanking.rank(set.ranked.map(\.quote), costs: costs)
        guard let best = ranked.first else { throw EVMEngineFailure.noQuote }

        var legs = [EVMTradeLeg(quote: best.quote, shareBps: 10_000)]
        if let gain = market.minimumSplitGain, TradeSplitOptimizer.shouldConsider(best),
           let split = await services.aggregator.proposeSplit(set, market: market.reference, costs: market.costs, minimumGainAbsolute: gain),
           let resolved = await resolve(split, against: best, market: market, costs: costs) {
            legs = resolved
        }
        return EVMTradeQuoteMapping.quote(
            sell: request.sell, buy: request.buy, amountIn: request.amountIn, legs: legs, ranked: ranked, allowances: allowances
        )
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
                    let quote = try? await aggregator.requote(legs[index].provider, intent: intent, market: market.reference, gasPriceWei: market.gasPriceWei)
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
        let requoted = try await requote(legs, intent: intent, market: market)

        // O garantido novo nao pode ter caido abaixo do que a tela mostrou por mais que a
        // tolerancia do dono: isso seria outra troca, nao a que ele revisou.
        let guaranteed = requoted.reduce(BigUInt()) { $0 + $1.quote.guaranteedOut }
        guard guaranteed >= intent.minimumOut(forExpected: quote.minimumOut) else { throw EVMEngineFailure.priceMoved }

        // Uma perna depois da outra: nonce, saldo nativo e saldo do token vendido seguem de
        // uma para a proxima, porque todas vao ser assinadas agora e executadas em sequencia.
        // Cada plano leva o instante em que foi montado, depois da recotacao e da leitura:
        // o prazo de 60 s conta dali, e a cotacao recem-validada nunca parece "do futuro".
        var plans = [SigningPlan]()
        var nextNonce: UInt64?
        var spentNative = BigUInt()
        var spentSell = BigUInt()
        for (index, leg) in requoted.enumerated() {
            let read = try await services.chainState.read(for: leg.quote, localNextNonce: nextNonce)
            let state = Self.remaining(read, spentNative: spentNative, spentSell: spentSell)
            let step = requoted.count > 1 ? TradeSplitStep(index: index, count: requoted.count, shareBps: leg.shareBps) : nil
            let plan = try TradePlanner.planSwap(
                walletID: request.walletID, account: context.account, quote: leg.quote, state: state,
                riskConfirmed: riskConfirmed, split: step
            )
            let transactions = plan.transactions.compactMap { $0 as? EVMTransaction }
            guard transactions.count == plan.transactions.count, let last = transactions.last else { throw EVMEngineFailure.batchMismatch }
            nextNonce = last.nonce + 1
            spentNative = spentNative + Self.maximumNativeCost(transactions, state: state)
            if !intent.sell.isNative { spentSell = spentSell + leg.quote.intent.amountIn }
            plans.append(plan)
        }
        guard plans.count > 1 else { return plans[0] }
        return Self.combined(plans, legs: requoted, intent: intent, walletID: request.walletID)
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
                    (index, try await aggregator.requote(leg.provider, intent: legIntent, market: market.reference, gasPriceWei: market.gasPriceWei))
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
            baseFeePerGas: network.baseFeePerGas, priorityFees: network.priorityFees, gasEstimate: network.gasEstimate,
            l1DataFee: network.l1DataFee, nativeBalance: network.nativeBalance.subtractingReportingUnderflow(spentNative) ?? 0,
            destinationHasCode: network.destinationHasCode
        )
        let token = state.sellToken.map {
            EVMTokenState(contractHasCode: $0.contractHasCode, balance: $0.balance.subtractingReportingUnderflow(spentSell) ?? 0, allowance: $0.allowance)
        }
        return TradeChainState(
            network: adjusted, sellToken: token, routerHasCode: state.routerHasCode, routerPin: state.routerPin,
            simulations: state.simulations, approveL1DataFee: state.approveL1DataFee, swapL1DataFee: state.swapL1DataFee,
            approveL1Gas: state.approveL1Gas, swapL1Gas: state.swapL1Gas
        )
    }

    /// O maximo que as transacoes de uma perna tiram do saldo nativo: gas maximo, valor e
    /// taxa L1 de cada uma (a autorizacao antes, a troca por ultimo).
    static func maximumNativeCost(_ transactions: [EVMTransaction], state: TradeChainState) -> BigUInt {
        var total = BigUInt()
        for (index, transaction) in transactions.enumerated() {
            let l1 = index == transactions.count - 1 ? state.swapL1DataFee : state.approveL1DataFee
            total = total + transaction.maxExecutionCost + transaction.value + (l1 ?? 0)
        }
        return total
    }

    /// Uma troca dividida vira um plano so, assinado de uma vez: as transacoes de todas as
    /// pernas em sequencia de nonce, e a revisao com a visao geral seguida das linhas de
    /// cada etapa. O prazo do plano conta da primeira perna, a mais antiga.
    static func combined(_ plans: [SigningPlan], legs: [EVMTradeLeg], intent: TradeIntent, walletID: UUID) -> SigningPlan {
        let count = plans.reduce(0) { $0 + $1.review.transactionCount }
        let guaranteed = legs.reduce(BigUInt()) { $0 + $1.quote.guaranteedOut }
        let expected = legs.reduce(BigUInt()) { $0 + $1.quote.expectedOut }
        let division = legs.map { "\(EVMEngineText.percent(bps: $0.shareBps)) pela \($0.quote.provider.displayName)" }
        var lines: [PlanReview.Line] = [
            .init("Rede", intent.chain.name),
            .init("Sai", EVMEngineText.amount(intent.amountIn, intent.sell)),
            .init("Entra, no mínimo", EVMEngineText.amount(guaranteed, intent.buy)),
            .init("Estimativa", EVMEngineText.amount(expected, intent.buy)),
            .init("Divisão", division.joined(separator: ", ")),
            .init("Transações", "\(count) transações independentes, em sequência, assinadas de uma vez"),
            .init("Se uma etapa falhar", "As outras continuam valendo: você fica com parte em \(intent.buy.symbol) e parte em \(intent.sell.symbol). Não existe desfazer, e a etapa que falhou custa só a taxa de rede."),
            .init("Taxa da Escalibur", "Sem taxa da Escalibur"),
        ]
        let overview = Set(["Rede", "Divisão", "Taxa da Escalibur"])
        for (index, plan) in plans.enumerated() {
            for line in plan.review.lines where !overview.contains(line.label) {
                lines.append(.init("Etapa \(index + 1) · \(line.label)", line.value, verbatim: line.verbatim))
            }
        }
        var warnings = [PlanReview.Warning]()
        for warning in plans.flatMap(\.review.warnings) where !warnings.contains(warning) { warnings.append(warning) }
        let title = "Trocar \(EVMEngineText.amount(intent.amountIn, intent.sell)) por \(intent.buy.symbol) em \(plans.count) etapas"
        let review = PlanReview(kind: .swap, title: title, lines: lines, warnings: warnings, transactionCount: count)
        let createdAt = plans.map(\.createdAt).min() ?? .now
        return SigningPlan(walletID: walletID, chain: intent.chain, review: review, transactions: plans.flatMap(\.transactions), createdAt: createdAt)
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
        let sell = try EVMEngineSupport.resolve(request.sell, on: chain).tradeAsset(on: chain)
        let buy = try EVMEngineSupport.resolve(request.buy, on: chain).tradeAsset(on: chain)
        guard !request.minimumOut.isZero else { throw CoWRefusal.zeroBuyAmount }
        guard !request.amountIn.isZero else { throw TradeRefusal.zeroAmount }

        // O minimo que o dono calculou vira preco decimal exato: a ordem assinada recebe
        // exatamente esse minimo, nem um wei a menos.
        let price = try Self.limitPrice(minimumOut: request.minimumOut, sellAmount: request.amountIn,
                                        sellDecimals: sell.decimals, buyDecimals: buy.decimals)
        let intent = try CoWLimitOrderIntent(owner: account.address, sell: sell, buy: buy, sellAmount: request.amountIn,
                                             price: price, validFor: request.validFor)
        guard intent.buyAmount == request.minimumOut, let sellToken = intent.orderSellToken else {
            throw EVMEngineFailure.limitPriceNotRepresentable
        }

        // Uma ordem aberta por token vendido (docs/seguranca.md 4.5): uma ordem antiga e
        // esquecida executaria quando o saldo voltasse. Somar ordens exigiria o "sim" do
        // dono, que o contrato do motor ainda nao traz.
        let open = try await services.cow.openSellTotal(owner: account.address, sellToken: sellToken.contract, chain: chain)
        guard open.isZero else { throw EVMEngineFailure.openOrderExists }

        let state = try await services.chainState.readCoW(intent: intent, openOrdersSellTotal: open, localNextNonce: nil)
        // O prazo do plano e o validTo da ordem contam de agora, depois das leituras.
        let now = Date()
        let plan = try CoWPlanner.planLimitOrder(walletID: request.walletID, account: account, intent: intent, state: state, now: now)
        await services.pendingOrders.store(plan, now: now)
        return plan
    }

    /// O preco-alvo como decimal exato que reproduz `minimumOut`.
    ///
    /// A CoW calcula `buyAmount = ceil(sellAmount * preco * 10^casasCompra / 10^(escala +
    /// casasVenda))`. Com o preco truncado em `escala` casas, o resultado fica em
    /// `[minimumOut - e, minimumOut]`, com `e < sellAmount * 10^casasCompra /
    /// 10^(escala + casasVenda)`. Escolhendo a escala para essa razao ficar abaixo de 1, o
    /// teto devolve exatamente `minimumOut`. A conta e conferida no fim.
    static func limitPrice(minimumOut: BigUInt, sellAmount: BigUInt, sellDecimals: Int, buyDecimals: Int) throws -> CoWLimitPrice {
        guard !sellAmount.isZero, !minimumOut.isZero else { throw CoWRefusal.zeroBuyAmount }
        let scale = max(0, sellAmount.decimalString.count + buyDecimals - sellDecimals)
        guard scale <= 36 else { throw EVMEngineFailure.limitPriceNotRepresentable }
        let mantissa = minimumOut * BigUInt.power(of: 10, scale + sellDecimals) / (sellAmount * BigUInt.power(of: 10, buyDecimals))
        let unit = BigUInt.power(of: 10, scale)
        let integer = (mantissa / unit).decimalString
        let fraction = (mantissa % unit).decimalString
        let text = scale == 0 ? integer : integer + "." + String(repeating: "0", count: scale - fraction.count) + fraction
        guard let price = CoWLimitPrice(text),
              price.buyAmount(sellAmount: sellAmount, sellDecimals: sellDecimals, buyDecimals: buyDecimals) == minimumOut
        else { throw EVMEngineFailure.limitPriceNotRepresentable }
        return price
    }

    // MARK: Envio

    /// Troca: devolve os ids das transacoes, calculados aqui, em ordem de nonce. Ordem
    /// limite: devolve o UID da ordem, conferido contra o calculado no plano.
    public func submit(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String] {
        do {
            guard plan.chain.id == chain.id else { throw EVMEngineFailure.wrongChain }
            switch plan.review.kind {
            case .swap: return try await submitSwap(signed, plan: plan)
            case .limitOrder: return [try await submitLimitOrder(signed, plan: plan)]
            default: throw EVMEngineFailure.batchMismatch
            }
        } catch {
            throw EVMEngineMessages.userFacing(error, .submit, chain: chain)
        }
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
