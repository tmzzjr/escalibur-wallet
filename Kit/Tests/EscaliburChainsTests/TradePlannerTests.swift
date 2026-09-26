import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// O plano de troca: approve exato e troca, simulacao de duas fontes, pin do router e a
/// revisao em portugues. Assina de ponta a ponta com a chave de teste (docs/convencoes.md).
@Suite("Troca: plano")
struct TradePlannerTests {
    typealias S = TradeTestSupport
    typealias T = EVMTestSupport

    static let wallet = UUID()

    static func quote(_ provider: TradeProvider, _ name: String, _ intent: TradeIntent) throws -> ValidatedTradeQuote {
        try TradeValidator.validate(S.proposal(provider, name), intent: intent, now: S.recordedAt)
    }

    static func line(_ plan: SigningPlan, _ label: String) -> String? {
        plan.review.lines.first { $0.label == label }?.value
    }

    @Test("USDC -> ETH na Base: approve exato e troca, nonces em sequencia, revisao e assinatura")
    func approveAndSwap() throws {
        let account = try T.account(T.testKey)
        #expect(account.address == S.owner)
        let quote = try Self.quote(.kyberSwap, "kyber-base-usdc-eth-build", S.baseIntent())
        let state = S.chainState(quote, allowance: 0, l1: BigUInt(20_000_000_000))
        let plan = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote, state: state,
                                             now: S.recordedAt.addingTimeInterval(10))
        #expect(plan.transactions.count == 2)
        #expect(plan.review.kind == .swap)
        #expect(plan.review.transactionCount == 2)
        let approve = plan.transactions[0] as! EVMTransaction
        let swap = plan.transactions[1] as! EVMTransaction
        #expect(approve.nonce == 7 && swap.nonce == 8)
        #expect(approve.to == S.baseUSDC.contract)
        #expect(approve.data == ERC20.approve(spender: quote.spender, amount: 100_000_000))
        #expect(swap.to == quote.to && swap.data == quote.data && swap.value == 0)
        #expect(swap.chainID == 8453)
        // Gas da simulacao (310.000) x 1,2; nunca o do provedor.
        #expect(swap.gasLimit == 372_000)
        #expect(approve.gasLimit == 55_200)

        #expect(plan.review.title == "Trocar 100\u{00A0}USDC por ETH")
        #expect(Self.line(plan, "Sai") == "100\u{00A0}USDC")
        #expect(Self.line(plan, "Entra, no mínimo") == EVMText.amount(quote.guaranteedOut, decimals: 18, symbol: "ETH"))
        #expect(Self.line(plan, "Taxa da Escalibur") == "Sem taxa da Escalibur")
        #expect(Self.line(plan, "Autorização") == "Exata: 100\u{00A0}USDC, nunca ilimitada")
        #expect(plan.review.lines.contains(PlanReview.Line("Autorizado a gastar", "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5", verbatim: true)))
        #expect(Self.line(plan, "Provedor") == "KyberSwap")
        #expect(Self.line(plan, "Taxa do provedor") == "Nenhuma")
        #expect(Self.line(plan, "Preço")?.hasPrefix("1\u{00A0}ETH ≈ ") == true)
        #expect(Self.line(plan, "Parte da taxa paga à L1") != nil)
        #expect(Self.line(plan, "Etapas") == "2 transações: autorizar e trocar, nesta ordem")
        #expect(Self.line(plan, "Nonce") == "7 a 8")
        // Nenhum texto com travessao.
        for line in plan.review.lines { #expect(!line.value.contains("—") && !line.value.contains("–")) }

        // Ponta a ponta: assina as duas com a chave de teste e monta.
        for transaction in [approve, swap] {
            let signed = try transaction.assemble(with: [T.sign(transaction.signingDigest, key: T.testKey)])
            #expect(signed.raw.first == 0x02)
        }
    }

