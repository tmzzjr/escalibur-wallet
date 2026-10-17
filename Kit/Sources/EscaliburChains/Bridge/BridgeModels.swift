import EscaliburCore
import Foundation

// O pedido de ponte e a cotacao conferida (docs/seguranca.md 4.12).
//
// Regras da v1, todas conferidas aqui antes de qualquer plano:
// - a mesma moeda dos dois lados, na versao do emissor: USDC so pelo CCTP V2 da Circle;
//   ETH, USDT e WBTC pelo Across; USDT so onde o Across entrega o USDT do emissor; WBTC so
//   onde o Across entrega o WBTC da lista curada; USDT para a Tron so pela Legacy Mesh da
//   propria Tether, da Ethereum e da Arbitrum (`USDT0Mesh`);
// - quem recebe e quem deposita sao a propria conta do dono (na Tron, a conta Tron da mesma
//   carteira); nenhuma mensagem nem chamada no destino (no CCTP, so o pedido de
//   encaminhamento da Circle);
// - a calldata e montada pelo app; das APIs vem so a taxa, sempre com teto compilado.

/// O que a ponte move na v1.
public enum BridgeAsset: String, Codable, Sendable, CaseIterable, Equatable {
    case usdc, eth, usdt, wbtc

    public var symbol: String {
        switch self {
        case .usdc: return "USDC"
        case .eth: return "ETH"
        case .usdt: return "USDT"
        case .wbtc: return "WBTC"
        }
    }

    /// As casas desta moeda nesta rede: o ETH tem 18 em toda parte; o WBTC, 8; o USDC e o
    /// USDT, 6 nos da Circle e da Tether e 18 nos da Binance (BNB).
    public func decimals(on chain: BridgeChain) -> Int {
        switch self {
        case .eth: return 18
        case .wbtc: return 8
        case .usdc, .usdt: return chain.stableDecimals
        }
    }

    /// Um valor de `from` casas em `to` casas, arredondado para baixo.
    public static func rescale(_ amount: BigUInt, from: Int, to: Int) -> BigUInt {
        if from == to { return amount }
        if from > to { return amount / BigUInt.power(of: 10, from - to) }
        return amount * BigUInt.power(of: 10, to - from)
    }

    /// O que chega (casas do destino) nao passa do que sai (casas da origem), comparado na
    /// unidade mais fina: arredondar para baixo deixava chegar ate 10^12 - 1 unidades a
    /// mais (revisao da ponte BNB, I1).
    public static func fits(_ output: BigUInt, outputDecimals: Int, within input: BigUInt, inputDecimals: Int) -> Bool {
        let finest = max(outputDecimals, inputDecimals)
        return rescale(output, from: outputDecimals, to: finest) <= rescale(input, from: inputDecimals, to: finest)
    }

    /// Sai como moeda nativa (ETH com `value`, sem approve)? So o ETH, e so onde ele e a
    /// moeda da rede: na BNB o ETH e token, com approve exato ao SpokePool.
    public func isNativeInput(on chain: BridgeChain) -> Bool {
        self == .eth && contract(on: chain) == nil
    }

    /// O USDC vai pelo CCTP quando as duas redes tem; senao, pelo Across.
    public static func usesCCTP(_ asset: BridgeAsset, from: BridgeChain, to: BridgeChain) -> Bool {
        asset == .usdc && from.cctp != nil && to.cctp != nil
    }

    /// O USDT vai para a Tron pela Legacy Mesh da Tether, so de onde ela tem o UsdtOFT e o
    /// USDT da lista e o que ele puxa.
    public static func usesMesh(_ asset: BridgeAsset, from: BridgeChain, to: BridgeChain) -> Bool {
        guard asset == .usdt, to.chain.family == .tron, let source = from.mesh else { return false }
        return from.usdt == source.usdt
    }

    /// O contrato nesta rede; `nil` para o ETH nativo ou onde a ponte nao move esta moeda.
    public func contract(on chain: BridgeChain) -> EVMAddress? {
        switch self {
        case .usdc: return chain.usdc
        case .eth: return chain.ethToken
        case .usdt: return chain.usdt
        case .wbtc: return chain.wbtc
        }
    }

