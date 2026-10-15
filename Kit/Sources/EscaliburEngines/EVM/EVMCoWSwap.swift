import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

// A troca imediata pela CoW (docs/blockchain.md 3.3, "Ordem grande pela CoW").
//
// A CoW entra na rodada da troca imediata como mais um provedor, mas executa diferente:
// em vez de uma transacao com calldata, uma ordem assinada (EIP-712) que os solvers
// disputam no leilao seguinte, com a liquidez das DEX e dos formadores de mercado. Para
// ordem grande e a fonte mais funda: em 10/10/2026, vender US$ 20 mi de ETH por USDC na
// Ethereum perdia 0,61% pela CoW, contra 1,35% na KyberSwap e 2,09% na Velora.
//
// - O minimo e o `buyAmount` da cotacao da CoW (ja sem a taxa de rede e sem a da CoW)
//   menos a tolerancia do dono, e vai gravado na ordem: chega ele ou mais. A tela mostra
//   exatamente esse numero, e o plano assina exatamente ele.
// - Execucao parcial ligada, valendo 30 minutos: o que nao couber de uma vez sai em
//   partes, cada uma pelo minimo ou mais; o que sobrar no fim fica na carteira, sem custo.
// - Compara com os agregadores pelo liquido do garantido. O da CoW so desconta a
//   autorizacao e o embrulho do nativo: a taxa de rede da troca ja saiu da cotacao.
// - Ancora: com preco de referencia, a cotacao fica a no maximo 5% dele, para pior ou
//   para melhor. Melhor demais e cotacao inflada: so ganharia a disputa para nunca
//   executar. Sem referencia, so junto de outra cotacao dos agregadores, e no maximo 5%
//   acima da melhor estimativa deles.
// - Uma ordem aberta por token vendido (docs/seguranca.md 4.5): com ordem aberta vendendo
//   o mesmo token, a CoW fica de fora da troca imediata.
//
// Ordem grande, em partes: quando a cotacao cheia da CoW perde mais de 0,3% para a
// referencia, a rodada cota tambem 25% do valor. Se o preco dessa fracao, aplicado ao
// valor inteiro, render um minimo pelo menos 0,2% maior que o da troca de uma vez, a tela
// oferece a troca em partes: a mesma ordem, com esse minimo, valendo 1 hora. A cada
// leilao os solvers preenchem o que cabe nesse preco, e entre um leilao e outro a
// liquidez volta aos pools pelos arbitradores.

/// A cotacao da CoW pelo valor cheio, ja ancorada e com o custo de executar.
struct EVMCoWCandidate: Sendable {
    let quote: CoWQuote
    /// O minimo que a ordem grava: o cotado menos a tolerancia.
    let guaranteed: BigUInt
    /// Autorizacao e embrulho do nativo, em unidades do token comprado.
    let cost: BigUInt
    let needsApproval: Bool
    /// Quanto a cotacao fica abaixo da referencia, em bps. nil sem referencia.
    let deviationBps: Int?
    let parts: TradeQuote.Parts?

    var net: TradeSignedAmount { .difference(guaranteed, cost) }
}

extension EVMTradeEngine {
    static let basisPoints = BigUInt(10_000)
    static let cowAnchorBps = 500
    static let partsTriggerBps = 30
    static let partsSampleShareBps = 2_500
    static let partsMinimumGainBps = 20
    /// Gas do `deposit()` do nativo embrulhado, so para comparar (o plano le o exato).
    static let wrapGasForRanking: UInt64 = 50_000

    /// Os tokens da ordem: o embrulhado quando vende o nativo; a sentinela da CoW quando
    /// compra o nativo.
    static func cowTokens(_ intent: TradeIntent) -> (sell: EVMAddress, buy: EVMAddress)? {
        let sell: EVMAddress
        switch intent.sell {
        case .token(let token): sell = token.contract
        case .native(let chain):
            guard let wrapped = CoWProtocol.wrappedNative(on: chain) else { return nil }
            sell = wrapped.contract
        }
        return (sell, intent.buy.contract ?? CoWProtocol.buyNativeToken)
    }

