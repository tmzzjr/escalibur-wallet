import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Tudo que o motor TON diz ao dono.
///
/// Os erros saem sempre como `SendEngineError.message`, em portugues, sem travessao e
/// sem nada que venha de fora: nem texto de provedor, nem endereco, nem valor
/// (docs/seguranca.md §5.6). As notas da tela de valor podem trazer valores: sao a
/// conta do proprio dono, montada aqui.
enum TONEngineText {
    // MARK: Erros

    /// Qualquer erro de leitura, planejamento ou conferencia, na frase da tela. `coin`
    /// separa o saldo de TON que falta para o valor do que falta para a taxa do USDT.
    static func userError(_ error: Error, coin: TONSendEngine.Coin? = nil) -> SendEngineError {
        switch error {
        case let error as SendEngineError: return error
        case let error as TONPlanError: return .message(planner(error, coin: coin))
        case let error as ReaderError: return .message(reader(error))
        case HTTPClient.Failure.offline: return .message(offline)
        default: return .message(readFailure)
        }
    }

    /// Erro depois de os bytes assinados terem saido para a rede: so a recusa explicita
    /// de todos os provedores garante que nada saiu. O resto manda conferir a Atividade
    /// antes de repetir.
    static func broadcastError(_ error: Error) -> SendEngineError {
        switch error {
        case ReaderError.broadcastRejected(let reason, _): return .message(rejected(reason))
        case ReaderError.broadcastMismatch: return .message(answerMismatch)
        default: return .message(broadcastUnconfirmed)
        }
    }

    static func planner(_ error: TONPlanError, coin: TONSendEngine.Coin?) -> String {
        switch error {
        case .invalidDestination(let problem):
            return address(problem)
        case .destinationIsSelf:
            return "O destino é a própria conta."
        case .destinationIsTokenContract:
            return tokenContract
        case .destinationFrozen:
            return "A conta de destino está congelada na rede TON e não recebe envios."
        case .zeroAmount:
            return "Informe um valor maior que zero."
        case .insufficientBalance:
            return coin == .usdt ? usdtNeedsTON : insufficientTON
        case .insufficientTokenBalance:
            return "Saldo de USDT insuficiente para este valor."
        case .missingFee, .feeAboveCeiling:
            return feeOutOfRange
        case .accountFrozen:
            return "Esta conta TON está congelada na rede por falta de pagamento de armazenamento e não consegue enviar agora."
        case .inconsistentState:
            return "O estado da conta recebido da rede é inconsistente. Tente de novo em instantes."
        case .walletVersionMismatch:
            return "O contrato desta carteira na rede não é da versão esperada. Nada foi montado."
        case .jettonWalletMismatch:
            return "A carteira de USDT informada pela rede não é a desta conta. Nada foi montado."
        case .commentTooLong:
            return "O comentário é longo demais para a mensagem."
        case .commentHasControlCharacters:
            return "O comentário tem caracteres invisíveis ou de controle. Digite de novo, só com texto comum."
        case .commentHasSurroundingSpaces:
            return "O comentário tem espaço no começo ou no fim. Tire os espaços: a exchange compara o comentário exatamente."
        case .invalidPath:
            return keyMismatch
        }
    }

    static func reader(_ error: ReaderError) -> String {
        switch error {
        case .providersDisagree:
            return "Os provedores da rede TON responderam diferente. Por segurança, nada foi montado. Tente de novo em instantes."
        case .implausibleValue:
            return feeOutOfRange
        case .invalidInput:
            return "O destino ou o comentário não puderam ser montados na mensagem. Confira os dois."
        case .broadcastRejected(let reason, _):
            return rejected(reason)
        case .broadcastMismatch:
            return answerMismatch
        case .malformed, .providerError, .notEnoughProviders, .wrongNetwork, .responseMismatch, .accountNotFound,
             .executionReverted, .unsupported:
            return readFailure
        }
    }

    static func address(_ problem: Address.Problem) -> String {
        switch problem {
        case .empty:
            return "Informe o endereço de destino."
        case .otherNetwork(let chain):
            return "Este endereço é da rede \(chain.name). Para TON, use um endereço TON."
        case .badChecksum:
            return "Uma letra deste endereço não confere. Ele pode ter sido copiado pela metade ou alterado. Copie de novo, inteiro."
        case .unsupportedType:
            return "Este endereço TON é de rede de teste ou de um tipo que a carteira não envia."
        case .malformed:
            return "Endereço TON inválido. Confira se copiou inteiro."
        }
    }

