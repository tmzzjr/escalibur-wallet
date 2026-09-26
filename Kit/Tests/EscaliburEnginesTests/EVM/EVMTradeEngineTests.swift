@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// O motor de troca EVM com as cotacoes reais gravadas dos quatro provedores, o
/// agregador e o validador de verdade, e estado de cadeia sintetico (ver
/// `EVMTradeFixtures`). Nada vai para a rede.
@Suite("Motor EVM: troca")
struct EVMTradeEngineTests {
    typealias F = EVMTradeFixtures
    typealias H = EVMTradeHarness

    /// O ranking esperado com o mesmo custo que o motor usa: gas a 0,006 gwei (baseFee
    /// mais gorjeta), taxa L1 de 20 gwei, ETH comprado sem conversao, allowance zero.
    static func expectedRanking() throws -> [TradeCandidate] {
        let quotes = try TradeProvider.allCases.map { try F.validated($0) }
        return TradeRanking.rank(quotes, costs: TradeCostModel(gasPriceWei: 6_000_000, l1FeePerTransactionWei: F.l1Fee, nativeToBuy: .identity))
    }

    // MARK: Cotacao

    @Test("Cotacao: quatro provedores comparados, minimo garantido decodificado da calldata, alternativas e autorizacao")
    func quote() async throws {
        let counter = EVMCallCounter()
        let engine = H.engine(sources: try H.sources(counter), transport: try H.baseTransport())
        let quote = try await engine.quote(F.request())
        let best = try #require(try Self.expectedRanking().first)

        #expect(quote.providersCompared == 4)
        #expect(quote.legs.count == 1)
        #expect(quote.legs[0].provider == best.quote.provider.displayName)
        #expect(quote.legs[0].fraction == 1 && quote.legs[0].amountIn == F.amount)
        // "Voce recebe no minimo" e o garantido decodificado, nunca o anunciado.
        #expect(quote.minimumOut == best.quote.guaranteedOut)
        #expect(quote.minimumOut < quote.expectedOut)
        #expect(quote.expectedOut == best.quote.expectedOut)
        #expect(quote.alternatives.count == 3)
        #expect(!quote.alternatives.contains { $0.provider == best.quote.provider.displayName })
        #expect(quote.needsApproval)
        #expect(quote.networkFeeFiat == nil)
        #expect(quote.sell == F.usdc && quote.buy == .native(.base) && quote.amountIn == F.amount)
        #expect(quote.expiresAt.timeIntervalSinceNow > 50 && quote.expiresAt.timeIntervalSinceNow <= 60)
        for provider in TradeProvider.allCases { #expect(await counter.count(provider.rawValue) == 1) }
    }

    @Test("Autorizacao que ja cobre o valor: a cotacao nao pede autorizar")
    func existingAllowance() async throws {
        let engine = H.engine(state: FakeTradeChain(allowance: 1_000_000_000), sources: try H.sources(EVMCallCounter()),
                              transport: try H.baseTransport())
        let quote = try await engine.quote(F.request())
        #expect(!quote.needsApproval)
    }

    @Test("Com preco de oraculo: sanidade conferida; preco longe demais recusa todas as cotacoes")
    func oracle() async throws {
        let best = try #require(try Self.expectedRanking().first)
        // ETH pelo preco que a propria cotacao implica (6 casas): dentro da faixa.
        func usd(_ micros: BigUInt) -> String {
            let text = micros.decimalString
            return String(text.dropLast(6)) + "." + String(text.suffix(6))
        }
        let ethMicros = BigUInt(100) * BigUInt.power(of: 10, 24) / best.quote.expectedOut
        let engine = H.engine(prices: ["usd-coin": "1", "ethereum": usd(ethMicros)], sources: try H.sources(EVMCallCounter()),
                              transport: try H.baseTransport())
        let quote = try await engine.quote(F.request())
        #expect(quote.providersCompared >= 1)

        // ETH a 1/10 do preco: pelo oraculo, 100 USDC valeriam dez vezes mais ETH.
        let refusing = H.engine(prices: ["usd-coin": "1", "ethereum": usd(ethMicros / BigUInt(10))], sources: try H.sources(EVMCallCounter()),
                                transport: try H.baseTransport())
        await #expect(throws: SendEngineError.message("Nenhuma cotação passou na conferência de segurança da carteira. Nada foi assinado.")) {
            _ = try await refusing.quote(F.request())
        }
    }

