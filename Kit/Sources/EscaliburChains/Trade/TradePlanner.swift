import EscaliburCore
import Foundation

// O plano de troca: de uma cotacao validada a um `SigningPlan`.
//
// Etapas: approve exato (EVMPlanner.planApprove, com `approve(0)` antes no USDT da
// Ethereum) e a troca, ou so a troca quando vende nativo ou a allowance ja cobre. Antes
// de montar, o plano confere o que depende da cadeia: codigo no router, implementacao
// ou faceta fixada, saldo, e a simulacao de duas fontes. O gas vem da simulacao; o que
// o provedor sugere e ignorado (docs/blockchain.md 3.5 item 6).
//
// A revisao, em portugues, diz o que sai, o minimo que entra, o preco, as taxas (rede,
// provedor e "Sem taxa da Escalibur"), a autorizacao exata e o provedor.

/// O estado publico que o plano de troca precisa, lido pela rede.
public struct TradeChainState: Sendable {
    /// Nonce (2 fontes), baseFee, gorjetas e saldo nativo. O `gasEstimate` e o
    /// `l1DataFee` daqui sao ignorados: cada transacao tem os seus abaixo.
    public let network: EVMNetworkState
    /// O token vendido: saldo e `allowance(dono, spender)`. `nil` se vende nativo.
    public let sellToken: EVMTokenState?
    /// `eth_getCode(router)` nao vazio, em duas fontes.
    public let routerHasCode: Bool
    /// O que a cadeia devolveu para a consulta de `ValidatedTradeQuote.pinQuery`, em duas
    /// fontes concordando. `nil` para router imutavel.
    public let routerPin: EVMAddress?
    /// `eth_simulateV1` das chamadas de `TradePlanner.simulationRequest`, uma por fonte.
    public let simulations: [TradeSimulation]
    /// OP e Base: `getL1FeeUpperBound` do tamanho de cada transacao.
    public let approveL1DataFee: BigUInt?
    public let swapL1DataFee: BigUInt?
    /// Arbitrum: a parcela L1 em unidades de gas (NodeInterface.gasEstimateL1Component),
    /// que a simulacao nao conta.
    public let approveL1Gas: UInt64
    public let swapL1Gas: UInt64

    public init(
        network: EVMNetworkState, sellToken: EVMTokenState?, routerHasCode: Bool, routerPin: EVMAddress?,
        simulations: [TradeSimulation], approveL1DataFee: BigUInt? = nil, swapL1DataFee: BigUInt? = nil,
        approveL1Gas: UInt64 = 0, swapL1Gas: UInt64 = 0
    ) {
        self.network = network
        self.sellToken = sellToken
        self.routerHasCode = routerHasCode
        self.routerPin = routerPin
        self.simulations = simulations
        self.approveL1DataFee = approveL1DataFee
        self.swapL1DataFee = swapL1DataFee
        self.approveL1Gas = approveL1Gas
        self.swapL1Gas = swapL1Gas
    }
}

/// O que a rede tem de ler para conferir o codigo atras do router.
public enum TradePinQuery: Sendable, Equatable {
    case none
    /// `eth_getStorageAt(router, slot)`; o endereco sao os 20 bytes baixos.
    case storage(slot: [UInt8])
    /// `eth_call(router, data)`; a resposta e um `address` ABI.
    case call(data: [UInt8])
}

extension ValidatedTradeQuote {
    public var pinQuery: TradePinQuery {
        switch router.pin {
        case .immutable:
            return .none
        case .eip1967:
            return .storage(slot: TradeRouterPin.eip1967ImplementationSlot)
        case .diamondFacet:
            let selector = Array(data.prefix(4))
            guard let call = try? TradeRouterPin.facetAddressFunction.encodeCall([.fixedBytes(selector)]) else { return .none }
            return .call(data: call)
        }
    }
}

/// Em que etapa de uma divisao este plano esta.
public struct TradeSplitStep: Sendable, Equatable {
    public let index: Int
    public let count: Int
    /// Quanto do valor total esta perna leva, em bps.
    public let shareBps: Int

    public init(index: Int, count: Int, shareBps: Int) {
        self.index = index
        self.count = count
        self.shareBps = shareBps
    }
}

