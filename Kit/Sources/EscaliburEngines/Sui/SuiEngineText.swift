import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Tudo que o motor da Sui diz ao dono.
///
/// Os erros saem sempre como `SendEngineError.message`, em portugues, sem travessao e
/// sem nada que venha de fora: nem texto de provedor, nem endereco, nem valor
/// (docs/seguranca.md §5.6). As notas da tela de valor podem trazer valores: sao a conta
/// do proprio dono, montada aqui.
enum SuiEngineText {
    // MARK: Erros

    static func userError(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is SendEngineError: return error
        case let error as SuiPlanError: return SendEngineError.message(planner(error))
        case ReaderError.unsupported: return SendEngineError.message(tooManyCoins)
        case ReaderError.executionReverted: return SendEngineError.message(simulationFailed)
        case ReaderError.providerError: return SendEngineError.message(simulationUnavailable)
        default: return NetworkFailureText.error(error)
        }
    }

    /// Erro depois de os bytes assinados terem saido: o gRPC-Web devolve o motivo da
    /// recusa so nos cabecalhos, que nao chegam aqui, entao nenhuma resposta garante que
    /// nada saiu. A tela manda conferir a Atividade antes de repetir.
    static func broadcastError(_ error: Error) -> SendEngineError {
        switch error {
        case ReaderError.broadcastMismatch: return .message(answerMismatch)
        default: return .message(broadcastUnconfirmed)
        }
    }

    static func planner(_ error: SuiPlanError) -> String {
        switch error {
        case .invalidPath, .keyMismatch:
            return keyMismatch
        case .invalidDestination(let problem):
            return address(problem)
        case .destinationIsSelf:
            return "O destino é a própria conta."
        case .destinationIsSystem:
            return systemAddress
        case .zeroAmount:
            return "Informe um valor maior que zero."
        case .amountTooLarge, .insufficientBalance, .noCoins:
            return insufficient
        case .duplicateCoin:
            return "A lista de moedas da conta veio repetida da rede. Por segurança, nada foi montado."
        case .gasPriceOutOfRange, .invalidEstimate, .feeAboveCeiling:
            return feeOutOfRange
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
            return "Este endereço é da rede \(chain.name). Para Sui, use um endereço Sui, que começa com 0x e tem 64 caracteres depois dele."
        case .badChecksum, .malformed, .unsupportedType:
            return "Endereço Sui inválido. Ele começa com 0x e tem 64 caracteres depois dele. Confira se copiou inteiro."
        }
    }

    static let insufficient = "Saldo de SUI insuficiente para este valor com a taxa da rede."
    static let systemAddress = "Este endereço é da própria rede Sui, não de uma carteira. O que é enviado para ele fica preso."
    static let feeOutOfRange = "A taxa informada pela rede está fora do normal. Nada foi montado. Tente de novo em instantes."
    static let simulationFailed = "A simulação do envio falhou na rede. Nada foi assinado. Confira o saldo e tente de novo."
    static let simulationUnavailable = "A rede Sui não simulou o envio agora. Nada foi montado. Tente de novo em instantes."
    static let tooManyCoins = "Esta conta tem moedas de SUI demais para a carteira juntar num envio. Nada foi montado."
    static let keyMismatch = "A chave desta conta não confere com o endereço. Nada foi montado."
    static let unsupportedAsset = "Por enquanto, a Escalibur envia só SUI na rede Sui."
    static let planMismatch = "O envio montado não confere com o destino pedido. Nada foi assinado."
    static let notOurTransaction = "A transação assinada não confere com a que foi montada. Nada foi transmitido."
    static let answerMismatch = "A resposta da rede não confere com a transação assinada. Confira a Atividade antes de enviar de novo."
    static let broadcastUnconfirmed = "Não foi possível confirmar a transmissão. Confira a Atividade antes de enviar de novo."
    static let historyFailure = "Não foi possível ler o histórico da Sui agora."

    // MARK: Acompanhamento

    static func confirmed(_ checkpoint: UInt64?) -> String {
        guard let checkpoint else { return "Confirmado na rede Sui, que já é final." }
        return "Incluída no checkpoint \(EngineFormat.grouped(checkpoint)), que já é final."
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

    static func feeNote(budget: UInt64) -> String {
        "Taxa máxima da rede: \(sui(budget)). O que não for usado volta para a conta."
    }

    static func addressBalanceNote(_ amount: UInt64) -> String {
        "\(sui(amount)) desta conta estão no saldo de endereço da Sui, que a Escalibur ainda não movimenta. O máximo conta só as moedas de SUI."
    }

    static func sui(_ mist: UInt64) -> String {
        EngineFormat.amount(BigUInt(mist), decimals: Chain.sui.nativeDecimals, symbol: "SUI")
    }
}
