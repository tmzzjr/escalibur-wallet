import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// A ponte sem rede: o validador com os tetos compilados, o plano com estado e simulacao
/// sinteticos, e cada ataque do modelo de ameaca (docs/seguranca.md 4.12) recusado.
@Suite("Ponte: validador e plano")
struct BridgePlannerTests {
    typealias T = EVMTestSupport
    typealias S = TradeTestSupport

    static let wallet = UUID()
    static let now = Date(timeIntervalSince1970: 1_791_769_979)
    static let owner = S.owner

    static let fees = CCTPFees(
        fast: .init(protocolBps: TradeDecimal("1")!, forwardFee: BigUInt(54_386)),
        standard: .init(protocolBps: TradeDecimal("0")!, forwardFee: BigUInt(54_386))
    )

    static func usdcIntent(_ amount: BigUInt = 100_000_000, from: Chain = .base, to: Chain = .arbitrum) throws -> BridgeIntent {
        try BridgeIntent(owner: owner, asset: .usdc, from: from, to: to, amount: amount)
    }

    static func cctpQuote(_ route: BridgeRoute = .cctpFast) throws -> ValidatedBridgeQuote {
        try BridgeValidator.cctp(try usdcIntent(), route: route, fees: fees, fastAllowance: BigUInt(50_000_000_000_000), now: now)
    }

    static func acrossQuote(_ intent: BridgeIntent, output: BigUInt, spoke: EVMAddress? = nil, timestamp: UInt32 = 1_791_769_979,
                            maxDeposit: BigUInt = BigUInt(decimal: "1000000000000000000000")!) -> AcrossQuote {
        AcrossQuote(
            inputAmount: intent.amount, outputAmount: output, quoteTimestamp: timestamp, fillDeadline: timestamp + 7_200,
            exclusiveRelayer: S.stranger, exclusivityDeadline: timestamp + 160, estimatedFillSeconds: 2,
            maxDeposit: maxDeposit, maxDepositInstant: maxDeposit, minDeposit: 1,
            spokePool: spoke ?? intent.from.across!.spokePool, destinationSpokePool: intent.to.across!.spokePool
        )
    }

    // MARK: Eventos e simulacao sinteticos

    static func depositForBurnLog(_ transfer: CCTPTransfer, recipient: EVMAddress? = nil) -> TradeSimulatedLog {
        let data = try! BridgeSimulationCheck.depositForBurnData.encodeCall([
            .uint(transfer.amount), .fixedBytes(CCTPMessage.word(recipient ?? transfer.recipient)),
            .uint(BigUInt(transfer.destinationDomain)), .fixedBytes(CCTPMessage.word(BridgeAllowlist.tokenMessenger)),
            .fixedBytes([UInt8](repeating: 0, count: 32)), .uint(transfer.maxFee), .bytes(CCTPCalldata.forwardHookData),
        ])
        return TradeSimulatedLog(
            address: BridgeAllowlist.tokenMessenger,
            topics: [BridgeSimulationCheck.depositForBurnTopic, S.topic(transfer.usdc), S.topic(transfer.owner), S.word(BigUInt(transfer.finality))],
            data: Array(data.dropFirst(4))
        )
    }

    static func fundsDepositedLog(_ transfer: AcrossTransfer, spoke: EVMAddress, recipient: EVMAddress? = nil) -> TradeSimulatedLog {
        let data = try! BridgeSimulationCheck.fundsDepositedData.encodeCall([
            .fixedBytes(CCTPMessage.word(transfer.inputToken)), .fixedBytes(CCTPMessage.word(transfer.outputToken)),
            .uint(transfer.inputAmount), .uint(transfer.outputAmount), .uint(BigUInt(transfer.quoteTimestamp)),
            .uint(BigUInt(transfer.fillDeadline)), .uint(0), .fixedBytes(CCTPMessage.word(recipient ?? transfer.recipient)),
            .fixedBytes([UInt8](repeating: 0, count: 32)), .bytes([]),
        ])
        return TradeSimulatedLog(
            address: spoke,
            topics: [BridgeSimulationCheck.fundsDepositedTopic, S.word(BigUInt(transfer.destinationChainID)), S.word(7), CCTPMessage.word(transfer.owner)],
            data: Array(data.dropFirst(4))
        )
    }

