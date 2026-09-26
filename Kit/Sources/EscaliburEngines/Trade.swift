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

    public init(walletID: UUID, chain: Chain, account: DerivedAccount, sell: Asset, buy: Asset, amountIn: BigUInt, slippageBasisPoints: Int) {
        self.walletID = walletID
        self.chain = chain
        self.account = account
        self.sell = sell
        self.buy = buy
        self.amountIn = amountIn
        self.slippageBasisPoints = slippageBasisPoints
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
    public let validFor: TimeInterval

    public init(walletID: UUID, chain: Chain, account: DerivedAccount, sell: Asset, buy: Asset, amountIn: BigUInt, minimumOut: BigUInt, validFor: TimeInterval) {
        self.walletID = walletID
        self.chain = chain
        self.account = account
        self.sell = sell
        self.buy = buy
        self.amountIn = amountIn
        self.minimumOut = minimumOut
        self.validFor = validFor
    }
}

/// O motor de troca de uma rede: cotar entre provedores, montar o plano validado,
/// transmitir. Ordens limite quando a rede tem protocolo nao custodial para elas.
public protocol TradeEngine: Sendable {
    func quote(_ request: TradeRequest) async throws -> TradeQuote
    func plan(_ request: TradeRequest, quote: TradeQuote) async throws -> SigningPlan
    func planLimitOrder(_ request: LimitOrderRequest) async throws -> SigningPlan
    func submit(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String]
    var supportsLimitOrders: Bool { get }
    /// Onde fica o dinheiro enquanto a ordem espera, dito como fato.
    var limitCustodyNote: String { get }
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
