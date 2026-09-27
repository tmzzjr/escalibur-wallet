import EscaliburCore
import Foundation

// A validacao de uma cotacao, fail-closed (docs/seguranca.md 4.3, docs/blockchain.md 3.5).
//
// Entra a proposta crua do provedor (to, value, data e o que ele anuncia), sai uma
// `ValidatedTradeQuote` ou uma recusa. A ordem das conferencias:
//
//  1. chainId e `from` da resposta, se vierem, batem com a rede compilada e o dono;
//  2. `to` e o router compilado daquele provedor naquela rede; o spender declarado
//     (approvalAddress) e o compilado;
//  3. a guarda de chamada (EVMCallGuard) recusa tipo 4, permit, setApprovalForAll e
//     seletor fora da lista do router, e decodifica os argumentos de forma canonica;
//  4. o decodificador do provedor le os campos que importam e recusa o que nao entende;
//  5. o resumo decodificado e conferido contra a intencao: tokens, valor, destinatario,
//     msg.value, taxa de integrador igual a compilada, taxa do provedor ate o teto,
//     prazo, e `minOut >= o minimo que o app calculou com a tolerancia do dono`;
//  6. sanidade contra o preco de oraculo e degraus de impacto de preco.
//
// O ranking usa o garantido decodificado, nunca o `expectedOut` que o provedor anuncia
// (inflar o anunciado e justamente como um provedor malicioso venceria a disputa).

/// O que o provedor devolveu, sem nenhuma conferencia ainda.
public struct TradeProposal: Sendable, Equatable {
    public let provider: TradeProvider
    /// O chainId que a resposta declara, se declara.
    public let chainID: UInt64?
    /// O `from` que a resposta declara, se declara.
    public let from: EVMAddress?
    public let to: EVMAddress
    public let value: BigUInt
    public let data: [UInt8]
    /// O que o provedor anuncia como saida provavel. Serve para o minimo do app e para a
    /// tela ("estimado"), nunca para ranquear.
    public let expectedOut: BigUInt
    /// O spender que a resposta declara (approvalAddress, tokenTransferProxy).
    public let spender: EVMAddress?
    /// Gas que o provedor estima. So para comparar provedores; o plano estima o seu.
    public let gasEstimate: UInt64?
    /// Pools ou DEXes da rota, em minusculas. `nil` quando a rota e opaca (a divisao
    /// entre provedores so usa rotas conhecidas e disjuntas).
    public let routeSources: Set<String>?
    /// Impacto de preco em bps, pelos valores em dolar que o provedor informa.
    public let reportedPriceImpactBps: Int?

    public init(
        provider: TradeProvider, chainID: UInt64?, from: EVMAddress?, to: EVMAddress, value: BigUInt, data: [UInt8],
        expectedOut: BigUInt, spender: EVMAddress?, gasEstimate: UInt64?, routeSources: Set<String>?,
        reportedPriceImpactBps: Int?
    ) {
        self.provider = provider
        self.chainID = chainID
        self.from = from
        self.to = to
        self.value = value
        self.data = data
        self.expectedOut = expectedOut
        self.spender = spender
        self.gasEstimate = gasEstimate
        self.routeSources = routeSources
        self.reportedPriceImpactBps = reportedPriceImpactBps
    }
}

/// A referencia de mercado que o chamador passa: a saida esperada pelo preco de
/// oraculo (CoinGecko pelo MarketService). Oraculo e cotacao chegam pelo mesmo caminho,
/// entao isto e sanidade, nao garantia (docs/seguranca.md 4.3 item 7).
public struct TradeMarketReference: Sendable, Equatable {
    /// Quanto do token comprado `amountIn` vale pelo oraculo, em unidades do token.
    public let oracleOut: BigUInt?

    public static let none = TradeMarketReference(oracleOut: nil)

    public init(oracleOut: BigUInt?) {
        self.oracleOut = oracleOut
    }