    /// Uma simulacao honesta: approve exato e o deposito, com o valor saindo do dono e o
    /// evento da ponte com os campos montados.
    static func simulation(_ quote: ValidatedBridgeQuote, source: String, allowance: BigUInt = 0, spent: BigUInt? = nil,
                           event: TradeSimulatedLog? = nil, extra: [TradeSimulatedLog] = []) -> TradeSimulation {
        let intent = quote.intent
        let request = BridgePlanner.simulationRequest(for: quote, currentAllowance: allowance)
        var calls = request.approvals.map { value in
            TradeSimulatedCall(success: true, gasUsed: 46_000, logs: [S.approvalLog(intent.sell.contract!, owner: owner, spender: quote.spender!, value)])
        }
        let moved = intent.sell.contract ?? TradeConstants.eeeeSentinel
        let defaultEvent: TradeSimulatedLog
        switch quote.call {
        case .cctp(let transfer): defaultEvent = depositForBurnLog(transfer)
        case .across(let transfer): defaultEvent = fundsDepositedLog(transfer, spoke: intent.from.across!.spokePool)
        case .mesh(let transfer): defaultEvent = USDT0MeshTests.oftSentLog(transfer)
        }
        calls.append(TradeSimulatedCall(success: true, gasUsed: 120_000, logs: [
            S.transferLog(moved, from: owner, to: quote.to, spent ?? intent.amount), event ?? defaultEvent,
        ] + extra))
        return TradeSimulation(source: source, calls: calls)
    }

    static func state(_ quote: ValidatedBridgeQuote, implementations: [EVMAddress]? = nil, domain: UInt32? = nil,
                      localToken: EVMAddress?? = nil, blacklisted: Bool = false, ownerCode: Bool = false,
                      simulations: [TradeSimulation]? = nil) -> BridgeChainState {
        let intent = quote.intent
        let cctp = quote.route.isCCTP
        return BridgeChainState(
            network: S.network(intent.from.chain), token: intent.sell.isNative ? nil : EVMTokenState(contractHasCode: true, balance: intent.amount, allowance: 0),
            implementations: implementations ?? BridgePlanner.pins(for: quote).map(\.implementation),
            destinationDomain: cctp ? (domain ?? intent.to.cctp!.domain) : nil,
            destinationLocalToken: cctp ? (localToken ?? intent.to.usdc) : nil,
            destinationBlacklisted: cctp ? blacklisted : nil, ownerHasCodeAtDestination: ownerCode,
            simulations: simulations ?? [simulation(quote, source: "a"), simulation(quote, source: "b")],
            // OP Stack (Base, Optimism): a taxa L1 entra no plano.
            approveL1DataFee: BigUInt(1_000), depositL1DataFee: BigUInt(2_000)
        )
    }

    static func plan(_ quote: ValidatedBridgeQuote, _ state: BridgeChainState) throws -> SigningPlan {
        try BridgePlanner.planDeposit(walletID: wallet, account: try T.account(T.testKey), quote: quote, state: state, now: now)
    }

    // MARK: Pedido

