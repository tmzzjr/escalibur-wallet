import EscaliburChains
import EscaliburCore
import Foundation

/// A cotacao que a tela mostra, ja validada pelo motor da rede. O que a tela chama
/// de "voce recebe no minimo" e o `minOut` decodificado da transacao, garantido na
/// cadeia, e nao o valor que o provedor anuncia.
public struct TradeQuote: Sendable, Equatable {
    public struct Leg: Sendable, Equatable {
        public let provider: String
        public let fraction: Double
        public let amountIn: BigUInt
        public let expectedOut: BigUInt

        public init(provider: String, fraction: Double, amountIn: BigUInt, expectedOut: BigUInt) {
            self.provider = provider
            self.fraction = fraction
            self.amountIn = amountIn
            self.expectedOut = expectedOut
        }
    }

    public struct Alternative: Sendable, Equatable {
        public let provider: String
        public let out: BigUInt

        public init(provider: String, out: BigUInt) {
            self.provider = provider
            self.out = out
        }
    }

    public let sell: Asset
    public let buy: Asset
    public let amountIn: BigUInt
    public let expectedOut: BigUInt
    public let minimumOut: BigUInt
    public let priceImpactPercent: Double?
    public let networkFeeFiat: Double?
    public let providerFeeNote: String?
    public let legs: [Leg]
    public let alternatives: [Alternative]
    public let providersCompared: Int
    public let needsApproval: Bool
    public let expiresAt: Date

    public init(
        sell: Asset, buy: Asset, amountIn: BigUInt, expectedOut: BigUInt, minimumOut: BigUInt,
        priceImpactPercent: Double?, networkFeeFiat: Double?, providerFeeNote: String?, legs: [Leg],
        alternatives: [Alternative], providersCompared: Int, needsApproval: Bool, expiresAt: Date
    ) {
        self.sell = sell
        self.buy = buy
        self.amountIn = amountIn
        self.expectedOut = expectedOut
        self.minimumOut = minimumOut
        self.priceImpactPercent = priceImpactPercent
        self.networkFeeFiat = networkFeeFiat
        self.providerFeeNote = providerFeeNote
        self.legs = legs
        self.alternatives = alternatives
        self.providersCompared = providersCompared
        self.needsApproval = needsApproval
        self.expiresAt = expiresAt
    }
}

public struct TradeRequest: Sendable {
    public let walletID: UUID
    public let chain: Chain
    public let account: DerivedAccount
    public let sell: Asset
    public let buy: Asset
    public let amountIn: BigUInt
    public let slippageBasisPoints: Int
    /// EVM: a fila local de transacoes desta conta ainda em transito (`PendingNonceQueue`).
    public let nonceQueue: PendingNonceQueue?

    public init(
        walletID: UUID, chain: Chain, account: DerivedAccount, sell: Asset, buy: Asset, amountIn: BigUInt, slippageBasisPoints: Int,
        nonceQueue: PendingNonceQueue? = nil
    ) {
        self.walletID = walletID
        self.chain = chain
        self.account = account
        self.sell = sell
        self.buy = buy
        self.amountIn = amountIn
        self.slippageBasisPoints = slippageBasisPoints
        self.nonceQueue = nonceQueue
    }
}

public struct LimitOrderRequest: Sendable {
    public let walletID: UUID
    public let chain: Chain
    public let account: DerivedAccount
    public let sell: Asset
    public let buy: Asset
    public let amountIn: BigUInt
    /// Quanto o dono recebe, calculado localmente a partir do preco-alvo digitado.
    public let minimumOut: BigUInt
    /// Por quanto tempo a ordem vale. nil: ate o dono cancelar. Na Stellar e no XRP Ledger
    /// a oferta vai sem prazo; na CoW, que exige um, a ordem vale o maximo pratico do
    /// protocolo (`CoWProtocol.untilCancelledValidity`) e a revisao diz isso.
    public let validFor: TimeInterval?
    /// EVM: a fila local de transacoes desta conta ainda em transito (`PendingNonceQueue`).
    public let nonceQueue: PendingNonceQueue?

    public init(
        walletID: UUID, chain: Chain, account: DerivedAccount, sell: Asset, buy: Asset, amountIn: BigUInt, minimumOut: BigUInt,
        validFor: TimeInterval?, nonceQueue: PendingNonceQueue? = nil
    ) {
        self.walletID = walletID
        self.chain = chain
        self.account = account
        self.sell = sell
        self.buy = buy
        self.amountIn = amountIn
        self.minimumOut = minimumOut
        self.validFor = validFor
        self.nonceQueue = nonceQueue
    }
}

/// Uma ordem limite aberta da conta, lida da rede.
public struct OpenOrder: Sendable, Equatable, Identifiable {
    /// Como a ordem pode ser cancelada.
    public enum Cancellation: String, Sendable, Equatable, CaseIterable {
        /// Pedido assinado ao protocolo (CoW), sem taxa de rede. Nao e garantido: um
        /// solver que ja estiver liquidando ainda executa a ordem.
        case offchain
        /// Transacao na cadeia, com taxa de rede. Garantido depois que confirmar.
        case onchain
    }

