import EscaliburCore
import Foundation

// O que as APIs da ponte respondem, ja conferido pelos clientes de EscaliburNetwork
// (CircleIrisClient, AcrossClient). Mora aqui porque o validador da ponte, que monta a
// calldata, precisa ler sem depender da rede.

/// As taxas de uma rota, por limiar de finalidade.
public struct CCTPFees: Sendable, Equatable {
    public struct Level: Sendable, Equatable {
        /// A taxa do protocolo em bps, exata (1.3 vira mantissa 13, escala 1).
        public let protocolBps: TradeDecimal
        /// A taxa de encaminhamento na faixa alta, em unidades de USDC (6 casas).
        public let forwardFee: BigUInt

        public init(protocolBps: TradeDecimal, forwardFee: BigUInt) {
            self.protocolBps = protocolBps
            self.forwardFee = forwardFee
        }
    }

    public let fast: Level?
    public let standard: Level?

    public init(fast: Level?, standard: Level?) {
        self.fast = fast
        self.standard = standard
    }

    /// O teto que vai na queima: a taxa do protocolo sobre o valor, arredondada para
    /// cima, mais a taxa de encaminhamento.
    public static func maxFee(amount: BigUInt, level: Level) -> BigUInt {
        let scale = BigUInt.power(of: 10, level.protocolBps.scale)
        let denominator = BigUInt(10_000) * scale
        let product = amount * level.protocolBps.mantissa
        let protocolFee = (product + denominator - 1) / denominator
        return protocolFee + level.forwardFee
    }
}

/// A taxa e os prazos que o Across sugere para um deposito, ja conferidos.
public struct AcrossQuote: Sendable, Equatable {
    public let inputAmount: BigUInt
    public let outputAmount: BigUInt
    public let quoteTimestamp: UInt32
    public let fillDeadline: UInt32
    public let exclusiveRelayer: EVMAddress?
    public let exclusivityDeadline: UInt32
    public let estimatedFillSeconds: Int?
    /// O maior deposito que a rota aceita agora, e o maior que sai na hora.
    public let maxDeposit: BigUInt
    public let maxDepositInstant: BigUInt
    public let minDeposit: BigUInt
    public let spokePool: EVMAddress
    public let destinationSpokePool: EVMAddress
    /// As casas dos tokens de cada lado, como a API disse; o validador exige as compiladas.
    public let inputDecimals: Int?
    public let outputDecimals: Int?

    public init(
        inputAmount: BigUInt, outputAmount: BigUInt, quoteTimestamp: UInt32, fillDeadline: UInt32, exclusiveRelayer: EVMAddress?,
        exclusivityDeadline: UInt32, estimatedFillSeconds: Int?, maxDeposit: BigUInt, maxDepositInstant: BigUInt, minDeposit: BigUInt,
        spokePool: EVMAddress, destinationSpokePool: EVMAddress, inputDecimals: Int? = nil, outputDecimals: Int? = nil
    ) {
        self.inputAmount = inputAmount
        self.outputAmount = outputAmount
        self.quoteTimestamp = quoteTimestamp
        self.fillDeadline = fillDeadline
        self.exclusiveRelayer = exclusiveRelayer
        self.exclusivityDeadline = exclusivityDeadline
        self.estimatedFillSeconds = estimatedFillSeconds
        self.maxDeposit = maxDeposit
        self.maxDepositInstant = maxDepositInstant
        self.minDeposit = minDeposit
        self.spokePool = spokePool
        self.destinationSpokePool = destinationSpokePool
        self.inputDecimals = inputDecimals
        self.outputDecimals = outputDecimals
    }
}

