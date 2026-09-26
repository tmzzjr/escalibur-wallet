import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Trocar e ordem limite na DEX nativa da Stellar, entre o XLM e os ativos da lista
/// curada.
///
/// Troca: `PathPaymentStrictSend` para a propria conta. O que protege o dono e o
/// `destMin`, que o `StellarPlanner` grava na transacao a partir da cotacao e da
/// tolerancia, e que a rede garante seja qual for a rota. Por isso a cotacao nao vem de
/// uma Horizon so (auditoria 2, A1):
/// - as duas Horizons cotam, e o minimo ancora na maior: uma que cota baixo nao rebaixa o
///   minimo; uma que infla so faz a troca falhar, sem perda;
/// - a rota so passa por XLM e ativos da lista curada, nunca por um livro qualquer;
/// - com preco de referencia do mercado, a cotacao mais de 5% pior recusa e acima de 2%
///   a revisao avisa (a mesma sanidade da troca EVM).
/// Se a conta ainda nao aceita o ativo comprado, o `ChangeTrust` vai na mesma transacao.
///
/// Ordem limite: `ManageSellOffer`, com o preco calculado localmente do minimo digitado.
struct StellarTradeEngine: TradeEngine {
    let reader: StellarReader
    let prices: any TradePriceOracle

    init(reader: StellarReader = StellarReader(), prices: any TradePriceOracle = MarketPriceOracle.shared) {
        self.reader = reader
        self.prices = prices
    }

    /// Por onde uma rota pode passar: XLM e os ativos da lista curada.
    static var allowedPath: [StellarAsset] { [.native] + StellarEngineSupport.allowedAssets }

    /// A maior das cotacoes das duas Horizons; nil se nenhuma achou rota.
    static func higher(_ quotes: [StellarPathQuote?]) -> StellarPathQuote? {
        quotes.compactMap { $0 }.max { $0.receiveAmount < $1.receiveAmount }
    }

    var supportsLimitOrders: Bool { true }

    var limitCustodyNote: String {
        "O valor fica na sua conta, reservado pela oferta, até executar ou você cancelar. A Stellar não tem prazo para ofertas: ela fica aberta até executar ou ser cancelada, e prende uma reserva de XLM enquanto isso."
    }

    static let provider = "DEX da Stellar"

    // MARK: Cotacao

    /// A maior das rotas strict send das duas Horizons, e o minimo que a transacao vai
    /// garantir a partir dela.
    ///
    /// O impacto no preco compara com uma cotacao de um milesimo do valor no mesmo par.
    func quote(_ request: TradeRequest) async throws -> TradeQuote {
        let (sell, buy) = try pair(request.chain, request.sell, request.buy)
        try TradeMath.requireSlippage(request.slippageBasisPoints)
        guard !request.amountIn.isZero else { throw SendEngineError.message("Digite um valor maior que zero.") }
        let referenceIn = request.amountIn / BigUInt(1_000)
        do {
            async let both = reader.quoteStrictSendOnBoth(send: sell, amount: request.amountIn, receive: buy, allowedPath: Self.allowedPath)
            async let small = referenceQuote(send: sell, amount: referenceIn, receive: buy)
            async let market = MarketReference.reference(amountIn: request.amountIn, sell: request.sell, buy: request.buy, oracle: prices)
            guard let route = Self.higher(try await both) else { throw SendEngineError.message(Self.noRoute(request)) }
            try Self.sanity(await market, expected: route.receiveAmount)
            let minimum = TradeMath.minimumOut(route.receiveAmount, slippageBasisPoints: request.slippageBasisPoints)
            guard !minimum.isZero else { throw StellarPlanError.minimumReceiveZero }
            let reference = await small
            let impact = reference.flatMap {
                TradeMath.impactPercent(amountIn: request.amountIn, out: route.receiveAmount, referenceIn: $0.sendAmount, referenceOut: $0.receiveAmount)
            }
            return TradeQuote(
                sell: request.sell, buy: request.buy, amountIn: request.amountIn,
                expectedOut: route.receiveAmount, minimumOut: minimum, priceImpactPercent: impact, networkFeeFiat: nil,
                providerFeeNote: "Sem taxa de provedor: a troca acontece direto na DEX da Stellar.",
                legs: [.init(provider: Self.provider, fraction: 1, amountIn: request.amountIn, expectedOut: route.receiveAmount)],
                alternatives: [], providersCompared: 1, needsApproval: false,
                expiresAt: Date().addingTimeInterval(TradeMath.quoteLifetime)
            )
        } catch {
            throw StellarEngineSupport.translate(error)
        }
    }

