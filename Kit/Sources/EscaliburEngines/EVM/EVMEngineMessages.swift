import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

// O que a tela diz quando um motor EVM recusa ou falha.
//
// Toda saida publica dos motores passa por aqui e vira `SendEngineError.message`, em
// portugues, sem travessao, e sem nenhum dado que venha de provedor: nem texto de erro,
// nem endereco, nem valor, nem hash (docs/seguranca.md 5.4 e 5.6). O que entra na frase e
// compilado: nome e simbolo da rede. Nada e registrado em log.

/// Em que ponto o erro aconteceu: decide a frase quando o erro nao tem uma propria.
enum EVMEngineOperation: Sendable {
    case destination, spendable, sendPlan, broadcast, history, quote, tradePlan, submit, limitOrder, cancellation, orderProgress
}

enum EVMEngineMessages {
    static let localNonceQueueAhead =
        kitText("Uma transação enviada deste aparelho não aparece mais na rede. Confira a Atividade antes de enviar outra. Nada foi assinado.")

    static func userFacing(_ error: Error, _ operation: EVMEngineOperation, chain: Chain) -> SendEngineError {
        if let ready = error as? SendEngineError { return ready }
        return .message(specific(error, chain: chain) ?? fallback(operation, chain: chain))
    }

    static func fallback(_ operation: EVMEngineOperation, chain: Chain) -> String {
        switch operation {
        case .destination: return kitText("Não foi possível consultar o destino agora. Tente de novo em instantes.")
        case .spendable: return kitText("Não foi possível calcular o valor disponível agora.")
        case .sendPlan: return kitText("Não foi possível preparar o envio agora. Nada foi assinado.")
        case .broadcast: return kitText("A rede não confirmou o recebimento da transação. Confira a Atividade antes de tentar de novo.")
        case .history: return kitText("Não foi possível ler o histórico da \(chain.name) agora.")
        case .quote: return kitText("Não foi possível cotar esta troca agora. Tente de novo em instantes.")
        case .tradePlan: return kitText("Não foi possível preparar a troca agora. Nada foi assinado.")
        case .submit: return kitText("A transmissão não foi concluída. Confira a Atividade antes de tentar de novo.")
        case .limitOrder: return kitText("Não foi possível preparar a ordem limite agora. Nada foi assinado.")
        case .cancellation: return kitText("Não foi possível cancelar a ordem agora. Tente de novo em instantes.")
        case .orderProgress: return kitText("Não foi possível ler o andamento da ordem agora.")
        }
    }

    static let staleProviders = kitText("Os provedores da rede não responderam de forma consistente. Nada foi assinado. Tente de novo em instantes.")
    static let quoteRefused = kitText("A cotação não passou na conferência de segurança da carteira. Nada foi assinado.")
    static let simulationMismatch = kitText("A simulação mostrou um movimento que a cotação não prometia. Troca bloqueada.")

    static func specific(_ error: Error, chain: Chain) -> String? {
        switch error {
        case let failure as EVMEngineFailure: return engine(failure, chain: chain)
        case let failure as EVMPlanError: return plan(failure, chain: chain)
        case let failure as ReaderError: return reader(failure, chain: chain)
        case let failure as HTTPClient.Failure: return transport(failure)
        case let failure as TradeRefusal: return trade(failure, chain: chain)
        case let failure as TradeProviderError: return provider(failure, chain: chain)
        case let failure as TradeStateError: return tradeState(failure)
        case let failure as CoWRefusal: return cow(failure, chain: chain)
        case let failure as CoWClientError: return cowClient(failure, chain: chain)
        case let failure as Address.Problem: return address(failure, chain: chain)
        case is EIP712Error: return kitText("A mensagem a assinar não passou na conferência da carteira. Nada foi assinado.")
        case is EVMTransactionError: return kitText("A transação não passou na conferência da carteira. Nada foi assinado.")
        default: return nil
        }
    }

