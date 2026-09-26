import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation

/// Trocar e ordem limite na DEX nativa do XRP Ledger, entre o XRP e os tokens da lista
/// curada (`TokenRegistry`).
///
/// Troca: um `OfferCreate` com tfSell e tfFillOrKill. O dono entrega exatamente o valor
/// de entrada (TakerGets) e recebe pelo menos o minimo (TakerPays), ou nada acontece:
/// quem garante o minimo e a rede, pelas marcas e valores gravados na oferta, nao a
/// cotacao. A cotacao sai do livro de ofertas lido em dois servidores no mesmo ledger.
///
/// Ordem limite: o mesmo `OfferCreate`, so com tfSell, que fica no livro ate executar,
/// vencer (`Expiration`) ou ser cancelado.
///
/// Se a conta ainda nao aceita o token comprado, o plano leva antes um `TrustSet` do
/// planejador, na Sequence anterior a da oferta. Nada e assinado aqui.
struct XRPLTradeEngine: TradeEngine {
    let reader: XRPLReader
    /// Os tokens do XRP Ledger que a troca aceita.
    let tokens: [Asset]

    /// Sem token curado nao ha par para trocar, e a rede fica fora da aba Trocar.
    init?(reader: XRPLReader = .shared, tokens: [Asset] = XRPLEngineSupport.registryAssets) {
        let usable = tokens.filter { XRPLEngineSupport.curated($0) != nil }
        guard !usable.isEmpty else { return nil }
        self.reader = reader
        self.tokens = usable
    }

    var curated: [XRPLCuratedAsset] { tokens.compactMap(XRPLEngineSupport.curated) }

    var supportsLimitOrders: Bool { true }

    var limitCustodyNote: String {
        "O valor fica na sua conta, reservado pela oferta, até executar, vencer ou você cancelar. Enquanto a oferta estiver no livro, a rede prende a reserva de um objeto em XRP."
    }

    static let provider = "DEX do XRP Ledger"
    /// A troca e tudo ou nada na hora; o `Expiration` so existe porque a oferta sempre
    /// leva um. O `LastLedgerSequence` (uns 80 segundos) vence antes.
    static let swapExpiration: TimeInterval = 5 * 60
    /// Limite da linha de confianca que a troca abre: um trilhao de unidades, na pratica
    /// sem teto para um token de valor unitario.
    static let trustLimit = "1000000000000"

    // MARK: Cotacao

    func quote(_ request: TradeRequest) async throws -> TradeQuote {
        let (sell, buy) = try sides(request.chain, request.sell, request.buy)
        try TradeMath.requireSlippage(request.slippageBasisPoints)
        guard !request.amountIn.isZero else { throw SendEngineError.message("Digite um valor maior que zero.") }
        do {
            let offers = try await reader.bookOffers(gets: buy.book, pays: sell.book, limit: XRPLReader.maxBookOffers)
            guard let fill = XRPLBookFill.fill(offers, amountIn: request.amountIn, sell: sell, buy: buy) else {
                throw SendEngineError.message(
                    "O livro de ofertas de \(request.sell.symbol) por \(request.buy.symbol) não cobre este valor agora. Tente um valor menor."
                )
            }
            let minimum = TradeMath.minimumOut(fill.out, slippageBasisPoints: request.slippageBasisPoints)
            guard !minimum.isZero else { throw SendEngineError.message("Com esta tolerância o mínimo a receber seria zero.") }
            return TradeQuote(
                sell: request.sell, buy: request.buy, amountIn: request.amountIn,
                expectedOut: fill.out, minimumOut: minimum,
                priceImpactPercent: TradeMath.impactPercent(
                    amountIn: request.amountIn, out: fill.out, referenceIn: fill.bestPays, referenceOut: fill.bestGets
                ),
                networkFeeFiat: nil,
                providerFeeNote: "Sem taxa de provedor: a troca acontece no livro de ofertas do XRP Ledger. O emissor do token pode cobrar taxa de transferência.",
                legs: [.init(provider: Self.provider, fraction: 1, amountIn: request.amountIn, expectedOut: fill.out)],
                alternatives: [], providersCompared: 1, needsApproval: false,
                expiresAt: Date().addingTimeInterval(TradeMath.quoteLifetime)
            )
        } catch {
            throw XRPLEngineSupport.translate(error)
        }
    }

