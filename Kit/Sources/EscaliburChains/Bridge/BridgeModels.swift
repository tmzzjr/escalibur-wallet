import EscaliburCore
import Foundation

// O pedido de ponte e a cotacao conferida (docs/seguranca.md 4.12).
//
// Regras da v1, todas conferidas aqui antes de qualquer plano:
// - a mesma moeda dos dois lados, na versao do emissor: USDC so pelo CCTP V2 da Circle;
//   ETH e USDT pelo Across; USDT so onde o Across entrega o USDT do emissor;
// - quem recebe e quem deposita sao a propria conta do dono; nenhuma mensagem nem
//   chamada no destino (no CCTP, so o pedido de encaminhamento da Circle);
// - a calldata e montada pelo app; das APIs vem so a taxa, sempre com teto compilado.

/// O que a ponte move na v1.
public enum BridgeAsset: String, Codable, Sendable, CaseIterable, Equatable {
    case usdc, eth, usdt

    public var symbol: String {
        switch self {
        case .usdc: return "USDC"
        case .eth: return "ETH"
        case .usdt: return "USDT"
        }
    }

    public var decimals: Int { self == .eth ? 18 : 6 }

    /// O contrato nesta rede; `nil` para o ETH nativo ou onde a ponte nao move esta moeda.
    public func contract(on chain: BridgeChain) -> EVMAddress? {
        switch self {
        case .usdc: return chain.usdc
        case .eth: return nil
        case .usdt: return chain.usdt
        }
    }

    /// A ponte move esta moeda de `from` para `to`?
    public func available(from: BridgeChain, to: BridgeChain) -> Bool {
        guard from.chain.id != to.chain.id else { return false }
        switch self {
        case .usdc: return true
        case .eth: return from.nativeETH && to.nativeETH && from.across != nil && to.across != nil
        case .usdt: return from.usdt != nil && to.usdt != nil && from.across != nil && to.across != nil
        }
    }

    /// O ativo da lista do app nesta rede (a moeda nativa, ou o token com este contrato).
    public func asset(on chain: BridgeChain) -> Asset? {
        guard let contract = contract(on: chain) else { return Asset.native(chain.chain) }
        return TokenRegistry.assets(on: chain.chain).first { asset in
            if case .token(let listed) = asset.kind { return listed.lowercased() == contract.checksummed.lowercased() }
            return false
        }
    }

    /// O ativo do app nesta rede: o id que a revisao e a conferencia usam.
    public func tradeAsset(on chain: BridgeChain) -> TradeAsset {
        guard let contract = contract(on: chain) else { return .native(chain.chain) }
        return .token(EVMToken(chain: chain.chain, contract: contract, symbol: symbol, decimals: UInt8(decimals)))
    }
}

/// Por onde vai.
public enum BridgeRoute: String, Codable, Sendable, Equatable {
    /// CCTP V2 rapido: a Circle atesta antes da finalidade e cobra a taxa rapida.
    case cctpFast
    /// CCTP V2 padrao: espera a finalidade da origem, sem taxa do protocolo.
    case cctpStandard
    case across

    public var isCCTP: Bool { self != .across }
}

/// Por que a ponte recusou.
public enum BridgeRefusal: Error, Equatable, Sendable {
    case sameChain
    case unsupportedRoute
    case zeroAmount
    case aboveBurnLimit(limit: BigUInt)
    case belowMinimum(minimum: BigUInt)
    case aboveRouteLimit(maximum: BigUInt)
    case fastUnavailable
    case feeAboveCap
    /// A taxa come uma parte grande demais do valor.
    case feeTooHigh(percent: Double)
    case quoteMismatch(String)
    case quoteExpired
    case ownerMismatch
    case missingTokenState
    case insufficientTokenBalance(needed: BigUInt, available: BigUInt)
    case contractHasNoCode(String)
    /// O dono do proxy trocou o codigo: a ponte desliga ate a proxima versao do app.
    case implementationChanged(String)
    /// O destino nao cunha o USDC desta origem (o caso da BNB).
    case destinationDoesNotMint
    /// A conta do dono no destino tem codigo: delegacao EIP-7702 ou contrato.
    case destinationHasCode
    /// O USDC do destino bloqueou a conta do dono: a cunhagem reverteria.
    case destinationBlacklisted
    case simulationUnavailable
    case simulationShape
    case simulationFailed(call: Int)
    case simulationUnexpectedTransfer(token: EVMAddress)
    case simulationUnexpectedApproval(token: EVMAddress, spender: EVMAddress)
    case simulationSpentWrong(found: BigUInt, expected: BigUInt)
    case simulationEventMissing
    case plan(EVMPlanError)
}

/// O pedido do dono: mover `amount` de `asset` da rede `from` para a mesma conta na `to`.
public struct BridgeIntent: Sendable, Equatable {
    public let owner: EVMAddress
    public let asset: BridgeAsset
    public let from: BridgeChain
    public let to: BridgeChain
    public let amount: BigUInt