    static func engine(_ failure: EVMEngineFailure, chain: Chain) -> String {
        switch failure {
        case .wrongChain: return kitText("Este pedido é de outra rede.")
        case .accountMismatch: return kitText("A conta desta rede não confere com a chave da carteira. Nada foi assinado.")
        case .assetNotListed: return kitText("Este ativo não está na lista de tokens verificados da \(chain.name).")
        case .customDecimalsChanged: return kitText("As casas decimais deste token na rede não são mais as que foram salvas. Remova a moeda e adicione de novo antes de enviar.")
        case .unlistedDecimalsChanged: return kitText("As casas decimais deste token na rede não conferem com as que a carteira mostrou. Atualize o saldo e tente de novo. Nada foi assinado.")
        case .tagNotSupported: return kitText("A rede \(chain.name) não usa tag nem memo. Envie só com o endereço.")
        case .recipientMismatch: return kitText("O envio montado não confere com o destino digitado. Nada foi assinado.")
        case .transferReturnedFalse: return kitText("O contrato do token recusaria esta transferência. Nada foi assinado.")
        case .batchMismatch: return kitText("As transações assinadas não conferem com o plano revisado. Nada foi transmitido.")
        case .partialBroadcast: return kitText("Parte das transações foi transmitida e parte não. Confira a Atividade antes de tentar de novo.")
        case .quoteMismatch: return kitText("A cotação não corresponde a esta troca. Atualize a cotação e revise de novo.")
        case .quoteExpired: return kitText("A cotação venceu. Atualize e revise de novo.")
        case .priceMoved: return kitText("O preço mudou mais que a sua tolerância desde a cotação. Atualize a cotação e revise de novo.")
        case .riskIncreased: return kitText("O impacto no preço subiu desde a cotação. Atualize a cotação e confirme de novo.")
        case .noQuote: return kitText("Nenhum provedor cotou esta troca agora. Tente um valor menor ou outro par.")
        case .allQuotesRefused: return kitText("Nenhuma cotação passou na conferência de segurança da carteira. Nada foi assinado.")
        case .limitOrdersUnavailable: return kitText("Ordens limite ainda não estão disponíveis na \(chain.name).")
        case .limitPriceNotRepresentable: return kitText("Este preço-alvo tem casas decimais demais para a ordem. Arredonde e tente de novo.")
        case .openOrderExists: return kitText("Já existe uma ordem limite aberta vendendo este token. Cancele a anterior antes de criar outra.")
        case .pendingOrderMissing: return kitText("A ordem venceu antes de ser enviada. Monte a ordem de novo.")
        case .prerequisiteFailed: return kitText("A autorização da ordem falhou na rede. A ordem não foi enviada.")
        case .prerequisiteTimedOut:
            return kitText("A autorização ainda não confirmou, e a ordem não foi enviada. Quando ela aparecer confirmada na Atividade, monte a ordem de novo.")
        case .invalidOrderReference: return kitText("Estas ordens não são desta conta.")
        }
    }

    static func plan(_ failure: EVMPlanError, chain: Chain) -> String? {
        switch failure {
        case .notEVMChain, .chainMismatch: return kitText("Os dados da rede não conferem com esta operação. Nada foi assinado.")
        case .nonceNeedsTwoSources, .nonceSourcesDisagree:
            return kitText("Os provedores da rede não concordaram sobre a sua conta. Nada foi assinado. Tente de novo em instantes.")
        case .localNonceQueueAhead:
            return localNonceQueueAhead
        case .invalidGasEstimate, .gasLimitAboveCap: return kitText("A rede estimou um custo fora do normal para esta transação. Nada foi assinado.")
        case .feeAboveCeiling: return kitText("A taxa da rede está acima do limite de segurança agora. Tente de novo mais tarde.")
        case .missingL1DataFee: return kitText("Não foi possível ler a parte da taxa paga à L1. Tente de novo em instantes.")
        case .zeroAmount: return kitText("Digite um valor maior que zero.")
        case .insufficientNativeBalance: return kitText("Saldo de \(chain.nativeSymbol) insuficiente para o valor e a taxa da rede.")
        case .insufficientTokenBalance: return kitText("Saldo insuficiente para este valor.")
        case .tokenHasNoCode: return kitText("O contrato deste token não respondeu nesta rede. Nada foi assinado.")
        case .spenderHasNoCode: return kitText("O contrato a autorizar não existe nesta rede. Nada foi assinado.")
        case .refused(let refusal): return callRefusal(refusal)
        case .legacyNotSupported, .selfApproval, .missingAllowance, .allowanceAlreadySet, .nothingToRevoke, .unlimitedMustBeExplicit:
            return nil
        }
    }

    static func callRefusal(_ refusal: EVMCallRefusal) -> String {
        switch refusal {
        case .recipientIsTokenContract:
            return kitText("Este endereço é o contrato do próprio token. O que for enviado para ele fica preso para sempre.")
        case .blockedRecipient: return kitText("Este endereço é um contrato de troca ou de token, não uma carteira. Envio recusado.")
        case .burnAddress: return kitText("Este endereço queima tudo o que recebe. Envio recusado.")
        default: return kitText("A transação não passou na conferência da carteira. Nada foi assinado.")
        }
    }

