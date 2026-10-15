import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Tudo que o motor da Polkadot diz ao dono.
///
/// Os erros saem sempre como `SendEngineError.message`, em portugues, sem travessao e
/// sem nada que venha de fora: nem texto de provedor, nem endereco, nem valor
/// (docs/seguranca.md §5.6). As notas e os erros de valor podem trazer valores: sao a
/// conta do proprio dono, montada aqui.
enum PolkadotEngineText {
    // MARK: Erros

    static func userError(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is SendEngineError: return error
        case let error as PolkadotPlanError: return SendEngineError.message(planner(error))
        case ReaderError.wrongNetwork: return SendEngineError.message(wrongNetwork)
        default: return NetworkFailureText.error(error)
        }
    }

    /// Erro depois de os bytes assinados terem saido: so a recusa explicita dos nos
    /// garante que nada saiu. O resto manda conferir a Atividade antes de repetir.
    static func broadcastError(_ error: Error) -> SendEngineError {
        switch error {
        case ReaderError.broadcastMismatch: return .message(answerMismatch)
        case ReaderError.broadcastRejected(let reason, _): return .message(rejected(reason))
        default: return .message(broadcastUnconfirmed)
        }
    }

    static func planner(_ error: PolkadotPlanError) -> String {
        switch error {
        case .invalidPath, .keyMismatch:
            return keyMismatch
        case .invalidDestination(let problem):
            return address(problem, text: nil)
        case .destinationIsSelf:
            return kitText("O destino é a própria conta.")
        case .zeroAmount:
            return kitText("Informe um valor maior que zero.")
        case .wrongNetwork:
            return wrongNetwork
        case .runtimeChanged:
            return runtimeChanged
        case .missingFee, .feeAboveCeiling:
            return kitText("A taxa informada pela rede está fora do normal. Nada foi montado. Tente de novo em instantes.")
        case .insufficientBalance:
            return insufficient
        case .belowExistentialDeposit(let minimum):
            return kitText("A conta de destino está vazia na rede Polkadot, e a rede só a cria com pelo menos \(dot(minimum)). Envie esse valor ou mais.")
        case .nonceOverflow:
            return kitText("Esta conta chegou ao limite de transações da rede. Nada foi montado.")
        }
    }

    /// `text`, quando veio, e o digitado: um SS58 valido de outra rede do ecossistema
    /// ganha a frase propria.
    static func address(_ problem: Address.Problem, text: String?) -> String {
        switch problem {
        case .empty:
            return kitText("Informe o endereço de destino.")
        case .otherNetwork(let chain):
            return kitText("Este endereço é da rede \(chain.name). Para Polkadot, use um endereço Polkadot, que começa com 1.")
        case .badChecksum:
            return kitText("Uma letra deste endereço não confere. Ele pode ter sido copiado pela metade ou alterado. Copie de novo, inteiro.")
        case .unsupportedType, .malformed:
            if let text, let prefix = PolkadotAddress.foreignPrefix(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let network = prefix == PolkadotAddress.kusamaPrefix ? kitText("da Kusama") : prefix == 42 ? kitText("no formato genérico do Substrate") : kitText("de outra rede do ecossistema Polkadot")
                return kitText("Este endereço é \(network), não da Polkadot. Peça o endereço no formato Polkadot, que começa com 1.")
            }
            return kitText("Endereço Polkadot inválido. Ele começa com 1. Confira se copiou inteiro.")
        }
    }

    static func rejected(_ reason: BroadcastRejection) -> String {
        switch reason {
        case .expired: return kitText("O envio venceu antes de chegar à rede. Nada saiu da conta. Revise e envie de novo.")
        case .insufficientFunds: return kitText("A rede Polkadot recusou o envio por saldo insuficiente para a taxa. Nada saiu da conta.")
        case .invalidSignature: return kitText("A rede Polkadot recusou a assinatura. Nada saiu da conta.")
        case .nonceTooLow, .nonceTooHigh:
            return kitText("Outra transação desta conta entrou antes. Nada saiu por esta. Confira a Atividade e envie de novo.")
        case .alreadyKnown, .underpriced, .wrongNetwork, .other:
            return kitText("A rede Polkadot recusou o envio. Nada saiu da conta.")
        }
    }

    static let insufficient = kitText("Saldo de DOT insuficiente para este valor com a taxa da rede e o mínimo que a conta precisa manter.")
    static let keyMismatch = kitText("A chave desta conta não confere com o endereço. Nada foi montado.")
    static let unsupportedAsset = kitText("Por enquanto, a Escalibur envia só DOT na rede Polkadot.")
    static let wrongNetwork = kitText("Um provedor respondeu de outra rede. Por segurança, nada foi montado. Tente de novo em instantes.")
    static let runtimeChanged = kitText("A rede Polkadot mudou o formato das transações numa atualização. A Escalibur volta a enviar DOT depois de conferir o novo formato, numa atualização do app. O saldo não é afetado.")
    static let notDecoded = kitText("A rede Polkadot não reconheceu o formato desta transação, talvez por uma atualização que o app ainda não conhece. Nada foi montado.")
    static let planMismatch = kitText("O envio montado não confere com o destino pedido. Nada foi assinado.")
    static let notOurTransaction = kitText("A transação assinada não confere com a que foi montada. Nada foi transmitido.")
    static let answerMismatch = kitText("A resposta da rede não confere com a transação assinada. Confira a Atividade antes de enviar de novo.")
    static let broadcastUnconfirmed = kitText("Não foi possível confirmar a transmissão. Confira a Atividade antes de enviar de novo.")
    static let historyFailure = kitText("Não foi possível ler o histórico da Polkadot agora.")

    // MARK: Acompanhamento

    static let confirmed = kitText("Confirmado num bloco finalizado da rede Polkadot.")

    static func failure(_ code: String) -> String {
        switch code {
        case "expired":
            return kitText("O envio venceu sem entrar na rede. Nada saiu da conta.")
        default:
            return kitText("A transação entrou na rede, mas a transferência não saiu. Só a taxa da rede foi cobrada.")
        }
    }

    // MARK: Notas da tela de destino e de valor

    static var emptyDestination: String {
        kitText("Esta conta ainda está vazia na rede Polkadot. O primeiro envio para ela precisa ser de pelo menos \(dot(PolkadotRuntime.existentialDeposit)).")
    }

    static func reserveNote(_ sender: PolkadotAccountInfo) -> String {
        let base = kitText("\(dot(PolkadotRuntime.existentialDeposit)) fica na conta: é o mínimo que a rede exige para ela existir.")
        let locked = sender.frozen.subtractingReportingUnderflow(sender.reserved) ?? 0
        guard locked > PolkadotRuntime.existentialDeposit else { return base }
        return kitText("\(dot(locked)) desta conta estão congelados na rede (stake, voto ou vesting) e ficam fora do máximo.")
    }

    static func feeNote(_ fee: BigUInt) -> String {
        kitText("Taxa da rede: cerca de \(dot(fee)). O máximo deixa uma folga para a taxa variar até o envio entrar num bloco.")
    }

    static func dot(_ planck: BigUInt) -> String {
        EngineFormat.amount(planck, decimals: Chain.polkadot.nativeDecimals, symbol: "DOT")
    }
}