    static func rejected(_ reason: BroadcastRejection) -> String {
        switch reason {
        case .expired: return "O envio venceu antes de chegar à rede. Nada saiu da conta. Revise e envie de novo."
        case .insufficientFunds: return "A rede TON recusou o envio por saldo insuficiente. Nada saiu da conta."
        case .invalidSignature: return "A rede TON recusou a assinatura. Nada saiu da conta."
        case .nonceTooLow, .nonceTooHigh, .alreadyKnown, .underpriced, .wrongNetwork, .other:
            return "A rede TON recusou o envio. Nada saiu da conta."
        }
    }

    static let insufficientTON = "Saldo de TON insuficiente para este valor com a taxa da rede."
    static let usdtNeedsTON = "Esta conta não tem TON suficiente para a taxa deste envio de USDT. Envie TON para esta conta e tente de novo."
    static let tokenContract = "Este endereço é um contrato de token, não uma carteira. O que é enviado para ele fica preso."
    static let feeOutOfRange = "A taxa estimada pela rede está fora do normal. Nada foi montado. Tente de novo em instantes."
    static let keyMismatch = "A chave desta conta não confere com o endereço. Nada foi montado."
    static let unsupportedAsset = "Por enquanto, a Escalibur envia só TON e USDT na TON."
    static let planMismatch = "O envio montado não confere com o destino ou o comentário pedidos. Nada foi assinado."
    static let notOurTransaction = "A mensagem assinada não confere com a que foi montada. Nada foi transmitido."
    static let answerMismatch = "A resposta da rede não confere com a mensagem assinada. Confira a Atividade antes de enviar de novo."
    static let broadcastUnconfirmed = "Não foi possível confirmar a transmissão. Confira a Atividade antes de enviar de novo."
    static let readFailure = "Não foi possível ler a rede TON agora. Tente de novo em instantes."
    static let offline = "Sem conexão com a internet. Nada foi montado."
    static let historyFailure = "Não foi possível ler o histórico da TON agora."

    // MARK: Acompanhamento

    static let confirmed = "Confirmado na rede TON."

    /// O motivo de uma falha final, pelo que o leitor devolve.
    static func failure(_ code: String) -> String {
        switch code {
        case "expired":
            return "O envio venceu sem entrar na rede. Nada saiu da conta."
        default:
            return "A carteira processou o pedido, mas a transferência não saiu. Só a taxa da rede foi cobrada."
        }
    }

    // MARK: Notas da tela de destino e de valor

    static func destinationNote(status: TONAccountStatus, tokenContract: Bool) -> String? {
        if tokenContract { return Self.tokenContract }
        switch status {
        case .frozen: return "Esta conta TON está congelada na rede e não recebe envios."
        case .uninitialized: return "Esta carteira TON ainda não foi ativada. O valor chega e fica nela, sem devolução automática."
        case .active: return nil
        }
    }

    static func tonFee(_ fee: BigUInt, activatesWallet: Bool) -> String {
        "Taxa estimada da rede: \(ton(fee))\(activatesWallet ? ", com a ativação da sua carteira" : "")."
    }

    static func margin(_ margin: BigUInt) -> String {
        "O máximo deixa \(ton(margin)) na conta como folga: a taxa cobrada de verdade pode passar um pouco da estimativa."
    }

    static func usdtFee(attached: BigUInt, fee: BigUInt, balance: BigUInt) -> String {
        let cost = "Cada envio de USDT leva \(ton(attached)) para a rede, e o que sobra volta, mais a taxa de cerca de \(ton(fee))."
        guard balance < attached + fee else { return cost }
        return "\(cost) A conta tem \(ton(balance)), menos que isso. Envie TON para esta conta antes."
    }

    // MARK: Numeros

    static func ton(_ nanoton: BigUInt) -> String { "\(units(nanoton, decimals: Chain.ton.nativeDecimals)) TON" }

    /// Valor exato, no padrao da carteira: ponto no milhar, virgula decimal, sem zeros a
    /// direita e sem arredondar.
    static func units(_ value: BigUInt, decimals: Int) -> String {
        let digits = value.decimalString
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let cut = padded.index(padded.endIndex, offsetBy: -decimals)
        let whole = Array(padded[..<cut])
        var fraction = String(padded[cut...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        var grouped = ""
        for (index, digit) in whole.enumerated() {
            if index > 0, (whole.count - index) % 3 == 0 { grouped.append(".") }
            grouped.append(digit)
        }
        return fraction.isEmpty ? grouped : "\(grouped),\(fraction)"
    }
}