    @Test("So as quatro redes, so a mesma moeda do emissor")
    func intents() throws {
        #expect(throws: BridgeRefusal.sameChain) { try BridgeIntent(owner: Self.owner, asset: .usdc, from: .base, to: .base, amount: 1) }
        // A BNB nao cunha USDC da Circle: o USDC para la vai pelo Across, nunca pelo CCTP.
        let toBNB = try BridgeIntent(owner: Self.owner, asset: .usdc, from: .ethereum, to: .bnb, amount: 1)
        #expect(!BridgeAsset.usesCCTP(.usdc, from: toBNB.from, to: toBNB.to))
        #expect(throws: BridgeRefusal.unsupportedRoute) { try BridgeIntent(owner: Self.owner, asset: .usdt, from: .ethereum, to: .base, amount: 1) }
        _ = try BridgeIntent(owner: Self.owner, asset: .usdt, from: .ethereum, to: .arbitrum, amount: 1)
        #expect(throws: BridgeRefusal.zeroAmount) { try BridgeIntent(owner: Self.owner, asset: .eth, from: .base, to: .optimism, amount: 0) }
        #expect(throws: BridgeRefusal.aboveBurnLimit(limit: BridgeAllowlist.burnLimitPerMessage)) {
            try Self.usdcIntent(BridgeAllowlist.burnLimitPerMessage + 1)
        }
    }

    @Test("BNB pelo Across: 18 casas no USDC, no USDT e no ETH de la, a taxa na unidade da origem, e o ETH entra como token")
    func bnbAcross() throws {
        let bnb = BridgeAllowlist.bnb
        #expect(BridgeAsset.usdc.decimals(on: bnb) == 18 && BridgeAsset.usdc.decimals(on: BridgeAllowlist.base) == 6)
        #expect(BridgeAsset.rescale(BigUInt(1_000_000), from: 6, to: 18) == BigUInt.power(of: 10, 18))
        #expect(BridgeAsset.rescale(BigUInt.power(of: 10, 18) + 999, from: 18, to: 6) == BigUInt(1_000_000))

        // 100 USDC da Base (6 casas) para a BNB: chegam 99,8 USDC da BNB (18 casas).
        let intent = try BridgeIntent(owner: Self.owner, asset: .usdc, from: .base, to: .bnb, amount: BigUInt(100_000_000))
        let output = BigUInt(decimal: "99800000000000000000")!
        let quote = try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: output), usdPrice: nil, now: Self.now)
        #expect(quote.route == .across && quote.bridgeFee == BigUInt(200_000) && quote.minimumReceived == output)
        guard case .across(let transfer) = quote.call else { Issue.record("rota"); return }
        #expect(transfer.outputToken == bnb.usdc && transfer.inputToken == BridgeAllowlist.base.usdc && !transfer.nativeInput)
        // Chegar mais do que saiu, na unidade da origem, e erro da cotacao.
        #expect(throws: BridgeRefusal.quoteMismatch("valor")) {
            try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: BigUInt(decimal: "100000001000000000000")!), usdPrice: nil, now: Self.now)
        }
        // Taxa acima do teto (US$ 3 em 100 USDC), contada nas 6 casas da origem.
        #expect(throws: BridgeRefusal.feeAboveCap) {
            try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: BigUInt(decimal: "96000000000000000000")!), usdPrice: nil, now: Self.now)
        }

        // A API dizendo 6 casas para o USDC da BNB: o token nao e o compilado, recusa.
        let honest = Self.acrossQuote(intent, output: output)
        let lying = AcrossQuote(
            inputAmount: honest.inputAmount, outputAmount: honest.outputAmount, quoteTimestamp: honest.quoteTimestamp,
            fillDeadline: honest.fillDeadline, exclusiveRelayer: honest.exclusiveRelayer, exclusivityDeadline: honest.exclusivityDeadline,
            estimatedFillSeconds: honest.estimatedFillSeconds, maxDeposit: honest.maxDeposit, maxDepositInstant: honest.maxDepositInstant,
            minDeposit: honest.minDeposit, spokePool: honest.spokePool, destinationSpokePool: honest.destinationSpokePool,
            inputDecimals: 6, outputDecimals: 6
        )
        #expect(throws: BridgeRefusal.quoteMismatch("casas")) { try BridgeValidator.across(intent, quote: lying, usdPrice: nil, now: Self.now) }

        // Da BNB para a Base: o USDT de la tem 18 casas, o teto de US$ 3 tambem.
        let back = try BridgeIntent(owner: Self.owner, asset: .usdt, from: .bnb, to: .arbitrum, amount: BigUInt.power(of: 10, 20))
        let fair = try BridgeValidator.across(back, quote: Self.acrossQuote(back, output: BigUInt(99_000_000)), usdPrice: nil, now: Self.now)
        #expect(fair.bridgeFee == BigUInt.power(of: 10, 18))

        // ETH saindo da BNB e token (approve exato, sem value); chegando na Base, e nativo.
        let eth = try BridgeIntent(owner: Self.owner, asset: .eth, from: .bnb, to: .base, amount: BigUInt.power(of: 10, 17))
        let ethQuote = try BridgeValidator.across(eth, quote: Self.acrossQuote(eth, output: BigUInt.power(of: 10, 17) - BigUInt.power(of: 10, 14)),
                                                  usdPrice: TradeDecimal("3000"), now: Self.now)
        guard case .across(let ethTransfer) = ethQuote.call else { Issue.record("rota"); return }
        #expect(!ethTransfer.nativeInput && ethQuote.value.isZero && ethQuote.spender == bnb.across!.spokePool)
        #expect(ethTransfer.inputToken == bnb.ethToken && ethTransfer.outputToken == BridgeAllowlist.base.across!.wrappedNative)
        // Para a Polygon nao: la o ETH e WETH de ponte, fora da lista da ponte.
        #expect(throws: BridgeRefusal.unsupportedRoute) { try BridgeIntent(owner: Self.owner, asset: .eth, from: .bnb, to: .polygon, amount: 1) }
        // CCTP para a BNB nunca: a rota rapida ou padrao recusa.
        #expect(throws: BridgeRefusal.unsupportedRoute) {
            try BridgeValidator.cctp(intent, route: .cctpStandard, fees: CCTPFees(fast: nil, standard: .init(protocolBps: TradeDecimal("0")!, forwardFee: 0)),
                                     fastAllowance: nil, now: Self.now)
        }
    }

    @Test("Revisao da ponte BNB: pin do USDC da Binance, aviso Binance-Peg, unidade mais fina e rota igual a chamada")
    func bnbReviewFixes() throws {
        let intent = try BridgeIntent(owner: Self.owner, asset: .usdc, from: .base, to: .bnb, amount: BigUInt(100_000_000))
        let output = BigUInt(decimal: "99800000000000000000")!
        let quote = try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: output), usdPrice: nil, now: Self.now)
        // B1: o USDC da BNB e proxy; a implementacao entra nos pins.
        let pins = BridgePlanner.pins(for: quote)
        #expect(pins.count == 3 && pins.last?.proxy == BridgeAllowlist.bnb.usdc && pins.last?.chain.id == "bnb")
        #expect(pins.last?.implementation == BridgeAllowlist.bnb.usdcImplementation)
        // M1: a revisao diz que na BNB e o da Binance.
        let plan = try Self.plan(quote, Self.state(quote))
        #expect(plan.review.warnings.contains(.binancePeg(symbol: "USDC")))
        #expect(plan.review.lines.contains { $0.label == "Na BNB" })
        // I1: 1 wei de 18 casas acima do que saiu de 6 casas e recusado.
        #expect(!BridgeAsset.fits(BigUInt.power(of: 10, 20) + 1, outputDecimals: 18, within: BigUInt(100_000_000), inputDecimals: 6))
        #expect(BridgeAsset.fits(BigUInt.power(of: 10, 20), outputDecimals: 18, within: BigUInt(100_000_000), inputDecimals: 6))
        #expect(throws: BridgeRefusal.quoteMismatch("valor")) {
            try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: BigUInt.power(of: 10, 20) + 1), usdPrice: nil, now: Self.now)
        }
        // I2: uma queima rotulada como Across (ou o contrario) nao vira pino nem plano.
        guard case .across(let transfer) = quote.call else { Issue.record("rota"); return }
        let lying = ValidatedBridgeQuote(
            intent: quote.intent, route: .cctpStandard, call: .across(transfer), to: quote.to, value: quote.value, data: quote.data,
            spender: quote.spender, minimumReceived: quote.minimumReceived, expectedReceived: quote.expectedReceived,
            bridgeFee: quote.bridgeFee, estimatedSeconds: quote.estimatedSeconds, createdAt: quote.createdAt
        )
        #expect(!lying.callMatchesRoute && BridgePlanner.pins(for: lying).isEmpty)
        #expect(throws: BridgeRefusal.unsupportedRoute) {
            try Self.plan(lying, Self.state(quote))
        }
    }

    @Test("Segunda leva: USDC em todas, ETH so onde o nativo e ETH, USDT so com USDT0 dos dois lados, Sonic sem Across")
    func secondWave() throws {
        _ = try BridgeIntent(owner: Self.owner, asset: .usdc, from: .polygon, to: .sonic, amount: 1)
        _ = try BridgeIntent(owner: Self.owner, asset: .usdc, from: .plasma, to: .linea, amount: 1)
        _ = try BridgeIntent(owner: Self.owner, asset: .eth, from: .linea, to: .unichain, amount: 1)
        _ = try BridgeIntent(owner: Self.owner, asset: .usdt, from: .unichain, to: .plasma, amount: 1)
        _ = try BridgeIntent(owner: Self.owner, asset: .usdt, from: .ethereum, to: .plasma, amount: 1)
        // ETH na Polygon e WETH de ponte; na Plasma o nativo e XPL; a Sonic nao tem Across.
        #expect(throws: BridgeRefusal.unsupportedRoute) { try BridgeIntent(owner: Self.owner, asset: .eth, from: .base, to: .polygon, amount: 1) }
        #expect(throws: BridgeRefusal.unsupportedRoute) { try BridgeIntent(owner: Self.owner, asset: .eth, from: .base, to: .plasma, amount: 1) }
        #expect(throws: BridgeRefusal.unsupportedRoute) { try BridgeIntent(owner: Self.owner, asset: .eth, from: .base, to: .sonic, amount: 1) }
        #expect(throws: BridgeRefusal.unsupportedRoute) { try BridgeIntent(owner: Self.owner, asset: .usdt, from: .ethereum, to: .polygon, amount: 1) }
        #expect(throws: BridgeRefusal.unsupportedRoute) { try BridgeIntent(owner: Self.owner, asset: .usdt, from: .ethereum, to: .linea, amount: 1) }
        // Dominios do CCTP, cada um diferente; a BNB nao tem CCTP (a Circle nao cunha la).
        let domains = BridgeAllowlist.chains.compactMap(\.cctp?.domain)
        #expect(Set(domains).count == domains.count)
        #expect(BridgeAllowlist.bnb.cctp == nil && domains.count == BridgeAllowlist.chains.count - 1)
    }

    // MARK: Validador

    @Test("CCTP: tetos de taxa e limite rapido")
    func cctpCaps() throws {
        let intent = try Self.usdcIntent()
        let quote = try Self.cctpQuote()
        // 100 USDC a 1 bps: 0,01 USDC, mais o encaminhamento.
        #expect(quote.bridgeFee == BigUInt(10_000 + 54_386))
        #expect(quote.minimumReceived == intent.amount - quote.bridgeFee)
        let expensive = CCTPFees(fast: .init(protocolBps: TradeDecimal("3")!, forwardFee: 0), standard: nil)
        #expect(throws: BridgeRefusal.feeAboveCap) { try BridgeValidator.cctp(intent, route: .cctpFast, fees: expensive, fastAllowance: intent.amount) }
        let paidStandard = CCTPFees(fast: nil, standard: .init(protocolBps: TradeDecimal("0.5")!, forwardFee: 0))
        #expect(throws: BridgeRefusal.feeAboveCap) { try BridgeValidator.cctp(intent, route: .cctpStandard, fees: paidStandard, fastAllowance: nil) }
        let greedyForward = CCTPFees(fast: nil, standard: .init(protocolBps: TradeDecimal("0")!, forwardFee: BigUInt(10_000_001)))
        #expect(throws: BridgeRefusal.feeAboveCap) { try BridgeValidator.cctp(intent, route: .cctpStandard, fees: greedyForward, fastAllowance: nil) }
        #expect(throws: BridgeRefusal.fastUnavailable) { try BridgeValidator.cctp(intent, route: .cctpFast, fees: Self.fees, fastAllowance: 1) }
        // 1 USDC com 0,05 de encaminhamento: a taxa passa de 5%.
        #expect(throws: BridgeRefusal.feeTooHigh(percent: 5.4386)) {
            try BridgeValidator.cctp(try Self.usdcIntent(1_000_000), route: .cctpStandard, fees: Self.fees, fastAllowance: nil)
        }
    }

    @Test("Across: SpokePool, taxa, horario e limite; sem relayer exclusivo e prazo da carteira")
    func acrossCaps() throws {
        let intent = try BridgeIntent(owner: Self.owner, asset: .eth, from: .base, to: .arbitrum, amount: BigUInt(decimal: "1000000000000000000")!)
        let price = TradeDecimal("3000")
        let fair = Self.acrossQuote(intent, output: BigUInt(decimal: "999000000000000000")!)
        let quote = try BridgeValidator.across(intent, quote: fair, usdPrice: price, now: Self.now)
        guard case .across(let transfer) = quote.call else { Issue.record("rota"); return }
        #expect(transfer.exclusiveRelayer == nil && transfer.exclusivityDeadline == 0)
        #expect(transfer.fillDeadline == fair.quoteTimestamp + BridgeValidator.acrossFillWindow)
        #expect(transfer.depositorIsOwner)
        #expect(quote.value == intent.amount && quote.spender == nil)

        #expect(throws: BridgeRefusal.quoteMismatch("SpokePool")) {
            try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: fair.outputAmount, spoke: S.stranger), usdPrice: price, now: Self.now)
        }
        // 1% de taxa num ETH a US$ 3.000: acima de 0,5% e de US$ 3.
        #expect(throws: BridgeRefusal.feeAboveCap) {
            try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: BigUInt(decimal: "990000000000000000")!), usdPrice: price, now: Self.now)
        }
        #expect(throws: BridgeRefusal.quoteMismatch("horário")) {
            try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: fair.outputAmount, timestamp: 1_791_760_000), usdPrice: price, now: Self.now)
        }
        #expect(throws: BridgeRefusal.aboveRouteLimit(maximum: 1)) {
            try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: fair.outputAmount, maxDeposit: 1), usdPrice: price, now: Self.now)
        }
        // US$ 3 vale mais que 0,5% num deposito pequeno.
        #expect(BridgeValidator.acrossFeeCap(BigUInt(100_000_000), asset: .usdt, decimals: 6, usdPrice: nil) == BigUInt(3_000_000))
        // Preco de uma fonte so, errado para baixo: o teto do ETH para em 0,002 ETH, e nao
        // sobe ate os 5% do bloqueio (pentest B5). 10 ETH: o maior e o 0,5%, 0,05 ETH.
        let tiny = TradeDecimal("0.000001")
        let ether = BigUInt.power(of: 10, 18)
        #expect(BridgeValidator.acrossFeeCap(ether / BigUInt(10), asset: .eth, decimals: 18, usdPrice: tiny) == BridgeValidator.acrossFeeCapETHWei)
        #expect(BridgeValidator.acrossFeeCap(ether * BigUInt(10), asset: .eth, decimals: 18, usdPrice: tiny) == ether * BigUInt(10) * BigUInt(50) / BigUInt(10_000))
        // Preco honesto (US$ 3.000): US$ 3 sao 0,001 ETH, abaixo do teto absoluto.
        #expect(BridgeValidator.acrossFeeCap(ether / BigUInt(10), asset: .eth, decimals: 18, usdPrice: TradeDecimal("3000")) == ether / BigUInt(1_000))
    }

    // MARK: Plano

    @Test("CCTP honesto: autorizar e queimar, revisao e conferencia com o pedido")
    func cctpPlan() throws {
        let quote = try Self.cctpQuote()
        let plan = try Self.plan(quote, Self.state(quote))
        #expect(plan.transactions.count == 2)
        #expect(plan.review.kind == .bridge)
        #expect(plan.review.lines.contains { $0.label == "Endereço que recebe" && $0.value == Self.owner.checksummed && $0.verbatim })
        #expect(plan.review.lines.contains { $0.label == "Autorização" && $0.value.hasPrefix("Exata") })
        let intent = quote.intent
        try PlanIntentCheck.bridge(plan.review, sell: intent.asset.asset(on: intent.from)!, amount: intent.amount, from: .base,
                                   receive: intent.asset.asset(on: intent.to)!, minimumOut: quote.minimumReceived, to: .arbitrum,
                                   owner: Self.owner.checksummed)
        // A conferencia recusa o mesmo plano lido contra outro destino.
        #expect(throws: PlanIntentCheck.Mismatch.wrongBuyAsset) {
            try PlanIntentCheck.bridge(plan.review, sell: intent.asset.asset(on: intent.from)!, amount: intent.amount, from: .base,
                                       receive: intent.asset.asset(on: BridgeAllowlist.optimism)!, minimumOut: quote.minimumReceived,
                                       to: .optimism, owner: Self.owner.checksummed)
        }
    }

    @Test("Destino que nao cunha, bloqueio, conta com codigo e proxy trocado: recusa")
    func destinationRefusals() throws {
        let quote = try Self.cctpQuote()
        // O caso da BNB: o destino devolve zero em getLocalToken.
        #expect(throws: BridgeRefusal.destinationDoesNotMint) { try Self.plan(quote, Self.state(quote, localToken: .some(nil))) }
        #expect(throws: BridgeRefusal.destinationDoesNotMint) { try Self.plan(quote, Self.state(quote, localToken: .some(S.stranger))) }
        #expect(throws: BridgeRefusal.destinationDoesNotMint) { try Self.plan(quote, Self.state(quote, domain: 17)) }
        #expect(throws: BridgeRefusal.destinationBlacklisted) { try Self.plan(quote, Self.state(quote, blacklisted: true)) }
        // Delegacao EIP-7702 (um varredor) ou contrato no destino.
        #expect(throws: BridgeRefusal.destinationHasCode) { try Self.plan(quote, Self.state(quote, ownerCode: true)) }
        var swapped = BridgePlanner.pins(for: quote).map(\.implementation)
        swapped[2] = S.stranger
        #expect(throws: BridgeRefusal.implementationChanged("TokenMessengerV2 na Arbitrum")) {
            try Self.plan(quote, Self.state(quote, implementations: swapped))
        }
    }

    @Test("Simulacao: uma fonte, valor errado, outro token saindo ou evento diferente: recusa")
    func simulationRefusals() throws {
        let quote = try Self.cctpQuote()
        guard case .cctp(let transfer) = quote.call else { return }
        let honest = Self.simulation(quote, source: "a")
        func plan(_ other: TradeSimulation) throws { _ = try Self.plan(quote, Self.state(quote, simulations: [honest, other])) }
        #expect(throws: BridgeRefusal.simulationUnavailable) { _ = try Self.plan(quote, Self.state(quote, simulations: [honest, honest])) }
        #expect(throws: BridgeRefusal.simulationSpentWrong(found: quote.intent.amount - 1, expected: quote.intent.amount)) {
            try plan(Self.simulation(quote, source: "b", spent: quote.intent.amount - 1))
        }
        let weth = T.address("0x4200000000000000000000000000000000000006")
        #expect(throws: BridgeRefusal.simulationUnexpectedTransfer(token: weth)) {
            try plan(Self.simulation(quote, source: "b", extra: [S.transferLog(weth, from: Self.owner, to: S.stranger, 1)]))
        }
        // O contrato cunharia para outra conta: o evento nao bate.
        #expect(throws: BridgeRefusal.simulationEventMissing) {
            try plan(Self.simulation(quote, source: "b", event: Self.depositForBurnLog(transfer, recipient: S.stranger)))
        }
        // Nenhum evento da ponte.
        #expect(throws: BridgeRefusal.simulationEventMissing) {
            try plan(Self.simulation(quote, source: "b", event: S.transferLog(weth, from: S.stranger, to: S.stranger, 0)))
        }
        #expect(throws: BridgeRefusal.simulationUnexpectedApproval(token: quote.intent.from.usdc, spender: S.stranger)) {
            try plan(Self.simulation(quote, source: "b", extra: [S.approvalLog(quote.intent.from.usdc, owner: Self.owner, spender: S.stranger, .uint256Max)]))
        }
    }

    @Test("Calldata adulterada depois de validada nao vira plano")
    func tamperedCalldata() throws {
        let quote = try Self.cctpQuote()
        guard case .cctp(let transfer) = quote.call else { return }
        let thief = CCTPTransfer(sourceDomain: transfer.sourceDomain, destinationDomain: transfer.destinationDomain, usdc: transfer.usdc,
                                 owner: transfer.owner, recipient: S.stranger, amount: transfer.amount, maxFee: transfer.maxFee,
                                 finality: transfer.finality)
        let tampered = ValidatedBridgeQuote(
            intent: quote.intent, route: quote.route, call: quote.call, to: quote.to, value: quote.value,
            data: try CCTPCalldata.encodeDeposit(thief), spender: quote.spender, minimumReceived: quote.minimumReceived,
            expectedReceived: quote.expectedReceived, bridgeFee: quote.bridgeFee, estimatedSeconds: quote.estimatedSeconds,
            createdAt: quote.createdAt
        )
        #expect(throws: BridgeRefusal.quoteMismatch("queima")) { try Self.plan(tampered, Self.state(tampered)) }
        let toBNB = CCTPTransfer(sourceDomain: transfer.sourceDomain, destinationDomain: 17, usdc: transfer.usdc, owner: transfer.owner,
                                 recipient: transfer.recipient, amount: transfer.amount, maxFee: transfer.maxFee, finality: transfer.finality)
        let rerouted = ValidatedBridgeQuote(
            intent: quote.intent, route: quote.route, call: .cctp(toBNB), to: quote.to, value: quote.value,
            data: try CCTPCalldata.encodeDeposit(toBNB), spender: quote.spender, minimumReceived: quote.minimumReceived,
            expectedReceived: quote.expectedReceived, bridgeFee: quote.bridgeFee, estimatedSeconds: quote.estimatedSeconds,
            createdAt: quote.createdAt
        )
        #expect(throws: BridgeRefusal.quoteMismatch("queima")) { try Self.plan(rerouted, Self.state(rerouted)) }
    }

    @Test("Across honesto com ETH; depositante trocado e recusado")
    func acrossPlan() throws {
        let intent = try BridgeIntent(owner: Self.owner, asset: .eth, from: .base, to: .arbitrum, amount: BigUInt(decimal: "100000000000000000")!)
        let quote = try BridgeValidator.across(intent, quote: Self.acrossQuote(intent, output: BigUInt(decimal: "99900000000000000")!),
                                               usdPrice: TradeDecimal("3000"), now: Self.now)
        let plan = try Self.plan(quote, Self.state(quote))
        #expect(plan.transactions.count == 1)
        #expect((plan.transactions[0] as! EVMTransaction).value == intent.amount)

        guard case .across(let transfer) = quote.call else { return }
        // Depositante de outra pessoa: ela poderia trocar destino e valor por speed-up.
        var arguments = try AcrossCalldata.deposit.decodeCall(quote.data)
        arguments[0] = .fixedBytes(CCTPMessage.word(S.stranger))
        let stolen = ValidatedBridgeQuote(
            intent: intent, route: .across, call: quote.call, to: quote.to, value: quote.value,
            data: try AcrossCalldata.deposit.encodeCall(arguments), spender: nil, minimumReceived: quote.minimumReceived,
            expectedReceived: quote.expectedReceived, bridgeFee: quote.bridgeFee, estimatedSeconds: quote.estimatedSeconds,
            createdAt: quote.createdAt
        )
        #expect(throws: BridgeRefusal.quoteMismatch("depósito")) { try Self.plan(stolen, Self.state(stolen)) }
        // Evento com outro destinatario na simulacao.
        let other = Self.simulation(quote, source: "b", event: Self.fundsDepositedLog(transfer, spoke: intent.from.across!.spokePool, recipient: S.stranger))
        #expect(throws: BridgeRefusal.simulationEventMissing) {
            try Self.plan(quote, Self.state(quote, simulations: [Self.simulation(quote, source: "a"), other]))
        }
    }
}

