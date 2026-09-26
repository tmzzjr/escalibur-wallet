import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Troca na Solana pela Jupiter (`/swap/v2/build`), com a mensagem montada e
/// conferida no aparelho pelo `SolanaSwapPlanner` (docs/seguranca.md §4.6).
///
/// Cotar ja e montar: a cotacao sai de um rascunho validado (proposta, tabelas lidas
/// de dois RPCs, estado, rota decodificada da mensagem compilada), e o "voce recebe
/// no minimo" e o minimo que a rota compilada garante na cadeia, nunca o numero que
/// a Jupiter anuncia. O plano pede outra proposta, monta, simula e confere tudo de
/// novo, e nao aceita garantir menos que a cotacao mostrou.
///
/// Sem taxa: nem conta de taxa da plataforma nem `platformFeeBps`
/// (`SolanaSwapPlanner.escaliburFeeBps` = 0, conferido nos bytes da rota).
///
/// Ordem limite fica de fora na v1: o Trigger v2 da Jupiter e custodial, e o
/// programa do Trigger v1 tem IDL que nao fecha com os bytes que a API monta
/// (docs/redes/solana.md). Sem decodificador completo, sem assinatura.
struct SolanaTradeEngine: TradeEngine {
    static let shared = SolanaTradeEngine(network: SolanaLiveNetwork(), book: .shared)

    /// Os degraus de `maxAccounts` do `SolanaPlanningService.planSwap`: sem limite e,
    /// se a mensagem nao couber num pacote, rotas com menos contas.
    static let routeAccountLimits: [Int?] = [nil, 40, 28]
    /// Quanto uma cotacao vale para o plano. A tela recota a cada 15 s; 30 s cobre um
    /// ciclo perdido sem deixar o dono decidir sobre preco velho.
    static let quoteLifetime: TimeInterval = 30
    static let provider = "Jupiter"

    let network: any SolanaEngineNetwork
    let book: SolanaTransferBook

    var supportsLimitOrders: Bool { false }

    var limitCustodyNote: String {
        "Ordem limite na Solana ainda não está disponível nesta versão. Nada sai da sua carteira para esperar uma ordem."
    }

    // MARK: Cotacao

    func quote(_ request: TradeRequest) async throws -> TradeQuote {
        do {
            let swap = try SolanaSwapRequest(request)
            let sell = try await verifiedAsset(swap.sell)
            let buy = try await verifiedAsset(swap.buy)
            let intent = SolanaSwapIntent(sell: sell, buy: buy, amountIn: request.amountIn, slippageBps: swap.slippageBps)
            let accounts = try await network.swapAccounts(owner: swap.owner.publicKey, sell: sell, buy: buy)
            let (draft, proposal, state) = try await draft(swap, intent: intent, accounts: accounts)
            let route = draft.route
            let expected = BigUInt(route.quotedOutAmount)
            return TradeQuote(
                sell: request.sell, buy: request.buy, amountIn: BigUInt(route.inAmount), expectedOut: expected,
                minimumOut: BigUInt(route.minimumOut), priceImpactPercent: proposal.priceImpactPercent, networkFeeFiat: nil,
                providerFeeNote: "Sem taxa da Escalibur e sem taxa de plataforma da Jupiter. A taxa dos pools já está no preço.",
                legs: [TradeQuote.Leg(provider: Self.provider, fraction: 1, amountIn: BigUInt(route.inAmount), expectedOut: expected)],
                alternatives: [], providersCompared: 1, needsApproval: false,
                expiresAt: state.fetchedAt.addingTimeInterval(Self.quoteLifetime)
            )
        } catch {
            throw SolanaEngineMessages.map(error, .swap)
        }
    }