    /// A partir de precos em dolar (texto decimal, como o oraculo devolve): converte
    /// `amountIn` para unidades do token comprado com aritmetica inteira exata.
    public init(amountIn: BigUInt, sell: TradeAsset, buy: TradeAsset, sellPriceUSD: String, buyPriceUSD: String) {
        self.init(amountIn: amountIn, sellDecimals: sell.decimals, buyDecimals: buy.decimals, sellPriceUSD: sellPriceUSD, buyPriceUSD: buyPriceUSD)
    }

    /// O mesmo para qualquer rede, pelas casas de cada lado.
    public init(amountIn: BigUInt, sellDecimals: Int, buyDecimals: Int, sellPriceUSD: String, buyPriceUSD: String) {
        guard let sellPrice = TradeDecimal(sellPriceUSD), let buyPrice = TradeDecimal(buyPriceUSD), !buyPrice.mantissa.isZero,
              (0...36).contains(sellDecimals), (0...36).contains(buyDecimals)
        else {
            self.oracleOut = nil
            return
        }
        // out = amountIn * sellPrice / buyPrice * 10^(buyDecimals - sellDecimals)
        var numerator = amountIn * sellPrice.mantissa * BigUInt.power(of: 10, buyPrice.scale + buyDecimals)
        var denominator = buyPrice.mantissa * BigUInt.power(of: 10, sellPrice.scale + sellDecimals)
        if denominator.isZero { denominator = 1; numerator = 0 }
        self.oracleOut = numerator / denominator
    }

    /// Quanto `expected` fica abaixo da referencia, em bps (negativo = melhor). nil sem
    /// referencia.
    public func deviationBps(expected: BigUInt) -> Int? {
        guard let oracle = oracleOut, !oracle.isZero else { return nil }
        return TradeMath.deviationBps(actual: expected, reference: oracle)
    }

    /// A sanidade das trocas de todas as redes (docs/seguranca.md 4.3 item 7): pior que a
    /// referencia em mais de 5% recusa; devolve o desvio para a tela avisar acima de 2%.
    /// Referencia e cotacao chegam por caminhos que o app nao controla, entao isto e
    /// sanidade, nao garantia: a garantia e o minimo gravado na transacao.
    @discardableResult
    public func check(expected: BigUInt) throws -> Int? {
        guard let deviation = deviationBps(expected: expected) else { return nil }
        guard deviation <= TradeRiskAssessment.oracleBlockBps else { throw TradeRefusal.priceFarFromOracle(deviationBps: deviation) }
        return deviation
    }

    /// Acima do degrau de aviso (2%).
    public static func warns(_ deviation: Int?) -> Bool {
        guard let deviation else { return false }
        return deviation > TradeRiskAssessment.oracleWarnBps
    }
}

/// O risco de mercado de uma cotacao, em degraus.
public struct TradeRiskAssessment: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        /// Nada a mostrar alem do normal.
        case normal
        /// Aviso visivel na revisao (impacto acima de 1%, preco 2% pior que o oraculo).
        case visible
        /// Exige confirmacao explicita do dono (impacto acima de 5%).
        case confirm

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // Degraus de docs/seguranca.md 4.3 e do pedido do dono.
    public static let impactVisibleBps = 100
    public static let impactConfirmBps = 500
    public static let impactBlockBps = 1_500
    public static let oracleWarnBps = 200
    public static let oracleBlockBps = 500

    /// Impacto de preco em bps, se conhecido.
    public let priceImpactBps: Int?
    /// Quanto a cotacao e pior que o oraculo, em bps (negativo = melhor).
    public let oracleDeviationBps: Int?
    public let level: Level

    public var requiresConfirmation: Bool { level == .confirm }

    public var warnings: [PlanReview.Warning] {
        guard let impact = priceImpactBps, impact > Self.impactVisibleBps else { return [] }
        return [.highPriceImpact(percent: Double(impact) / 100)]
    }

    /// Avalia, ou lanca se passa do degrau de bloqueio.
    static func assess(expectedOut: BigUInt, oracleOut: BigUInt?, reportedImpactBps: Int?) throws -> TradeRiskAssessment {
        var deviation: Int?
        if let oracle = oracleOut, !oracle.isZero {
            deviation = TradeMath.deviationBps(actual: expectedOut, reference: oracle)
        }
        if let deviation, deviation > oracleBlockBps { throw TradeRefusal.priceFarFromOracle(deviationBps: deviation) }
        // Sem impacto informado, o desvio do oraculo e a melhor medida que existe.
        let impact = reportedImpactBps.map { max(0, $0) } ?? deviation.map { max(0, $0) }
        if let impact, impact > impactBlockBps { throw TradeRefusal.priceImpactTooHigh(bps: impact) }

        var level = Level.normal
        if let impact, impact > impactVisibleBps { level = max(level, .visible) }
        if let impact, impact > impactConfirmBps { level = max(level, .confirm) }
        if let deviation, deviation > oracleWarnBps { level = max(level, .visible) }
        return TradeRiskAssessment(priceImpactBps: impact, oracleDeviationBps: deviation, level: level)
    }
}