    /// A ponte move esta moeda de `from` para `to`?
    public func available(from: BridgeChain, to: BridgeChain) -> Bool {
        guard from.chain.id != to.chain.id else { return false }
        switch self {
        case .usdc:
            return BridgeAsset.usesCCTP(self, from: from, to: to)
                || (from.across != nil && to.across != nil && from.acrossUSDC && to.acrossUSDC)
        case .eth:
            return (from.nativeETH || from.ethToken != nil) && (to.nativeETH || to.ethToken != nil) && from.across != nil && to.across != nil
        case .usdt:
            return BridgeAsset.usesMesh(self, from: from, to: to)
                || (from.usdt != nil && to.usdt != nil && from.across != nil && to.across != nil)
        case .wbtc: return from.wbtc != nil && to.wbtc != nil && from.across != nil && to.across != nil
        }
    }

    /// O ativo da lista do app nesta rede (a moeda nativa, ou o token com este contrato).
    public func asset(on chain: BridgeChain) -> Asset? {
        guard let contract = contract(on: chain) else { return Asset.native(chain.chain) }
        if chain.chain.family == .tron {
            // Na Tron a lista guarda o contrato em base58.
            let base58 = TronAddress(account20: contract.bytes)?.base58
            return TokenRegistry.assets(on: chain.chain).first { asset in
                if case .token(let listed) = asset.kind { return listed == base58 }
                return false
            }
        }
        return TokenRegistry.assets(on: chain.chain).first { asset in
            if case .token(let listed) = asset.kind { return listed.lowercased() == contract.checksummed.lowercased() }
            return false
        }
    }

    /// O ativo do app nesta rede: o id que a revisao e a conferencia usam.
    public func tradeAsset(on chain: BridgeChain) -> TradeAsset {
        guard let contract = contract(on: chain) else { return .native(chain.chain) }
        return .token(EVMToken(chain: chain.chain, contract: contract, symbol: symbol, decimals: UInt8(decimals(on: chain))))
    }
}

/// Por onde vai.
public enum BridgeRoute: String, Codable, Sendable, Equatable {
    /// CCTP V2 rapido: a Circle atesta antes da finalidade e cobra a taxa rapida.
    case cctpFast
    /// CCTP V2 padrao: espera a finalidade da origem, sem taxa do protocolo.
    case cctpStandard
    case across
    /// USDT para a Tron pela Legacy Mesh do USDT0, a ponte da Tether (LayerZero).
    case usdt0

    public var isCCTP: Bool { self == .cctpFast || self == .cctpStandard }
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
    /// A ponte para a Tron precisa da conta Tron da carteira, e so dela.
    case recipientMissing
    /// O contrato da Tether nao aponta mais para o UsdtOFT da Tron, ou mudou o USDT que puxa.
    case meshPeerChanged
    /// A Tron nao tem liquidez da Tether para este valor agora.
    case meshNoLiquidity(available: BigUInt)
    /// A conta Tron da carteira esta sob o controle de outra chave: o que chegasse la nao sairia.
    case tronAccountNotControlled
    case plan(EVMPlanError)
}

/// O pedido do dono: mover `amount` de `asset` da rede `from` para a mesma conta na `to`.
public struct BridgeIntent: Sendable, Equatable {
    public let owner: EVMAddress
    public let asset: BridgeAsset
    public let from: BridgeChain
    public let to: BridgeChain
    public let amount: BigUInt
    /// Na Tron: a conta Tron da mesma carteira, que recebe. Nas redes EVM, `nil` (recebe o
    /// proprio `owner`).
    public let tronRecipient: TronAddress?

    public init(owner: EVMAddress, asset: BridgeAsset, from: Chain, to: Chain, amount: BigUInt, tronRecipient: TronAddress? = nil) throws {
        guard from.id != to.id else { throw BridgeRefusal.sameChain }
        guard let source = BridgeAllowlist.chain(from), let destination = BridgeAllowlist.chain(to),
              source.chain.family == .evm, asset.available(from: source, to: destination)
        else { throw BridgeRefusal.unsupportedRoute }
        guard !amount.isZero else { throw BridgeRefusal.zeroAmount }
        if BridgeAsset.usesCCTP(asset, from: source, to: destination), amount > BridgeAllowlist.burnLimitPerMessage {
            throw BridgeRefusal.aboveBurnLimit(limit: BridgeAllowlist.burnLimitPerMessage)
        }
        // A conta que recebe na Tron vem junto, e so quando o destino e a Tron.
        guard (destination.chain.family == .tron) == (tronRecipient != nil) else { throw BridgeRefusal.recipientMissing }
        self.owner = owner
        self.asset = asset
        self.from = source
        self.to = destination
        self.amount = amount
        self.tronRecipient = tronRecipient
    }

