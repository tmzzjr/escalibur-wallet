import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation

/// A cotacao que a tela mostra, ja validada pelo motor da rede. O que a tela chama
/// de "voce recebe no minimo" e o `minOut` decodificado da transacao, garantido na
/// cadeia, e nao o valor que o provedor anuncia.
struct TradeQuote: Sendable, Equatable {
    struct Leg: Sendable, Equatable {
        let provider: String
        let fraction: Double
        let amountIn: BigUInt
        let expectedOut: BigUInt
    }

    let sell: Asset
    let buy: Asset
    let amountIn: BigUInt
    let expectedOut: BigUInt
    let minimumOut: BigUInt
    let priceImpactPercent: Double?
    let networkFeeFiat: Double?
    let providerFeeNote: String?
    let legs: [Leg]
    let alternatives: [(provider: String, out: BigUInt)]
    let providersCompared: Int
    let needsApproval: Bool
    let expiresAt: Date

    static func == (a: TradeQuote, b: TradeQuote) -> Bool {
        a.expectedOut == b.expectedOut && a.minimumOut == b.minimumOut && a.legs == b.legs && a.expiresAt == b.expiresAt
    }
}

struct TradeRequest: Sendable {
    let walletID: UUID
    let chain: Chain
    let account: DerivedAccount
    let sell: Asset
    let buy: Asset
    let amountIn: BigUInt
    let slippageBasisPoints: Int
}

struct LimitOrderRequest: Sendable {
    let walletID: UUID
    let chain: Chain
    let account: DerivedAccount
    let sell: Asset
    let buy: Asset
    let amountIn: BigUInt
    /// Quanto o dono recebe, calculado localmente a partir do preco-alvo digitado.
    let minimumOut: BigUInt
    let validFor: TimeInterval
}

/// O motor de troca de uma rede: cotar entre provedores, montar o plano validado,
/// transmitir. Ordens limite quando a rede tem protocolo nao custodial para elas.
protocol TradeEngine: Sendable {
    func quote(_ request: TradeRequest) async throws -> TradeQuote
    func plan(_ request: TradeRequest, quote: TradeQuote) async throws -> SigningPlan
    func planLimitOrder(_ request: LimitOrderRequest) async throws -> SigningPlan
    func submit(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> [String]
    var supportsLimitOrders: Bool { get }
    /// Onde fica o dinheiro enquanto a ordem espera, dito como fato.
    var limitCustodyNote: String { get }
}

enum TradeEngines {
    /// As redes com troca nesta versao, na ordem da interface.
    static var chains: [Chain] { Chain.all.filter { engine(for: $0) != nil } }

    static func engine(for chain: Chain) -> (any TradeEngine)? {
        nil
    }
}

/// Os degraus de impacto no preco (docs/design/produto-ux.md T1).
enum PriceImpact {
    case normal, visible, confirm, blocked

    static func level(_ percent: Double?) -> PriceImpact {
        guard let percent else { return .normal }
        switch percent {
        case ..<1: return .normal
        case ..<5: return .visible
        case ..<15: return .confirm
        default: return .blocked
        }
    }
}