    /// A CoW pelo valor cheio, ancorada na referencia quando ha. nil se a rede nao tem
    /// CoW, se ja ha ordem aberta vendendo o mesmo token, se a CoW nao cotou ou se a
    /// cotacao fica longe demais da referencia.
    func cowCandidate(_ context: EVMTradeContext, market: EVMTradeMarket) async -> EVMCoWCandidate? {
        guard CoWProtocol.supports(chain), let tokens = Self.cowTokens(context.intent) else { return nil }
        let intent = context.intent
        let owner = context.account.address
        let cow = services.cow
        let chain = self.chain
        async let open = try? cow.openSellTotal(owner: owner, sellToken: tokens.sell, chain: chain)
        async let allowance = try? services.chainState.token(chain: chain, token: tokens.sell, owner: owner, spender: CoWProtocol.vaultRelayer)
        guard let quote = try? await cow.quote(sellToken: tokens.sell, buyToken: tokens.buy, sellAmount: intent.amountIn, owner: owner,
                                              chain: chain, appData: .limitOrder),
              let openTotal = await open, openTotal.isZero
        else { return nil }

        let deviation = market.reference.deviationBps(expected: quote.buyAmount)
        if let deviation, abs(deviation) > Self.cowAnchorBps { return nil }

        // Custo: a autorizacao, sempre que ela nao e exatamente o valor (o planejador
        // ajusta para o exato), e o embrulho de quem vende o nativo.
        let current = (await allowance)?.allowance ?? 0
        let needsApproval = current != intent.amountIn
        var gas: UInt64 = needsApproval ? market.costs.approveGas : 0
        var transactions: UInt64 = needsApproval ? 1 : 0
        if intent.sell.isNative {
            gas += Self.wrapGasForRanking
            transactions += 1
        }
        let wei = BigUInt(gas) * market.costs.gasPriceWei + market.costs.l1FeePerTransactionWei * BigUInt(transactions)
        let guaranteed = intent.minimumOut(forExpected: quote.buyAmount)

        var parts: TradeQuote.Parts?
        if let deviation, deviation > Self.partsTriggerBps {
            parts = await partsOption(intent: intent, tokens: tokens, guaranteed: guaranteed, market: market)
        }
        return EVMCoWCandidate(quote: quote, guaranteed: guaranteed, cost: market.costs.nativeToBuy.apply(wei),
                               needsApproval: needsApproval, deviationBps: deviation, parts: parts)
    }

    /// O preco de 25% do valor, aplicado ao valor inteiro: o minimo da troca em partes,
    /// quando rende pelo menos 0,2% mais que `single`.
    func partsOption(intent: TradeIntent, tokens: (sell: EVMAddress, buy: EVMAddress), guaranteed single: BigUInt,
                     market: EVMTradeMarket) async -> TradeQuote.Parts? {
        let share = BigUInt(Self.partsSampleShareBps)
        let sample = intent.amountIn * share / EVMTradeEngine.basisPoints
        guard !sample.isZero,
              let quote = try? await services.cow.quote(sellToken: tokens.sell, buyToken: tokens.buy, sellAmount: sample,
                                                       owner: intent.owner, chain: chain, appData: .limitOrder)
        else { return nil }
        let expected = quote.buyAmount * intent.amountIn / sample
        guard let deviation = market.reference.deviationBps(expected: expected), abs(deviation) <= Self.cowAnchorBps else { return nil }
        let minimum = intent.minimumOut(forExpected: expected)
        let required = single + single * BigUInt(Self.partsMinimumGainBps) / EVMTradeEngine.basisPoints
        guard minimum >= required else { return nil }
        return TradeQuote.Parts(expectedOut: expected, minimumOut: minimum, sampleShareBps: Self.partsSampleShareBps,
                                validFor: CoWProtocol.partsValidity)
    }

    /// Sem referencia, a CoW so vale junto de outra cotacao, e no maximo 5% acima da
    /// melhor estimativa dos agregadores.
    static func cowAnchored(_ candidate: EVMCoWCandidate, aggregatorExpected: [BigUInt]) -> Bool {
        if candidate.deviationBps != nil { return true }
        guard let best = aggregatorExpected.max() else { return false }
        let ceiling = best + best * BigUInt(cowAnchorBps) / EVMTradeEngine.basisPoints
        return candidate.quote.buyAmount <= ceiling
    }

    /// O `TradeQuote` da troca pela CoW. As alternativas sao os agregadores, cada um com o
    /// seu garantido.
    static func cowQuote(_ request: TradeRequest, candidate: EVMCoWCandidate, ranked: [TradeCandidate]) -> TradeQuote {
        let fee = candidate.quote.protocolFeeBps.map { kitText(" (\(EVMEngineText.percent(bps: $0)) do volume)") } ?? ""
        return TradeQuote(
            sell: request.sell, buy: request.buy, amountIn: request.amountIn,
            expectedOut: candidate.quote.buyAmount, minimumOut: candidate.guaranteed,
            priceImpactPercent: candidate.deviationBps.map { Double(max(0, $0)) / 100 },
            networkFeeFiat: nil,
            providerFeeNote: kitText("A taxa da CoW\(fee) e a taxa da rede da troca já saíram da cotação e do mínimo garantido."),
            legs: [TradeQuote.Leg(provider: "CoW", fraction: 1, amountIn: request.amountIn, expectedOut: candidate.quote.buyAmount)],
            alternatives: ranked.map { TradeQuote.Alternative(provider: $0.quote.provider.displayName, out: $0.quote.guaranteedOut) },
            providersCompared: ranked.count + 1, needsApproval: candidate.needsApproval,
            expiresAt: Date().addingTimeInterval(ValidatedTradeQuote.lifetime), execution: .order, parts: candidate.parts
        )
    }

    // MARK: Plano

