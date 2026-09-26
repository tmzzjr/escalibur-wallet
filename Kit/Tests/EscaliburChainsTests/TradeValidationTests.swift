import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// A validacao fail-closed da calldata, contra respostas reais dos quatro provedores
/// (Fixtures/trade, gravadas ao vivo em 26/09/2026) e contra as mesmas respostas
/// adulteradas campo a campo, como um provedor hostil faria.
@Suite("Troca: validacao da calldata")
struct TradeValidationTests {
    typealias S = TradeTestSupport
    typealias T = EVMTestSupport

    static let cases: [(TradeProvider, String, Int)] = [
        (.velora, "velora-base-usdc-eth", 0), (.kyberSwap, "kyber-base-usdc-eth-build", 0),
        (.lifi, "lifi-base-usdc-eth", 0), (.de1, "de1-base-usdc-eth", 0),
        (.velora, "velora-arbitrum-eth-usdc", 1), (.kyberSwap, "kyber-arbitrum-eth-usdc-build", 1),
        (.lifi, "lifi-arbitrum-eth-usdc", 1), (.de1, "de1-arbitrum-eth-usdc", 1),
        (.lifi, "lifi-arbitrum-usdc-usdt", 2),
    ]

    static func intent(_ kind: Int) throws -> TradeIntent {
        switch kind {
        case 0: return try S.baseIntent()
        case 1: return try S.arbIntent()
        default: return try S.arbStableIntent()
        }
    }

    static func validate(_ proposal: TradeProposal, _ intent: TradeIntent, market: TradeMarketReference = .none) throws -> ValidatedTradeQuote {
        try TradeValidator.validate(proposal, intent: intent, market: market, now: S.recordedAt)
    }

    @Test("As nove respostas reais passam, e o resumo decodificado bate com a intencao")
    func realResponsesPass() throws {
        for (provider, name, kind) in Self.cases {
            let intent = try Self.intent(kind)
            let proposal = try S.proposal(provider, name)
            let quote = try Self.validate(proposal, intent)
            #expect(quote.provider == provider, "\(name)")
            #expect(quote.decoded.recipient == S.owner, "\(name)")
            #expect(quote.decoded.amountIn == intent.amountIn, "\(name)")
            #expect(quote.decoded.integratorFee == .none, "\(name)")
            #expect(quote.guaranteedOut > 0 && quote.guaranteedOut <= quote.expectedOut, "\(name)")
            #expect(quote.guaranteedOut + 2 >= intent.minimumOut(forExpected: quote.expectedOut), "\(name)")
            #expect(quote.to == TradeAllowlist.router(for: provider, on: intent.chain)?.address, "\(name)")
            #expect(quote.value == (intent.sell.isNative ? intent.amountIn : 0), "\(name)")
        }
    }

    @Test("Valores decodificados conferidos a mao contra a calldata gravada")
    func decodedValues() throws {
        // Velora: toAmount - 1 (a poeira que a Augustus deixa no router).
        let velora = try Self.validate(S.proposal(.velora, "velora-base-usdc-eth"), S.baseIntent())
        #expect(velora.decoded.function == "swapExactAmountIn(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)")
        #expect(velora.decoded.guaranteedOut == velora.decoded.minOutField - 1)
        #expect(velora.decoded.sellToken == S.baseUSDC.contract)
        #expect(velora.decoded.buyToken == TradeConstants.eeeeSentinel)

        // KyberSwap: minReturnAmount e 0,5% abaixo do amountOut da resposta.
        let kyber = try Self.validate(S.proposal(.kyberSwap, "kyber-base-usdc-eth-build"), S.baseIntent())
        let kyberExpected = S.amount(S.string(try S.json("kyber-base-usdc-eth-build")["data"], "amountOut"))
        #expect(kyber.guaranteedOut == kyberExpected * 9_950 / 10_000)

        // LI.FI: a taxa fixa de 0,25% sai no primeiro passo (FeeForwarder) e aparece
        // decodificada: 0,25 USDC de 100.
        let lifi = try Self.validate(S.proposal(.lifi, "lifi-base-usdc-eth"), S.baseIntent())
        #expect(lifi.decoded.providerFeeAmount == 250_000)
        #expect(lifi.decoded.function.hasPrefix("swapTokensMultipleV3ERC20ToNative("))
        #expect(lifi.decoded.buyToken == .zero)
        let lifiNative = try Self.validate(S.proposal(.lifi, "lifi-arbitrum-eth-usdc"), S.arbIntent())
        #expect(lifiNative.decoded.function.hasPrefix("swapTokensMultipleV3NativeToERC20("))
        #expect(lifiNative.decoded.providerFeeAmount == BigUInt(decimal: "100000000000000")!)

        // De¹: minReturnAmount da resposta.
        let de1 = try Self.validate(S.proposal(.de1, "de1-base-usdc-eth"), S.baseIntent())
        #expect(de1.guaranteedOut == S.amount(S.string(try S.json("de1-base-usdc-eth")["data"], "minOutAmount")))
    }