    public init(owner: EVMAddress, asset: BridgeAsset, from: Chain, to: Chain, amount: BigUInt) throws {
        guard from.id != to.id else { throw BridgeRefusal.sameChain }
        guard let source = BridgeAllowlist.chain(from), let destination = BridgeAllowlist.chain(to),
              asset.available(from: source, to: destination)
        else { throw BridgeRefusal.unsupportedRoute }
        guard !amount.isZero else { throw BridgeRefusal.zeroAmount }
        if asset == .usdc, amount > BridgeAllowlist.burnLimitPerMessage {
            throw BridgeRefusal.aboveBurnLimit(limit: BridgeAllowlist.burnLimitPerMessage)
        }
        self.owner = owner
        self.asset = asset
        self.from = source
        self.to = destination
        self.amount = amount
    }

    public var sell: TradeAsset { asset.tradeAsset(on: from) }
    public var receive: TradeAsset { asset.tradeAsset(on: to) }
    public var route: BridgeRoute? { nil }
}

/// A transacao de deposito que o app montou, com o que a revisao mostra.
public struct ValidatedBridgeQuote: Sendable, Equatable {
    public enum Call: Sendable, Equatable {
        case cctp(CCTPTransfer)
        case across(AcrossTransfer)
    }

    public let intent: BridgeIntent
    public let route: BridgeRoute
    public let call: Call
    /// TokenMessengerV2 ou SpokePool da origem.
    public let to: EVMAddress
    public let value: BigUInt
    public let data: [UInt8]
    /// Quem recebe o approve exato; `nil` quando sai ETH nativo.
    public let spender: EVMAddress?
    /// O que chega no pior caso: no CCTP, o valor menos a taxa maxima; no Across, o
    /// valor exato que o relayer tem de entregar.
    public let minimumReceived: BigUInt
    public let expectedReceived: BigUInt
    /// A taxa maxima da ponte (CCTP) ou a exata (Across), na moeda movida.
    public let bridgeFee: BigUInt
    public let estimatedSeconds: Int
    public let createdAt: Date

    /// A cotacao vale 60 segundos, como o plano.
    public static let lifetime: TimeInterval = 60

    public func isExpired(now: Date = .now) -> Bool {
        now.timeIntervalSince(createdAt) > Self.lifetime
    }

    public var feePercent: Double {
        let amount = Double(intent.amount.decimalString) ?? 0
        return amount > 0 ? (Double(bridgeFee.decimalString) ?? 0) / amount * 100 : 0
    }
}

/// O que a cotacao precisa vencer para virar transacao.
public enum BridgeValidator {
    /// Taxa rapida do CCTP: ate 2 bps (vistos 1 a 1,4). Padrao: zero.
    public static let fastBpsCap = 2
    /// Encaminhamento da Circle: ate 10 USDC (visto 0,05 para L2 e 1,07 para a Ethereum).
    public static let forwardFeeCap = BigUInt(10_000_000)
    /// Across: a taxa ate 0,5% do valor ou US$ 3, o que for maior.
    public static let acrossFeeCapBps = 50
    public static let acrossFeeCapUSD = 3
    /// Acima disso a ponte nao monta: a taxa come demais do valor.
    public static let blockFeePercent = 5.0
    /// Prazo para o relayer do Across entregar: 2 h depois da cotacao. Sem entrega, o
    /// deposito volta ao dono na origem.
    public static let acrossFillWindow: UInt32 = 7_200

    // MARK: CCTP

    /// Monta a queima com encaminhamento. `fastAllowance`: quanto ainda cabe em
    /// transferencia rapida agora (Iris).
    public static func cctp(_ intent: BridgeIntent, route: BridgeRoute, fees: CCTPFees, fastAllowance: BigUInt?, now: Date = .now) throws
        -> ValidatedBridgeQuote {
        guard intent.asset == .usdc, route.isCCTP else { throw BridgeRefusal.unsupportedRoute }
        let level: CCTPFees.Level
        switch route {
        case .cctpFast:
            guard let fast = fees.fast, let allowance = fastAllowance, allowance >= intent.amount else { throw BridgeRefusal.fastUnavailable }
            guard fast.protocolBps.mantissa <= BigUInt(fastBpsCap) * BigUInt.power(of: 10, fast.protocolBps.scale) else {
                throw BridgeRefusal.feeAboveCap
            }
            level = fast
        case .cctpStandard:
            guard let standard = fees.standard else { throw BridgeRefusal.quoteMismatch("taxa padrão") }
            guard standard.protocolBps.isZero else { throw BridgeRefusal.feeAboveCap }
            level = standard
        case .across:
            throw BridgeRefusal.unsupportedRoute
        }
        guard level.forwardFee <= forwardFeeCap else { throw BridgeRefusal.feeAboveCap }
        let maxFee = CCTPFees.maxFee(amount: intent.amount, level: level)
        guard maxFee < intent.amount else { throw BridgeRefusal.feeTooHigh(percent: 100) }

        let transfer = CCTPTransfer(
            sourceDomain: intent.from.cctpDomain, destinationDomain: intent.to.cctpDomain, usdc: intent.from.usdc,
            owner: intent.owner, recipient: intent.owner, amount: intent.amount, maxFee: maxFee,
            finality: route == .cctpFast ? CCTPCalldata.fastFinality : CCTPCalldata.standardFinality
        )
        let quote = ValidatedBridgeQuote(
            intent: intent, route: route, call: .cctp(transfer), to: BridgeAllowlist.tokenMessenger, value: 0,
            data: try CCTPCalldata.encodeDeposit(transfer), spender: BridgeAllowlist.tokenMessenger,
            minimumReceived: transfer.minimumReceived, expectedReceived: transfer.minimumReceived, bridgeFee: maxFee,
            estimatedSeconds: route == .cctpFast ? 30 : 20 * 60, createdAt: now
        )
        guard quote.feePercent <= blockFeePercent else { throw BridgeRefusal.feeTooHigh(percent: quote.feePercent) }
        return quote
    }

