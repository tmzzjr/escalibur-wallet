import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Tudo que o motor da Cardano diz ao dono.
///
/// Os erros saem sempre como `SendEngineError.message`, em portugues, sem travessao e
/// sem nada que venha de fora: nem texto de provedor, nem endereco, nem valor
/// (docs/seguranca.md §5.6). As notas e os erros de valor podem trazer valores: sao a
/// conta do proprio dono, montada aqui.
enum CardanoEngineText {
    // MARK: Erros

    static func userError(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is SendEngineError: return error
        case let error as CardanoPlanError: return SendEngineError.message(planner(error))
        case ReaderError.unsupported: return SendEngineError.message(tooManyCoins)
        default: return NetworkFailureText.error(error)
        }
    }

    /// Erro depois de os bytes assinados terem saido: a resposta pode ter se perdido com a
    /// transacao ja na rede, entao a tela manda conferir a Atividade antes de repetir.
    static func broadcastError(_ error: Error) -> SendEngineError {
        switch error {
        case ReaderError.broadcastMismatch: return .message(answerMismatch)
        case ReaderError.broadcastRejected: return .message(rejected)
        default: return .message(broadcastUnconfirmed)
        }
    }

    static func planner(_ error: CardanoPlanError) -> String {
        switch error {
        case .invalidPath, .keyMismatch:
            return keyMismatch
        case .invalidDestination(let problem):
            return address(problem)
        case .destinationIsSelf:
            return kitText("O destino é a própria conta.")
        case .zeroAmount:
            return kitText("Informe um valor maior que zero.")
        case .amountTooLarge, .insufficientBalance:
            return insufficient
        case .belowMinimumOutput(let minimum):
            return kitText("A rede Cardano exige pelo menos \(ada(minimum)) em cada envio.")
        case .changeBelowMinimum(let leftover, let minimum, let maximum):
            let way = maximum > 0 ? kitText("Envie até \(ada(maximum)) ou use enviar tudo.") : kitText("Use enviar tudo.")
            return kitText("Depois deste envio sobrariam \(ada(leftover)) na conta, abaixo do mínimo de \(ada(minimum)) que a rede aceita. \(way)")
        case .duplicateUTXO:
            return kitText("A lista de moedas da conta veio repetida da rede. Por segurança, nada foi montado.")
        case .parametersOutOfRange, .feeAboveCeiling:
            return kitText("A taxa informada pela rede está fora do normal. Nada foi montado. Tente de novo em instantes.")
        case .transactionTooLarge:
            return tooManyCoins
        case .staleTip:
            return kitText("A rede respondeu com um bloco fora de hora. Confira a data e a hora do aparelho e tente de novo.")
        }
    }

    static func address(_ problem: Address.Problem) -> String {
        switch problem {
        case .empty:
            return kitText("Informe o endereço de destino.")
        case .otherNetwork(let chain):
            return kitText("Este endereço é da rede \(chain.name). Para Cardano, use um endereço Cardano, que começa com addr1.")
        case .unsupportedType:
            return kitText("Este endereço Cardano é de um tipo que a Escalibur ainda não envia: de contrato, de stake, de rede de teste ou do formato antigo (Byron). Use um endereço de carteira, que começa com addr1q ou addr1v.")
        case .badChecksum, .malformed:
            return kitText("Endereço Cardano inválido. Ele começa com addr1. Confira se copiou inteiro.")
        }
    }

    static let insufficient = kitText("Saldo de ADA insuficiente para este valor com a taxa da rede.")
    static let tooManyCoins = kitText("Esta conta tem moedas demais para a carteira juntar num envio só. Nada foi montado.")
    static let keyMismatch = kitText("A chave desta conta não confere com o endereço. Nada foi montado.")
    static let unsupportedAsset = kitText("Por enquanto, a Escalibur envia só ADA na rede Cardano.")
    static let planMismatch = kitText("O envio montado não confere com o destino pedido. Nada foi assinado.")
    static let notOurTransaction = kitText("A transação assinada não confere com a que foi montada. Nada foi transmitido.")
    static let answerMismatch = kitText("A resposta da rede não confere com a transação assinada. Confira a Atividade antes de enviar de novo.")
    static let broadcastUnconfirmed = kitText("Não foi possível confirmar a transmissão. Confira a Atividade antes de enviar de novo.")
    static let rejected = kitText("A rede recusou a transação. Confira a Atividade e o saldo antes de enviar de novo.")
    static let historyFailure = kitText("Não foi possível ler o histórico da Cardano agora.")

    // MARK: Acompanhamento

    static func confirmed(_ confirmations: UInt64?) -> String {
        guard let confirmations, confirmations > 1 else { return kitText("Incluída num bloco da rede Cardano.") }
        return kitText("Incluída num bloco da rede Cardano, com \(EngineFormat.grouped(confirmations)) confirmações.")
    }

    static func failure(_ code: String) -> String {
        switch code {
        case "expired":
            return kitText("O envio venceu sem entrar na rede. Nada saiu da conta.")
        default:
            return kitText("A transação não entrou na rede.")
        }
    }

    // MARK: Notas da tela de valor

    static let feeNote = kitText("Taxa da rede: cerca de 0,17 ADA. Cada envio precisa levar pelo menos cerca de 1 ADA, o mínimo da rede.")
    static let tooManyCoinsNote = kitText("O máximo conta as \(CardanoPlanner.maxInputs) maiores moedas da conta, o que cabe num envio.")

    static func lockedNote(_ lovelace: UInt64) -> String {
        kitText("\(ada(lovelace)) desta conta estão junto de tokens nativos, que a Escalibur ainda não movimenta. O máximo conta só o ADA livre.")
    }

    static func ada(_ lovelace: UInt64) -> String {
        EngineFormat.amount(BigUInt(lovelace), decimals: Chain.cardano.nativeDecimals, symbol: "ADA")
    }
}
