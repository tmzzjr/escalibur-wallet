import EscaliburChains
import EscaliburNetwork
import Foundation

/// A frase que a tela mostra quando a rede nao deixou ler, montar ou transmitir.
///
/// Os erros dos leitores ja carregam so nome de campo e codigo curto, nunca endereco,
/// valor ou texto de provedor. Mesmo assim nada deles chega a tela: cada caso vira uma
/// frase fixa, em portugues, sem travessao. Erro que o motor ja traduziu passa direto,
/// e cancelamento continua cancelamento.
enum NetworkFailureText {
    static let offline = "Não foi possível falar com a rede agora. Confira a conexão e tente de novo."
    static let busy = "Os provedores da rede pediram uma pausa. Tente de novo em um minuto."
    static let fewSources = "Menos provedores responderam do que a carteira exige para seguir com segurança. Nada foi montado. Tente de novo em instantes."
    static let disagree = "Os provedores da rede deram respostas diferentes. Por segurança, nada foi montado. Tente de novo em instantes."
    static let malformed = "Um provedor da rede respondeu fora do esperado. Por segurança, nada foi montado."
    static let inconsistent = "A transação assinada não confere com o que foi revisado. Nada foi transmitido."
    static let refused = "A rede recusou a transação. Nada foi debitado."
    static let wrongAccount = "Esta conta não serve para esta rede."
    static let scanLimit = "A busca pelos endereços desta carteira passou do limite. Nada foi montado."
    static let xrplAccountMissing = "Esta conta ainda não existe no XRP Ledger. Ela passa a existir quando receber o primeiro XRP."

    /// O erro que sai do motor.
    static func error(_ error: Error) -> Error {
        if error is CancellationError || error is SendEngineError { return error }
        return SendEngineError.message(text(error))
    }

    static func text(_ error: Error) -> String {
        switch error {
        case let failure as HTTPClient.Failure: return text(failure)
        case let failure as ChainReaderError: return text(failure)
        case let failure as ReaderError: return text(failure)
        default: return malformed
        }
    }

    static func text(_ failure: HTTPClient.Failure) -> String {
        switch failure {
        case .status(429): return busy
        case .offline, .timeout, .status: return offline
        case .tooLarge, .redirectRefused, .invalidResponse, .decoding, .hostNotAllowed: return malformed
        }
    }

    static func text(_ failure: ChainReaderError) -> String {
        switch failure {
        case .malformedResponse, .mismatchedResponse: return malformed
        case .notEnoughSources: return fewSources
        case .providersDisagree: return disagree
        case .signedTransactionInconsistent: return inconsistent
        case .broadcastRejected: return refused
        case .unsupportedAccount: return wrongAccount
        case .invalidGapLimit, .tooManyAddresses: return scanLimit
        }
    }

    static func text(_ failure: ReaderError) -> String {
        switch failure {
        case .malformed, .providerError, .wrongNetwork, .implausibleValue, .responseMismatch, .executionReverted, .unsupported:
            return malformed
        case .notEnoughProviders: return fewSources
        case .providersDisagree: return disagree
        case .accountNotFound: return xrplAccountMissing
        case .broadcastMismatch: return inconsistent
        case .broadcastRejected(let reason, _): return text(reason)
        case .invalidInput: return "O endereço ou o identificador não vale para esta rede."
        }
    }

    static func text(_ rejection: BroadcastRejection) -> String {
        switch rejection {
        case .nonceTooLow: return "Outra transação desta conta entrou antes desta. Revise de novo."
        case .nonceTooHigh: return "A rede ainda não viu a transação anterior desta conta. Tente de novo em instantes."
        case .insufficientFunds: return "Saldo insuficiente na rede para esta transação. Nada foi debitado."
        case .underpriced: return "A taxa ficou abaixo do mínimo que a rede pede agora. Revise de novo."
        case .expired: return "O prazo da transação venceu antes de ela entrar na rede. Nada foi debitado. Revise de novo."
        case .invalidSignature: return "A rede não aceitou a assinatura. Nada foi debitado."
        case .wrongNetwork: return "A transação foi montada para outra rede. Nada foi transmitido."
        case .alreadyKnown, .other: return refused
        }
    }
}