public enum TradePlanner {
    /// Os approves que o plano vai precisar, dados a allowance atual. A rede simula
    /// exatamente estas chamadas.
    public static func approvals(for quote: ValidatedTradeQuote, currentAllowance: BigUInt?) -> [BigUInt] {
        guard case .token(let token) = quote.intent.sell else { return [] }
        let current = currentAllowance ?? 0
        guard current < quote.intent.amountIn else { return [] }
        if EVMPlanner.requiresZeroFirstApproval(token), !current.isZero { return [0, quote.intent.amountIn] }
        return [quote.intent.amountIn]
    }

    /// As chamadas que a simulacao tem de rodar, na ordem: approves e a troca.
    public static func simulationRequest(for quote: ValidatedTradeQuote, currentAllowance: BigUInt?) -> TradeSimulationRequest {
        let owner = quote.intent.owner
        let values = approvals(for: quote, currentAllowance: currentAllowance)
        var calls = [TradeSimulationRequest.Call]()
        if let token = quote.intent.sell.contract {
            for value in values {
                calls.append(.init(from: owner, to: token, value: 0, data: ERC20.approve(spender: quote.spender, amount: value)))
            }
        }
        calls.append(.init(from: owner, to: quote.to, value: quote.value, data: quote.data))
        return TradeSimulationRequest(calls: calls, approvals: values)
    }