    /// O lado da troca lido da rede, conferido contra a lista: token da lista com
    /// outras casas na rede e recusado (a revisao mostraria outro valor).
    func verifiedAsset(_ asset: SolanaEngineAsset) async throws -> SolanaSwapAsset {
        switch asset {
        case .sol:
            return .sol
        case .token(let mint, let listed):
            let read = try await network.swapAsset(mint: mint)
            guard read.mint == mint, !read.isNativeSOL, read.isVerified, Int(read.decimals) == listed.decimals else {
                throw SolanaEngineProblem.tokenNotVerified
            }
            return read
        }
    }

    /// Proposta, tabelas (dois RPCs), estado e rascunho: o mesmo caminho de
    /// `SolanaPlanningService.draft`, aqui com a proposta a mao, porque o impacto no
    /// preco que a tela usa para avisar e bloquear so existe nela. O rascunho passa
    /// pelo `SolanaSwapPlanner.draft` inteiro; nada da proposta e usado sem ele.
    func draft(
        _ swap: SolanaSwapRequest, intent: SolanaSwapIntent, accounts: SolanaSwapAccounts
    ) async throws -> (SolanaSwapDraft, SolanaSwapProposal, SolanaNetworkState) {
        var lastError: Error = SolanaSwapError.plan(.transactionTooLarge(0))
        for maxAccounts in Self.routeAccountLimits {
            let proposal = try await network.swapProposal(
                sellMint: swap.sell.swapMint, buyMint: swap.buy.swapMint, amount: swap.amount, slippageBps: swap.slippageBps,
                taker: swap.owner.publicKey, maxAccounts: maxAccounts
            )
            let tables = try await network.lookupTables(proposal.lookupTableAddresses)
            let writable = proposal.swapInstruction.accounts.filter(\.isWritable).map(\.publicKey)
            let state = try await network.networkState(owner: swap.owner.publicKey, writableAccounts: writable)
            do {
                let draft = try SolanaSwapPlanner.draft(
                    walletID: swap.walletID, owner: swap.owner, intent: intent, proposal: proposal, lookupTables: tables, accounts: accounts,
                    network: state
                )
                return (draft, proposal, state)
            } catch SolanaSwapError.plan(.transactionTooLarge(let size)) {
                lastError = SolanaSwapError.plan(.transactionTooLarge(size))
            }
        }
        throw lastError
    }

    // MARK: Plano

    func plan(_ request: TradeRequest, quote: TradeQuote) async throws -> SigningPlan {
        do {
            let swap = try SolanaSwapRequest(request)
            guard quote.sell == request.sell, quote.buy == request.buy, quote.amountIn == request.amountIn, !quote.minimumOut.isZero else {
                throw SolanaEngineProblem.quoteMismatch
            }
            guard quote.expiresAt > Date() else { throw SolanaEngineProblem.quoteExpired }
            var attempt = 1
            while true {
                do {
                    // Outra proposta, montada, simulada e conferida do zero, presa ao
                    // minimo que a tela mostrou.
                    let plan = try await network.planSwap(
                        walletID: request.walletID, owner: swap.owner, sellMint: swap.sell.swapMint, buyMint: swap.buy.swapMint,
                        amountIn: request.amountIn, slippageBps: swap.slippageBps, minimumOutShown: quote.minimumOut
                    )
                    try Self.check(plan, request: request, swap: swap)
                    await book.planned(plan)
                    return plan
                } catch SolanaSwapError.minimumBelowShown where attempt < Self.planAttempts {
                    attempt += 1
                }
            }
        } catch {
            throw SolanaEngineMessages.map(error, .swap)
        }
    }

    /// Propostas pedidas para o plano quando a unica recusa e o minimo abaixo do
    /// mostrado. O preco oscila para os dois lados de um bloco para outro, e conferido
    /// ao vivo: a proposta pedida segundos depois da cotacao garante, com frequencia,
    /// uma fracao a menos. Outra proposta costuma voltar ao minimo da tela; o plano
    /// nunca aceita menos que ele. Cada tentativa espera a vez na Jupiter (2 s).
    static let planAttempts = 3