    @Test("Regressao M5: sem preco de referencia, uma cotacao so nao troca; com a referencia, troca")
    func anchorRequired() async throws {
        let proposals = try F.proposals()
        let single = try H.sources(EVMCallCounter(), proposals: [try #require(proposals.first)])
        let blind = H.engine(sources: single, transport: try H.baseTransport())
        await #expect(throws: SendEngineError.message(
            "Sem preço de referência do mercado agora, a troca precisa de pelo menos duas cotações para comparar, e só uma respondeu. Tente de novo em instantes."
        )) { _ = try await blind.quote(F.request()) }

        // Com o preco de referencia, a mesma cotacao unica passa pela sanidade e troca.
        let best = try TradeValidator.validate(try #require(proposals.first), intent: F.intent())
        let ethMicros = BigUInt(100) * BigUInt.power(of: 10, 24) / best.expectedOut
        let text = ethMicros.decimalString
        let price = String(text.dropLast(6)) + "." + String(text.suffix(6))
        let seeing = H.engine(prices: ["usd-coin": "1", "ethereum": price], sources: try H.sources(EVMCallCounter(), proposals: [proposals[0]]),
                              transport: try H.baseTransport())
        let quote = try await seeing.quote(F.request())
        #expect(quote.providersCompared == 1)
    }

    @Test("Preco do oraculo vira texto decimal sem expoente; preco nulo ou invalido fica de fora")
    func oracleDecimalText() {
        for price in [3_998.12, 1, 0.000_001_23, 1e-12, 64_123_456.5] {
            let text = EVMMarketPriceOracle.decimalText(price)
            #expect(text.flatMap(TradeDecimal.init) != nil, "\(price)")
            #expect(text?.lowercased().contains("e") == false, "\(price)")
        }
        #expect(EVMMarketPriceOracle.decimalText(0) == nil)
        #expect(EVMMarketPriceOracle.decimalText(-1) == nil)
        #expect(EVMMarketPriceOracle.decimalText(.nan) == nil)
        #expect(EVMMarketPriceOracle.decimalText(.infinity) == nil)
    }

    @Test("Nenhum provedor com rota: a tela diz isso, sem texto de provedor")
    func noRoute() async throws {
        let engine = H.engine(sources: try H.sources(EVMCallCounter()), transport: try H.baseTransport())
        await #expect(throws: SendEngineError.message("Nenhum provedor cotou esta troca agora. Tente um valor menor ou outro par.")) {
            _ = try await engine.quote(F.request(amount: 7))
        }
    }

