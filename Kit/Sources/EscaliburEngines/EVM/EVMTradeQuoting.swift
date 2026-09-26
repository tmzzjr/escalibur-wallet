import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

// A rodada de cotacao da troca EVM e a traducao do resultado para o `TradeQuote` da tela.
//
// O agregador pergunta a Velora, KyberSwap, LI.FI e De¹ em paralelo, valida cada calldata
// (EscaliburChains/Trade/TradeValidator) e ranqueia pelo liquido do garantido. O que a
// tela chama de "voce recebe no minimo" e a soma dos garantidos decodificados das
// calldatas escolhidas, nunca o que o provedor anuncia.

/// Um pedido de troca ja conferido: conta, ativos da lista curada e a intencao.
struct EVMTradeContext {
    let chain: Chain
    let account: EVMAccount
    let sell: EVMResolvedAsset
    let buy: EVMResolvedAsset
    let intent: TradeIntent

    init(_ request: TradeRequest, chain: Chain) throws {
        guard request.chain.id == chain.id else { throw EVMEngineFailure.wrongChain }
        self.chain = chain
        account = try EVMEngineSupport.account(request.account, chain: chain)
        sell = try EVMEngineSupport.resolve(request.sell, on: chain)
        buy = try EVMEngineSupport.resolve(request.buy, on: chain)
        guard let slippage = UInt32(exactly: request.slippageBasisPoints) else { throw TradeRefusal.slippageOutOfRange(0) }
        intent = try TradeIntent(
            owner: account.address, sell: sell.tradeAsset(on: chain), buy: buy.tradeAsset(on: chain),
            amountIn: request.amountIn, slippageBps: slippage
        )
    }

    var sellIsStable: Bool { Self.isStable(sell, chain: chain) }
    var buyIsStable: Bool { Self.isStable(buy, chain: chain) }

    static func isStable(_ asset: EVMResolvedAsset, chain: Chain) -> Bool {
        guard case .token(let token) = asset else { return false }
        return TokenRegistry.find(chainID: chain.id, contract: token.contract.checksummed)?.isStablecoin == true
    }

    /// O id do CoinGecko de um ativo resolvido: o da rede para o nativo, o da lista para
    /// o token.
    static func coingeckoID(_ asset: EVMResolvedAsset, chain: Chain) -> String? {
        switch asset {
        case .native: return chain.coingeckoID
        case .token(let token): return TokenRegistry.find(chainID: chain.id, contract: token.contract.checksummed)?.coingeckoID
        }
    }
}

/// O que a rodada precisa alem da intencao: o custo de executar, igual para todos os
/// provedores, e a referencia de mercado.
struct EVMTradeMarket: Sendable {
    let gasPriceWei: BigUInt
    let costs: TradeCostModel
    let reference: TradeMarketReference
    /// US$ 5 em unidades do token comprado: o ganho minimo absoluto para dividir entre
    /// provedores (docs/blockchain.md 3.3). `nil` sem preco, e ai nao ha divisao.
    let minimumSplitGain: BigUInt?

    /// Tamanho de calldata usado so para estimar a taxa L1 na comparacao. As calldatas
    /// de troca vistas ficam entre 1 e 2 KB; o plano le a taxa do tamanho exato.
    static let comparisonCalldataSize = 2_000

    static func read(_ context: EVMTradeContext, services: EVMTradeServices) async throws -> EVMTradeMarket {
        let chain = context.chain
        async let network = services.chainState.network(
            chain: chain, owner: context.account.address, localNextNonce: nil, gasEstimate: 21_000, l1DataFee: nil,
            destinationHasCode: true
        )
        async let l1 = services.chainState.l1DataFee(chain: chain, calldataSize: comparisonCalldataSize)
        let nativeID = chain.coingeckoID
        let sellID = EVMTradeContext.coingeckoID(context.sell, chain: chain)
        let buyID = EVMTradeContext.coingeckoID(context.buy, chain: chain)
        // Sem preco, a troca continua: so a sanidade contra o oraculo e a conversao do gas
        // ficam de fora. O minimo garantido nunca depende de preco.
        let prices = (try? await services.prices.usdPrices(Array(Set([nativeID] + [sellID, buyID].compactMap { $0 })))) ?? [:]
        let state = try await network
        let gasPrice = gasPriceWei(state, chain: chain)
        return make(
            context: context, gasPriceWei: gasPrice, l1Fee: try await l1 ?? 0, nativePrice: prices[nativeID],
            sellPrice: sellID.flatMap { prices[$0] }, buyPrice: buyID.flatMap { prices[$0] }
        )
    }