    // MARK: Across

    /// Monta o deposito no Across. `usdPrice`: o preco de oraculo da moeda, para o teto
    /// de US$ 3; sem preco, vale so o teto de 0,5%.
    public static func across(_ intent: BridgeIntent, quote: AcrossQuote, usdPrice: TradeDecimal?, now: Date = .now) throws
        -> ValidatedBridgeQuote {
        guard intent.asset != .usdc, let fromAcross = intent.from.across, let toAcross = intent.to.across else {
            throw BridgeRefusal.unsupportedRoute
        }
        guard quote.spokePool == fromAcross.spokePool, quote.destinationSpokePool == toAcross.spokePool else {
            throw BridgeRefusal.quoteMismatch("SpokePool")
        }
        guard quote.inputAmount == intent.amount, quote.outputAmount <= intent.amount, !quote.outputAmount.isZero else {
            throw BridgeRefusal.quoteMismatch("valor")
        }
        guard intent.amount >= quote.minDeposit else { throw BridgeRefusal.belowMinimum(minimum: quote.minDeposit) }
        guard intent.amount <= quote.maxDeposit else { throw BridgeRefusal.aboveRouteLimit(maximum: quote.maxDeposit) }

        let fee = intent.amount - quote.outputAmount
        guard fee <= acrossFeeCap(intent.amount, asset: intent.asset, usdPrice: usdPrice) else { throw BridgeRefusal.feeAboveCap }

        let clock = UInt32(now.timeIntervalSince1970)
        guard quote.quoteTimestamp <= clock + 120, clock <= quote.quoteTimestamp + 3_600 else { throw BridgeRefusal.quoteMismatch("horário") }
        // O prazo e o da carteira, nao o da API: 2 h depois da cotacao.
        let fillDeadline = quote.quoteTimestamp + acrossFillWindow
        guard fillDeadline >= clock + 600 else { throw BridgeRefusal.quoteMismatch("prazo") }

        let input = intent.asset.contract(on: intent.from) ?? fromAcross.wrappedNative
        let output = intent.asset.contract(on: intent.to) ?? toAcross.wrappedNative
        // Sem relayer exclusivo: um relayer escolhido pela API que nunca entregasse
        // prenderia o deposito ate o prazo.
        let transfer = AcrossTransfer(
            originChainID: intent.from.chain.evmChainID ?? 0, destinationChainID: intent.to.chain.evmChainID ?? 0,
            owner: intent.owner, recipient: intent.owner, inputToken: input, outputToken: output,
            inputAmount: intent.amount, outputAmount: quote.outputAmount, exclusiveRelayer: nil,
            quoteTimestamp: quote.quoteTimestamp, fillDeadline: fillDeadline, exclusivityDeadline: 0,
            nativeInput: intent.asset == .eth
        )
        let validated = ValidatedBridgeQuote(
            intent: intent, route: .across, call: .across(transfer), to: fromAcross.spokePool, value: transfer.value,
            data: try AcrossCalldata.encode(transfer), spender: intent.asset == .eth ? nil : fromAcross.spokePool,
            minimumReceived: quote.outputAmount, expectedReceived: quote.outputAmount, bridgeFee: fee,
            estimatedSeconds: max(5, min(quote.estimatedFillSeconds ?? 60, 3_600)), createdAt: now
        )
        guard validated.feePercent <= blockFeePercent else { throw BridgeRefusal.feeTooHigh(percent: validated.feePercent) }
        return validated
    }

    /// O maior entre 0,5% do valor e US$ 3 na moeda movida.
    static func acrossFeeCap(_ amount: BigUInt, asset: BridgeAsset, usdPrice: TradeDecimal?) -> BigUInt {
        let percentCap = amount * BigUInt(acrossFeeCapBps) / BigUInt(10_000)
        let unit = BigUInt.power(of: 10, asset.decimals)
        var usdCap = BigUInt()
        switch asset {
        case .usdt, .usdc:
            usdCap = BigUInt(acrossFeeCapUSD) * unit
        case .eth:
            // US$ 3 / preco, em wei: 3 * 10^18 * 10^escala / mantissa.
            if let price = usdPrice, !price.mantissa.isZero {
                usdCap = BigUInt(acrossFeeCapUSD) * unit * BigUInt.power(of: 10, price.scale) / price.mantissa
            }
        }
        return max(percentCap, usdCap)
    }
}