    /// Quem recebe, como a rede de destino escreve: o endereco EVM do dono, ou a conta Tron.
    public var recipientText: String { tronRecipient?.base58 ?? owner.checksummed }

    public var sell: TradeAsset { asset.tradeAsset(on: from) }
    public var receive: TradeAsset { asset.tradeAsset(on: to) }
    public var route: BridgeRoute? { nil }
}

/// A transacao de deposito que o app montou, com o que a revisao mostra.
public struct ValidatedBridgeQuote: Sendable, Equatable {
    public enum Call: Sendable, Equatable {
        case cctp(CCTPTransfer)
        case across(AcrossTransfer)
        case mesh(MeshTransfer)
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
    /// A taxa maxima da ponte (CCTP) ou a exata (Across, Tether), na moeda movida.
    public let bridgeFee: BigUInt
    public let estimatedSeconds: Int
    public let createdAt: Date
    /// Na Legacy Mesh: a taxa de mensagem da LayerZero, que sai na moeda nativa da origem
    /// (`value`), e quanto ela pesa no valor, pelo preco de mercado (zero sem preco).
    public var messageFee: BigUInt = 0
    public var messageFeePercent: Double = 0

    /// A cotacao vale 60 segundos, como o plano.
    public static let lifetime: TimeInterval = 60

    public func isExpired(now: Date = .now) -> Bool {
        now.timeIntervalSince(createdAt) > Self.lifetime
    }

    /// A rota, a chamada e o pedido dizem a mesma coisa: CCTP so com queima e entre redes
    /// com CCTP; Across so com deposito. O plano e o leitor de estado conferem antes de
    /// tudo (revisao da ponte BNB, I2: o reencode era a unica barreira).
    public var callMatchesRoute: Bool {
        let cctp = BridgeAsset.usesCCTP(intent.asset, from: intent.from, to: intent.to)
        let mesh = BridgeAsset.usesMesh(intent.asset, from: intent.from, to: intent.to)
        switch call {
        case .cctp: return route.isCCTP && cctp && !mesh
        case .across: return route == .across && !cctp && !mesh
        case .mesh: return route == .usdt0 && mesh && !cctp
        }
    }

    /// A rota toca a BNB, onde as moedas da ponte sao as da Binance.
    public var touchesBinancePeg: Bool { intent.from.chain.id == "bnb" || intent.to.chain.id == "bnb" }

    /// A taxa da ponte sobre o valor e, na Legacy Mesh, a taxa de mensagem tambem.
    public var feePercent: Double {
        let amount = Double(intent.amount.decimalString) ?? 0
        return (amount > 0 ? (Double(bridgeFee.decimalString) ?? 0) / amount * 100 : 0) + messageFeePercent
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
    /// Teto absoluto da parte em dolar no ETH, compilado: 0,002 ETH. O preco vem de uma
    /// fonte so, e um preco errado para baixo subia o teto ate o bloqueio de 5% (pentest
    /// de 14/10/2026, B5). Preco errado para cima so baixa o teto: a ponte recusa.
    public static let acrossFeeCapETHWei = BigUInt(2_000_000_000_000_000)
    /// O mesmo teto absoluto no WBTC: 0,00005 WBTC (5.000 satoshis), pela mesma razao.
    public static let acrossFeeCapWBTCSats = BigUInt(5_000)
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
        guard BridgeAsset.usesCCTP(intent.asset, from: intent.from, to: intent.to), route.isCCTP,
              let source = intent.from.cctp, let destination = intent.to.cctp else { throw BridgeRefusal.unsupportedRoute }
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
        case .across, .usdt0:
            throw BridgeRefusal.unsupportedRoute
        }
        guard level.forwardFee <= forwardFeeCap else { throw BridgeRefusal.feeAboveCap }
        let maxFee = CCTPFees.maxFee(amount: intent.amount, level: level)
        guard maxFee < intent.amount else { throw BridgeRefusal.feeTooHigh(percent: 100) }