    /// O plano que voltou e o da troca pedida: rede, carteira, troca, uma transacao do
    /// dono no caminho dele; o valor que sai aparece na revisao com as casas da lista
    /// compilada (as do mint vendido vem da rede, e a revisao nao pode mostrar menos
    /// do que sai); token comprado fora da lista e impacto no degrau de bloqueio
    /// recusam.
    static func check(_ plan: SigningPlan, request: TradeRequest, swap: SolanaSwapRequest) throws {
        guard plan.chain == .solana, plan.walletID == request.walletID, plan.review.kind == .swap,
              plan.transactions.count == 1, let transaction = plan.transactions.first as? SolanaTransaction,
              transaction.signer == swap.owner.publicKey, transaction.signerPath == swap.owner.path
        else { throw SolanaEngineProblem.planMismatch }
        let sold = SolanaAmountText.format(request.amountIn, decimals: swap.sell.decimals, symbol: swap.sell.symbol)
        guard plan.review.lines.first(where: { $0.label == soldLineLabel })?.value == sold else { throw SolanaEngineProblem.planMismatch }
        for warning in plan.review.warnings {
            switch warning {
            case .unverifiedToken: throw SolanaEngineProblem.tokenNotVerified
            case .highPriceImpact(let percent) where PriceImpact.level(percent) == .blocked: throw SolanaEngineProblem.priceImpactTooHigh
            default: continue
            }
        }
    }

    /// O rotulo da linha do valor vendido na revisao (`SolanaSwapPlanner.makeReview`).
    static let soldLineLabel = "Sai"

    func planLimitOrder(_ request: LimitOrderRequest) async throws -> SigningPlan {
        throw SolanaEngineMessages.map(SolanaEngineProblem.limitOrdersUnavailable, .swap)
    }

    // MARK: Transmissao

    /// Transmite os bytes assinados do plano. A mensagem assinada tem de ser a do
    /// plano, byte a byte; o prazo do acompanhamento e o do proprio plano.
    func submit(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String] {
        do {
            guard plan.chain == .solana, plan.review.kind == .swap, signed.count == 1, plan.transactions.count == 1,
                  let transaction = plan.transactions.first as? SolanaTransaction
            else { throw SolanaEngineProblem.signedMismatch }
            let envelope = try SolanaSignedEnvelope(signed[0])
            guard envelope.messageBytes == transaction.messageBytes, envelope.signer == transaction.signer else {
                throw SolanaEngineProblem.signedMismatch
            }
            let id = try await SolanaTransfers.transmit(
                signed[0], envelope: envelope, network: network, book: book, lastValidBlockHeight: transaction.lastValidBlockHeight
            )
            return [id]
        } catch {
            throw SolanaEngineMessages.map(error, .broadcast)
        }
    }
}

/// O pedido de troca, conferido antes de qualquer leitura: rede, conta do dono,
/// ativos da lista (SOL ou token), valor que cabe em u64 e tolerancia dentro do teto.
struct SolanaSwapRequest {
    let walletID: UUID
    let owner: SolanaOwner
    let sell: SolanaEngineAsset
    let buy: SolanaEngineAsset
    let amount: UInt64
    let slippageBps: UInt16

    init(_ request: TradeRequest) throws {
        try SolanaEngineGuard.chain(request.chain)
        owner = try SolanaEngineGuard.owner(request.account)
        sell = try SolanaEngineAsset(request.sell)
        buy = try SolanaEngineAsset(request.buy)
        guard sell != buy else { throw SolanaSwapError.sameAsset }
        guard !request.amountIn.isZero else { throw SolanaSwapError.zeroAmount }
        guard let amount = request.amountIn.uint64 else { throw SolanaEngineProblem.amountOutOfRange }
        guard (0...Int(SolanaSwapPlanner.maxSlippageBps)).contains(request.slippageBasisPoints) else {
            throw SolanaEngineProblem.slippageOutOfRange
        }
        walletID = request.walletID
        self.amount = amount
        slippageBps = UInt16(request.slippageBasisPoints)
    }
}