    /// A cotacao de referencia do impacto. Sem ela, o impacto fica desconhecido; a troca
    /// nao depende dela.
    ///
    /// Esta pode passar por qualquer ativo: so serve de regua do impacto, e uma regua mais
    /// favoravel so faz o impacto parecer maior (mais cautela), nunca muda o minimo.
    private func referenceQuote(send: StellarAsset, amount: BigUInt, receive: StellarAsset) async -> StellarPathQuote? {
        guard !amount.isZero else { return nil }
        return try? await reader.quoteStrictSend(send: send, amount: amount, receive: receive)
    }

    /// Mais de 5% pior que o mercado: recusa ja na cotacao, com a frase da tela.
    static func sanity(_ reference: TradeMarketReference, expected: BigUInt) throws {
        do {
            try reference.check(expected: expected)
        } catch TradeRefusal.priceFarFromOracle(let deviation) {
            throw SendEngineError.message(MarketReference.farText(deviationBps: deviation))
        }
    }

    // MARK: Plano

    /// O plano da cotacao que o dono viu: `destMin` igual ao minimo da cotacao, conferido
    /// na transacao montada. A rota e lida de novo agora; se ela ja nao entrega o minimo,
    /// recusa antes de assinar, em vez de deixar a rede recusar e cobrar a taxa.
    func plan(_ request: TradeRequest, quote: TradeQuote) async throws -> SigningPlan {
        let (sell, buy) = try pair(request.chain, request.sell, request.buy)
        try TradeMath.requireSlippage(request.slippageBasisPoints)
        try TradeMath.requireCurrent(quote, for: request)
        let source = try StellarEngineSupport.source(request.account)
        do {
            async let owner = reader.ownerAccount(source.account)
            async let networkState = reader.networkState()
            async let fresh = reader.quoteStrictSendOnBoth(send: sell, amount: request.amountIn, receive: buy, allowedPath: Self.allowedPath)
            async let market = MarketReference.reference(amountIn: request.amountIn, sell: request.sell, buy: request.buy, oracle: prices)
            let network = try await networkState
            guard let account = try await owner else { throw SendEngineError.message(StellarEngineSupport.accountMissing) }
            guard let route = Self.higher(try await fresh), route.receiveAmount >= quote.minimumOut else {
                throw SendEngineError.message(TradeMath.priceMoved)
            }
            let context = StellarPlanContext(
                walletID: request.walletID, source: source, account: account, network: network,
                allowedAssets: StellarEngineSupport.allowedAssets
            )
            // O planejador confere a rota contra a lista e a cotacao contra a referencia.
            let plan = try StellarPlanner.planSwap(
                send: sell, amount: request.amountIn, receive: buy, quotedReceive: quote.expectedOut,
                slippageBasisPoints: UInt32(request.slippageBasisPoints), path: route.path, reference: await market, context: context
            )
            guard let swap = Self.swap(in: plan), swap.sendAsset == sell, swap.sendAmount == request.amountIn,
                  swap.destAsset == buy, swap.destination == StellarMuxedAccount(account: source.account),
                  swap.destMin == quote.minimumOut
            else { throw SendEngineError.message(TradeMath.priceMoved) }
            return plan
        } catch {
            throw StellarEngineSupport.translate(error)
        }
    }

    /// Oferta de venda no livro: entrega `amountIn`, recebe no minimo `minimumOut`. A
    /// Stellar nao expira ofertas, entao `validFor` nao tem onde ir; a revisao diz isso.
    func planLimitOrder(_ request: LimitOrderRequest) async throws -> SigningPlan {
        let (sell, buy) = try pair(request.chain, request.sell, request.buy)
        let source = try StellarEngineSupport.source(request.account)
        do {
            async let owner = reader.ownerAccount(source.account)
            async let networkState = reader.networkState()
            let network = try await networkState
            guard let account = try await owner else { throw SendEngineError.message(StellarEngineSupport.accountMissing) }
            let context = StellarPlanContext(
                walletID: request.walletID, source: source, account: account, network: network,
                allowedAssets: StellarEngineSupport.allowedAssets
            )
            return try StellarPlanner.planLimitOrder(
                sell: sell, amount: request.amountIn, buy: buy, minimumReceive: request.minimumOut, context: context
            )
        } catch {
            throw StellarEngineSupport.translate(error)
        }
    }

    // MARK: Ordens abertas

    /// As ofertas abertas da conta nas duas Horizons, juntas. Na Stellar a oferta nao vence.
    func openOrders(account: DerivedAccount) async throws -> [OpenOrder] {
        let source = try StellarEngineSupport.source(account)
        do {
            return try await reader.offersOnBoth(source.account).compactMap { entry in
                Self.openOrder(entry.offer, sources: entry.sources)
            }
        } catch {
            throw StellarEngineSupport.translate(error)
        }
    }

