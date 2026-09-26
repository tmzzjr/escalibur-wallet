import EscaliburCore
import Foundation

// A troca na EVM: o vocabulario comum.
//
// O provedor propoe, o app decide (docs/seguranca.md 4.1). Tudo que chega de um
// agregador e tratado como hostil: a calldata e decodificada aqui, conferida contra a
// intencao do dono e so entao vira plano. Esta pasta e pura: nao busca nada, nao
// assina nada. A rede (EscaliburNetwork/Trade) cota e le o estado; o assinador so
// recebe o `SigningPlan` que sai daqui.

/// Os agregadores da v1: todos sem API key (docs/blockchain.md 3.1). Provedor com key
/// (1inch, 0x, OKX, Uniswap) entra depois, pelo relay.
public enum TradeProvider: String, Sendable, Hashable, CaseIterable, Codable {
    case velora
    case kyberSwap
    case lifi
    case de1

    public var displayName: String {
        switch self {
        case .velora: return "Velora"
        case .kyberSwap: return "KyberSwap"
        case .lifi: return "LI.FI"
        case .de1: return "De¹"
        }
    }
}

/// O que se vende ou se compra: a moeda nativa da rede ou um token da lista curada.
/// Token definido por resposta de provedor nao existe aqui (docs/seguranca.md 5.4).
public enum TradeAsset: Sendable, Hashable {
    case native(Chain)
    case token(EVMToken)

    public var chain: Chain {
        switch self {
        case .native(let chain): return chain
        case .token(let token): return token.chain
        }
    }

    public var symbol: String {
        switch self {
        case .native(let chain): return chain.nativeSymbol
        case .token(let token): return token.symbol
        }
    }

    public var decimals: Int {
        switch self {
        case .native(let chain): return chain.nativeDecimals
        case .token(let token): return Int(token.decimals)
        }
    }

    /// O contrato ERC-20; `nil` para a moeda nativa.
    public var contract: EVMAddress? {
        if case .token(let token) = self { return token.contract }
        return nil
    }

    public var isNative: Bool { contract == nil }

    /// Como cada router escreve a moeda nativa. Velora, KyberSwap, De¹ e CoW usam
    /// 0xEeee...EEeE; a LI.FI usa o endereco zero. Um token de verdade nunca mora em
    /// nenhum dos dois.
    func routerAddress(nativeSentinel: EVMAddress) -> EVMAddress {
        contract ?? nativeSentinel
    }
}

enum TradeConstants {
    /// 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE: "moeda nativa" em Velora, KyberSwap,
    /// De¹ e CoW (ERC20Utils.isETH da Augustus, `ETH_ADDRESS` do MetaAggregationRouterV2,
    /// `BUY_ETH_ADDRESS` do GPv2Transfer).
    static let eeeeSentinel = EVMAddress(uncheckedBytes: [UInt8](repeating: 0xEE, count: 20))
    static let basisPoints = BigUInt(10_000)
}

/// A intencao do dono: vender exatamente `amountIn` de `sell` por `buy`, aceitando
/// receber ate `slippageBps` a menos que a cotacao, com o destino sendo a propria conta.
public struct TradeIntent: Sendable, Equatable {
    /// Tolerancia maxima que a carteira aceita: 10%. Acima disso, o "minimo garantido"
    /// deixa de proteger, e impacto acima de 15% ja bloqueia de qualquer forma.
    public static let maxSlippageBps: UInt32 = 1_000

    public let chain: Chain
    /// A conta que vende e recebe. O planejamento confere que e a conta que assina.
    public let owner: EVMAddress
    public let sell: TradeAsset
    public let buy: TradeAsset
    public let amountIn: BigUInt
    public let slippageBps: UInt32

    public init(owner: EVMAddress, sell: TradeAsset, buy: TradeAsset, amountIn: BigUInt, slippageBps: UInt32) throws {
        let chain = sell.chain
        guard chain.family == .evm, chain.evmChainID != nil else { throw TradeRefusal.notEVMChain }
        guard buy.chain.id == chain.id else { throw TradeRefusal.assetsOnDifferentChains }
        guard sell != buy else { throw TradeRefusal.sameAsset }
        guard !amountIn.isZero else { throw TradeRefusal.zeroAmount }
        guard slippageBps >= 1, slippageBps <= Self.maxSlippageBps else { throw TradeRefusal.slippageOutOfRange(slippageBps) }
        guard !owner.isZero else { throw TradeRefusal.recipientMismatch(owner) }
        self.chain = chain
        self.owner = owner
        self.sell = sell
        self.buy = buy
        self.amountIn = amountIn
        self.slippageBps = slippageBps
    }

    /// O minimo que o app aceita para uma cotacao que promete `expected`:
    /// `expected * (1 - tolerancia)`, arredondado para baixo. E o app que calcula, com a
    /// tolerancia do dono; o `minOut` que o provedor escreveu na calldata tem de ficar
    /// acima disto.
    public func minimumOut(forExpected expected: BigUInt) -> BigUInt {
        expected * (TradeConstants.basisPoints - BigUInt(slippageBps)) / TradeConstants.basisPoints
    }

