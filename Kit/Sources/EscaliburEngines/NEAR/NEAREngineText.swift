import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Tudo que o motor da NEAR diz ao dono.
///
/// Os erros saem sempre como `SendEngineError.message`, em portugues, sem travessao e
/// sem nada que venha de fora: nem texto de provedor, nem conta, nem valor
/// (docs/seguranca.md §5.6). As notas podem trazer valores: sao a conta do proprio dono,
/// montada aqui.
enum NEAREngineText {
    // MARK: Erros

    static func userError(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is SendEngineError: return error
        case let error as NEARPlanError: return SendEngineError.message(planner(error))
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

    static func planner(_ error: NEARPlanError) -> String {
        switch error {
        case .invalidPath, .keyMismatch:
            return keyMismatch
        case .invalidDestination(let problem):
            return address(problem)
        case .destinationIsSelf:
            return "O destino é a própria conta."
        case .destinationMissing:
            return namedMissing
        case .zeroAmount:
            return "Informe um valor maior que zero."
        case .wrongNetwork:
            return wrongNetwork
        case .keyNotFullAccess:
            return keyNotOnAccount
        case .nonceNotReady:
            return "Esta conta acabou de mudar na rede. Tente de novo em alguns segundos."
        case .feeAboveCeiling, .missingGasPrice:
            return "A taxa calculada pela rede está fora do normal. Nada foi montado. Tente de novo em instantes."
        case .insufficientBalance:
            return insufficient
        case .amountTooLarge:
            return "Valor acima do que a rede NEAR aceita numa transferência."
        }
    }

    static func address(_ problem: Address.Problem) -> String {
        switch problem {
        case .empty:
            return "Informe a conta de destino."
        case .otherNetwork(let chain):
            return "Este endereço é da rede \(chain.name). Para NEAR, use uma conta NEAR: os 64 caracteres da conta implícita ou um nome como alice.near."
        case .unsupportedType:
            return "Este tipo de conta NEAR ainda não recebe envios pela Escalibur. Peça a conta implícita, de 64 caracteres, ou um nome como alice.near."
        case .badChecksum, .malformed:
            return "Conta NEAR inválida. Ela tem 64 caracteres de 0 a 9 e de a até f, ou é um nome como alice.near, só com letras minúsculas. Confira se copiou inteira."
        }
    }

    static func rejected(_ reason: BroadcastRejection) -> String {
        switch reason {
        case .expired: return "O envio venceu antes de chegar à rede. Nada saiu da conta. Revise e envie de novo."
        case .insufficientFunds: return "A rede NEAR recusou o envio por saldo insuficiente para o valor e a taxa. Nada saiu da conta."
        case .invalidSignature: return "A rede NEAR recusou a assinatura. Nada saiu da conta."
        case .nonceTooLow, .nonceTooHigh:
            return "Outra transação desta conta entrou antes. Nada saiu por esta. Confira a Atividade e envie de novo."
        case .alreadyKnown, .underpriced, .wrongNetwork, .other:
            return "A rede NEAR recusou o envio. Nada saiu da conta."
        }
    }

    static let insufficient = "Saldo de NEAR insuficiente para este valor com a reserva da taxa da rede."
    static let keyMismatch = "A chave desta conta não confere com a conta NEAR. Nada foi montado."
    static let unsupportedAsset = "Por enquanto, a Escalibur envia só NEAR na rede NEAR."
    static let wrongNetwork = "Um provedor respondeu de outra rede. Por segurança, nada foi montado. Tente de novo em instantes."
    static let namedMissing = "Esta conta não existe na rede NEAR, conferido em dois provedores. Confira o nome com quem vai receber. Nada foi montado."
    static let accountMissing = "Esta conta ainda não existe na rede NEAR. Ela passa a existir quando receber o primeiro NEAR."
    static let keyNotOnAccount = "A chave desta carteira não pode mover esta conta NEAR: ela foi removida da conta ou só chama contratos. Nada foi montado."
    static let planMismatch = "O envio montado não confere com o destino pedido. Nada foi assinado."
    static let notOurTransaction = "A transação assinada não confere com a que foi montada. Nada foi transmitido."
    static let answerMismatch = "A resposta da rede não confere com a transação assinada. Confira a Atividade antes de enviar de novo."
    static let broadcastUnconfirmed = "Não foi possível confirmar a transmissão. Confira a Atividade antes de enviar de novo."
    static let historyFailure = "Não foi possível ler o histórico da NEAR agora."

    // MARK: Acompanhamento

    static let confirmed = "Confirmado num bloco final da rede NEAR."

    static func failure(_ code: String) -> String {
        switch code {
        case "expired":
            return "O envio venceu sem entrar na rede. Nada saiu da conta."
        default:
            return "A transação entrou na rede, mas a transferência não saiu. O valor volta para a conta, e só a taxa da rede foi cobrada."
        }
    }

    // MARK: Notas da tela de destino e de valor

    static let newImplicit = "Esta conta ainda não tem registro na rede NEAR. O primeiro envio a cria, e a rede cobra a mais por conta nova, cerca de 0,007 NEAR hoje, junto da taxa. Confira que é uma conta NEAR, e não um endereço de outra rede sem o 0x."
    static let contractDestination = "Esta conta tem um contrato. Confira com quem vai receber se ela aceita NEAR enviado direto."

    /// A parte do saldo que o armazenamento da conta prende, quando prende. Conta de ate
    /// 770 bytes (a de uma chave so) nao prende nada.
    static func reserveNote(_ sender: NEARAccountState, rules: NEARProtocolRules) -> String? {
        let locked = sender.amount.subtractingReportingUnderflow(sender.liquid(storageAmountPerByte: rules.storageAmountPerByte)) ?? 0
        guard !locked.isZero else { return nil }
        return "\(near(locked)) ficam presos pelo armazenamento da conta na rede e ficam fora do máximo."
    }

    static func feeNote(_ cost: NEARTransferCost) -> String {
        "Taxa da rede: cerca de \(near(cost.expected)). O máximo deixa \(near(cost.reserved)) reservados para a taxa, e o que não for usado volta para a conta."
    }

    static func near(_ yocto: BigUInt) -> String {
        EngineFormat.amount(yocto, decimals: Chain.near.nativeDecimals, symbol: "NEAR")
    }
}