    // MARK: Adulteracoes

    @Test("Destinatario trocado: recusado nos quatro provedores")
    func recipientSwapped() throws {
        let intent = try S.baseIntent()
        let other = ABIValue.address(S.stranger)
        let paths: [(TradeProvider, String, [Int])] = [
            (.velora, "velora-base-usdc-eth", [1, 6]),
            (.kyberSwap, "kyber-base-usdc-eth-build", [0, 3, 6]),
            (.lifi, "lifi-base-usdc-eth", [3]),
            (.de1, "de1-base-usdc-eth", [1, 3]),
        ]
        for (provider, name, path) in paths {
            let proposal = try S.proposal(provider, name)
            let router = TradeAllowlist.router(for: provider, on: .base)!
            let data = try S.mutate(proposal.data, router: router) { S.replacing($0, at: path, with: other) }
            #expect(throws: TradeRefusal.recipientMismatch(S.stranger), "\(provider)") {
                try Self.validate(S.with(proposal, data: data), intent)
            }
        }
    }

    @Test("minOut menor que o minimo do app: recusado")
    func minOutTooLow() throws {
        let intent = try S.baseIntent()
        let paths: [(TradeProvider, String, [Int])] = [
            (.velora, "velora-base-usdc-eth", [1, 3]),
            (.kyberSwap, "kyber-base-usdc-eth-build", [0, 3, 8]),
            (.lifi, "lifi-base-usdc-eth", [4]),
            (.de1, "de1-base-usdc-eth", [1, 5]),
        ]
        for (provider, name, path) in paths {
            let proposal = try S.proposal(provider, name)
            let router = TradeAllowlist.router(for: provider, on: .base)!
            let arguments = try router.functions.first { $0.selector == Array(proposal.data.prefix(4)) }!.decodeCall(proposal.data)
            let original = S.value(arguments, at: path)!.uintValue!
            // 1% a menos: com tolerancia de 0,5%, fica abaixo do minimo do app.
            let lowered = original * 99 / 100
            let data = try S.mutate(proposal.data, router: router) { S.replacing($0, at: path, with: .uint(lowered)) }
            #expect(throws: TradeRefusal.self, "\(provider)") { try Self.validate(S.with(proposal, data: data), intent) }
            do {
                _ = try Self.validate(S.with(proposal, data: data), intent)
            } catch let refusal as TradeRefusal {
                guard case .minimumOutTooLow = refusal else {
                    Issue.record("\(provider): esperava minimumOutTooLow, veio \(refusal)")
                    continue
                }
            }
        }
    }

    @Test("Provedor que alarga a tolerancia por conta propria e recusado (De¹ com 0,5% pedido devolve minimo 0,6% abaixo)")
    func providerWidensSlippage() throws {
        // Gravado com slippage=0.5: a De¹ poe o minimo em 99,4% do estimado. O cliente de
        // rede pede 0,1 ponto a menos para compensar; a validacao nao compensa nada.
        let proposal = try S.proposal(.de1, "de1-base-usdc-eth-folga-extra")
        do {
            _ = try Self.validate(proposal, S.baseIntent())
            Issue.record("minimo 0,6% abaixo devia ser recusado com tolerancia de 0,5%")
        } catch TradeRefusal.minimumOutTooLow(let found, let required) {
            // De¹ arredonda para cima: 99,4% do estimado, com 1 unidade de diferenca.
            #expect(found >= proposal.expectedOut * 994 / 1_000 && found <= proposal.expectedOut * 994 / 1_000 + 1)
            #expect(required == proposal.expectedOut * 995 / 1_000)
        }
        // Com 0,6% de tolerancia, a mesma calldata passa.
        _ = try Self.validate(proposal, S.baseIntent(slippage: 60))
    }

    @Test("Inflar o estimado nao ajuda: o minimo do app sobe junto e a calldata honesta passa a ser recusada")
    func inflatedExpected() throws {
        let intent = try S.baseIntent()
        let proposal = try S.proposal(.kyberSwap, "kyber-base-usdc-eth-build")
        #expect(throws: TradeRefusal.self) {
            try Self.validate(S.with(proposal, expectedOut: proposal.expectedOut * 2), intent)
        }
    }

    @Test("Router fora da lista, spender declarado diferente, chainId trocado: recusados")
    func routerAndChain() throws {
        let intent = try S.baseIntent()
        let proposal = try S.proposal(.velora, "velora-base-usdc-eth")
        #expect(throws: TradeRefusal.routerNotAllowed(S.stranger)) { try Self.validate(S.with(proposal, to: S.stranger), intent) }
        // O router da Kyber recebendo calldata da Velora tambem e "fora da lista".
        let kyber = TradeAllowlist.router(for: .kyberSwap, on: .base)!.address
        #expect(throws: TradeRefusal.routerNotAllowed(kyber)) { try Self.validate(S.with(proposal, to: kyber), intent) }
        #expect(throws: TradeRefusal.spenderNotAllowed(S.stranger)) { try Self.validate(S.with(proposal, spender: .some(S.stranger)), intent) }
        #expect(throws: TradeRefusal.chainIDMismatch) { try Self.validate(S.with(proposal, chainID: .some(1)), intent) }
        // A mesma calldata da Base apresentada como cotacao na Arbitrum.
        let wrongChain = try TradeIntent(owner: S.owner, sell: .token(S.arbUSDC), buy: .native(.arbitrum), amountIn: 100_000_000, slippageBps: 50)
        #expect(throws: TradeRefusal.self) { try Self.validate(S.with(proposal, chainID: .some(nil)), wrongChain) }
    }

    @Test("Seletor desconhecido, permit, approve disfarcado e bytes sobrando: recusados antes de decodificar o resto")
    func selectors() throws {
        let intent = try S.baseIntent()
        let proposal = try S.proposal(.kyberSwap, "kyber-base-usdc-eth-build")
        var unknown = proposal.data
        unknown[0] ^= 0xFF
        #expect(throws: TradeRefusal.selectorNotAllowed(Array(unknown.prefix(4)))) { try Self.validate(S.with(proposal, data: unknown), intent) }
        // approve disfarcado de troca, mandado ao router.
        let approve = ERC20.approve(spender: S.stranger, amount: .uint256Max)
        #expect(throws: TradeRefusal.selectorNotAllowed(Array(approve.prefix(4)))) { try Self.validate(S.with(proposal, data: approve), intent) }
        // Bytes a mais depois da codificacao canonica.
        #expect(throws: TradeRefusal.callRefused(.invalidArguments(.trailingBytes(32)))) {
            try Self.validate(S.with(proposal, data: proposal.data + [UInt8](repeating: 0, count: 32)), intent)
        }
        // Permit dentro da troca (Velora e Kyber).
        let velora = try S.proposal(.velora, "velora-base-usdc-eth")
        let veloraRouter = TradeAllowlist.router(for: .velora, on: .base)!
        let withPermit = try S.mutate(velora.data, router: veloraRouter) { S.replacing($0, at: [3], with: .bytes([1, 2, 3])) }
        #expect(throws: TradeRefusal.malformed("permit")) { try Self.validate(S.with(velora, data: withPermit), intent) }
    }

    @Test("Taxa de integrador diferente da compilada (zero): recusada")
    func integratorFee() throws {
        let intent = try S.baseIntent()
        // Velora: parceiro e 0,25% no partnerAndFee.
        let velora = try S.proposal(.velora, "velora-base-usdc-eth")
        let veloraRouter = TradeAllowlist.router(for: .velora, on: .base)!
        let partnerWord = BigUInt(bigEndian: S.stranger.bytes + [UInt8](repeating: 0, count: 10) + [0x00, 25])
        let veloraFee = try S.mutate(velora.data, router: veloraRouter) { S.replacing($0, at: [2], with: .uint(partnerWord)) }
        #expect(throws: TradeRefusal.integratorFeeMismatch) { try Self.validate(S.with(velora, data: veloraFee), intent) }
        // A flag de referral (sobra dividida com um "parceiro") sem parceiro tambem.
        let referral = BigUInt(bigEndian: [UInt8](repeating: 0, count: 20) + [0x40] + [UInt8](repeating: 0, count: 11))
        let veloraReferral = try S.mutate(velora.data, router: veloraRouter) { S.replacing($0, at: [2], with: .uint(referral)) }
        #expect(throws: TradeRefusal.integratorFeeMismatch) { try Self.validate(S.with(velora, data: veloraReferral), intent) }

        // Kyber: feeReceivers/feeAmounts preenchidos.
        let kyber = try S.proposal(.kyberSwap, "kyber-base-usdc-eth-build")
        let kyberRouter = TradeAllowlist.router(for: .kyberSwap, on: .base)!
        let kyberFee = try S.mutate(kyber.data, router: kyberRouter) { arguments in
            let withReceivers = S.replacing(arguments, at: [0, 3, 4], with: .array([.address(S.stranger)]))
            return S.replacing(withReceivers, at: [0, 3, 5], with: .array([.uint(10)]))
        }
        #expect(throws: TradeRefusal.integratorFeeMismatch) { try Self.validate(S.with(kyber, data: kyberFee), intent) }

        // De¹: referrer preenchido.
        let de1 = try S.proposal(.de1, "de1-base-usdc-eth")
        let de1Router = TradeAllowlist.router(for: .de1, on: .base)!
        let de1Fee = try S.mutate(de1.data, router: de1Router) { S.replacing($0, at: [1, 8], with: .address(S.stranger)) }
        #expect(throws: TradeRefusal.integratorFeeMismatch) { try Self.validate(S.with(de1, data: de1Fee), intent) }

        // LI.FI: a taxa propria acima de 0,25% (aqui 1%) passa do teto compilado.
        let lifi = try S.proposal(.lifi, "lifi-base-usdc-eth")
        let lifiRouter = TradeAllowlist.router(for: .lifi, on: .base)!
        let arguments = try LiFiCalldata.multipleERC20ToNative.decodeCall(lifi.data)
        let feeCall = S.value(arguments, at: [5, 0, 5])!.bytesValue!
        var feeArguments = try LiFiCalldata.forwardERC20Fees.decodeCall(feeCall)
        feeArguments = S.replacing(feeArguments, at: [1, 0, 1], with: .uint(1_000_000))
        let greedy = try LiFiCalldata.forwardERC20Fees.encodeCall(feeArguments)
        let lifiFee = try S.mutate(lifi.data, router: lifiRouter) { S.replacing($0, at: [5, 0, 5], with: .bytes(greedy)) }
        #expect(throws: TradeRefusal.providerFeeTooHigh(bps: 100)) { try Self.validate(S.with(lifi, data: lifiFee), intent) }
    }

    @Test("Valor, tokens e msg.value: tudo tem de ser a intencao")
    func amountsAndValue() throws {
        let intent = try S.baseIntent()
        let proposal = try S.proposal(.kyberSwap, "kyber-base-usdc-eth-build")
        // Intencao de 90 USDC contra calldata de 100.
        #expect(throws: TradeRefusal.amountInMismatch(expected: 90_000_000, found: 100_000_000)) {
            try Self.validate(proposal, S.baseIntent(amount: 90_000_000))
        }
        // msg.value junto de venda de token.
        #expect(throws: TradeRefusal.valueMismatch(expected: 0, found: 1)) { try Self.validate(S.with(proposal, value: 1), intent) }
        // Token comprado trocado (USDC -> WETH em vez de ETH).
        let weth = try TradeIntent(owner: S.owner, sell: .token(S.baseUSDC),
                                   buy: .token(EVMToken(chain: .base, contract: T.address("0x4200000000000000000000000000000000000006"), symbol: "WETH", decimals: 18)),
                                   amountIn: 100_000_000, slippageBps: 50)
        #expect(throws: TradeRefusal.buyTokenMismatch) { try Self.validate(proposal, weth) }
        // Venda de nativo com msg.value menor.
        let native = try S.proposal(.velora, "velora-arbitrum-eth-usdc")
        #expect(throws: TradeRefusal.self) { try Self.validate(S.with(native, value: native.value - 1), S.arbIntent()) }
    }

    @Test("Estrutura: flags, executor, deposito de outro token e passo de taxa fora do lugar")
    func structure() throws {
        let intent = try S.baseIntent()
        // Kyber com PARTIAL_FILL.
        let kyber = try S.proposal(.kyberSwap, "kyber-base-usdc-eth-build")
        let kyberRouter = TradeAllowlist.router(for: .kyberSwap, on: .base)!
        let partial = try S.mutate(kyber.data, router: kyberRouter) { S.replacing($0, at: [0, 3, 9], with: .uint(0x201)) }
        #expect(throws: TradeRefusal.malformed("flags 0x201")) { try Self.validate(S.with(kyber, data: partial), intent) }
        // Kyber com approveTarget preenchido.
        let approveTarget = try S.mutate(kyber.data, router: kyberRouter) { S.replacing($0, at: [0, 1], with: .address(S.stranger)) }
        #expect(throws: TradeRefusal.malformed("approveTarget")) { try Self.validate(S.with(kyber, data: approveTarget), intent) }

        // LI.FI puxando outro token do dono num passo de deposito.
        let lifi = try S.proposal(.lifi, "lifi-base-usdc-eth")
        let lifiRouter = TradeAllowlist.router(for: .lifi, on: .base)!
        let otherDeposit = try S.mutate(lifi.data, router: lifiRouter) { arguments in
            let flagged = S.replacing(arguments, at: [5, 1, 6], with: .bool(true))
            return S.replacing(flagged, at: [5, 1, 2], with: .address(S.stranger))
        }
        #expect(throws: TradeRefusal.malformed("deposito de outro token")) { try Self.validate(S.with(lifi, data: otherDeposit), intent) }

        // De¹ vendendo token sem SHOULD_CLAIM.
        let de1 = try S.proposal(.de1, "de1-base-usdc-eth")
        let de1Router = TradeAllowlist.router(for: .de1, on: .base)!
        let noClaim = try S.mutate(de1.data, router: de1Router) { S.replacing($0, at: [1, 7], with: .uint(1)) }
        #expect(throws: TradeRefusal.malformed("flags 0x1")) { try Self.validate(S.with(de1, data: noClaim), intent) }

        // De¹ mandando o token vendido a um terceiro que a rota nao chama; e aceitando
        // quando o recebedor e um contrato que as calls chamam.
        let wrongReceiver = try S.mutate(de1.data, router: de1Router) { S.replacing($0, at: [1, 2], with: .address(S.stranger)) }
        #expect(throws: TradeRefusal.malformed("srcReceiver")) { try Self.validate(S.with(de1, data: wrongReceiver), intent) }
        let calls = try De1Calldata.swap.decodeCall(de1.data)[2].arrayValue!
        let target = calls.compactMap { call -> EVMAddress? in
            let word = call.tupleValue![0].uintValue!.bigEndianBytes(padTo: 32)!
            let address = EVMAddress(uncheckedBytes: Array(word.suffix(20)))
            return address.isZero ? nil : address
        }.first!
        let toPool = try S.mutate(de1.data, router: de1Router) { S.replacing($0, at: [1, 2], with: .address(target)) }
        _ = try Self.validate(S.with(de1, data: toPool), intent)

        // Velora com quotedAmount abaixo de toAmount (a "sobra" comeria o minimo).
        let velora = try S.proposal(.velora, "velora-base-usdc-eth")
        let veloraRouter = TradeAllowlist.router(for: .velora, on: .base)!
        let lowQuote = try S.mutate(velora.data, router: veloraRouter) { S.replacing($0, at: [1, 4], with: .uint(1)) }
        #expect(throws: TradeRefusal.malformed("quotedAmount abaixo de toAmount")) { try Self.validate(S.with(velora, data: lowQuote), intent) }
    }

    @Test("Prazo: aceito ate 20 minutos, recusado alem e recusado vencido")
    func deadline() throws {
        let now = S.recordedAt
        let current = UInt64(now.timeIntervalSince1970)
        try TradeValidator.checkDeadline(current + 600, now: now)
        try TradeValidator.checkDeadline(current + 1_200, now: now)
        #expect(throws: TradeRefusal.deadlineTooFar(seconds: 1_201)) { try TradeValidator.checkDeadline(current + 1_201, now: now) }
        #expect(throws: TradeRefusal.deadlineTooFar(seconds: 86_400)) { try TradeValidator.checkDeadline(current + 86_400, now: now) }
        #expect(throws: TradeRefusal.deadlineExpired) { try TradeValidator.checkDeadline(current, now: now) }
        try TradeValidator.checkDeadline(nil, now: now)
    }

    @Test("Oraculo: 2% pior avisa, mais de 5% bloqueia; impacto em degraus de 1, 5 e 15%")
    func marketChecks() throws {
        let intent = try S.baseIntent()
        let proposal = try S.proposal(.velora, "velora-base-usdc-eth")
        let expected = proposal.expectedOut
        // Oraculo igual: normal.
        let fair = try Self.validate(proposal, intent, market: TradeMarketReference(oracleOut: expected))
        #expect(fair.assessment.level == .normal)
        // Cotacao 3% pior que o oraculo: aviso visivel.
        let worse = try Self.validate(proposal, intent, market: TradeMarketReference(oracleOut: expected * 100 / 97))
        #expect(worse.assessment.level == .visible)
        #expect((299...300).contains(worse.assessment.oracleDeviationBps ?? 0))
        // 6% pior: bloqueia.
        do {
            _ = try Self.validate(proposal, intent, market: TradeMarketReference(oracleOut: expected * 100 / 94))
            Issue.record("6% pior que o oraculo devia bloquear")
        } catch TradeRefusal.priceFarFromOracle(let bps) {
            #expect((599...600).contains(bps))
        }
        // Cotacao melhor que o oraculo: desvio negativo, nada a avisar.
        let better = try Self.validate(proposal, intent, market: TradeMarketReference(oracleOut: expected * 98 / 100))
        #expect(better.assessment.level == .normal)
        #expect((better.assessment.oracleDeviationBps ?? 0) < 0)
        // Impacto informado de 2%: visivel, com aviso na revisao.
        let visible = try Self.validate(S.with(proposal, impact: .some(200)), intent)
        #expect(visible.assessment.level == .visible)
        #expect(visible.assessment.warnings == [.highPriceImpact(percent: 2)])
        // 6%: exige confirmacao.
        let confirm = try Self.validate(S.with(proposal, impact: .some(600)), intent)
        #expect(confirm.assessment.requiresConfirmation)
        // 16%: bloqueia.
        #expect(throws: TradeRefusal.priceImpactTooHigh(bps: 1_600)) { try Self.validate(S.with(proposal, impact: .some(1_600)), intent) }
    }

    @Test("Oraculo por precos em dolar: conta inteira exata")
    func oracleFromPrices() throws {
        // 100 USDC a US$ 1 com ETH a US$ 2.500: 0,04 ETH.
        let reference = TradeMarketReference(amountIn: 100_000_000, sell: .token(S.baseUSDC), buy: .native(.base),
                                             sellPriceUSD: "1", buyPriceUSD: "2500")
        #expect(reference.oracleOut == BigUInt(decimal: "40000000000000000")!)
        let comma = TradeMarketReference(amountIn: 100_000_000, sell: .token(S.baseUSDC), buy: .native(.base),
                                         sellPriceUSD: "0,99991", buyPriceUSD: "2693.52")
        #expect(comma.oracleOut == BigUInt(decimal: "37122798419911491")!)
        #expect(TradeMarketReference(amountIn: 1, sell: .token(S.baseUSDC), buy: .native(.base), sellPriceUSD: "1e3", buyPriceUSD: "1").oracleOut == nil)
    }

    @Test("Intencao invalida: mesma moeda, redes diferentes, zero, tolerancia fora da faixa")
    func intents() throws {
        #expect(throws: TradeRefusal.sameAsset) { try TradeIntent(owner: S.owner, sell: .native(.base), buy: .native(.base), amountIn: 1, slippageBps: 50) }
        #expect(throws: TradeRefusal.assetsOnDifferentChains) {
            try TradeIntent(owner: S.owner, sell: .native(.base), buy: .token(S.arbUSDC), amountIn: 1, slippageBps: 50)
        }
        #expect(throws: TradeRefusal.zeroAmount) { try TradeIntent(owner: S.owner, sell: .native(.base), buy: .token(S.baseUSDC), amountIn: 0, slippageBps: 50) }
        #expect(throws: TradeRefusal.slippageOutOfRange(1_001)) {
            try TradeIntent(owner: S.owner, sell: .native(.base), buy: .token(S.baseUSDC), amountIn: 1, slippageBps: 1_001)
        }
        #expect(throws: TradeRefusal.notEVMChain) {
            try TradeIntent(owner: S.owner, sell: .native(.solana), buy: .native(.base), amountIn: 1, slippageBps: 50)
        }
        let intent = try S.baseIntent()
        #expect(intent.minimumOut(forExpected: 1_000_000) == 995_000)
    }
}
