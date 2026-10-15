import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Tudo que o motor Tron diz ao dono.
///
/// Os erros saem sempre como `SendEngineError.message`, em portugues, sem travessao e
/// sem nada que venha de fora: nem texto de provedor, nem endereco, nem valor
/// (docs/seguranca.md §5.6). As notas da tela de valor podem trazer valores: sao a
/// conta do proprio dono, montada aqui.
enum TronEngineText {
    // MARK: Erros

    /// Qualquer erro de leitura, planejamento ou conferencia, na frase da tela.
    static func userError(_ error: Error) -> SendEngineError {
        switch error {
        case let error as SendEngineError: return error
        case let error as TronPlanError: return .message(planner(error))
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

    static func planner(_ error: TronPlanError) -> String {
        switch error {
        case .invalidOwnerKey, .ownerKeyMismatch:
            return keyMismatch
        case .invalidBlockReference:
            return kitText("O bloco recebido da rede é inconsistente. Tente de novo em instantes.")
        case .parameterOutOfRange:
            return kitText("Os parâmetros de taxa recebidos da rede estão fora do normal. Tente de novo em instantes.")
        case .controlForOtherAccount:
            return kitText("A verificação de permissões não corresponde a esta conta. Tente de novo.")
        case .accountCompromised:
            return compromised
        case .ownerNotActivated:
            return ownerNotActivated
        case .invalidDestination(let problem):
            return address(problem)
        case .destinationIsOwner:
            return kitText("O destino é a própria conta.")
        case .destinationIsTokenContract:
            return kitText("O destino é o contrato do USDT. O que é enviado para ele fica preso para sempre.")
        case .destinationIsBurnAddress:
            return kitText("O destino é o endereço de queima da Tron. O que é enviado para ele se perde.")
        case .destinationIsContract:
            return kitText("O destino é um contrato. A rede Tron não aceita TRX enviado direto para contrato.")
        case .zeroAmount:
            return kitText("Informe um valor maior que zero.")
        case .amountTooLarge:
            return kitText("Valor acima do que a rede aceita.")
        case .memoTooLong:
            return kitText("O memo é longo demais para a rede Tron.")
        case .insufficientTRX:
            return insufficientTRX
        case .insufficientUSDT:
            return kitText("Saldo de USDT insuficiente para este valor.")
        case .noTRXForFees:
            return kitText("Para enviar USDT na Tron é preciso ter TRX: cada envio queima TRX para pagar a energia da rede. A Escalibur não paga essa taxa por você. Envie TRX para esta conta e tente de novo.")
        case .insufficientTRXForFees:
            return kitText("O TRX desta conta não cobre as taxas da rede deste envio. A Escalibur não paga essa taxa por você. Envie mais TRX para esta conta e tente de novo.")
        case .missingEnergyEstimate, .energyEstimateOutOfRange:
            return kitText("Não foi possível estimar a energia deste envio. Tente de novo em instantes.")
        case .feeLimitAboveCeiling:
            return kitText("A taxa máxima calculada passa do teto de segurança da carteira. Nada foi assinado.")
        case .deviceClockSkew:
            return error.message
        }
    }

    static func reader(_ error: ReaderError) -> String {
        switch error {
        case .providersDisagree:
            return kitText("Os provedores da rede Tron responderam diferente. Por segurança, nada foi montado. Tente de novo em instantes.")
        case .executionReverted:
            return kitText("O contrato do USDT recusaria este envio agora, e a energia seria queimada à toa. Confira o saldo de USDT e tente de novo.")
        case .invalidInput:
            return address(.malformed)
        case .broadcastRejected(let reason, _):
            return rejected(reason)
        case .broadcastMismatch:
            return answerMismatch
        case .malformed, .providerError, .notEnoughProviders, .wrongNetwork, .implausibleValue, .responseMismatch,
             .accountNotFound, .unsupported:
            return readFailure
        }
    }

    static func address(_ problem: Address.Problem) -> String {
        switch problem {
        case .empty:
            return kitText("Informe o endereço de destino.")
        case .otherNetwork(let chain):
            return kitText("Este endereço é da rede \(chain.name). Para Tron, use um endereço que começa com T.")
        case .badChecksum:
            return kitText("Uma letra deste endereço não confere. Ele pode ter sido copiado pela metade ou alterado. Copie de novo, inteiro.")
        case .malformed, .unsupportedType:
            return kitText("Endereço Tron inválido. Confira se ele começa com T e se foi copiado inteiro.")
        }
    }

    static func rejected(_ reason: BroadcastRejection) -> String {
        switch reason {
        case .insufficientFunds: return kitText("A rede Tron recusou o envio por saldo insuficiente. Nada saiu da conta.")
        case .expired: return kitText("O envio venceu antes de chegar à rede. Nada saiu da conta. Revise e envie de novo.")
        case .invalidSignature: return kitText("A rede Tron recusou a assinatura. Nada saiu da conta.")
        case .nonceTooLow, .nonceTooHigh, .alreadyKnown, .underpriced, .wrongNetwork, .other:
            return kitText("A rede Tron recusou o envio. Nada saiu da conta.")
        }
    }

    static let compromised = kitText("As permissões desta conta Tron foram alteradas: outra chave controla a conta ou divide o controle com a sua. A Escalibur não envia a partir dela. Não mande TRX para cá, porque quem tem a outra chave pode levar.")
    static let ownerNotActivated = kitText("Esta conta ainda não existe na rede Tron. Ela passa a existir quando recebe TRX.")
    static let usdtWithoutAccount = kitText("Esta conta ainda não existe na rede Tron: ela só recebeu USDT. Para enviar, ela precisa de TRX para pagar a energia da rede, e a Escalibur não paga essa taxa por você. Envie TRX para esta conta e tente de novo.")
    static let insufficientTRX = kitText("Saldo de TRX insuficiente para este valor com as taxas da rede.")
    static let keyMismatch = kitText("A chave desta conta não confere com o endereço. Nada foi montado.")
    static let unsupportedAsset = kitText("Por enquanto, a Escalibur envia só TRX e USDT na Tron.")
    static let planMismatch = kitText("O envio montado não confere com o destino ou o memo pedidos. Nada foi assinado.")
    static let notOurTransaction = kitText("A transação assinada não confere com a que foi montada. Nada foi transmitido.")
    static let answerMismatch = kitText("A resposta da rede não confere com a transação assinada. Confira a Atividade antes de enviar de novo.")
    static let broadcastUnconfirmed = kitText("Não foi possível confirmar a transmissão. Confira a Atividade antes de enviar de novo.")
    static let readFailure = kitText("Não foi possível ler a rede Tron agora. Tente de novo em instantes.")
    static let offline = kitText("Sem conexão com a internet. Nada foi montado.")
    static let historyFailure = kitText("Não foi possível ler o histórico da Tron agora.")

    // MARK: Acompanhamento

    static let confirmed = kitText("Confirmado na rede Tron. O bloco já é irreversível.")

    /// O motivo de uma falha final, pelo codigo da rede (`receipt.result` do java-tron)
    /// ou pelo vencimento.
    static func failure(_ code: String) -> String {
        switch code {
        case "expired":
            return kitText("O envio venceu sem entrar num bloco. Nada saiu da conta.")
        case "OUT_OF_ENERGY":
            return kitText("A energia acabou antes do fim da transferência. O USDT não saiu, e o TRX queimado na tentativa não volta.")
        default:
            return kitText("A rede Tron registrou o envio como falho. O valor não saiu, e o TRX queimado na tentativa não volta.")
        }
    }

    // MARK: Notas da tela de destino e de valor

    static func destinationNote(activated: Bool, isContract: Bool, activationFee: BigUInt) -> String? {
        if isContract {
            return kitText("O destino é um contrato, não uma carteira comum. A rede Tron não aceita TRX enviado direto para contrato.")
        }
        guard !activated else { return nil }
        return kitText("Esta conta ainda não existe na rede Tron. Um envio de TRX a ativa e queima até \(trx(activationFee)) da sua conta. USDT chega sem ativar a conta, e o dono dela vai precisar de TRX para movimentá-lo.")
    }

    static func trxFee(burn: BigUInt, activates: Bool, memo: Bool) -> String {
        guard !burn.isZero else { return kitText("A banda deste envio sai do stake ou da cota grátis da conta, sem queimar TRX.") }
        let parts = (activates ? [kitText("a ativação da conta de destino")] : []) + (memo ? [kitText("a taxa do memo")] : [])
        let joined = parts.count == 2 ? kitText("\(parts[0]) e \(parts[1])") : parts.first ?? ""
        let detail = parts.isEmpty ? "" : kitText(", com ") + joined
        return kitText("Custo da rede neste envio: \(trx(burn)) queimados da conta\(detail). O máximo já desconta.")
    }

    static func usdtFee(burn: BigUInt, trxBalance: BigUInt, memo: Bool) -> String {
        guard !burn.isZero else { return kitText("A energia e a banda deste envio saem do stake da conta, sem queimar TRX.") }
        let cost = memo
            ? kitText("Cada envio de USDT queima TRX para pagar energia e banda: cerca de \(trx(burn)) neste, com a taxa do memo.")
            : kitText("Cada envio de USDT queima TRX para pagar energia e banda: cerca de \(trx(burn)) neste.")
        guard trxBalance < burn else { return kitText("\(cost) A conta tem \(trx(trxBalance)).") }
        return kitText("\(cost) A conta tem \(trx(trxBalance)), menos que isso. Envie TRX para esta conta antes: a Escalibur não paga essa taxa por você.")
    }

    static let usdtWithoutAccountNote = kitText("Esta conta ainda não tem TRX. Para enviar USDT na Tron ela precisa de TRX para pagar a energia da rede, e a Escalibur não paga essa taxa por você.")

    // MARK: Numeros

    static func trx(_ sun: BigUInt) -> String { "\(units(sun, decimals: Chain.tron.nativeDecimals)) TRX" }

    /// Valor exato, no padrao da carteira: ponto no milhar, virgula decimal, sem zeros a
    /// direita e sem arredondar.
    static func units(_ value: BigUInt, decimals: Int) -> String {
        let digits = value.decimalString
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let cut = padded.index(padded.endIndex, offsetBy: -decimals)
        let whole = Array(padded[..<cut])
        var fraction = String(padded[cut...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let grouped = NumberStyle.current.group(String(whole))
        return NumberStyle.current.decimal(grouped, fraction)
    }
}
