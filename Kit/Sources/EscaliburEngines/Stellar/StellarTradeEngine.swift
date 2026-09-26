import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Trocar e ordem limite na DEX nativa da Stellar, entre o XLM e os ativos da lista
/// curada.
///
/// Troca: `PathPaymentStrictSend` para a propria conta. A rota e cotada pela Horizon; o
/// que protege o dono e o `destMin`, que o `StellarPlanner` grava na transacao a partir
/// da cotacao e da tolerancia, e que a rede garante seja qual for a rota. Se a conta
/// ainda nao aceita o ativo comprado, o `ChangeTrust` vai na mesma transacao.
///
/// Ordem limite: `ManageSellOffer`, com o preco calculado localmente do minimo digitado.
struct StellarTradeEngine: TradeEngine {
    let reader: StellarReader

    init(reader: StellarReader = StellarReader()) {
        self.reader = reader
    }

    var supportsLimitOrders: Bool { true }

    var limitCustodyNote: String {
        "O valor fica na sua conta, reservado pela oferta, até executar ou você cancelar. A Stellar não tem prazo para ofertas: ela fica aberta até executar ou ser cancelada, e prende uma reserva de XLM enquanto isso."
    }

    static let provider = "DEX da Stellar"

    // MARK: Cotacao

    /// A melhor rota strict send da Horizon, e o minimo que a transacao vai garantir.
    ///
    /// O impacto no preco compara com uma cotacao de um milesimo do valor no mesmo par.
    func quote(_ request: TradeRequest) async throws -> TradeQuote {
        let (sell, buy) = try pair(request.chain, request.sell, request.buy)
        try TradeMath.requireSlippage(request.slippageBasisPoints)
        guard !request.amountIn.isZero else { throw SendEngineError.message("Digite um valor maior que zero.") }
        let referenceIn = request.amountIn / BigUInt(1_000)
        do {
            async let main = reader.quoteStrictSend(send: sell, amount: request.amountIn, receive: buy)
            async let small = referenceQuote(send: sell, amount: referenceIn, receive: buy)
            guard let route = try await main else { throw SendEngineError.message(Self.noRoute(request)) }
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
    private func referenceQuote(send: StellarAsset, amount: BigUInt, receive: StellarAsset) async -> StellarPathQuote? {
        guard !amount.isZero else { return nil }
        return try? await reader.quoteStrictSend(send: send, amount: amount, receive: receive)
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
            async let fresh = reader.quoteStrictSend(send: sell, amount: request.amountIn, receive: buy)
            let network = try await networkState
            guard let account = try await owner else { throw SendEngineError.message(StellarEngineSupport.accountMissing) }
            guard let route = try await fresh, route.receiveAmount >= quote.minimumOut else {
                throw SendEngineError.message(TradeMath.priceMoved)
            }
            let context = StellarPlanContext(
                walletID: request.walletID, source: source, account: account, network: network,
                allowedAssets: StellarEngineSupport.allowedAssets
            )
            let plan = try StellarPlanner.planSwap(
                send: sell, amount: request.amountIn, receive: buy, quotedReceive: quote.expectedOut,
                slippageBasisPoints: UInt32(request.slippageBasisPoints), path: route.path, context: context
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