    static func make(
        context: EVMTradeContext, gasPriceWei: BigUInt, l1Fee: BigUInt, nativePrice: String?, sellPrice: String?, buyPrice: String?
    ) -> EVMTradeMarket {
        let intent = context.intent
        var reference = TradeMarketReference.none
        if let sellPrice, let buyPrice {
            reference = TradeMarketReference(amountIn: intent.amountIn, sell: intent.sell, buy: intent.buy, sellPriceUSD: sellPrice, buyPriceUSD: buyPrice)
        } else if context.sellIsStable, context.buyIsStable {
            // Dois stablecoins da lista: a paridade e a referencia, sem perguntar a ninguem.
            reference = TradeMarketReference(amountIn: intent.amountIn, sell: intent.sell, buy: intent.buy, sellPriceUSD: "1", buyPriceUSD: "1")
        }
        // Gas convertido para o token comprado pela mesma taxa para todos. Sem preco, a
        // conversao da zero e o ranking fica so pelo garantido, igual para todos.
        var rate = TradeRate(numerator: 0, denominator: 1)
        if intent.buy.isNative {
            rate = .identity
        } else if let nativePrice, let buyPrice,
                  let converted = TradeRate.nativeToBuy(chain: context.chain, buy: intent.buy, nativePriceUSD: nativePrice, buyPriceUSD: buyPrice) {
            rate = converted
        }
        var gain: BigUInt?
        if let buyPrice, let price = TradeDecimal(buyPrice), !price.isZero {
            gain = BigUInt(5) * BigUInt.power(of: 10, intent.buy.decimals + price.scale) / price.mantissa
        }
        return EVMTradeMarket(
            gasPriceWei: gasPriceWei, costs: TradeCostModel(gasPriceWei: gasPriceWei, l1FeePerTransactionWei: l1Fee, nativeToBuy: rate),
            reference: reference, minimumSplitGain: gain
        )
    }

    /// baseFee mais a gorjeta normal, dentro dos limites do perfil da rede: o mesmo preco
    /// que o plano usaria.
    static func gasPriceWei(_ state: EVMNetworkState, chain: Chain) -> BigUInt {
        guard let profile = EVMFeeProfile.for(chain) else { return state.baseFeePerGas + state.priorityFees.normal }
        let tip = min(max(state.priorityFees.normal, profile.minPriorityFee), profile.maxPriorityFee)
        return state.baseFeePerGas + tip
    }
}

extension TradeCostModel {
    func with(allowances: [EVMAddress: BigUInt]) -> TradeCostModel {
        TradeCostModel(gasPriceWei: gasPriceWei, l1FeePerTransactionWei: l1FeePerTransactionWei, nativeToBuy: nativeToBuy,
                       approveGas: approveGas, allowances: allowances)
    }
}

/// Uma perna da troca escolhida: a cotacao validada e a fracao do total.
struct EVMTradeLeg: Sendable {
    let quote: ValidatedTradeQuote
    let shareBps: Int
}

enum EVMTradeQuoteMapping {
    /// O `TradeQuote` da tela a partir das pernas escolhidas e do ranking.
    static func quote(
        sell: Asset, buy: Asset, amountIn: BigUInt, legs: [EVMTradeLeg], ranked: [TradeCandidate], allowances: [EVMAddress: BigUInt]
    ) -> TradeQuote {
        let chosen = Set(legs.map(\.quote.provider))
        let isSplit = legs.count > 1
        let impact = legs.compactMap(\.quote.assessment.priceImpactBps).max()
        let notes = legs.compactMap { providerFeeNote($0.quote) }
        let sellsToken = legs.first?.quote.intent.sell.isNative == false
        return TradeQuote(
            sell: sell, buy: buy, amountIn: amountIn,
            expectedOut: legs.reduce(BigUInt()) { $0 + $1.quote.expectedOut },
            minimumOut: legs.reduce(BigUInt()) { $0 + $1.quote.guaranteedOut },
            priceImpactPercent: impact.map { Double($0) / 100 },
            networkFeeFiat: nil,
            providerFeeNote: notes.isEmpty ? nil : notes.joined(separator: " "),
            legs: legs.map { leg in
                TradeQuote.Leg(
                    provider: leg.quote.provider.displayName, fraction: Double(leg.shareBps) / 10_000,
                    amountIn: leg.quote.intent.amountIn, expectedOut: leg.quote.expectedOut
                )
            },
            // Cada alternativa e uma cotacao de um provedor so, pelo valor inteiro, com o
            // garantido dela. Numa divisao, os proprios provedores das pernas tambem sao
            // alternativa ("tudo por um so").
            alternatives: ranked.filter { isSplit || !chosen.contains($0.quote.provider) }.map {
                TradeQuote.Alternative(provider: $0.quote.provider.displayName, out: $0.quote.guaranteedOut)
            },
            providersCompared: ranked.count,
            needsApproval: sellsToken && legs.contains { (allowances[$0.quote.spender] ?? 0) < $0.quote.intent.amountIn },
            expiresAt: (legs.map(\.quote.validatedAt).min() ?? .now).addingTimeInterval(ValidatedTradeQuote.lifetime)
        )
    }

    /// O que o proprio provedor cobra, dito como fato. A taxa da Escalibur e zero e a tela
    /// ja diz isso.
    static func providerFeeNote(_ quote: ValidatedTradeQuote) -> String? {
        switch quote.provider {
        case .lifi:
            let fee = quote.decoded.providerFeeAmount
            guard !fee.isZero, !quote.intent.amountIn.isZero,
                  let bps = (fee * BigUInt(10_000) / quote.intent.amountIn).uint64 else { return nil }
            return "A LI.FI fica com \(EVMEngineText.percent(bps: Int(bps))) do valor vendido, já descontado do mínimo garantido."
        case .velora:
            return "A Velora fica com o que vier acima da estimativa. O mínimo garantido não muda."
        case .de1:
            return "A De¹ embute a própria taxa na rota. O mínimo garantido já considera essa taxa."
        case .kyberSwap:
            return nil
        }
    }

    /// O provedor de uma perna pelo nome que a tela mostra.
    static func provider(named name: String) -> TradeProvider? {
        TradeProvider.allCases.first { $0.displayName == name }
    }
}
