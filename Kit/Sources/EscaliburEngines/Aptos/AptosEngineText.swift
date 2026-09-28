import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Tudo que o motor da Aptos diz ao dono.
///
/// Os erros saem sempre como `SendEngineError.message`, em portugues, sem travessao e sem
/// nada que venha de fora: nem texto de provedor, nem endereco, nem valor
/// (docs/seguranca.md §5.6). As notas da tela de valor podem trazer valores: sao a conta do
/// proprio dono, montada aqui.
enum AptosEngineText {
    // MARK: Erros

    static func userError(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is SendEngineError: return error
        case let error as AptosPlanError: return SendEngineError.message(planner(error))
        case ReaderError.executionReverted: return SendEngineError.message(simulationFailed)
        case ReaderError.wrongNetwork: return SendEngineError.message(wrongNetwork)
        default: return NetworkFailureText.error(error)
        }
    }

    /// Erro depois de os bytes assinados terem saido. Recusa explicita dos provedores (4xx)
    /// quase sempre quer dizer que nada saiu, mas o motivo nao chega aqui, e a mesma
    /// transacao pode ja ter entrado por outro caminho: a tela manda conferir a Atividade
    /// antes de repetir.
    static func broadcastError(_ error: Error) -> SendEngineError {
        switch error {
        case ReaderError.broadcastRejected: return .message(rejected)
        case ReaderError.broadcastMismatch: return .message(answerMismatch)
        default: return .message(broadcastUnconfirmed)
        }
    }

    static func planner(_ error: AptosPlanError) -> String {
        switch error {
        case .invalidPath, .keyMismatch:
            return keyMismatch
        case .authenticationKeyRotated:
            return "A chave desta conta foi trocada na rede Aptos, e a frase desta carteira não assina mais por ela. Nada foi montado."
        case .wrongNetwork:
            return wrongNetwork
        case .invalidDestination(let problem):
            return address(problem)
        case .destinationIsSelf:
            return "O destino é a própria conta."
        case .destinationIsSystem:
            return systemAddress
        case .zeroAmount:
            return "Informe um valor maior que zero."
        case .amountTooLarge, .insufficientBalance:
            return insufficient
        case .gasPriceOutOfRange, .invalidEstimate, .feeAboveCeiling:
            return feeOutOfRange
        case .clockSkew:
            return "O relógio deste iPhone está diferente da hora da rede Aptos. Ajuste a data e a hora automáticas e tente de novo."
        case .simulationMissing, .simulationFailed:
            return simulationFailed
        case .simulationMismatch:
            return "A simulação da rede não moveu exatamente o valor revisado. Nada foi assinado."
        }
    }

    static func address(_ problem: Address.Problem) -> String {
        switch problem {
        case .empty:
            return "Informe o endereço de destino."
        case .otherNetwork(let chain):
            return "Este endereço é da rede \(chain.name). Para Aptos, use um endereço Aptos, que começa com 0x e tem 64 caracteres depois dele."
        case .badChecksum, .malformed, .unsupportedType:
            return "Endereço Aptos inválido. Ele começa com 0x e tem 64 caracteres depois dele. Confira se copiou inteiro."
        }
    }

    static let insufficient = "Saldo de APT insuficiente para este valor com a taxa da rede."
    static let systemAddress = "Este endereço é da própria rede Aptos, não de uma carteira. O que é enviado para ele fica preso."
    static let feeOutOfRange = "A taxa informada pela rede está fora do normal. Nada foi montado. Tente de novo em instantes."
    static let simulationFailed = "A simulação do envio falhou na rede. Nada foi assinado. Confira o saldo e tente de novo."
    static let wrongNetwork = "Um provedor respondeu por outra rede que não a Aptos principal. Por segurança, nada foi montado."
    static let keyMismatch = "A chave desta conta não confere com o endereço. Nada foi montado."
    static let unsupportedAsset = "Por enquanto, a Escalibur envia só APT na rede Aptos."
    static let planMismatch = "O envio montado não confere com o destino pedido. Nada foi assinado."
    static let notOurTransaction = "A transação assinada não confere com a que foi montada. Nada foi transmitido."
    static let answerMismatch = "A resposta da rede não confere com a transação assinada. Confira a Atividade antes de enviar de novo."
    static let broadcastUnconfirmed = "Não foi possível confirmar a transmissão. Confira a Atividade antes de enviar de novo."
    static let rejected = "A rede Aptos recusou a transação. Confira a Atividade antes de enviar de novo."
    static let historyFailure = "Não foi possível ler o histórico da Aptos agora."
    static let newAccountNote = "Esta conta ainda não existe na Aptos. O envio de APT cria a conta, e a taxa inclui o armazenamento dela."

    // MARK: Acompanhamento

    static func confirmed(_ version: UInt64?) -> String {
        guard let version else { return "Confirmado na rede Aptos, que já é final." }
        return "Incluída na versão \(EngineFormat.grouped(version)) do ledger, que já é final."
    }

    static func failure(_ code: String) -> String {
        switch code {
        case "expired":
            return "O envio venceu sem entrar na rede. Nada saiu da conta."
        default:
            return "A transação entrou na rede e falhou. Só a taxa foi cobrada."
        }
    }

    // MARK: Notas da tela de valor

    static func feeNote(maximum: UInt64, createsAccount: Bool) -> String {
        let base = "Taxa máxima da rede: \(apt(maximum)). A rede cobra só o gas usado."
        return createsAccount ? base + " Este envio também cria a conta de destino." : base
    }

    static func apt(_ octas: UInt64) -> String {
        EngineFormat.amount(BigUInt(octas), decimals: Chain.aptos.nativeDecimals, symbol: "APT")
    }
}