        let transfer = CCTPTransfer(
            sourceDomain: source.domain, destinationDomain: destination.domain, usdc: intent.from.usdc,
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
        guard !BridgeAsset.usesCCTP(intent.asset, from: intent.from, to: intent.to), let fromAcross = intent.from.across,
              let toAcross = intent.to.across else {
            throw BridgeRefusal.unsupportedRoute
        }
        guard quote.spokePool == fromAcross.spokePool, quote.destinationSpokePool == toAcross.spokePool else {
            throw BridgeRefusal.quoteMismatch("SpokePool")
        }
        // O que chega e na moeda do destino, com as casas de la (18 no USDC da BNB, 6 no da
        // Base): a comparacao e a taxa sao na unidade da origem, arredondando o que chega
        // para baixo.
        let inputDecimals = intent.asset.decimals(on: intent.from)
        let outputDecimals = intent.asset.decimals(on: intent.to)
        // Casas que a API diz diferentes das compiladas: o token nao e o que o app pensa.
        guard quote.inputDecimals.map({ $0 == inputDecimals }) ?? true, quote.outputDecimals.map({ $0 == outputDecimals }) ?? true else {
            throw BridgeRefusal.quoteMismatch("casas")
        }
        let delivered = BridgeAsset.rescale(quote.outputAmount, from: outputDecimals, to: inputDecimals)
        guard quote.inputAmount == intent.amount, delivered <= intent.amount, !quote.outputAmount.isZero, !delivered.isZero,
              BridgeAsset.fits(quote.outputAmount, outputDecimals: outputDecimals, within: intent.amount, inputDecimals: inputDecimals) else {
            throw BridgeRefusal.quoteMismatch("valor")
        }
        guard intent.amount >= quote.minDeposit else { throw BridgeRefusal.belowMinimum(minimum: quote.minDeposit) }
        guard intent.amount <= quote.maxDeposit else { throw BridgeRefusal.aboveRouteLimit(maximum: quote.maxDeposit) }

        let fee = intent.amount - delivered
        guard fee <= acrossFeeCap(intent.amount, asset: intent.asset, decimals: inputDecimals, usdPrice: usdPrice) else {
            throw BridgeRefusal.feeAboveCap
        }

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
            nativeInput: intent.asset.isNativeInput(on: intent.from)
        )
        let validated = ValidatedBridgeQuote(
            intent: intent, route: .across, call: .across(transfer), to: fromAcross.spokePool, value: transfer.value,
            data: try AcrossCalldata.encode(transfer), spender: intent.asset.isNativeInput(on: intent.from) ? nil : fromAcross.spokePool,
            minimumReceived: quote.outputAmount, expectedReceived: quote.outputAmount, bridgeFee: fee,
            estimatedSeconds: max(5, min(quote.estimatedFillSeconds ?? 60, 3_600)), createdAt: now
        )
        guard validated.feePercent <= blockFeePercent else { throw BridgeRefusal.feeTooHigh(percent: validated.feePercent) }
        return validated
    }

    // MARK: Legacy Mesh (Tron)