extension AcrossTransfer {
    var depositorIsOwner: Bool { owner == recipient }
}

/// A chegada pelo Across amarrada ao deposito do dono (pentest de 14/10/2026, B4).
@Suite("Ponte: a entrega do Across e a do deposito do dono")
struct AcrossArrivalBindingTests {
    typealias S = TradeTestSupport
    static let owner = try! EVMAddress("0x411580947c337770994174855f8cbf56936e3062")
    static let zero = [UInt8](repeating: 0, count: 32)

    static func transfer(fillDeadline: UInt32 = 1_791_772_367) -> AcrossTransfer {
        AcrossTransfer(originChainID: 8453, destinationChainID: 42161, owner: owner, recipient: owner,
                       inputToken: BridgeAllowlist.base.across!.wrappedNative, outputToken: BridgeAllowlist.arbitrum.across!.wrappedNative,
                       inputAmount: BigUInt(2_992_129_562_251_732), outputAmount: BigUInt(2_986_913_403_912_798), exclusiveRelayer: nil,
                       quoteTimestamp: 1_791_765_167, fillDeadline: fillDeadline, exclusivityDeadline: 0, nativeInput: true)
    }

    static func filledRelay(_ transfer: AcrossTransfer, depositID: BigUInt, fillDeadline: UInt32? = nil) -> TradeSimulatedLog {
        let owner = CCTPMessage.word(transfer.owner)
        let data = try! BridgeArrival.filledRelayData.encodeCall([
            .fixedBytes(CCTPMessage.word(transfer.inputToken)), .fixedBytes(CCTPMessage.word(transfer.outputToken)),
            .uint(transfer.inputAmount), .uint(transfer.outputAmount), .uint(BigUInt(transfer.destinationChainID)),
            .uint(BigUInt(fillDeadline ?? transfer.fillDeadline)), .uint(0), .fixedBytes(zero),
            .fixedBytes(owner), .fixedBytes(owner), .fixedBytes(zero),
            .tuple([.fixedBytes(owner), .fixedBytes(zero), .uint(transfer.outputAmount), .uint(0)]),
        ])
        return TradeSimulatedLog(
            address: BridgeAllowlist.arbitrum.across!.spokePool,
            topics: [BridgeArrival.filledRelayTopic, S.word(BigUInt(transfer.originChainID)), S.word(depositID), S.word(1)],
            data: Array(data.dropFirst(4))
        )
    }