    static func openOrder(_ offer: StellarOpenOffer, sources: Int) -> OpenOrder? {
        guard offer.priceNumerator > 0, offer.priceDenominator > 0 else { return nil }
        // O minimo pelo que falta: quantidade x n/d, para baixo, como a rede executa.
        let minimum = offer.amount * BigUInt(UInt64(offer.priceNumerator)) / BigUInt(UInt64(offer.priceDenominator))
        return OpenOrder(
            id: String(offer.id), chain: .stellar, sellAssetID: assetID(offer.selling), buyAssetID: assetID(offer.buying),
            remainingSell: offer.amount, minimumBuy: minimum, expiresAt: nil, sources: sources, cancellations: [.onchain]
        )
    }

    /// O `Asset.id` de um ativo da Stellar (a Stellar sempre conta 7 casas).
    static func assetID(_ asset: StellarAsset) -> String {
        guard let issuer = asset.issuer else { return Asset.native(.stellar).id }
        return "\(Chain.stellar.id):\(asset.code):\(issuer.address)"
    }

    /// `ManageSellOffer` com quantidade zero, com os ativos da oferta como as Horizons a
    /// mostram agora, nunca como a tela mandou.
    func planCancel(
        _ order: OpenOrder, walletID: UUID, account: DerivedAccount, via: OpenOrder.Cancellation, nonceQueue: PendingNonceQueue?
    ) async throws -> SigningPlan {
        guard via == .onchain, order.chain == .stellar, let offerID = Int64(order.id) else {
            throw SendEngineError.message("Esta oferta não é da Stellar.")
        }
        let source = try StellarEngineSupport.source(account)
        do {
            async let offers = reader.offersOnBoth(source.account)
            async let owner = reader.ownerAccount(source.account)
            async let networkState = reader.networkState()
            guard let offer = try await offers.first(where: { $0.offer.id == offerID })?.offer else {
                throw SendEngineError.message("Esta oferta não está mais aberta: já executou ou foi cancelada.")
            }
            guard let state = try await owner else { throw SendEngineError.message(StellarEngineSupport.accountMissing) }
            let context = StellarPlanContext(
                walletID: walletID, source: source, account: state, network: try await networkState,
                allowedAssets: StellarEngineSupport.allowedAssets
            )
            return try StellarPlanner.planCancelOrder(offerID: offerID, selling: offer.selling, buying: offer.buying, context: context)
        } catch {
            throw StellarEngineSupport.translate(error)
        }
    }

    // MARK: Transmissao

    func submit(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String] {
        guard plan.chain == .stellar, !signed.isEmpty, signed.count == plan.transactions.count else {
            throw SendEngineError.message(NetworkFailureText.inconsistent)
        }
        var ids: [String] = []
        for transaction in signed {
            ids.append(try await StellarEngineSupport.broadcast(transaction, reader: reader))
        }
        return ids
    }

    // MARK: Apoio

    struct Swap: Equatable {
        let sendAsset: StellarAsset
        let sendAmount: BigUInt
        let destination: StellarMuxedAccount
        let destAsset: StellarAsset
        let destMin: BigUInt
    }

    /// O path payment decodificado da transacao do plano.
    static func swap(in plan: SigningPlan) -> Swap? {
        guard plan.transactions.count == 1, let transaction = plan.transactions.first as? StellarTransaction else { return nil }
        let payments: [Swap] = transaction.tx.operations.compactMap { operation in
            guard case .pathPaymentStrictSend(let sendAsset, let sendAmount, let destination, let destAsset, let destMin, _) = operation.body,
                  sendAmount > 0, destMin > 0
            else { return nil }
            return Swap(
                sendAsset: sendAsset, sendAmount: BigUInt(UInt64(sendAmount)), destination: destination,
                destAsset: destAsset, destMin: BigUInt(UInt64(destMin))
            )
        }
        return payments.count == 1 ? payments[0] : nil
    }

    private func pair(_ chain: Chain, _ sellAsset: Asset, _ buyAsset: Asset) throws -> (StellarAsset, StellarAsset) {
        guard chain == .stellar else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
        let sell = try StellarEngineSupport.stellar(sellAsset)
        let buy = try StellarEngineSupport.stellar(buyAsset)
        guard sell != buy else { throw SendEngineError.message(StellarPlanError.sameAsset.reason) }
        return (sell, buy)
    }

    static func noRoute(_ request: TradeRequest) -> String {
        "Nenhuma rota troca \(request.sell.symbol) por \(request.buy.symbol) na Stellar agora. Tente um valor menor."
    }
}