    /// Monta o envio para a Tron pela Legacy Mesh da Tether, a partir do que a rede leu do
    /// UsdtOFT de origem. Nada vem de API: a taxa da Tether, o que chega, a liquidez e a taxa
    /// de mensagem sao do proprio contrato. `nativeUSDPrice`: o preco da moeda nativa da
    /// origem, so para dizer quanto a taxa de mensagem pesa no valor.
    public static func mesh(_ intent: BridgeIntent, quote: MeshQuote, nativeUSDPrice: TradeDecimal?, now: Date = .now) throws
        -> ValidatedBridgeQuote {
        guard BridgeAsset.usesMesh(intent.asset, from: intent.from, to: intent.to), let source = intent.from.mesh,
              let recipient = intent.tronRecipient
        else { throw BridgeRefusal.unsupportedRoute }
        // O contrato de origem ainda e o que foi lido: puxa o USDT da lista e entrega pelo
        // UsdtOFT da Tron.
        guard quote.token == source.usdt, quote.tronPeer == USDT0Mesh.tronPeerWord else { throw BridgeRefusal.meshPeerChanged }
        guard quote.feeBps <= BigUInt(USDT0Mesh.feeCapBps) else { throw BridgeRefusal.feeAboveCap }
        // O que chega e o valor menos a taxa de agora, como o contrato conta (`_debitView`).
        let fee = intent.amount * quote.feeBps / BigUInt(10_000)
        let received = intent.amount - fee
        guard quote.sent == intent.amount, quote.received == received, !received.isZero else { throw BridgeRefusal.quoteMismatch("valor") }
        guard quote.maxAmount >= received else { throw BridgeRefusal.meshNoLiquidity(available: quote.maxAmount) }
        guard quote.lzTokenFee.isZero, !quote.nativeFee.isZero else { throw BridgeRefusal.quoteMismatch("taxa de mensagem") }
        // A folga sobre a taxa de mensagem volta ao dono pelo EndpointV2, na mesma transacao.
        let nativeFee = quote.nativeFee + quote.nativeFee * BigUInt(USDT0Mesh.nativeFeeMarginBps) / BigUInt(10_000)
        guard nativeFee <= USDT0Mesh.nativeFeeCap else { throw BridgeRefusal.feeAboveCap }

        let transfer = MeshTransfer(
            sourceChainID: intent.from.chain.evmChainID ?? 0, oft: source.oft, owner: intent.owner, recipient: recipient,
            amount: intent.amount, minimumReceived: received, nativeFee: nativeFee
        )
        var validated = ValidatedBridgeQuote(
            intent: intent, route: .usdt0, call: .mesh(transfer), to: source.oft, value: nativeFee,
            data: try MeshCalldata.encode(transfer), spender: source.oft, minimumReceived: received, expectedReceived: received,
            bridgeFee: fee, estimatedSeconds: meshEstimatedSeconds, createdAt: now
        )
        validated.messageFee = nativeFee
        validated.messageFeePercent = messagePercent(nativeFee, nativeDecimals: intent.from.chain.nativeDecimals, price: nativeUSDPrice,
                                                     amount: intent.amount, decimals: intent.asset.decimals(on: intent.from))
        guard validated.feePercent <= blockFeePercent else { throw BridgeRefusal.feeTooHigh(percent: validated.feePercent) }
        return validated
    }

    /// A LayerZero espera a confirmacao na origem antes de entregar: uns minutos.
    public static let meshEstimatedSeconds = 5 * 60

    /// Quanto a taxa de mensagem, em moeda nativa, pesa num valor em USDT (um dolar cada).
    static func messagePercent(_ fee: BigUInt, nativeDecimals: Int, price: TradeDecimal?, amount: BigUInt, decimals: Int) -> Double {
        guard let price, !price.mantissa.isZero, !amount.isZero else { return 0 }
        // taxa [wei] x preco [US$ por moeda] / valor [US$] x 100, contado inteiro em milionesimos
        // de ponto percentual e so no fim em Double.
        let numerator = fee * price.mantissa * BigUInt.power(of: 10, decimals) * BigUInt(100_000_000)
        let denominator = BigUInt.power(of: 10, price.scale + nativeDecimals) * amount
        return (Double((numerator / denominator).decimalString) ?? 0) / 1_000_000
    }

    /// O maior entre 0,5% do valor e US$ 3 na moeda movida (no ETH, no maximo 0,002 ETH; no
    /// WBTC, no maximo 5.000 satoshis).
    static func acrossFeeCap(_ amount: BigUInt, asset: BridgeAsset, decimals: Int, usdPrice: TradeDecimal?) -> BigUInt {
        let percentCap = amount * BigUInt(acrossFeeCapBps) / BigUInt(10_000)
        let unit = BigUInt.power(of: 10, decimals)
        var usdCap = BigUInt()
        switch asset {
        case .usdt, .usdc:
            usdCap = BigUInt(acrossFeeCapUSD) * unit
        case .eth, .wbtc:
            // US$ 3 / preco, na menor unidade: 3 * 10^casas * 10^escala / mantissa.
            if let price = usdPrice, !price.mantissa.isZero {
                let ceiling = asset == .eth ? acrossFeeCapETHWei : acrossFeeCapWBTCSats
                usdCap = min(BigUInt(acrossFeeCapUSD) * unit * BigUInt.power(of: 10, price.scale) / price.mantissa, ceiling)
            }
        }
        return max(percentCap, usdCap)
    }
}