    @Test("Taxa da Escalibur zero em todo provedor e rede, e zero nas calldatas aceitas")
    func zeroFee() throws {
        for chain in Chain.evmChains {
            for provider in TradeProvider.allCases {
                #expect(TradeFeeSchedule.escaliburFee(provider: provider, chain: chain).isNone, "\(chain.id) \(provider)")
            }
        }
        for provider in TradeProvider.allCases { #expect(try F.validated(provider).decoded.integratorFee.isNone) }
    }

    // MARK: Plano

    @Test("Plano: recota o provedor escolhido, autorizacao exata e troca, nonces em sequencia")
    func plan() async throws {
        let counter = EVMCallCounter()
        let state = FakeTradeChain()
        let engine = H.engine(state: state, sources: try H.sources(counter), transport: try H.baseTransport())
        let request = try F.request()
        let quote = try await engine.quote(request)
        let plan = try await engine.plan(request, quote: quote)
        expectIntent(plan, request, quote)
        let provider = try #require(EVMTradeQuoteMapping.provider(named: quote.legs[0].provider))

        #expect(plan.review.kind == .swap)
        #expect(plan.review.transactionCount == 2)
        #expect(plan.transactions.count == 2)
        let approve = try #require(plan.transactions[0] as? EVMTransaction)
        let swap = try #require(plan.transactions[1] as? EVMTransaction)
        let router = try #require(TradeAllowlist.router(for: provider, on: .base))
        #expect(approve.nonce == 7 && swap.nonce == 8)
        #expect(approve.to == F.usdcToken.contract && approve.data == ERC20.approve(spender: router.spender, amount: F.amount))
        #expect(swap.to == router.address && swap.value == 0)
        #expect(plan.review.lines.contains { $0.label == "Taxa da Escalibur" && $0.value == "Sem taxa da Escalibur" })
        #expect(plan.review.lines.contains { $0.label == "Entra, no mínimo" })
        // Recotado: uma chamada na rodada e outra no plano.
        #expect(await counter.count(provider.rawValue) == 2)
        #expect(await state.reads.map(\.provider) == [provider])
    }

    @Test("Regressao M1: a fila local do pedido chega ao plano da troca; sem ela, o nonce e o das fontes")
    func planWithNonceQueue() async throws {
        let counter = EVMCallCounter()
        let state = FakeTradeChain()
        let engine = H.engine(state: state, sources: try H.sources(counter), transport: try H.baseTransport())
        let base = try F.request()
        // As fontes dizem 7; a fila diz que a 7 esta em transito e o proximo e 8.
        let request = TradeRequest(
            walletID: base.walletID, chain: base.chain, account: base.account, sell: base.sell, buy: base.buy, amountIn: base.amountIn,
            slippageBasisPoints: base.slippageBasisPoints, nonceQueue: PendingNonceQueue(nextNonce: 8, pendingHashes: ["0x01"])
        )
        let plan = try await engine.plan(request, quote: try await engine.quote(request))
        let approve = try #require(plan.transactions.first as? EVMTransaction)
        #expect(approve.nonce == 8)
        #expect(await state.reads.first?.localNextNonce == 8)
    }

    @Test("Regressao: leitura lenta antes da recotacao nao faz a cotacao recem-validada parecer do futuro")
    func slowReadBeforeRequote() async throws {
        // O plano capturava o instante antes da leitura de mercado e da recotacao, e o
        // planejador recusa cotacao validada mais de 5 s depois do instante do plano. Com a
        // rede lenta (aqui, o oraculo levando 5,5 s), a troca saia como "cotacao vencida".
        let engine = H.engine(oracleDelay: .milliseconds(5_500), sources: try H.sources(EVMCallCounter()), transport: try H.baseTransport())
        let request = try F.request()
        let quote = try await engine.quote(request)
        let plan = try await engine.plan(request, quote: quote)
        expectIntent(plan, request, quote)
        #expect(plan.transactions.count == 2)
        #expect(!plan.isExpired())
    }

    @Test("Plano recusa cotacao de outro par, vencida, de provedor desconhecido, ou com preco que caiu alem da tolerancia")
    func planRefusals() async throws {
        let engine = H.engine(sources: try H.sources(EVMCallCounter()), transport: try H.baseTransport())
        let request = try F.request()
        let quote = try await engine.quote(request)
        func copy(sell: Asset? = nil, minimumOut: BigUInt? = nil, legs: [TradeQuote.Leg]? = nil, expiresAt: Date? = nil) -> TradeQuote {
            TradeQuote(sell: sell ?? quote.sell, buy: quote.buy, amountIn: quote.amountIn, expectedOut: quote.expectedOut,
                       minimumOut: minimumOut ?? quote.minimumOut, priceImpactPercent: quote.priceImpactPercent,
                       networkFeeFiat: nil, providerFeeNote: nil, legs: legs ?? quote.legs, alternatives: [],
                       providersCompared: quote.providersCompared, needsApproval: quote.needsApproval,
                       expiresAt: expiresAt ?? quote.expiresAt)
        }
        let mismatch = SendEngineError.message("A cotação não corresponde a esta troca. Atualize a cotação e revise de novo.")
        await #expect(throws: mismatch) { _ = try await engine.plan(request, quote: copy(sell: .native(.base))) }
        await #expect(throws: mismatch) {
            _ = try await engine.plan(request, quote: copy(legs: [TradeQuote.Leg(provider: "1inch", fraction: 1, amountIn: F.amount, expectedOut: 1)]))
        }
        await #expect(throws: mismatch) {
            _ = try await engine.plan(request, quote: copy(legs: [TradeQuote.Leg(provider: "Velora", fraction: 1, amountIn: F.amount - 1, expectedOut: 1)]))
        }
        await #expect(throws: SendEngineError.message("A cotação venceu. Atualize e revise de novo.")) {
            _ = try await engine.plan(request, quote: copy(expiresAt: .now.addingTimeInterval(-1)))
        }
        // A tela mostrou o dobro do minimo que a recotacao garante: outra troca.
        await #expect(throws: SendEngineError.message("O preço mudou mais que a sua tolerância desde a cotação. Atualize a cotação e revise de novo.")) {
            _ = try await engine.plan(request, quote: copy(minimumOut: quote.minimumOut * BigUInt(2)))
        }
    }

    @Test("Simulacao que falha numa das duas fontes: o plano nao sai")
    func simulationFailure() async throws {
        let engine = H.engine(state: FakeTradeChain(failingSimulationSource: "drpc"), sources: try H.sources(EVMCallCounter()),
                              transport: try H.baseTransport())
        let request = try F.request()
        let quote = try await engine.quote(request)
        await #expect(throws: SendEngineError.message("A simulação mostra que esta troca falharia agora. Nada foi assinado.")) {
            _ = try await engine.plan(request, quote: quote)
        }
    }

    /// Uma cotacao dividida em duas pernas de 100 USDC (Velora e KyberSwap), montada com os
    /// garantidos que a recotacao vai dar.
    static func splitQuote() throws -> TradeQuote {
        let velora = try F.validated(.velora)
        let kyber = try F.validated(.kyberSwap)
        return TradeQuote(
            sell: F.usdc, buy: .native(.base), amountIn: F.amount * BigUInt(2), expectedOut: velora.expectedOut + kyber.expectedOut,
            minimumOut: velora.guaranteedOut + kyber.guaranteedOut, priceImpactPercent: nil, networkFeeFiat: nil, providerFeeNote: nil,
            legs: [
                .init(provider: "Velora", fraction: 0.5, amountIn: F.amount, expectedOut: velora.expectedOut),
                .init(provider: "KyberSwap", fraction: 0.5, amountIn: F.amount, expectedOut: kyber.expectedOut),
            ],
            alternatives: [], providersCompared: 4, needsApproval: true, expiresAt: .now.addingTimeInterval(60)
        )
    }

    @Test("Divisao em duas pernas: um plano so, nonces em sequencia entre as pernas, revisao com cada etapa")
    func splitPlan() async throws {
        let state = FakeTradeChain(tokenBalance: BigUInt(250_000_000))
        let engine = H.engine(state: state, sources: try H.sources(EVMCallCounter()), transport: try H.baseTransport())
        let plan = try await engine.plan(try F.request(amount: F.amount * BigUInt(2)), quote: try Self.splitQuote())
        let transactions = plan.transactions.compactMap { $0 as? EVMTransaction }
        #expect(transactions.map(\.nonce) == [7, 8, 9, 10])
        #expect(plan.review.transactionCount == 4)
        #expect(plan.review.title == "Trocar 200\u{00A0}USDC por ETH em 2 etapas")
        #expect(plan.review.lines.contains { $0.label == "Divisão" && $0.value == "50% pela Velora, 50% pela KyberSwap" })
        #expect(plan.review.lines.contains { $0.label.hasPrefix("Etapa 2 · ") })
        // A segunda perna le o estado com o nonce local depois da primeira.
        #expect(await state.reads.map(\.localNextNonce) == [nil, 9])
    }

    @Test("Divisao sem saldo para as duas pernas: a segunda recusa, nada sai")
    func splitInsufficientBalance() async throws {
        let engine = H.engine(state: FakeTradeChain(tokenBalance: BigUInt(150_000_000)), sources: try H.sources(EVMCallCounter()),
                              transport: try H.baseTransport())
        await #expect(throws: SendEngineError.message("Saldo insuficiente para este valor.")) {
            _ = try await engine.plan(try F.request(amount: F.amount * BigUInt(2)), quote: try Self.splitQuote())
        }
    }

    // MARK: Envio

    @Test("Envio: bytes conferidos contra o plano e transmitidos em ordem de nonce pela rota publica da Base")
    func submit() async throws {
        let transport = try H.baseTransport()
        let engine = H.engine(sources: try H.sources(EVMCallCounter()), transport: transport)
        let request = try F.request()
        let plan = try await engine.plan(request, quote: try await engine.quote(request))
        let signed = try EVMTestAccounts.sign(plan)
        let ids = try await engine.submit(signed, plan: plan)
        #expect(ids == signed.map { Hex.encode(Hash.keccak256($0.raw), prefix: true) })
        let sent = transport.calls("eth_sendRawTransaction").map { $0.params.first as? String }
        #expect(sent == [signed[0].encoded, signed[0].encoded, signed[1].encoded, signed[1].encoded])
        #expect(Set(transport.calls("eth_sendRawTransaction").map(\.host)) == ["a.test", "b.test"])
    }

    @Test("Envio: lote fora de ordem ou incompleto nao transmite nada")
    func submitMismatch() async throws {
        let transport = try H.baseTransport()
        let engine = H.engine(sources: try H.sources(EVMCallCounter()), transport: transport)
        let request = try F.request()
        let plan = try await engine.plan(request, quote: try await engine.quote(request))
        let signed = try EVMTestAccounts.sign(plan)
        let refused = SendEngineError.message("As transações assinadas não conferem com o plano revisado. Nada foi transmitido.")
        await #expect(throws: refused) { _ = try await engine.submit([signed[1], signed[0]], plan: plan) }
        await #expect(throws: refused) { _ = try await engine.submit([signed[0]], plan: plan) }
        #expect(transport.calls("eth_sendRawTransaction").isEmpty)
    }

    @Test("Ethereum: a troca sai pelos relays com protecao de MEV, nunca pelo mempool publico")
    func ethereumMEVRoute() async throws {
        let transport = try EVMEthereumFixtures.transport()
        let engine = H.engine(chain: .ethereum, sources: [], transport: transport)
        let account = try EVMAccount(path: EVMTestAccounts.path, publicKey: EVMTestAccounts.testAccount(on: .ethereum).publicKey)
        let transaction = try EVMTransaction(
            chain: .ethereum, account: account, nonce: 3, fee: .eip1559(maxPriorityFeePerGas: 1_000_000, maxFeePerGas: 100_000_000),
            gasLimit: 21_000, to: EVMTestAccounts.binance14, value: 1, data: []
        )
        let plan = SigningPlan(walletID: UUID(), chain: .ethereum, review: PlanReview(kind: .swap, title: "Troca", lines: []),
                               transactions: [transaction])
        let signed = try EVMTestAccounts.sign(plan)
        let ids = try await engine.submit(signed, plan: plan)
        #expect(ids == [Hex.encode(Hash.keccak256(signed[0].raw), prefix: true)])
        let hosts = Set(transport.calls("eth_sendRawTransaction").map(\.host))
        #expect(hosts == ["relay1.test", "relay2.test"])
    }

    @Test("Bytes assinados de outra transacao nao passam pela conferencia")
    func signedMatchesPlan() throws {
        let account = try EVMAccount(path: EVMTestAccounts.path, publicKey: EVMTestAccounts.testAccount(on: .base).publicKey)
        func transaction(_ nonce: UInt64) throws -> EVMTransaction {
            try EVMTransaction(chain: .base, account: account, nonce: nonce, fee: .eip1559(maxPriorityFeePerGas: 1, maxFeePerGas: 10),
                               gasLimit: 21_000, to: EVMTestAccounts.binance14, value: 1, data: [])
        }
        let first = try transaction(1)
        let second = try transaction(2)
        let plan = SigningPlan(walletID: UUID(), chain: .base, review: PlanReview(kind: .swap, title: "", lines: []), transactions: [first, second])
        let signed = try EVMTestAccounts.sign(plan)
        #expect(EVMEngineSupport.matches(signed[0], first))
        #expect(!EVMEngineSupport.matches(signed[0], second))
        #expect(!EVMEngineSupport.matches(signed[1], first))
        #expect(try EVMEngineSupport.pairs(signed, [first, second]).map(\.0.nonce) == [1, 2])
        // Nonce com buraco: recusa.
        let third = try transaction(4)
        let gap = SigningPlan(walletID: UUID(), chain: .base, review: PlanReview(kind: .swap, title: "", lines: []), transactions: [first, third])
        #expect(throws: EVMEngineFailure.batchMismatch) { _ = try EVMEngineSupport.pairs(try EVMTestAccounts.sign(gap), [first, third]) }
    }

    // MARK: Mensagens

    @Test("Mensagens de erro: portugues sem travessao, sem endereco nem hash")
    func messages() {
        let address = EVMTestAccounts.binance14
        let errors: [Error] = [
            EVMEngineFailure.wrongChain, EVMEngineFailure.accountMismatch, EVMEngineFailure.assetNotListed, EVMEngineFailure.tagNotSupported,
            EVMEngineFailure.recipientMismatch, EVMEngineFailure.transferReturnedFalse, EVMEngineFailure.batchMismatch,
            EVMEngineFailure.partialBroadcast, EVMEngineFailure.quoteMismatch, EVMEngineFailure.quoteExpired, EVMEngineFailure.priceMoved,
            EVMEngineFailure.riskIncreased, EVMEngineFailure.noQuote, EVMEngineFailure.allQuotesRefused,
            EVMEngineFailure.limitOrdersUnavailable, EVMEngineFailure.limitPriceNotRepresentable, EVMEngineFailure.openOrderExists,
            EVMEngineFailure.pendingOrderMissing, EVMEngineFailure.prerequisiteFailed, EVMEngineFailure.prerequisiteTimedOut,
            EVMEngineFailure.invalidOrderReference,
            EVMPlanError.insufficientNativeBalance(needed: 1, available: 0), EVMPlanError.refused(.blockedRecipient(address)),
            EVMPlanError.nonceSourcesDisagree, EVMPlanError.feeAboveCeiling, EVMPlanError.allowanceAlreadySet,
            ReaderError.providersDisagree(field: "eth_call"), ReaderError.executionReverted, ReaderError.wrongNetwork,
            ReaderError.broadcastRejected(.nonceTooLow, code: "-32000"), ReaderError.broadcastRejected(.other, code: "x"),
            ReaderError.providerError(code: "-32000"), HTTPClient.Failure.offline, HTTPClient.Failure.status(429), HTTPClient.Failure.tooLarge,
            TradeRefusal.recipientMismatch(address), TradeRefusal.simulationUnexpectedTransfer(token: address),
            TradeRefusal.priceFarFromOracle(deviationBps: 900), TradeRefusal.plan(.zeroAmount),
            TradeProviderError.refused(.velora, .integratorFeeMismatch), TradeProviderError.http(.lifi, .timeout),
            TradeStateError.sourcesDisagree("x"), CoWRefusal.validityOutOfRange, CoWClientError.uidMismatch,
            Address.Problem.badChecksum, EIP712Error.notAllowlisted, CancellationError(),
        ]
        let operations: [EVMEngineOperation] = [.destination, .spendable, .sendPlan, .broadcast, .history, .quote, .tradePlan, .submit,
                                                .limitOrder, .cancellation]
        for error in errors {
            for operation in operations {
                guard case .message(let text) = EVMEngineMessages.userFacing(error, operation, chain: .base) else {
                    Issue.record("sem mensagem: \(error)")
                    continue
                }
                #expect(!text.isEmpty)
                #expect(!text.contains("—") && !text.contains("–"), "\(text)")
                #expect(!text.lowercased().contains("0x"), "\(text)")
                #expect(text.hasSuffix(".") && text.first?.isUppercase == true, "\(text)")
            }
        }
    }
}