/// Uma cotacao que passou por toda a validacao. So nasce aqui: o inicializador e
/// interno ao modulo, e o planejamento so aceita este tipo.
public struct ValidatedTradeQuote: Sendable, Equatable {
    /// Uma cotacao validada vale 60 s, o mesmo que um plano (docs/seguranca.md 4.2).
    public static let lifetime: TimeInterval = 60

    public let intent: TradeIntent
    public let router: TradeRouter
    public let to: EVMAddress
    public let value: BigUInt
    public let data: [UInt8]
    public let decoded: DecodedSwap
    /// O estimado para a tela: o anunciado, limitado pelo teto do router quando ha.
    public let expectedOut: BigUInt
    /// O minimo que o app exigiu: `expected * (1 - tolerancia)`.
    public let requiredMinimum: BigUInt
    public let assessment: TradeRiskAssessment
    public let gasEstimate: UInt64?
    public let routeSources: Set<String>?
    public let validatedAt: Date

    public var provider: TradeProvider { router.provider }
    /// O que chega, no minimo, pelo codigo do router. E o numero que ranqueia.
    public var guaranteedOut: BigUInt { decoded.guaranteedOut }
    public var spender: EVMAddress { router.spender }

    public func isExpired(now: Date = .now) -> Bool {
        now.timeIntervalSince(validatedAt) > Self.lifetime || now < validatedAt.addingTimeInterval(-5)
    }
}

public enum TradeValidator {
    /// Prazo maximo aceito numa calldata que tem prazo.
    public static let maxDeadline: TimeInterval = 20 * 60
    /// Folga de arredondamento no minimo, em unidades do token comprado: a poeira de
    /// 1 wei da Augustus e o arredondamento para cima/baixo de cada API.
    static let roundingSlack = BigUInt(2)