    /// Monta o plano de troca. `riskConfirmed` e o "sim" explicito do dono quando a
    /// cotacao exige confirmacao (impacto acima de 5%).
    public static func planSwap(
        walletID: UUID, account: EVMAccount, quote: ValidatedTradeQuote, state: TradeChainState,
        riskConfirmed: Bool = false, split: TradeSplitStep? = nil,
        speed: EVMFeeSpeed = .normal, format: EVMTransactionFormat = .eip1559, now: Date = .now
    ) throws -> SigningPlan {
        let intent = quote.intent
        let chain = intent.chain
        guard account.address == intent.owner else { throw TradeRefusal.ownerMismatch }
        guard !quote.isExpired(now: now) else { throw TradeRefusal.quoteExpired }
        guard state.network.chain.id == chain.id else { throw TradeRefusal.plan(.chainMismatch) }
        guard !quote.assessment.requiresConfirmation || riskConfirmed else { throw TradeRefusal.riskNotConfirmed }

        // O router tem codigo, e o codigo e o que foi lido ao gravar a allowlist.
        guard state.routerHasCode else { throw TradeRefusal.routerHasNoCode }
        if let expected = quote.router.pin.expected {
            guard let found = state.routerPin else { throw TradeRefusal.routerPinMissing }
            guard found == expected else { throw TradeRefusal.routerPinMismatch(found: found) }
        }

        // Saldo do token e approves.
        var approvalValues = [BigUInt]()
        if case .token = intent.sell {
            guard let tokenState = state.sellToken, tokenState.contractHasCode, let allowance = tokenState.allowance else {
                throw TradeRefusal.missingTokenState
            }
            guard tokenState.balance >= intent.amountIn else {
                throw TradeRefusal.insufficientTokenBalance(needed: intent.amountIn, available: tokenState.balance)
            }
            approvalValues = approvals(for: quote, currentAllowance: allowance)
        }

        // A simulacao, de duas fontes, com exatamente estas chamadas.
        let request = simulationRequest(for: quote, currentAllowance: state.sellToken?.allowance)
        guard request.approvals == approvalValues else { throw TradeRefusal.simulationShape }
        let gas = try TradeSimulationCheck.verify(state.simulations, request: request, quote: quote)

        var transactions = [EVMTransaction]()
        var approveQuote: EVMFeeQuote?
        if case .token(let token) = intent.sell, !approvalValues.isEmpty, let tokenState = state.sellToken {
            let approveGas = (gas.approvals.max() ?? 0) + state.approveL1Gas
            let approveState = derivedState(state.network, gas: approveGas, l1: state.approveL1DataFee, hasCode: state.routerHasCode)
            let approvePlan: SigningPlan
            do {
                approvePlan = try EVMPlanner.planApprove(
                    walletID: walletID, account: account, token: token, spender: quote.spender,
                    amount: .exact(intent.amountIn), state: approveState, tokenState: tokenState,
                    policy: EVMCallPolicy(approvedSpenders: [quote.spender]), speed: speed, format: format, now: now
                )
                approveQuote = try EVMFeeCalculator.quote(chain: chain, state: approveState, speed: speed, format: format, plainTransfer: false)
            } catch let error as EVMPlanError {
                throw TradeRefusal.plan(error)
            }
            let approves = approvePlan.transactions.compactMap { $0 as? EVMTransaction }
            guard approves.count == approvalValues.count else { throw TradeRefusal.simulationShape }
            transactions += approves
        }

        // A troca, com o nonce depois dos approves.
        let swapState = derivedState(state.network, gas: gas.swap + state.swapL1Gas, l1: state.swapL1DataFee, hasCode: state.routerHasCode)
        let swapQuote: EVMFeeQuote
        let nonce: UInt64
        do {
            swapQuote = try EVMFeeCalculator.quote(chain: chain, state: swapState, speed: speed, format: format, plainTransfer: false)
            nonce = try EVMFeeCalculator.nonce(state.network) + UInt64(transactions.count)
        } catch let error as EVMPlanError {
            throw TradeRefusal.plan(error)
        }
        let swap: EVMTransaction
        do {
            swap = try EVMTransaction(
                chain: chain, account: account, nonce: nonce, fee: swapQuote.fee, gasLimit: swapQuote.gasLimit,
                to: quote.to, value: quote.value, data: quote.data
            )
        } catch {
            throw TradeRefusal.plan(.gasLimitAboveCap)
        }
        // A transacao montada volta pela guarda e pelo decodificador: tem de dizer
        // exatamente o que a cotacao validada disse.
        let again = try TradeValidator.decode(
            TradeProposal(provider: quote.provider, chainID: swap.chainID, from: account.address, to: swap.to, value: swap.value,
                          data: swap.data, expectedOut: quote.expectedOut, spender: nil, gasEstimate: nil, routeSources: nil,
                          reportedPriceImpactBps: nil),
            router: quote.router,
            context: TradeDecodeContext(intent: intent, router: quote.router, fee: quote.decoded.integratorFee, value: swap.value)
        )
        guard again == quote.decoded else { throw TradeRefusal.callRefused(.malformedCalldata) }
        transactions.append(swap)

        // Saldo nativo para tudo: taxa maxima de cada transacao e o valor vendido.
        let approveCost = (approveQuote?.maxCost ?? 0) * BigUInt(approvalValues.count)
        let needed = approveCost + swapQuote.maxCost + quote.value
        guard state.network.nativeBalance >= needed else {
            throw TradeRefusal.plan(.insufficientNativeBalance(needed: needed, available: state.network.nativeBalance))
        }

        let review = swapReview(
            quote: quote, approvalValues: approvalValues, approveQuote: approveQuote, swapQuote: swapQuote,
            firstNonce: transactions.first?.nonce ?? nonce, split: split
        )
        return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: transactions, createdAt: now)
    }

    static func derivedState(_ base: EVMNetworkState, gas: UInt64, l1: BigUInt?, hasCode: Bool) -> EVMNetworkState {
        EVMNetworkState(
            chain: base.chain, pendingNonces: base.pendingNonces, localNextNonce: base.localNextNonce,
            baseFeePerGas: base.baseFeePerGas, priorityFees: base.priorityFees, gasEstimate: gas,
            l1DataFee: l1, nativeBalance: base.nativeBalance, destinationHasCode: hasCode
        )
    }

    // MARK: Revisao

    static func swapReview(
        quote: ValidatedTradeQuote, approvalValues: [BigUInt], approveQuote: EVMFeeQuote?, swapQuote: EVMFeeQuote,
        firstNonce: UInt64, split: TradeSplitStep?
    ) -> PlanReview {
        let intent = quote.intent
        let chain = intent.chain
        let native = TradeAsset.native(chain)
        let count = approvalValues.count + 1
        var lines: [PlanReview.Line] = [
            .init("Rede", chain.name),
            .init("Sai", TradeText.amount(intent.amountIn, intent.sell)),
            .init("Entra, no mínimo", TradeText.amount(quote.guaranteedOut, intent.buy)),
            .init("Estimativa", TradeText.amount(quote.expectedOut, intent.buy)),
            .init("Preço", TradeText.price(amountIn: intent.amountIn, out: quote.expectedOut, sell: intent.sell, buy: intent.buy)),
            .init("Tolerância", TradeText.percent(bps: intent.slippageBps)),
            .init("Provedor", quote.provider.displayName),
            .init("Contrato do provedor", quote.to.checksummed, verbatim: true),
        ]

        // Autorizacao.
        if intent.sell.isNative {
            lines.append(.init("Autorização", "Não precisa: moeda nativa"))
        } else if approvalValues.isEmpty {
            lines.append(.init("Autorização", "Já existe e cobre o valor"))
        } else {
            lines.append(.init("Autorização", "Exata: \(TradeText.amount(intent.amountIn, intent.sell)), nunca ilimitada"))
            lines.append(.init("Autorizado a gastar", quote.spender.checksummed, verbatim: true))
            if approvalValues.count == 2 {
                lines.append(.init("Antes", "Zerar a autorização atual (exigência do \(intent.sell.symbol))"))
            }
        }

        // Taxas.
        let approveCount = BigUInt(approvalValues.count)
        let expectedFee = swapQuote.expectedCost + (approveQuote?.expectedCost ?? 0) * approveCount
        let maxFee = swapQuote.maxCost + (approveQuote?.maxCost ?? 0) * approveCount
        lines.append(.init("Taxa da rede (estimada)", TradeText.amount(expectedFee, native)))
        lines.append(.init("Taxa da rede (máxima)", TradeText.amount(maxFee, native)))
        let l1 = swapQuote.l1DataFee + (approveQuote?.l1DataFee ?? 0) * approveCount
        if !l1.isZero { lines.append(.init("Parte da taxa paga à L1", TradeText.amount(l1, native))) }
        lines.append(.init("Taxa do provedor", providerFeeText(quote)))
        let fee = quote.decoded.integratorFee
        if fee.isNone {
            lines.append(.init("Taxa da Escalibur", "Sem taxa da Escalibur"))
        } else if let recipient = fee.recipient {
            lines.append(.init("Taxa da Escalibur", TradeText.percent(bps: fee.bps)))
            lines.append(.init("Recebedor da taxa", recipient.checksummed, verbatim: true))
        }

        // Mercado.
        if let impact = quote.assessment.priceImpactBps {
            lines.append(.init("Impacto no preço", TradeText.percent(bps: impact)))
        }
        if let deviation = quote.assessment.oracleDeviationBps, deviation > TradeRiskAssessment.oracleWarnBps {
            lines.append(.init("Preço de referência", "\(TradeText.percent(bps: deviation)) pior que o preço médio de mercado"))
        }

        // Etapas.
        if approvalValues.isEmpty {
            lines.append(.init("Etapas", "1 transação: a troca"))
        } else {
            lines.append(.init("Etapas", "\(count) transações: autorizar e trocar, nesta ordem"))
        }
        if let split {
            lines.append(.init("Divisão", "Etapa \(split.index + 1) de \(split.count): \(TradeText.percent(bps: split.shareBps)) do valor"))
            lines.append(.init("Transações independentes", split.index + 1 < split.count
                ? "Se uma etapa seguinte falhar, esta continua valendo: você fica com parte em \(intent.buy.symbol) e parte em \(intent.sell.symbol). Não existe desfazer."
                : "As etapas anteriores já valeram. Se esta falhar, o restante fica em \(intent.sell.symbol) e você perde só a taxa de rede."))
        }
        lines.append(.init("Sem prazo na cadeia", "Se não confirmar logo, cancele com o mesmo nonce em vez de esperar"))
        lines.append(.init("Nonce", count == 1 ? "\(firstNonce)" : "\(firstNonce) a \(firstNonce + UInt64(count - 1))"))

        let title = "Trocar \(TradeText.amount(intent.amountIn, intent.sell)) por \(intent.buy.symbol)"
        return PlanReview(kind: .swap, title: title, lines: lines, warnings: quote.assessment.warnings, transactionCount: count)
    }

    static func providerFeeText(_ quote: ValidatedTradeQuote) -> String {
        let intent = quote.intent
        switch quote.provider {
        case .lifi:
            guard !quote.decoded.providerFeeAmount.isZero else { return "Nenhuma" }
            return "\(TradeText.amount(quote.decoded.providerFeeAmount, intent.sell)) para a LI.FI, já descontada do mínimo"
        case .velora:
            // Sem parceiro, a Augustus manda a sobra acima de `quotedAmount` para a Velora
            // (limitada a 1% dele com a flag de limite). O minimo nao muda.
            return quote.decoded.integratorFee.isNone ? "Nenhuma; o que vier acima da estimativa fica com a Velora" : "Nenhuma"
        case .kyberSwap:
            return "Nenhuma"
        case .de1:
            return "Embutida na rota; o mínimo já considera"
        }
    }
}
