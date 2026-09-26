import EscaliburCore
import Foundation

// A comparacao liquida entre provedores (docs/blockchain.md 3.2).
//
//   liquido = garantido - gas x preco - taxa L1 - approval (se faltar)
//
// - O garantido e o `minOut` decodificado da calldata, nunca o `expectedOut` anunciado.
// - O gas de todos e convertido pelo **mesmo** preco de gas e pela **mesma** taxa
//   nativo -> token comprado: quem compara nao pode ter duas fontes de preco.
// - Fees que o provedor cobra fora da cotacao ja estao no garantido: a taxa da LI.FI
//   sai antes da troca e reduz o `minAmountOut`; Kyber e Velora nao cobram na calldata
//   sem parceiro; a De¹ embute na rota.

/// Uma quantia com sinal: o liquido pode ficar negativo quando o gas passa do garantido.
public struct TradeSignedAmount: Sendable, Equatable, Comparable {
    public let magnitude: BigUInt
    public let isNegative: Bool

    public init(_ magnitude: BigUInt, negative: Bool = false) {
        self.magnitude = magnitude
        self.isNegative = negative && !magnitude.isZero
    }

    /// a - b.
    public static func difference(_ a: BigUInt, _ b: BigUInt) -> TradeSignedAmount {
        a >= b ? TradeSignedAmount(a - b) : TradeSignedAmount(b - a, negative: true)
    }

    public static func < (lhs: TradeSignedAmount, rhs: TradeSignedAmount) -> Bool {
        switch (lhs.isNegative, rhs.isNegative) {
        case (true, false): return true
        case (false, true): return false
        case (false, false): return lhs.magnitude < rhs.magnitude
        case (true, true): return lhs.magnitude > rhs.magnitude
        }
    }

    /// O valor se nao for negativo.
    public var nonNegative: BigUInt? { isNegative ? nil : magnitude }
}

/// Uma razao exata: `x * numerator / denominator`.
public struct TradeRate: Sendable, Equatable {
    public let numerator: BigUInt
    public let denominator: BigUInt

    public init(numerator: BigUInt, denominator: BigUInt) {
        self.numerator = numerator
        self.denominator = denominator.isZero ? 1 : denominator
    }

    public static let identity = TradeRate(numerator: 1, denominator: 1)

    public func apply(_ value: BigUInt) -> BigUInt { value * numerator / denominator }

    /// Quanto de `buy` vale 1 wei do nativo, pelos precos em dolar do oraculo.
    public static func nativeToBuy(chain: Chain, buy: TradeAsset, nativePriceUSD: String, buyPriceUSD: String) -> TradeRate? {
        if buy.isNative { return .identity }
        guard let native = TradeDecimal(nativePriceUSD), let price = TradeDecimal(buyPriceUSD), !price.isZero else { return nil }
        return TradeRate(
            numerator: native.mantissa * BigUInt.power(of: 10, price.scale + buy.decimals),
            denominator: price.mantissa * BigUInt.power(of: 10, native.scale + chain.nativeDecimals)
        )
    }
}

/// O custo de executar, igual para todos os provedores.
public struct TradeCostModel: Sendable, Equatable {
    /// Gas medio de um swap quando o provedor nao informa.
    public static let defaultSwapGas: UInt64 = 350_000
    /// Faixa aceita para o gas informado pelo provedor: menos que isso e otimismo que
    /// so serve para ganhar a disputa.
    public static let swapGasRange: ClosedRange<UInt64> = 80_000...5_000_000

    /// Preco do gas em wei: baseFee + gorjeta, o mesmo para todos.
    public let gasPriceWei: BigUInt
    /// OP e Base: taxa L1 por transacao, em wei.
    public let l1FeePerTransactionWei: BigUInt
    /// Conversao de wei para o token comprado.
    public let nativeToBuy: TradeRate
    /// Gas de um approve.
    public let approveGas: UInt64
    /// Allowance atual do dono por spender. Spender ausente conta como zero.
    public let allowances: [EVMAddress: BigUInt]

    public init(gasPriceWei: BigUInt, l1FeePerTransactionWei: BigUInt = 0, nativeToBuy: TradeRate,
                approveGas: UInt64 = 60_000, allowances: [EVMAddress: BigUInt] = [:]) {
        self.gasPriceWei = gasPriceWei
        self.l1FeePerTransactionWei = l1FeePerTransactionWei
        self.nativeToBuy = nativeToBuy
        self.approveGas = approveGas
        self.allowances = allowances
    }

    /// Sem custo: o ranking vira so o garantido.
    public static let free = TradeCostModel(gasPriceWei: 0, nativeToBuy: .identity)
}

/// Uma cotacao validada com o seu liquido.
public struct TradeCandidate: Sendable, Equatable {
    public let quote: ValidatedTradeQuote
    /// Gas da troca, taxa L1 e approve se faltar, em unidades do token comprado.
    public let costInBuy: BigUInt
    public let netOut: TradeSignedAmount
    public let needsApproval: Bool
}

public enum TradeRanking {
    /// O custo fixo de executar uma cotacao, em unidades do token comprado.
    public static func cost(of quote: ValidatedTradeQuote, costs: TradeCostModel) -> (inBuy: BigUInt, needsApproval: Bool) {
        let intent = quote.intent
        let reported = quote.gasEstimate ?? TradeCostModel.defaultSwapGas
        let swapGas = min(max(reported, TradeCostModel.swapGasRange.lowerBound), TradeCostModel.swapGasRange.upperBound)
        var wei = BigUInt(swapGas) * costs.gasPriceWei + costs.l1FeePerTransactionWei
        var needsApproval = false
        if case .token(let token) = intent.sell {
            let current = costs.allowances[quote.spender] ?? 0
            if current < intent.amountIn {
                needsApproval = true
                let count: UInt64 = EVMPlanner.requiresZeroFirstApproval(token) && !current.isZero ? 2 : 1
                wei = wei + BigUInt(costs.approveGas * count) * costs.gasPriceWei + costs.l1FeePerTransactionWei * BigUInt(count)
            }
        }
        return (costs.nativeToBuy.apply(wei), needsApproval)
    }

    /// Ordena pelo liquido do garantido, do melhor para o pior. Empate: maior garantido,
    /// depois a ordem fixa dos provedores (nada de aleatorio na tela).
    public static func rank(_ quotes: [ValidatedTradeQuote], costs: TradeCostModel) -> [TradeCandidate] {
        let order = Dictionary(uniqueKeysWithValues: TradeProvider.allCases.enumerated().map { ($1, $0) })
        return quotes.map { quote in
            let (cost, approval) = cost(of: quote, costs: costs)
            return TradeCandidate(quote: quote, costInBuy: cost, netOut: .difference(quote.guaranteedOut, cost), needsApproval: approval)
        }
        .sorted { a, b in
            if a.netOut != b.netOut { return a.netOut > b.netOut }
            if a.quote.guaranteedOut != b.quote.guaranteedOut { return a.quote.guaranteedOut > b.quote.guaranteedOut }
            return (order[a.quote.provider] ?? 0) < (order[b.quote.provider] ?? 0)
        }
    }
}
