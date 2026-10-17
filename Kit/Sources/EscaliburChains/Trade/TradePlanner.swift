import EscaliburCore
import Foundation

// O plano de troca: de uma cotacao validada a um `SigningPlan`.
//
// Etapas: approve exato (EVMPlanner.planApprove, com `approve(0)` antes no USDT da
// Ethereum), na Uniswap a permissao exata do Permit2 ao router, e a troca; ou so a
// troca quando vende nativo ou as permissoes ja cobrem. Antes
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
    /// Uniswap: o que o Permit2 ja permite ao router, e a taxa L1 da permissao nova.
    public let permit2: TradePermit2Allowance?
    public let permit2L1DataFee: BigUInt?
    public let permit2L1Gas: UInt64

    public init(
        network: EVMNetworkState, sellToken: EVMTokenState?, routerHasCode: Bool, routerPin: EVMAddress?,
        simulations: [TradeSimulation], approveL1DataFee: BigUInt? = nil, swapL1DataFee: BigUInt? = nil,
        approveL1Gas: UInt64 = 0, swapL1Gas: UInt64 = 0,
        permit2: TradePermit2Allowance? = nil, permit2L1DataFee: BigUInt? = nil, permit2L1Gas: UInt64 = 0
    ) {
        self.permit2 = permit2
        self.permit2L1DataFee = permit2L1DataFee
        self.permit2L1Gas = permit2L1Gas
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

/// O que o Permit2 ja permite a um router: `allowance(dono, token, router)`, valor e prazo
/// (segundos Unix), o menor de duas fontes.
public struct TradePermit2Allowance: Sendable, Equatable {
    public let amount: BigUInt
    public let expiration: UInt64

    public init(amount: BigUInt, expiration: UInt64) {
        self.amount = amount
        self.expiration = expiration
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

    /// Folga do prazo da permissao do Permit2 que ja existe: abaixo de 5 minutos, o plano
    /// pede uma nova, para a troca nao chegar depois do prazo.
    static let permit2Margin: UInt64 = 5 * 60

    /// A permissao do Permit2 ao router que o plano precisa (Uniswap), dada a que ja
    /// existe: valor exato, prazo de 30 minutos. O prazo conta da cotacao validada, para a
    /// simulacao e o plano montarem exatamente a mesma chamada.
    public static func permit2Approval(for quote: ValidatedTradeQuote, current: TradePermit2Allowance?) -> EVMPermit2Approval? {
        guard quote.router.viaPermit2, let token = quote.intent.sell.contract else { return nil }
        let start = UInt64(max(0, quote.validatedAt.timeIntervalSince1970))
        if let current, current.amount >= quote.intent.amountIn, current.expiration >= start + permit2Margin { return nil }
        return EVMPermit2Approval(token: token, spender: quote.router.address, amount: quote.intent.amountIn,
                                  expiration: start + EVMPermit2Approval.maxLifetime)
    }

    /// As chamadas que a simulacao tem de rodar, na ordem: approves, a permissao do Permit2
    /// (Uniswap) e a troca.
    public static func simulationRequest(
        for quote: ValidatedTradeQuote, currentAllowance: BigUInt?, permit2: TradePermit2Allowance? = nil
    ) -> TradeSimulationRequest {
        let owner = quote.intent.owner
        let values = approvals(for: quote, currentAllowance: currentAllowance)
        var calls = [TradeSimulationRequest.Call]()
        if let token = quote.intent.sell.contract {
            for value in values {
                calls.append(.init(from: owner, to: token, value: 0, data: ERC20.approve(spender: quote.spender, amount: value)))
            }
        }
        let grant = permit2Approval(for: quote, current: permit2)
        if let grant, let data = try? grant.calldata() {
            calls.append(.init(from: owner, to: EIP712ValidatedMessage.permit2, value: 0, data: data))
        }
        calls.append(.init(from: owner, to: quote.to, value: quote.value, data: quote.data))
        return TradeSimulationRequest(calls: calls, approvals: values, permit2: grant)
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
        let grant = permit2Approval(for: quote, current: state.permit2)
        let request = simulationRequest(for: quote, currentAllowance: state.sellToken?.allowance, permit2: state.permit2)
        guard request.approvals == approvalValues, request.permit2 == grant else { throw TradeRefusal.simulationShape }
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

        // Uniswap: a permissao exata do Permit2 ao router, depois dos approves. A guarda so
        // aceita esta chamada com exatamente este token, router, valor e prazo.
        var permit2Quote: EVMFeeQuote?
        if let grant {
            guard let permit2Gas = gas.permit2, grant.spender == quote.router.address, grant.token == intent.sell.contract,
                  grant.amount == intent.amountIn
            else { throw TradeRefusal.simulationShape }
            let grantState = derivedState(state.network, gas: permit2Gas + state.permit2L1Gas, l1: state.permit2L1DataFee, hasCode: true)
            let transaction: EVMTransaction
            do {
                let fee = try EVMFeeCalculator.quote(chain: chain, state: grantState, speed: speed, format: format, plainTransfer: false)
                let nonce = try EVMFeeCalculator.nonce(state.network) + UInt64(transactions.count)
                transaction = try EVMTransaction(
                    chain: chain, account: account, nonce: nonce, fee: fee.fee, gasLimit: fee.gasLimit,
                    to: EIP712ValidatedMessage.permit2, value: 0, data: try grant.calldata()
                )
                try EVMPlanner.confirm(
                    transaction,
                    decodesTo: .contractCall(contract: EIP712ValidatedMessage.permit2, function: EVMPermit2Approval.function.signature,
                                             arguments: grant.arguments, value: 0),
                    policy: EVMCallPolicy(permit2Approval: grant)
                )
                permit2Quote = fee
            } catch let error as EVMPlanError {
                throw TradeRefusal.plan(error)
            } catch let refusal as TradeRefusal {
                throw refusal
            } catch {
                throw TradeRefusal.plan(.gasLimitAboveCap)
            }
            transactions.append(transaction)
        }

        // A troca, com o nonce depois dos approves e da permissao.
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
        let needed = approveCost + (permit2Quote?.maxCost ?? 0) + swapQuote.maxCost + quote.value
        guard state.network.nativeBalance >= needed else {
            throw TradeRefusal.plan(.insufficientNativeBalance(needed: needed, available: state.network.nativeBalance))
        }

        let review = swapReview(
            quote: quote, approvalValues: approvalValues, approveQuote: approveQuote, swapQuote: swapQuote,
            firstNonce: transactions.first?.nonce ?? nonce, split: split, permit2: grant.map { ($0, permit2Quote) }
        )
        return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: transactions, createdAt: now)
    }

    static func derivedState(_ base: EVMNetworkState, gas: UInt64, l1: BigUInt?, hasCode: Bool) -> EVMNetworkState {
        EVMNetworkState(
            chain: base.chain, pendingNonces: base.pendingNonces, localNextNonce: base.localNextNonce, localPendingCount: base.localPendingCount,
            baseFeePerGas: base.baseFeePerGas, priorityFees: base.priorityFees, gasEstimate: gas,
            l1DataFee: l1, nativeBalance: base.nativeBalance, destinationHasCode: hasCode
        )
    }

    // MARK: Revisao

    static func swapReview(
        quote: ValidatedTradeQuote, approvalValues: [BigUInt], approveQuote: EVMFeeQuote?, swapQuote: EVMFeeQuote,
        firstNonce: UInt64, split: TradeSplitStep?, permit2: (grant: EVMPermit2Approval, fee: EVMFeeQuote?)? = nil
    ) -> PlanReview {
        let intent = quote.intent
        let chain = intent.chain
        let native = TradeAsset.native(chain)
        let count = approvalValues.count + (permit2 == nil ? 0 : 1) + 1
        var lines: [PlanReview.Line] = [
            .init(kitText("Rede"), chain.name),
            .init(kitText("Sai"), TradeText.amount(intent.amountIn, intent.sell), role: .sold),
            .init(kitText("Entra, no mínimo"), TradeText.amount(quote.guaranteedOut, intent.buy)),
            .init(kitText("Estimativa"), TradeText.amount(quote.expectedOut, intent.buy)),
            .init(kitText("Preço"), TradeText.price(amountIn: intent.amountIn, out: quote.expectedOut, sell: intent.sell, buy: intent.buy)),
            .init(kitText("Tolerância"), TradeText.percent(bps: intent.slippageBps)),
            .init(kitText("Provedor"), quote.provider.displayName),
            .init(kitText("Contrato do provedor"), quote.to.checksummed, verbatim: true, role: .assetReference),
        ]

        // Autorizacao.
        if intent.sell.isNative {
            lines.append(.init(kitText("Autorização"), kitText("Não precisa: moeda nativa")))
        } else if approvalValues.isEmpty {
            lines.append(.init(kitText("Autorização"), kitText("Já existe e cobre o valor")))
        } else {
            lines.append(.init(kitText("Autorização"), kitText("Exata: \(TradeText.amount(intent.amountIn, intent.sell)), nunca ilimitada")))
            lines.append(.init(kitText("Autorizado a gastar"), quote.spender.checksummed, verbatim: true))
            if approvalValues.count == 2 {
                lines.append(.init(kitText("Antes"), kitText("Zerar a autorização atual (exigência do \(intent.sell.symbol))")))
            }
        }
        if let permit2 {
            lines.append(.init(kitText("Permissão no Permit2"), kitText("\(TradeText.amount(permit2.grant.amount, intent.sell)) para o contrato da Uniswap, por 30 minutos")))
            lines.append(.init(kitText("Contrato autorizado no Permit2"), permit2.grant.spender.checksummed, verbatim: true))
        }

        // Taxas.
        let approveCount = BigUInt(approvalValues.count)
        let expectedFee = swapQuote.expectedCost + (approveQuote?.expectedCost ?? 0) * approveCount + (permit2?.fee?.expectedCost ?? 0)
        let maxFee = swapQuote.maxCost + (approveQuote?.maxCost ?? 0) * approveCount + (permit2?.fee?.maxCost ?? 0)
        lines.append(.init(kitText("Taxa da rede (estimada)"), TradeText.amount(expectedFee, native)))
        lines.append(.init(kitText("Taxa da rede (máxima)"), TradeText.amount(maxFee, native)))
        let l1 = swapQuote.l1DataFee + (approveQuote?.l1DataFee ?? 0) * approveCount + (permit2?.fee?.l1DataFee ?? 0)
        if !l1.isZero { lines.append(.init(kitText("Parte da taxa paga à L1"), TradeText.amount(l1, native))) }
        lines.append(.init(kitText("Taxa do provedor"), providerFeeText(quote)))
        let fee = quote.decoded.integratorFee
        if fee.isNone {
            lines.append(.init(kitText("Taxa da Escalibur"), kitText("Sem taxa da Escalibur")))
        } else if let recipient = fee.recipient {
            lines.append(.init(kitText("Taxa da Escalibur"), TradeText.percent(bps: fee.bps)))
            lines.append(.init(kitText("Recebedor da taxa"), recipient.checksummed, verbatim: true))
        }

        // Mercado.
        if let impact = quote.assessment.priceImpactBps {
            lines.append(.init(kitText("Impacto no preço"), TradeText.percent(bps: impact)))
        }
        if let deviation = quote.assessment.oracleDeviationBps, deviation > TradeRiskAssessment.oracleWarnBps {
            lines.append(.init(kitText("Preço de referência"), kitText("\(TradeText.percent(bps: deviation)) pior que o preço médio de mercado")))
        }

        // Etapas.
        if count == 1 {
            lines.append(.init(kitText("Etapas"), kitText("1 transação: a troca")))
        } else if permit2 != nil {
            lines.append(.init(kitText("Etapas"), kitText("\(count) transações: autorizar, liberar no Permit2 e trocar, nesta ordem")))
        } else {
            lines.append(.init(kitText("Etapas"), kitText("\(count) transações: autorizar e trocar, nesta ordem")))
        }
        if let split {
            lines.append(.init(kitText("Divisão"), kitText("Etapa \(split.index + 1) de \(split.count): \(TradeText.percent(bps: split.shareBps)) do valor")))
            lines.append(.init(kitText("Transações independentes"), split.index + 1 < split.count
                ? kitText("Se uma etapa seguinte falhar, esta continua valendo: você fica com parte em \(intent.buy.symbol) e parte em \(intent.sell.symbol). Não existe desfazer.")
                : kitText("As etapas anteriores já valeram. Se esta falhar, o restante fica em \(intent.sell.symbol) e você perde só a taxa de rede.")))
        }
        lines.append(deadlineLine(quote))
        lines.append(.init(kitText("Nonce"), count == 1 ? String(firstNonce) : kitText("\(String(firstNonce)) a \(String(firstNonce + UInt64(count - 1)))")))

        // O que sai, o minimo que entra e quem recebe saem da calldata decodificada da
        // transacao montada (`again == quote.decoded`), nunca da intencao.
        let decoded = quote.decoded
        let title = kitText("Trocar \(TradeText.amount(decoded.amountIn, intent.sell)) por \(intent.buy.symbol)")
        return PlanReview(
            kind: .swap, title: title, lines: lines, warnings: quote.assessment.warnings, transactionCount: count,
            outgoing: intent.sell.movement(decoded.amountIn), incomingMinimum: intent.buy.movement(decoded.guaranteedOut),
            beneficiary: decoded.recipient.checksummed
        )
    }

    /// O prazo na cadeia, dito como o router confere (auditoria 2, B5). Nenhum dos quatro
    /// routers da v1 confere prazo na funcao aceita (`TradeValidator` diz por que, router
    /// a router): a revisao diz isso sem prometer o que o app nao faz. So o decodificador
    /// de um router que confira prazo no proprio codigo preenche `deadline`, e o
    /// validador ja exige que ele esteja entre agora e 20 minutos.
    static func deadlineLine(_ quote: ValidatedTradeQuote) -> PlanReview.Line {
        guard let deadline = quote.decoded.deadline else {
            return .init(kitText("Prazo na cadeia"), kitText("Nenhum que a carteira consiga conferir: o contrato da \(quote.provider.displayName) não tem prazo. Se a transação ficar presa na rede, ela pode executar bem mais tarde, e então vale só o mínimo acima, mesmo que o preço tenha melhorado"))
        }
        let date = NumberStyle.current.utcStamp(Date(timeIntervalSince1970: TimeInterval(deadline)))
        return .init(kitText("Prazo na cadeia"), kitText("Até \(date). Depois disso, o contrato da \(quote.provider.displayName) recusa a troca"))
    }

    static func providerFeeText(_ quote: ValidatedTradeQuote) -> String {
        let intent = quote.intent
        switch quote.provider {
        case .lifi:
            guard !quote.decoded.providerFeeAmount.isZero else { return kitText("Nenhuma") }
            return kitText("\(TradeText.amount(quote.decoded.providerFeeAmount, intent.sell)) para a LI.FI, já descontada do mínimo")
        case .velora:
            // Sem parceiro, a Augustus manda a sobra acima de `quotedAmount` para a Velora
            // (limitada a 1% dele com a flag de limite). O minimo nao muda.
            return quote.decoded.integratorFee.isNone ? kitText("Nenhuma; o que vier acima da estimativa fica com a Velora") : kitText("Nenhuma")
        case .kyberSwap:
            return kitText("Nenhuma")
        case .de1:
            return kitText("Embutida na rota; o mínimo já considera")
        case .uniswap, .pancakeswap, .shibaswap:
            return kitText("Só a taxa do pool, já no preço; o mínimo já considera")
        }
    }
}

// MARK: Mudanca de rota

/// Por que a troca saiu por outro provedor que nao o da cotacao mostrada.
public enum TradeReroute: Sendable, Equatable {
    /// A rota cotada nao passou na simulacao agora (a De¹ na Base, que promete e nao entrega).
    case simulationFailed(TradeProvider)
    /// A divisao entre estes provedores nao se sustentou na simulacao em sequencia.
    case splitInterfered([TradeProvider])
}

extension TradePlanner {
    /// A revisao diz por que a troca vai por este provedor, logo depois dele: o dono viu outro
    /// provedor (ou a divisao) na cotacao. Em tom de escolha, nao de alarme (pedido do dono,
    /// 17/10/2026), sem prometer o que nao e: a rota nova e a proxima da fila, nao uma melhor.
    public static func rerouted(_ plan: SigningPlan, _ reason: TradeReroute, to provider: TradeProvider) -> SigningPlan {
        let text: String
        switch reason {
        case .simulationFailed(let shown):
            text = kitText("A cotação da \(shown.displayName) falharia na rede agora. Escolhemos a próxima melhor, a da \(provider.displayName), que passou na simulação.")
        case .splitInterfered(let shown):
            let names = shown.map(\.displayName).joined(separator: " e ")
            text = kitText("Dividir entre \(names) não funcionaria agora. Escolhemos a melhor cotação inteira, a da \(provider.displayName), que passou na simulação.")
        }
        return plan.addingLine(.init(kitText("Rota escolhida"), text), after: kitText("Provedor"))
    }
}

// MARK: Troca dividida

extension TradePlanner {
    /// Junta as pernas de uma troca dividida num plano so, assinado de uma vez: as
    /// transacoes de todas as pernas em sequencia de nonce, e a revisao com a visao geral
    /// seguida das linhas de cada etapa.
    ///
    /// Tudo o que a revisao diz sai daqui, das pernas: cada plano tem de ser uma troca
    /// montada por `planSwap` a partir da cotacao validada na mesma posicao (a troca e a
    /// ultima transacao, com o router, o valor e a calldata dela), da mesma conta, dos
    /// mesmos ativos, com nonces seguidos. O motor so entrega os planos e as cotacoes;
    /// nao escreve titulo nem linha. O prazo do plano conta da primeira perna.
    public static func combineSplit(_ plans: [SigningPlan], quotes: [ValidatedTradeQuote]) throws -> SigningPlan {
        guard plans.count >= 2, plans.count == quotes.count, plans.count <= TradeSplitOptimizer.maxProviders,
              let reference = quotes.first?.intent
        else { throw SigningPlan.CompositionError.partsDoNotMatch }
        let owner = reference.owner
        var nextNonce: UInt64?
        for (plan, quote) in zip(plans, quotes) {
            guard plan.review.kind == .swap else {
                throw plan.review.kind == .send ? SigningPlan.CompositionError.sendInsideTrade : SigningPlan.CompositionError.partsDoNotMatch
            }
            let intent = quote.intent
            guard intent.chain.id == reference.chain.id, intent.owner == owner, intent.sell == reference.sell, intent.buy == reference.buy,
                  intent.slippageBps == reference.slippageBps, plan.chain.id == reference.chain.id
            else { throw SigningPlan.CompositionError.partsDoNotMatch }
            let transactions = plan.transactions.compactMap { $0 as? EVMTransaction }
            guard transactions.count == plan.transactions.count, let swap = transactions.last,
                  swap.to == quote.to, swap.value == quote.value, swap.data == quote.data,
                  transactions.allSatisfy({ $0.account.address == owner && $0.chain.id == reference.chain.id }),
                  plan.review.outgoing == intent.sell.movement(quote.decoded.amountIn),
                  plan.review.incomingMinimum == intent.buy.movement(quote.guaranteedOut),
                  plan.review.beneficiary == owner.checksummed
            else { throw SigningPlan.CompositionError.partsDoNotMatch }
            for transaction in transactions {
                if let expected = nextNonce, transaction.nonce != expected { throw SigningPlan.CompositionError.partsDoNotMatch }
                nextNonce = transaction.nonce + 1
            }
        }

        let sell = reference.sell
        let buy = reference.buy
        let total = quotes.reduce(BigUInt()) { $0 + $1.decoded.amountIn }
        let guaranteed = quotes.reduce(BigUInt()) { $0 + $1.guaranteedOut }
        let expected = quotes.reduce(BigUInt()) { $0 + $1.expectedOut }
        let count = plans.reduce(0) { $0 + $1.review.transactionCount }
        let division = quotes.map { quote -> String in
            let share = (quote.decoded.amountIn * BigUInt(10_000) / total).uint64.map(Int.init) ?? 0
            return kitText("\(TradeText.percent(bps: share)) pela \(quote.provider.displayName)")
        }
        let lead: [PlanReview.Line] = [
            .init(kitText("Rede"), reference.chain.name),
            .init(kitText("Sai"), TradeText.amount(total, sell), role: .sold),
            .init(kitText("Entra, no mínimo"), TradeText.amount(guaranteed, buy)),
            .init(kitText("Estimativa"), TradeText.amount(expected, buy)),
            .init(kitText("Divisão"), division.joined(separator: ", ")),
            .init(kitText("Transações"), kitText("\(count) transações independentes, em sequência, assinadas de uma vez")),
            .init(kitText("Se uma etapa falhar"), kitText("As outras continuam valendo: você fica com parte em \(buy.symbol) e parte em \(sell.symbol). Não existe desfazer, e a etapa que falhou custa só a taxa de rede.")),
            .init(kitText("Taxa da Escalibur"), kitText("Sem taxa da Escalibur")),
        ]
        let title = kitText("Trocar \(TradeText.amount(total, sell)) por \(buy.symbol) em \(plans.count) etapas")
        return try SigningPlan.sequence(
            plans, kind: .swap, title: title, lead: lead, stepPrefix: true, omitting: [kitText("Rede"), kitText("Divisão"), kitText("Taxa da Escalibur")],
            outgoing: sell.movement(total), incomingMinimum: buy.movement(guaranteed), beneficiary: owner.checksummed
        )
    }
}

extension TradeAsset {
    /// O movimento deste ativo, com o id da lista curada.
    func movement(_ amount: BigUInt) -> PlanReview.Movement {
        switch self {
        case .native(let chain): return .native(chain, amount)
        case .token(let token): return .token(token.chain, contract: token.contract.checksummed, amount)
        }
    }
}