    static func reader(_ failure: ReaderError, chain: Chain) -> String? {
        switch failure {
        case .malformed, .responseMismatch, .implausibleValue:
            return kitText("Um provedor da rede respondeu fora do esperado. Nada foi assinado. Tente de novo em instantes.")
        case .providerError: return "Os provedores da rede recusaram a consulta. Tente de novo em instantes."
        case .notEnoughProviders:
            return kitText("Não houve provedores suficientes respondendo para conferir os dados. Tente de novo em instantes.")
        case .providersDisagree: return staleProviders
        case .wrongNetwork: return kitText("Um provedor respondeu por outra rede e foi descartado. Tente de novo em instantes.")
        case .executionReverted: return kitText("A simulação mostra que a rede recusaria esta transação agora. Nada foi assinado.")
        case .unsupported: return kitText("Esta consulta ainda não está disponível na \(chain.name).")
        case .broadcastMismatch: return kitText("A transação assinada não confere com esta rede. Nada foi transmitido.")
        case .broadcastRejected(let reason, _): return rejection(reason, chain: chain)
        case .accountNotFound, .invalidInput: return nil
        }
    }

    static func rejection(_ reason: BroadcastRejection, chain: Chain) -> String {
        switch reason {
        case .nonceTooLow: return kitText("Outra transação desta conta entrou antes. Revise e envie de novo.")
        case .nonceTooHigh: return kitText("Uma transação anterior desta conta ainda está pendente. Espere ela confirmar e envie de novo.")
        case .alreadyKnown: return kitText("A rede já tinha recebido esta transação. Confira a Atividade.")
        case .insufficientFunds: return kitText("Saldo de \(chain.nativeSymbol) insuficiente para o valor e a taxa da rede. Nada foi debitado.")
        case .underpriced: return kitText("A taxa ficou abaixo do mínimo da rede agora. Revise e envie de novo.")
        case .expired: return kitText("A transação venceu antes de entrar na rede. Revise e envie de novo.")
        case .invalidSignature: return kitText("A rede recusou a assinatura. Nada foi debitado.")
        case .wrongNetwork: return kitText("A rede recusou a transação por ser de outra rede. Nada foi debitado.")
        case .other: return kitText("A rede recusou a transação. Nada foi debitado.")
        }
    }

    static func transport(_ failure: HTTPClient.Failure) -> String? {
        switch failure {
        case .offline: return kitText("Sem conexão com a internet.")
        case .timeout: return kitText("A rede demorou para responder. Tente de novo em instantes.")
        case .status(429): return kitText("Os provedores estão limitando as consultas agora. Tente de novo em instantes.")
        default: return nil
        }
    }

    static func trade(_ refusal: TradeRefusal, chain: Chain) -> String? {
        switch refusal {
        case .notEVMChain, .assetsOnDifferentChains: return kitText("Os dois ativos precisam estar na mesma rede.")
        case .sameAsset: return kitText("Escolha dois ativos diferentes para trocar.")
        case .zeroAmount: return kitText("Digite um valor maior que zero.")
        case .slippageOutOfRange: return kitText("A tolerância de preço precisa ficar entre 0,01% e 10%.")
        case .quoteExpired: return engine(.quoteExpired, chain: chain)
        case .ownerMismatch: return engine(.accountMismatch, chain: chain)
        case .riskNotConfirmed: return engine(.riskIncreased, chain: chain)
        case .routerHasNoCode, .routerPinMissing, .routerPinMismatch:
            return kitText("O contrato do provedor não confere com o que a carteira conhece. Troca bloqueada.")
        case .insufficientTokenBalance: return kitText("Saldo insuficiente para este valor.")
        case .plan(let failure): return plan(failure, chain: chain)
        case .simulationUnavailable:
            return kitText("A simulação da troca não está disponível agora, e sem ela a carteira não troca. Tente de novo em instantes.")
        case .simulationFailed: return kitText("A simulação mostra que esta troca falharia agora. Nada foi assinado.")
        case .simulationShape, .simulationSpentTooMuch, .simulationReceivedTooLittle, .simulationUnexpectedTransfer,
             .simulationUnexpectedApproval:
            return simulationMismatch
        case .priceFarFromOracle: return kitText("O preço desta cotação está longe demais do preço médio de mercado. Troca bloqueada.")
        case .noPriceAnchor:
            return kitText("Sem preço de referência do mercado agora, a troca precisa de pelo menos duas cotações para comparar, e só uma respondeu. Tente de novo em instantes.")
        case .priceImpactTooHigh: return kitText("Esta troca perderia demais para o impacto no preço. Tente um valor menor ou uma ordem limite.")
        case .missingTokenState, .missingApprovalGas: return nil
        case .providerNotOnChain, .chainIDMismatch, .senderMismatch, .routerNotAllowed, .spenderNotAllowed, .selectorNotAllowed,
             .callRefused, .malformed, .recipientMismatch, .sellTokenMismatch, .buyTokenMismatch, .amountInMismatch,
             .valueMismatch, .zeroMinimumOut, .minimumOutTooLow, .deadlineTooFar, .deadlineExpired, .integratorFeeMismatch,
             .integratorFeeNotVerifiable, .providerFeeTooHigh:
            return quoteRefused
        }
    }