    @Test("O depositId sai do FundsDeposited do proprio recibo, com os campos assinados")
    func depositID() {
        let transfer = Self.transfer()
        let spoke = BridgeAllowlist.base.across!.spokePool
        let deposit = BridgePlannerTests.fundsDepositedLog(transfer, spoke: spoke)
        #expect(BridgeArrival.acrossDepositID([deposit], transfer: transfer, originSpoke: spoke) == BigUInt(7))
        // Outro destinatario, outro prazo ou outro contrato: nao e este deposito.
        #expect(BridgeArrival.acrossDepositID([BridgePlannerTests.fundsDepositedLog(transfer, spoke: spoke, recipient: S.stranger)],
                                              transfer: transfer, originSpoke: spoke) == nil)
        #expect(BridgeArrival.acrossDepositID([deposit], transfer: Self.transfer(fillDeadline: 1), originSpoke: spoke) == nil)
        #expect(BridgeArrival.acrossDepositID([deposit], transfer: transfer, originSpoke: BridgeAllowlist.arbitrum.across!.spokePool) == nil)
    }

    @Test("Token que chega como token: o recibo tem de ter o Transfer cheio para o dono (B2); reembolso conferido na origem (B4)")
    func tokenDeliveryAndRefund() {
        let usdt = AcrossTransfer(originChainID: 1, destinationChainID: 42161, owner: Self.owner, recipient: Self.owner,
                                  inputToken: BridgeAllowlist.ethereum.usdt!, outputToken: BridgeAllowlist.arbitrum.usdt!,
                                  inputAmount: BigUInt(100_000_000), outputAmount: BigUInt(99_900_000), exclusiveRelayer: nil,
                                  quoteTimestamp: 1_791_765_167, fillDeadline: 1_791_772_367, exclusivityDeadline: 0, nativeInput: false)
        let spoke = BridgeAllowlist.arbitrum.across!.spokePool
        let weth = BridgeAllowlist.arbitrum.across!.wrappedNative
        func transferLog(_ token: EVMAddress, from: EVMAddress, to: EVMAddress, value: BigUInt) -> TradeSimulatedLog {
            TradeSimulatedLog(address: token, topics: [TradeSimulationCheck.transferTopic, S.topic(from), S.topic(to)],
                              data: value.bigEndianBytes(padTo: 32)!)
        }
        let fill = Self.filledRelay(usdt, depositID: 7)
        let relayer = S.stranger
        #expect(!BridgeArrival.acrossDelivered([fill], transfer: usdt, destinationSpoke: spoke, depositID: 7, destinationWrappedNative: weth))
        #expect(!BridgeArrival.acrossDelivered([fill, transferLog(usdt.outputToken, from: relayer, to: Self.owner, value: 1)], transfer: usdt,
                                               destinationSpoke: spoke, depositID: 7, destinationWrappedNative: weth))
        #expect(BridgeArrival.acrossDelivered([fill, transferLog(usdt.outputToken, from: relayer, to: Self.owner, value: usdt.outputAmount)],
                                              transfer: usdt, destinationSpoke: spoke, depositID: 7, destinationWrappedNative: weth))
        let origin = BridgeAllowlist.ethereum.across!.spokePool
        #expect(BridgeArrival.acrossRefunded([transferLog(usdt.inputToken, from: origin, to: Self.owner, value: usdt.inputAmount)],
                                             transfer: usdt, originSpoke: origin))
        #expect(!BridgeArrival.acrossRefunded([transferLog(usdt.inputToken, from: relayer, to: Self.owner, value: usdt.inputAmount)],
                                              transfer: usdt, originSpoke: origin))
        #expect(!BridgeArrival.acrossRefunded([transferLog(usdt.inputToken, from: origin, to: Self.owner, value: 1)], transfer: usdt, originSpoke: origin))
    }

    @Test("Entrega antiga de mesmo valor, com outro depositId ou outro prazo, nao conta como chegada")
    func delivery() {
        let transfer = Self.transfer()
        let spoke = BridgeAllowlist.arbitrum.across!.spokePool
        #expect(BridgeArrival.acrossDelivered([Self.filledRelay(transfer, depositID: 7)], transfer: transfer, destinationSpoke: spoke, depositID: 7,
                                              destinationWrappedNative: BridgeAllowlist.arbitrum.across!.wrappedNative))
        #expect(!BridgeArrival.acrossDelivered([Self.filledRelay(transfer, depositID: 6)], transfer: transfer, destinationSpoke: spoke, depositID: 7, destinationWrappedNative: BridgeAllowlist.arbitrum.across!.wrappedNative))
        #expect(!BridgeArrival.acrossDelivered([Self.filledRelay(transfer, depositID: 7, fillDeadline: 1)], transfer: transfer,
                                               destinationSpoke: spoke, depositID: 7, destinationWrappedNative: BridgeAllowlist.arbitrum.across!.wrappedNative))
    }
}