    // MARK: Planos

    /// A oferta tudo ou nada da cotacao que o dono viu: entrega `amountIn`, recebe no
    /// minimo `quote.minimumOut`, conferidos na transacao montada.
    func plan(_ request: TradeRequest, quote: TradeQuote) async throws -> SigningPlan {
        let (sell, buy) = try sides(request.chain, request.sell, request.buy)
        try TradeMath.requireSlippage(request.slippageBasisPoints)
        try TradeMath.requireCurrent(quote, for: request)
        try XRPLEngineSupport.owner(request.account)
        let give = EngineFormat.amount(request.amountIn, decimals: request.sell.decimals, symbol: request.sell.symbol)
        return try await offerPlan(
            walletID: request.walletID, account: request.account, sell: sell, buy: buy, give: request.amountIn, receive: quote.minimumOut,
            expiration: Date().addingTimeInterval(Self.swapExpiration), timeInForce: .fillOrKill,
            kind: .swap, title: "Trocar \(give) por \(request.buy.symbol)"
        )
    }

    /// Oferta que fica no livro: entrega `amountIn`, recebe no minimo `minimumOut`
    /// (calculado pelo app a partir do preco digitado), ate `validFor`.
    func planLimitOrder(_ request: LimitOrderRequest) async throws -> SigningPlan {
        let (sell, buy) = try sides(request.chain, request.sell, request.buy)
        try XRPLEngineSupport.owner(request.account)
        return try await offerPlan(
            walletID: request.walletID, account: request.account, sell: sell, buy: buy, give: request.amountIn, receive: request.minimumOut,
            expiration: Date().addingTimeInterval(request.validFor), timeInForce: .goodTilExpiration,
            kind: .limitOrder, title: nil
        )
    }

    /// Le a conta, o ledger e as linhas de confianca dos dois lados e monta a oferta,
    /// com o `TrustSet` antes quando a conta ainda nao aceita o token comprado.
    private func offerPlan(
        walletID: UUID, account owner: DerivedAccount, sell: XRPLTradeSide, buy: XRPLTradeSide, give: BigUInt, receive: BigUInt,
        expiration: Date, timeInForce: XRPLTimeInForce, kind: PlanReview.Kind, title: String?
    ) async throws -> SigningPlan {
        do {
            async let ledgerState = reader.ledgerState()
            async let accountState = reader.accountState(address: owner.address)
            async let sellLine = line(sell, account: owner.address)
            async let buyLine = line(buy, account: owner.address)
            let ledger = try await ledgerState
            var account = try await accountState
            if !sell.isXRP {
                // O planejador confere a reserva e o XRP; o saldo do token vendido e daqui.
                guard let line = try await sellLine,
                      let held = XRPLUnits.units(line.balance, decimals: sell.asset.decimals, roundingUp: false), held >= give
                else { throw SendEngineError.message("Saldo de \(sell.asset.symbol) insuficiente para esta ordem.") }
            }
            let boughtLine = try await buyLine
            let needsTrustline = !buy.isXRP && boughtLine == nil

            var plans: [SigningPlan] = []
            if needsTrustline, let token = buy.curated {
                let trust = try XRPLPlanner.planTrustline(
                    XRPLTrustlineIntent(currency: token.currency, issuer: token.issuer, limit: Self.trustLimit),
                    signer: try .init(path: owner.path, publicKey: owner.publicKey), account: account, ledger: ledger,
                    curated: curated, walletID: walletID
                )
                account = try XRPLPlanComposer.stateAfter(trust, account: account)
                plans.append(trust)
            }
            let offer = try XRPLPlanner.planOffer(
                XRPLOfferIntent(
                    give: sell.offerAsset(give), receiveAtLeast: buy.offerAsset(receive), expiration: expiration,
                    sell: true, passive: false, timeInForce: timeInForce
                ),
                signer: try .init(path: owner.path, publicKey: owner.publicKey), account: account, ledger: ledger,
                curated: curated, walletID: walletID
            )
            try Self.verify(offer, sell: sell, buy: buy, give: give, receive: receive, timeInForce: timeInForce)
            plans.append(offer)

            if plans.count == 1, title == nil { return offer }
            let lead = needsTrustline
                ? [PlanReview.Line("Transações", "2: primeiro aceitar \(buy.asset.symbol), depois a \(kind == .swap ? "troca" : "ordem")")]
                : []
            return try XRPLPlanComposer.sequence(plans, kind: kind, title: title ?? offer.review.title, lead: lead)
        } catch {
            throw XRPLEngineSupport.translate(error)
        }
    }