    public static func validate(
        _ proposal: TradeProposal, intent: TradeIntent, market: TradeMarketReference = .none, now: Date = .now
    ) throws -> ValidatedTradeQuote {
        let chain = intent.chain
        guard let chainID = chain.evmChainID else { throw TradeRefusal.notEVMChain }
        if let declared = proposal.chainID, declared != chainID { throw TradeRefusal.chainIDMismatch }
        if let from = proposal.from, from != intent.owner { throw TradeRefusal.senderMismatch(from) }

        guard let router = TradeAllowlist.router(for: proposal.provider, on: chain) else {
            throw TradeRefusal.providerNotOnChain(proposal.provider)
        }
        guard proposal.to == router.address else { throw TradeRefusal.routerNotAllowed(proposal.to) }
        if let spender = proposal.spender, spender != router.spender { throw TradeRefusal.spenderNotAllowed(spender) }
        guard proposal.data.count >= 4 else { throw TradeRefusal.callRefused(.malformedCalldata) }
        let selector = Array(proposal.data.prefix(4))
        guard router.selectors.contains(selector) else { throw TradeRefusal.selectorNotAllowed(selector) }

        let fee = TradeFeeSchedule.escaliburFee(provider: proposal.provider, chain: chain)
        let context = TradeDecodeContext(intent: intent, router: router, fee: fee, value: proposal.value)
        let decoded = try decode(proposal, router: router, context: context)

        // Tokens e valor.
        let sentinel = router.nativeSentinel
        guard decoded.sellToken == intent.sell.routerAddress(nativeSentinel: sentinel) else { throw TradeRefusal.sellTokenMismatch }
        guard decoded.buyToken == intent.buy.routerAddress(nativeSentinel: sentinel) else { throw TradeRefusal.buyTokenMismatch }
        guard decoded.amountIn == intent.amountIn else {
            throw TradeRefusal.amountInMismatch(expected: intent.amountIn, found: decoded.amountIn)
        }
        // msg.value: o valor inteiro so se vende nativo; zero em qualquer outro caso.
        let expectedValue = intent.sell.isNative ? intent.amountIn : BigUInt()
        guard proposal.value == expectedValue else { throw TradeRefusal.valueMismatch(expected: expectedValue, found: proposal.value) }
        guard decoded.recipient == intent.owner else { throw TradeRefusal.recipientMismatch(decoded.recipient) }

        // Taxas.
        guard decoded.integratorFee == fee else { throw TradeRefusal.integratorFeeMismatch }
        let ceiling = TradeFeeSchedule.providerFeeCeilingBps(proposal.provider)
        if !decoded.providerFeeAmount.isZero {
            let bps = TradeMath.ceilBps(decoded.providerFeeAmount, of: intent.amountIn)
            guard bps <= ceiling else { throw TradeRefusal.providerFeeTooHigh(bps: bps) }
        }

        // Prazo, quando o router confere um (auditoria 2, B5). Nenhum dos quatro routers
        // da v1 confere prazo na funcao aceita; conferido no fonte verificado (Sourcify,
        // Ethereum) em 26/09/2026:
        // - Velora, AugustusV6 `swapExactAmountIn`: `GenericData` nao tem prazo, e nada
        //   no contrato le `block.timestamp` fora do permit;
        // - KyberSwap, MetaAggregationRouterV2 `swap`: `SwapDescriptionV2` nao tem prazo;
        //   o router so confere prazo no modo simples (`SimpleSwapData.deadline`), que a
        //   carteira recusa. A API poe um prazo nos dados do executor (20 minutos por
        //   padrao, pela especificacao da API; o valor aparece nas gravacoes), mas o
        //   executor e opaco e sem codigo verificado, e a carteira nao conta com ele;
        // - LI.FI, GenericSwapFacetV3: nenhum argumento de prazo; `block.timestamp` so
        //   entra nos eventos. Prazos de DEX dentro das `callData` sao opacos;
        // - De¹, OpenOceanExchange `swap`/`simpleSwap`: sem prazo, so no permit.
        // O minimo protege o preco; a execucao tardia so e dita na revisao
        // (`TradePlanner.deadlineLine`). Um router que confira prazo tem o decodificador
        // preenchendo `deadline`, e aqui ele tem de estar entre agora e 20 minutos.
        try checkDeadline(decoded.deadline, now: now)

        // O minimo: calculado pelo app, com a tolerancia do dono, a partir do estimado.
        var expected = proposal.expectedOut
        if let cap = decoded.outputCap, cap < expected { expected = cap }
        let required = intent.minimumOut(forExpected: expected)
        guard !decoded.guaranteedOut.isZero else { throw TradeRefusal.zeroMinimumOut }
        guard decoded.guaranteedOut + roundingSlack >= required else {
            throw TradeRefusal.minimumOutTooLow(found: decoded.guaranteedOut, required: required)
        }

        let assessment = try TradeRiskAssessment.assess(
            expectedOut: expected, oracleOut: market.oracleOut, reportedImpactBps: proposal.reportedPriceImpactBps
        )
        return ValidatedTradeQuote(
            intent: intent, router: router, to: proposal.to, value: proposal.value, data: proposal.data,
            decoded: decoded, expectedOut: expected, requiredMinimum: required, assessment: assessment,
            gasEstimate: proposal.gasEstimate, routeSources: proposal.routeSources, validatedAt: now
        )
    }