    /// A mesma intencao com outro valor: a perna de uma divisao.
    public func withAmount(_ amount: BigUInt) throws -> TradeIntent {
        try TradeIntent(owner: owner, sell: sell, buy: buy, amountIn: amount, slippageBps: slippageBps)
    }
}

/// Por que uma cotacao, uma calldata ou um plano foi recusado. Toda recusa e final:
/// nao existe "assinar mesmo assim".
public enum TradeRefusal: Error, Equatable, Sendable {
    // Intencao
    case notEVMChain
    case assetsOnDifferentChains
    case sameAsset
    case zeroAmount
    case slippageOutOfRange(UInt32)
    // Provedor e contrato
    case providerNotOnChain(TradeProvider)
    case chainIDMismatch
    case senderMismatch(EVMAddress)
    case routerNotAllowed(EVMAddress)
    case spenderNotAllowed(EVMAddress)
    case selectorNotAllowed([UInt8])
    case callRefused(EVMCallRefusal)
    /// A calldata decodifica, mas tem um campo que a carteira nao aceita (permit nao
    /// vazio, flag desconhecida, lista de tamanho errado). O texto diz qual.
    case malformed(String)
    // Conferencia contra a intencao
    case recipientMismatch(EVMAddress)
    case sellTokenMismatch
    case buyTokenMismatch
    case amountInMismatch(expected: BigUInt, found: BigUInt)
    case valueMismatch(expected: BigUInt, found: BigUInt)
    case zeroMinimumOut
    case minimumOutTooLow(found: BigUInt, required: BigUInt)
    case deadlineTooFar(seconds: UInt64)
    case deadlineExpired
    case integratorFeeMismatch
    /// Taxa de integrador nao verificavel na calldata daquele provedor: com taxa ligada,
    /// o provedor sai da disputa em vez de cobrar as cegas.
    case integratorFeeNotVerifiable(TradeProvider)
    case providerFeeTooHigh(bps: UInt32)
    // Mercado
    case priceFarFromOracle(deviationBps: Int)
    case priceImpactTooHigh(bps: Int)
    // Plano
    case quoteExpired
    case ownerMismatch
    case riskNotConfirmed
    case routerHasNoCode
    case routerPinMissing
    case routerPinMismatch(found: EVMAddress)
    case insufficientTokenBalance(needed: BigUInt, available: BigUInt)
    case missingTokenState
    case missingApprovalGas
    case plan(EVMPlanError)
    // Simulacao (docs/seguranca.md 4.9)
    case simulationUnavailable
    case simulationFailed(call: Int)
    case simulationShape
    case simulationSpentTooMuch(found: BigUInt, allowed: BigUInt)
    case simulationReceivedTooLittle(found: BigUInt, required: BigUInt)
    case simulationUnexpectedTransfer(token: EVMAddress)
    case simulationUnexpectedApproval(token: EVMAddress, spender: EVMAddress)
}

/// A taxa de integrador que a carteira aceita ver na calldata: destinatario e bps.
/// Compilada, por provedor e rede. **Hoje zero em todos** (docs/blockchain.md 3.7: a
/// taxa so liga depois do parecer juridico sobre PSAV).
public struct TradeFeeTerms: Sendable, Equatable {
    /// `nil` = sem taxa. Com taxa, o endereco da empresa naquela rede (multisig ou
    /// cold, rotacionado por release).
    public let recipient: EVMAddress?
    public let bps: UInt32

    public static let none = TradeFeeTerms(recipient: nil, bps: 0)

    public init(recipient: EVMAddress?, bps: UInt32) {
        self.recipient = recipient
        self.bps = bps
    }

    public var isNone: Bool { recipient == nil && bps == 0 }
}

public enum TradeFeeSchedule {
    /// A taxa da Escalibur. Para ligar: um literal por provedor e rede aqui, com o
    /// endereco da empresa, e os decodificadores passam a exigir exatamente esse par.
    /// A config remota nunca liga nem muda taxa.
    public static func escaliburFee(provider: TradeProvider, chain: Chain) -> TradeFeeTerms {
        .none
    }

    /// Teto da taxa que o proprio provedor embute na calldata, em bps do valor vendido.
    /// LI.FI: 0,25% fixos ("LIFI Fixed Fee", visto ao vivo em 25/09/2026, pago via
    /// FeeForwarder dentro do swapData). Os outros nao cobram na calldata: a Velora sem
    /// parceiro fica com a sobra acima da cotacao, o que so reduz o estimado, nunca o
    /// garantido.
    static func providerFeeCeilingBps(_ provider: TradeProvider) -> UInt32 {
        provider == .lifi ? 25 : 0
    }
}