    /// A troca pela CoW: a ordem assinada com exatamente o minimo que a tela mostrou (o
    /// da troca de uma vez ou o da troca em partes), com execucao parcial.
    func makeCoWSwapPlan(_ request: TradeRequest, quote: TradeQuote) async throws -> SigningPlan {
        let context = try EVMTradeContext(request, chain: chain)
        guard quote.sell == request.sell, quote.buy == request.buy, quote.amountIn == request.amountIn else {
            throw EVMEngineFailure.quoteMismatch
        }
        guard quote.expiresAt > .now else { throw EVMEngineFailure.quoteExpired }
        guard supportsLimitOrders else { throw EVMEngineFailure.limitOrdersUnavailable }
        if request.inParts {
            guard quote.parts != nil else { throw EVMEngineFailure.quoteMismatch }
        } else {
            guard quote.execution == .order else { throw EVMEngineFailure.quoteMismatch }
            guard PriceImpact.level(quote.priceImpactPercent) != .blocked else { throw EVMEngineFailure.riskIncreased }
        }
        let minimum = quote.minimumOut(inParts: request.inParts)
        let account = context.account
        let sell = context.intent.sell
        let buy = context.intent.buy
        let intent = try CoWLimitOrderIntent(
            owner: account.address, sell: sell, buy: buy, sellAmount: request.amountIn, buyAmount: minimum,
            validFor: request.inParts ? CoWProtocol.partsValidity : CoWProtocol.instantValidity,
            partiallyFillable: true, style: request.inParts ? .parts : .instant
        )
        guard intent.buyAmount == minimum, let sellToken = intent.orderSellToken else { throw EVMEngineFailure.limitPriceNotRepresentable }

        let open = try await services.cow.openSellTotal(owner: account.address, sellToken: sellToken.contract, chain: chain)
        guard open.isZero else { throw EVMEngineFailure.openOrderExists }
        let read = try await services.chainState.readCoW(intent: intent, openOrdersSellTotal: open, localNextNonce: request.nonceQueue?.nextNonce)
        let state = CoWChainState(
            network: read.network.applying(request.nonceQueue), sellToken: read.sellToken, wrapGasEstimate: read.wrapGasEstimate,
            wrapL1DataFee: read.wrapL1DataFee, openOrdersSellTotal: read.openOrdersSellTotal
        )
        let now = Date()
        let plan = try CoWPlanner.planLimitOrder(walletID: request.walletID, account: account, intent: intent, state: state, now: now)
        await services.pendingOrders.store(plan, now: now)
        return plan.signingPlan
    }

    // MARK: Andamento

    public func orderProgress(id: String, account: DerivedAccount) async throws -> OrderProgress {
        do {
            guard supportsLimitOrders else { throw EVMEngineFailure.limitOrdersUnavailable }
            let owner = try EVMEngineSupport.account(account, chain: chain)
            guard id.hasPrefix("0x"), let uid = Hex.decode(id), uid.count == CoWProtocol.uidLength,
                  CoWProtocol.owner(ofUID: uid) == owner.address
            else { throw EVMEngineFailure.invalidOrderReference }
            let status = try await services.cow.order(uid: uid, chain: chain, expected: nil)
            guard status.owner == owner.address else { throw EVMEngineFailure.invalidOrderReference }
            return Self.progress(status, now: Date())
        } catch {
            throw EVMEngineMessages.userFacing(error, .orderProgress, chain: chain)
        }
    }

    static func progress(_ status: CoWOrderStatus, now: Date) -> OrderProgress {
        let state: OrderProgress.State
        switch status.status {
        case .fulfilled: state = .filled
        case .cancelled: state = .cancelled
        case .expired: state = .expired
        case .open, .presignaturePending, .unknown:
            if status.invalidated {
                state = .cancelled
            } else if TimeInterval(status.validTo) <= now.timeIntervalSince1970 {
                state = .expired
            } else {
                state = .open
            }
        }
        return OrderProgress(
            id: Hex.encode(status.uid, prefix: true), state: state, totalSell: status.sellAmount,
            soldSell: min(status.executedSellAmount, status.sellAmount), receivedBuy: status.executedBuyAmount,
            minimumBuy: status.buyAmount, expiresAt: Date(timeIntervalSince1970: TimeInterval(status.validTo))
        )
    }
}

extension TradeQuote {
    /// A troca pelos agregadores com a CoW ao lado: a CoW entra nas alternativas, e a
    /// troca em partes dela vira opcao quando garante pelo menos 0,2% mais que esta.
    func adding(cow: EVMCoWCandidate?) -> TradeQuote {
        guard let cow else { return self }
        var option: Parts?
        if let parts = cow.parts {
            let required = minimumOut + minimumOut * BigUInt(EVMTradeEngine.partsMinimumGainBps) / EVMTradeEngine.basisPoints
            if parts.minimumOut >= required { option = parts }
        }
        return TradeQuote(
            sell: sell, buy: buy, amountIn: amountIn, expectedOut: expectedOut, minimumOut: minimumOut,
            priceImpactPercent: priceImpactPercent, networkFeeFiat: networkFeeFiat, providerFeeNote: providerFeeNote, legs: legs,
            alternatives: alternatives + [Alternative(provider: "CoW", out: cow.guaranteed)], providersCompared: providersCompared + 1,
            needsApproval: needsApproval, expiresAt: expiresAt, execution: execution, parts: option
        )
    }
}