    /// A oferta montada entrega exatamente o pedido, pede exatamente o minimo e so leva
    /// as marcas esperadas.
    static func verify(
        _ plan: SigningPlan, sell: XRPLTradeSide, buy: XRPLTradeSide, give: BigUInt, receive: BigUInt, timeInForce: XRPLTimeInForce
    ) throws {
        let expected: XRPLOfferOptions = timeInForce == .fillOrKill ? [.sell, .fillOrKill] : [.sell]
        guard plan.transactions.count == 1, let transaction = plan.transactions.first as? XRPLTransaction,
              case .offerCreate(let offer) = transaction.body,
              offer.takerGets == (try sell.amount(give)), offer.takerPays == (try buy.amount(receive)), offer.options == expected
        else { throw XRPLPlanError.transaction(.redundant) }
    }

    // MARK: Transmissao

    /// Transmite na ordem do plano. A proxima so sai se a anterior foi aceita pelo
    /// servidor (tesSUCCESS ou na fila): uma linha de confianca que falhou nao deixa a
    /// troca seguir.
    func submit(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String] {
        guard plan.chain == .xrpl, !signed.isEmpty, signed.count == plan.transactions.count else {
            throw SendEngineError.message(NetworkFailureText.inconsistent)
        }
        let ledger: XRPLLedgerState
        do {
            ledger = try await reader.ledgerState()
        } catch {
            throw XRPLEngineSupport.translate(error)
        }
        var ids: [String] = []
        for (index, transaction) in signed.enumerated() {
            let result: (id: String, provisional: String?)
            do {
                result = try await XRPLSendEngine.submit(transaction, validatedLedger: ledger.validatedLedgerIndex, reader: reader)
            } catch let error as SendEngineError where index > 0 {
                throw SendEngineError.message("O primeiro passo foi enviado; o seguinte não saiu. \(error.errorDescription ?? NetworkFailureText.refused)")
            }
            ids.append(result.id)
            if index < signed.count - 1, let provisional = result.provisional, provisional != "tesSUCCESS", provisional != "terQUEUED" {
                throw SendEngineError.message("O primeiro passo entrou na rede e falhou, e só a taxa foi cobrada. O resto não foi enviado.")
            }
        }
        return ids
    }

    // MARK: Apoio

    private func line(_ side: XRPLTradeSide, account: String) async throws -> XRPLTrustLine? {
        guard let token = side.curated else { return nil }
        return try await reader.trustLine(account: account, currency: token.currency, issuer: token.issuer)
    }

    private func sides(_ chain: Chain, _ sellAsset: Asset, _ buyAsset: Asset) throws -> (XRPLTradeSide, XRPLTradeSide) {
        guard chain == .xrpl else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
        let sell = try side(sellAsset)
        let buy = try side(buyAsset)
        guard sell.asset.id != buy.asset.id else { throw SendEngineError.message(XRPLEngineSupport.text(.sameAssetBothSides)) }
        guard !(sell.isXRP && buy.isXRP) else { throw SendEngineError.message(XRPLEngineSupport.text(.xrpBothSides)) }
        return (sell, buy)
    }

    private func side(_ asset: Asset) throws -> XRPLTradeSide {
        if asset == Asset.native(.xrpl) { return XRPLTradeSide(asset: asset, curated: nil) }
        guard tokens.contains(where: { $0.id == asset.id }), let token = XRPLEngineSupport.curated(asset) else {
            throw SendEngineError.message(XRPLEngineSupport.text(.assetNotCurated(currency: asset.symbol, issuer: "")))
        }
        return XRPLTradeSide(asset: asset, curated: token)
    }
}