    static func provider(_ failure: TradeProviderError, chain: Chain) -> String {
        switch failure {
        case .unsupported, .noRoute: return kitText("O provedor escolhido não tem rota para esta troca agora. Atualize a cotação.")
        case .refused(_, let refusal): return trade(refusal, chain: chain) ?? quoteRefused
        case .http(_, let failure): return transport(failure) ?? kitText("O provedor escolhido não respondeu. Atualize a cotação e tente de novo.")
        case .benched, .timedOut, .badResponse: return kitText("O provedor escolhido não respondeu a tempo. Atualize a cotação e tente de novo.")
        }
    }

    static func tradeState(_ failure: TradeStateError) -> String {
        switch failure {
        case .wrongChainID: return kitText("Um provedor respondeu por outra rede e foi descartado. Tente de novo em instantes.")
        case .notEnoughSources:
            return kitText("Não houve provedores suficientes respondendo para conferir os dados. Tente de novo em instantes.")
        case .sourcesDisagree: return staleProviders
        case .badResponse: return kitText("Um provedor da rede respondeu fora do esperado. Nada foi assinado. Tente de novo em instantes.")
        case .simulationUnavailable:
            return kitText("A simulação da troca não está disponível agora, e sem ela a carteira não troca. Tente de novo em instantes.")
        }
    }

    static func cow(_ refusal: CoWRefusal, chain: Chain) -> String? {
        switch refusal {
        case .unsupportedChain: return engine(.limitOrdersUnavailable, chain: chain)
        case .validityOutOfRange: return kitText("A validade da ordem precisa ficar entre 1 hora e 30 dias.")
        case .zeroBuyAmount: return kitText("Este preço-alvo resulta em zero. Confira o valor.")
        case .sameToken: return kitText("Escolha dois ativos diferentes para a ordem.")
        case .openOrderExists: return engine(.openOrderExists, chain: chain)
        case .invalidUID: return engine(.invalidOrderReference, chain: chain)
        case .relayerHasNoCode: return kitText("O contrato da CoW não respondeu nesta rede. Nada foi assinado.")
        case .insufficientBalance: return kitText("Saldo insuficiente para esta ordem.")
        case .plan(let failure): return plan(failure, chain: chain)
        case .missingWrapGas: return nil
        }
    }

    static func cowClient(_ failure: CoWClientError, chain: Chain) -> String {
        switch failure {
        case .unsupportedChain: return engine(.limitOrdersUnavailable, chain: chain)
        case .malformedSignature: return "A assinatura da ordem não confere. Nada foi enviado à CoW."
        case .uidMismatch, .orderMismatch: return kitText("A CoW devolveu uma ordem diferente da assinada. Confira a Atividade.")
        case .badResponse: return kitText("A CoW respondeu fora do esperado. Confira a Atividade antes de tentar de novo.")
        }
    }

    static func address(_ problem: Address.Problem, chain: Chain) -> String {
        switch problem {
        case .badChecksum:
            return kitText("Uma letra deste endereço não confere. Ele pode ter sido copiado pela metade ou alterado. Copie de novo, inteiro.")
        default: return kitText("Este endereço não é da \(chain.name). Confira se copiou inteiro.")
        }
    }
}

extension SendEngineError {
    /// A fila local do app estava a frente do que a rede conhece (transacao descartada
    /// pela rede). O app limpa a fila da conta: o proximo plano parte da rede.
    public var isLocalNonceQueueAhead: Bool {
        if case .message(let text) = self { return text == EVMEngineMessages.localNonceQueueAhead }
        return false
    }
}