    /// O identificador na rede: o UID da CoW (hex com `0x`), a Sequence da transacao que
    /// criou a oferta no XRP Ledger, o id da oferta na Stellar.
    public let id: String
    public let chain: Chain
    /// O `Asset.id` do que a ordem vende e do que recebe, e o `Asset` da lista quando o
    /// ativo esta nela (ordem criada fora da carteira pode ser de ativo fora da lista).
    public let sellAssetID: String
    public let buyAssetID: String
    public let sell: Asset?
    public let buy: Asset?
    /// O que ainda falta vender, na menor unidade.
    public let remainingSell: BigUInt
    /// O minimo que a ordem recebe pelo que ainda falta vender, pelo preco gravado.
    public let minimumBuy: BigUInt
    /// Quando a ordem vence sozinha. nil: nao vence, fica ate executar ou ser cancelada.
    public let expiresAt: Date?
    /// Quantas fontes independentes mostraram a ordem (1 onde o protocolo so tem uma API).
    public let sources: Int
    /// Os jeitos de cancelar esta ordem, do preferido para o outro.
    public let cancellations: [Cancellation]

    public init(
        id: String, chain: Chain, sellAssetID: String, buyAssetID: String, remainingSell: BigUInt, minimumBuy: BigUInt,
        expiresAt: Date?, sources: Int, cancellations: [Cancellation]
    ) {
        self.id = id
        self.chain = chain
        self.sellAssetID = sellAssetID
        self.buyAssetID = buyAssetID
        self.sell = Self.listed(sellAssetID, chain: chain)
        self.buy = Self.listed(buyAssetID, chain: chain)
        self.remainingSell = remainingSell
        self.minimumBuy = minimumBuy
        self.expiresAt = expiresAt
        self.sources = sources
        self.cancellations = cancellations
    }

    static func listed(_ id: String, chain: Chain) -> Asset? {
        TokenRegistry.assets(on: chain).first { $0.id == id }
    }
}

/// O motor de troca de uma rede: cotar entre provedores, montar o plano validado,
/// transmitir. Ordens limite quando a rede tem protocolo nao custodial para elas.
public protocol TradeEngine: Sendable {
    func quote(_ request: TradeRequest) async throws -> TradeQuote
    func plan(_ request: TradeRequest, quote: TradeQuote) async throws -> SigningPlan
    func planLimitOrder(_ request: LimitOrderRequest) async throws -> SigningPlan
    /// Transmite qualquer plano deste motor: troca, ordem limite e cancelamento.
    func submit(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String]
    var supportsLimitOrders: Bool { get }
    /// Onde fica o dinheiro enquanto a ordem espera, dito como fato.
    var limitCustodyNote: String { get }

    /// As ordens limite abertas da conta, lidas da rede (das duas fontes quando o leitor
    /// tem duas). Onde nao ha ordem limite, `SendEngineError.unavailable`.
    func openOrders(account: DerivedAccount) async throws -> [OpenOrder]
    /// O plano que cancela a ordem, por um dos jeitos que `order.cancellations` oferece.
    /// O plano sai com `kind == .cancelOrder` e vai para `submit` como os outros.
    /// `nonceQueue`: no EVM, a fila local da conta (o cancelamento na cadeia usa nonce).
    func planCancel(
        _ order: OpenOrder, walletID: UUID, account: DerivedAccount, via: OpenOrder.Cancellation, nonceQueue: PendingNonceQueue?
    ) async throws -> SigningPlan
}

extension TradeEngine {
    public func openOrders(account: DerivedAccount) async throws -> [OpenOrder] {
        throw SendEngineError.unavailable("Ordens limite ainda não estão disponíveis nesta rede.")
    }

    public func planCancel(
        _ order: OpenOrder, walletID: UUID, account: DerivedAccount, via: OpenOrder.Cancellation, nonceQueue: PendingNonceQueue?
    ) async throws -> SigningPlan {
        throw SendEngineError.unavailable("Ordens limite ainda não estão disponíveis nesta rede.")
    }

    /// Cancela pelo jeito escolhido, sem fila local.
    public func planCancel(_ order: OpenOrder, walletID: UUID, account: DerivedAccount, via: OpenOrder.Cancellation) async throws -> SigningPlan {
        try await planCancel(order, walletID: walletID, account: account, via: via, nonceQueue: nil)
    }

    /// Cancela pelo jeito preferido da ordem.
    public func planCancel(_ order: OpenOrder, walletID: UUID, account: DerivedAccount) async throws -> SigningPlan {
        guard let via = order.cancellations.first else { throw SendEngineError.unavailable("Esta ordem não pode ser cancelada pela carteira.") }
        return try await planCancel(order, walletID: walletID, account: account, via: via, nonceQueue: nil)
    }
}

public enum TradeEngines {
    /// As redes com troca nesta versao, na ordem da interface.
    public static var chains: [Chain] { Chain.all.filter { engine(for: $0) != nil } }

    public static func engine(for chain: Chain) -> (any TradeEngine)? {
        switch chain.family {
        case .utxo: return EngineRegistry.utxoTrade(chain)
        case .evm: return EngineRegistry.evmTrade(chain)
        case .solana: return EngineRegistry.solanaTrade(chain)
        case .xrpl: return EngineRegistry.xrplTrade(chain)
        case .stellar: return EngineRegistry.stellarTrade(chain)
        case .tron: return EngineRegistry.tronTrade(chain)
        case .ton: return EngineRegistry.tonTrade(chain)
        case .sui: return EngineRegistry.suiTrade(chain)
        case .cardano: return EngineRegistry.cardanoTrade(chain)
        case .polkadot: return EngineRegistry.polkadotTrade(chain)
        case .near: return EngineRegistry.nearTrade(chain)
        case .aptos: return EngineRegistry.aptosTrade(chain)
        }
    }
}

/// Os degraus de impacto no preco (docs/design/produto-ux.md T1).
public enum PriceImpact: Sendable {
    case normal, visible, confirm, blocked

    public static func level(_ percent: Double?) -> PriceImpact {
        guard let percent else { return .normal }
        switch percent {
        case ..<1: return .normal
        case ..<5: return .visible
        case ..<15: return .confirm
        default: return .blocked
        }
    }
}