    /// O minimo ancorado fora do proprio provedor (auditoria 2, M5).
    ///
    /// Cada cotacao ja exige `minOut >= esperado x (1 - tolerancia)`, mas o esperado e o
    /// numero que o proprio provedor anuncia: um provedor que cota baixo rebaixa o proprio
    /// minimo. Por isso a troca so segue com uma ancora de fora:
    /// - com preco de referencia, cada cotacao ja passou pela sanidade (5% pior bloqueia);
    /// - sem referencia, pelo menos duas cotacoes validas, e so ficam as que garantem o
    ///   minimo calculado da maior estimativa entre elas.
    public static func anchored(_ quotes: [ValidatedTradeQuote], market: TradeMarketReference) throws -> [ValidatedTradeQuote] {
        guard !quotes.isEmpty, market.oracleOut == nil else { return quotes }
        guard quotes.count >= 2, let anchor = quotes.map(\.expectedOut).max() else { throw TradeRefusal.noPriceAnchor }
        let kept = quotes.filter { $0.guaranteedOut + roundingSlack >= $0.intent.minimumOut(forExpected: anchor) }
        guard !kept.isEmpty else {
            let best = quotes.map(\.guaranteedOut).max() ?? BigUInt()
            throw TradeRefusal.minimumOutTooLow(found: best, required: quotes[0].intent.minimumOut(forExpected: anchor))
        }
        return kept
    }

    /// Prazo ate 20 minutos a frente; vencido ou mais longe, recusa.
    static func checkDeadline(_ deadline: UInt64?, now: Date) throws {
        guard let deadline else { return }
        let current = UInt64(max(0, now.timeIntervalSince1970))
        guard deadline > current else { throw TradeRefusal.deadlineExpired }
        guard deadline - current <= UInt64(maxDeadline) else { throw TradeRefusal.deadlineTooFar(seconds: deadline - current) }
    }

    /// Passa a calldata pela guarda de chamada com as regras do router: seletor, lista
    /// de recusas e decodificacao canonica; depois o decodificador do provedor.
    static func decode(_ proposal: TradeProposal, router: TradeRouter, context: TradeDecodeContext) throws -> DecodedSwap {
        let rules = router.functions.map { function in
            EVMContractCallRule(contract: router.address, function: function) { arguments, _ in
                _ = try router.decode(function: function, arguments: arguments, context: context)
            }
        }
        let call: EVMDecodedCall
        do {
            call = try EVMCallGuard.inspect(
                EVMCallProposal(transactionType: 2, to: proposal.to, value: proposal.value, data: proposal.data),
                policy: EVMCallPolicy(contractRules: rules)
            )
        } catch let refusal as EVMCallRefusal {
            if case .unknownSelector(let selector) = refusal { throw TradeRefusal.selectorNotAllowed(selector) }
            throw TradeRefusal.callRefused(refusal)
        }
        guard case .contractCall(let contract, let signature, let arguments, _) = call, contract == router.address,
              let function = router.functions.first(where: { $0.signature == signature })
        else { throw TradeRefusal.callRefused(.malformedCalldata) }
        return try router.decode(function: function, arguments: arguments, context: context)
    }
}

/// Contas inteiras de bps, sem Double.
enum TradeMath {
    /// ceil(part * 10000 / whole), saturado em UInt32.
    static func ceilBps(_ part: BigUInt, of whole: BigUInt) -> UInt32 {
        guard !whole.isZero else { return UInt32.max }
        let bps = (part * TradeConstants.basisPoints + whole - 1) / whole
        return bps.uint64.map { UInt32(min($0, UInt64(UInt32.max))) } ?? UInt32.max
    }

    /// Quanto `actual` fica abaixo de `reference`, em bps. Negativo se acima.
    static func deviationBps(actual: BigUInt, reference: BigUInt) -> Int {
        guard !reference.isZero else { return 0 }
        if actual <= reference {
            let bps = (reference - actual) * TradeConstants.basisPoints / reference
            return Int(min(bps.uint64 ?? 1_000_000, 1_000_000))
        }
        let bps = (actual - reference) * TradeConstants.basisPoints / reference
        return -Int(min(bps.uint64 ?? 1_000_000, 1_000_000))
    }
}