    @Test("Venda de nativo: so a troca, com msg.value, e a autorizacao dita 'nao precisa'")
    func nativeSell() throws {
        let account = try T.account(T.testKey)
        for (provider, name) in [(TradeProvider.velora, "velora-arbitrum-eth-usdc"), (.lifi, "lifi-arbitrum-eth-usdc"), (.de1, "de1-arbitrum-eth-usdc")] {
            let quote = try Self.quote(provider, name, S.arbIntent())
            let plan = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote,
                                                 state: S.chainState(quote), now: S.recordedAt)
            #expect(plan.transactions.count == 1, "\(provider)")
            let swap = plan.transactions[0] as! EVMTransaction
            #expect(swap.value == BigUInt(decimal: "40000000000000000")!)
            #expect(Self.line(plan, "Autorização") == "Não precisa: moeda nativa")
        }
    }

    @Test("Allowance que ja cobre: sem approve; allowance parcial: approve do valor exato")
    func existingAllowance() throws {
        let account = try T.account(T.testKey)
        let quote = try Self.quote(.velora, "velora-base-usdc-eth", S.baseIntent())
        let covered = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote,
                                                state: S.chainState(quote, allowance: 500_000_000), now: S.recordedAt)
        #expect(covered.transactions.count == 1)
        #expect(Self.line(covered, "Autorização") == "Já existe e cobre o valor")
        let partial = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote,
                                                state: S.chainState(quote, allowance: 1), now: S.recordedAt)
        #expect(partial.transactions.count == 2)
        #expect((partial.transactions[0] as! EVMTransaction).data == ERC20.approve(spender: quote.spender, amount: 100_000_000))
    }

    @Test("USDT na Ethereum com allowance antiga: approve(0), approve exato e troca")
    func usdtZeroFirst() throws {
        let account = try T.account(T.testKey)
        let intent = try TradeIntent(owner: S.owner, sell: .token(S.ethUSDT), buy: .native(.ethereum), amountIn: 50_000_000, slippageBps: 50)
        // Calldata da Velora montada localmente para o par, com os campos que a API poe.
        let router = TradeAllowlist.router(for: .velora, on: .ethereum)!
        let expected = BigUInt(decimal: "20000000000000000")!
        let data = try VeloraCalldata.swapExactAmountIn.encodeCall([
            .address(T.address("0x000010036c0190e009a000d0fc3541100a07380a")),
            .tuple([.address(S.ethUSDT.contract), .address(TradeConstants.eeeeSentinel), .uint(50_000_000),
                    .uint(intent.minimumOut(forExpected: expected)), .uint(expected), .fixedBytes([UInt8](repeating: 7, count: 32)),
                    .address(S.owner)]),
            .uint(BigUInt(1).shiftedLeft(by: 92)), .bytes([]), .bytes([1, 2, 3, 4]),
        ])
        let proposal = TradeProposal(provider: .velora, chainID: 1, from: S.owner, to: router.address, value: 0, data: data,
                                     expectedOut: expected, spender: router.spender, gasEstimate: 200_000, routeSources: nil,
                                     reportedPriceImpactBps: nil)
        let quote = try TradeValidator.validate(proposal, intent: intent, now: S.recordedAt)
        let plan = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote,
                                             state: S.chainState(quote, allowance: 3), now: S.recordedAt)
        #expect(plan.transactions.count == 3)
        #expect((plan.transactions[0] as! EVMTransaction).data == ERC20.approve(spender: router.spender, amount: 0))
        #expect((plan.transactions[1] as! EVMTransaction).data == ERC20.approve(spender: router.spender, amount: 50_000_000))
        #expect((plan.transactions.map { ($0 as! EVMTransaction).nonce }) == [7, 8, 9])
        #expect(Self.line(plan, "Antes") == "Zerar a autorização atual (exigência do USDT)")
    }

    @Test("Simulacao: uma fonte so, recebido abaixo do minimo, outro token saindo, approval estranho")
    func simulationRefusals() throws {
        let account = try T.account(T.testKey)
        let quote = try Self.quote(.kyberSwap, "kyber-base-usdc-eth-build", S.baseIntent())
        func plan(_ simulations: [TradeSimulation]) throws -> SigningPlan {
            try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote,
                                      state: S.chainState(quote, allowance: 0, simulations: simulations), now: S.recordedAt)
        }
        let honest = S.simulation(quote, source: "a", allowance: 0)
        #expect(throws: TradeRefusal.simulationUnavailable) { try plan([honest]) }
        #expect(throws: TradeRefusal.simulationUnavailable) { try plan([honest, honest]) }

        let short = S.simulation(quote, source: "b", allowance: 0, received: quote.guaranteedOut - 1)
        #expect(throws: TradeRefusal.simulationReceivedTooLittle(found: quote.guaranteedOut - 1, required: quote.guaranteedOut)) {
            try plan([honest, short])
        }
        let weth = T.address("0x4200000000000000000000000000000000000006")
        let drain = S.simulation(quote, source: "b", allowance: 0, extraSwapLogs: [S.transferLog(weth, from: S.owner, to: S.stranger, 1)])
        #expect(throws: TradeRefusal.simulationUnexpectedTransfer(token: weth)) { try plan([honest, drain]) }
        let approval = S.simulation(quote, source: "b", allowance: 0,
                                    extraSwapLogs: [S.approvalLog(S.baseUSDC.contract, owner: S.owner, spender: S.stranger, .uint256Max)])
        #expect(throws: TradeRefusal.simulationUnexpectedApproval(token: S.baseUSDC.contract, spender: S.stranger)) { try plan([honest, approval]) }
        var reverted = S.simulation(quote, source: "b", allowance: 0)
        reverted = TradeSimulation(source: "b", calls: [reverted.calls[0], TradeSimulatedCall(success: false, gasUsed: 90_000, logs: [])])
        #expect(throws: TradeRefusal.simulationFailed(call: 1)) { try plan([honest, reverted]) }
        // Simulou so a troca, sem o approve que o plano vai assinar.
        let noApprove = TradeSimulation(source: "b", calls: [honest.calls[1]])
        #expect(throws: TradeRefusal.simulationShape) { try plan([honest, noApprove]) }
    }

    @Test("Pin: faceta da LI.FI e implementacao da De¹ tem de ser as compiladas")
    func routerPin() throws {
        let account = try T.account(T.testKey)
        let lifi = try Self.quote(.lifi, "lifi-base-usdc-eth", S.baseIntent())
        #expect(lifi.pinQuery == .call(data: try TradeRouterPin.facetAddressFunction.encodeCall([.fixedBytes(Array(lifi.data.prefix(4)))])))
        _ = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: lifi, state: S.chainState(lifi), now: S.recordedAt)
        #expect(throws: TradeRefusal.routerPinMismatch(found: S.stranger)) {
            try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: lifi, state: S.chainState(lifi, pin: .some(S.stranger)), now: S.recordedAt)
        }
        #expect(throws: TradeRefusal.routerPinMissing) {
            try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: lifi, state: S.chainState(lifi, pin: .some(nil)), now: S.recordedAt)
        }
        let de1 = try Self.quote(.de1, "de1-base-usdc-eth", S.baseIntent())
        #expect(de1.pinQuery == .storage(slot: TradeRouterPin.eip1967ImplementationSlot))
        #expect(throws: TradeRefusal.routerPinMismatch(found: S.stranger)) {
            try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: de1, state: S.chainState(de1, pin: .some(S.stranger)), now: S.recordedAt)
        }
        let kyber = try Self.quote(.kyberSwap, "kyber-base-usdc-eth-build", S.baseIntent())
        #expect(kyber.pinQuery == .none)
    }

    @Test("Recusas do plano: outra conta, cotacao vencida, risco sem confirmacao, saldos")
    func planRefusals() throws {
        let account = try T.account(T.testKey)
        let other = try T.account("4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318")
        let quote = try Self.quote(.velora, "velora-base-usdc-eth", S.baseIntent())
        #expect(throws: TradeRefusal.ownerMismatch) {
            try TradePlanner.planSwap(walletID: Self.wallet, account: other, quote: quote, state: S.chainState(quote), now: S.recordedAt)
        }
        #expect(throws: TradeRefusal.quoteExpired) {
            try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote, state: S.chainState(quote),
                                      now: S.recordedAt.addingTimeInterval(61))
        }
        #expect(throws: TradeRefusal.insufficientTokenBalance(needed: 100_000_000, available: 99_999_999)) {
            try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote,
                                      state: S.chainState(quote, balance: 99_999_999), now: S.recordedAt)
        }
        #expect(throws: TradeRefusal.self) {
            try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote,
                                      state: S.chainState(quote, nativeBalance: 1), now: S.recordedAt)
        }
        let risky = try TradeValidator.validate(S.with(S.proposal(.velora, "velora-base-usdc-eth"), impact: .some(700)),
                                                intent: S.baseIntent(), now: S.recordedAt)
        #expect(throws: TradeRefusal.riskNotConfirmed) {
            try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: risky, state: S.chainState(risky), now: S.recordedAt)
        }
        let confirmed = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: risky, state: S.chainState(risky),
                                                  riskConfirmed: true, now: S.recordedAt)
        #expect(confirmed.review.warnings == [.highPriceImpact(percent: 7)])
        #expect(Self.line(confirmed, "Impacto no preço") == "7%")
    }

    @Test("Taxa do provedor na revisao: LI.FI mostra os 0,25 USDC, Velora explica a sobra")
    func providerFeeLines() throws {
        let account = try T.account(T.testKey)
        let lifi = try Self.quote(.lifi, "lifi-base-usdc-eth", S.baseIntent())
        let lifiPlan = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: lifi, state: S.chainState(lifi), now: S.recordedAt)
        #expect(Self.line(lifiPlan, "Taxa do provedor") == "0,25\u{00A0}USDC para a LI.FI, já descontada do mínimo")
        let velora = try Self.quote(.velora, "velora-base-usdc-eth", S.baseIntent())
        let veloraPlan = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: velora, state: S.chainState(velora), now: S.recordedAt)
        #expect(Self.line(veloraPlan, "Taxa do provedor")?.contains("Velora") == true)
    }

    @Test("Etapa de uma divisao: a revisao diz que as transacoes sao independentes")
    func splitStep() throws {
        let account = try T.account(T.testKey)
        let quote = try Self.quote(.kyberSwap, "kyber-base-usdc-eth-build", S.baseIntent())
        let plan = try TradePlanner.planSwap(walletID: Self.wallet, account: account, quote: quote, state: S.chainState(quote),
                                             split: TradeSplitStep(index: 0, count: 2, shareBps: 6_000), now: S.recordedAt)
        #expect(Self.line(plan, "Divisão") == "Etapa 1 de 2: 60% do valor")
        #expect(Self.line(plan, "Transações independentes")?.contains("Não existe desfazer") == true)
    }
}
