import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A traducao de toda falha da Solana para o texto que a tela mostra.
///
/// Regras (docs/seguranca.md §5.4 e §5.6): portugues claro, sem travessao, e nada
/// que veio de fora. O texto do no, o endereco, o valor e o id da transacao nunca
/// entram na mensagem: um provedor malicioso nao escolhe o que o dono le, e a
/// mensagem pode ir para um relatorio sem carregar dado da conta.
enum SolanaEngineMessages {
    /// O que estava acontecendo quando a falha veio. Algumas recusas do planejador
    /// dizem coisas diferentes num envio de SOL, num envio de token e numa troca.
    enum Flow: Sendable {
        case destination
        case sendSOL
        case sendToken
        case swap
        case broadcast
        case history
    }

    /// A falha como `SendEngineError.message`, pronta para a tela. Cancelamento passa
    /// adiante como esta: nao e falha, e a tela que foi embora.
    static func map(_ error: Error, _ flow: Flow) -> Error {
        if error is CancellationError { return error }
        if let ready = error as? SendEngineError { return ready }
        return SendEngineError.message(text(error, flow))
    }

    static func text(_ error: Error, _ flow: Flow) -> String {
        switch error {
        case let problem as SolanaEngineProblem: return text(problem)
        case let problem as SolanaPlanError: return text(problem, flow)
        case let problem as SolanaSwapError: return text(problem)
        case let problem as SolanaAccountParseError: return text(problem, flow)
        case let problem as SolanaBroadcastError: return text(problem)
        case is SolanaSimulationFailure:
            return flow == .swap ? swapSimulationFailed : kitText("A simulação da rede diz que este envio falharia agora. Nada foi montado.")
        case is ConsensusFailure:
            return kitText("Os provedores da rede Solana não concordaram sobre os dados da transação. Nada foi montado. Tente de novo em instantes.")
        case is SolanaInconsistentResponse:
            return kitText("A rede Solana respondeu dados que não fecham. Tente de novo em instantes.")
        case is SolanaSwapProposalError, is JupiterRouteError:
            return routeRefused
        case let failure as HTTPClient.Failure: return text(failure)
        case is SolanaRPCError:
            return kitText("A rede Solana recusou a consulta. Tente de novo em instantes.")
        default:
            return kitText("Não foi possível falar com a rede Solana agora. Tente de novo.")
        }
    }

    // MARK: Recusas dos motores

    static func text(_ problem: SolanaEngineProblem) -> String {
        switch problem {
        case .wrongChain: return kitText("Este motor só atende a rede Solana.")
        case .accountMismatch: return kitText("A conta Solana desta carteira não confere com a chave guardada. Nada foi montado.")
        case .assetNotSupported: return kitText("Este ativo não é enviado nem trocado por esta carteira na Solana.")
        case .tokenNotVerified: return kitText("Os dados deste token na rede não conferem com a lista da carteira. Nada foi montado.")
        case .invalidDestination: return kitText("Este não é um endereço Solana válido. Confira se copiou inteiro.")
        case .tagNotSupported: return kitText("A rede Solana não usa tag nem memo de destino. Envie sem tag.")
        case .destinationIsTokenAccount: return tokenAccountDestination
        case .destinationIsMint: return mintDestination
        case .destinationIsProgram: return programDestination
        case .planMismatch: return kitText("O plano montado não confere com o pedido. Nada foi assinado.")
        case .quoteMismatch: return kitText("A cotação não confere com a troca pedida. Cote de novo.")
        case .quoteExpired: return kitText("A cotação venceu. Atualize o preço e tente de novo.")
        case .slippageOutOfRange: return kitText("A tolerância de preço passa do máximo que a carteira aceita na Solana. Escolha uma menor.")
        case .amountOutOfRange: return kitText("Valor fora do que uma transação da Solana aceita.")
        case .priceImpactTooHigh: return kitText("Esta troca perderia demais para o impacto no preço. Diminua o valor.")
        case .nothingToSpend: return kitText("Não há SOL suficiente para este envio depois da taxa da rede e da reserva mínima da conta.")
        case .limitOrdersUnavailable: return kitText("Ordem limite na Solana ainda não está disponível nesta versão.")
        case .signedMismatch: return kitText("A transação assinada não confere com o plano. Nada foi enviado.")
        }
    }

    // MARK: Planejador de envio

    static func text(_ problem: SolanaPlanError, _ flow: Flow) -> String {
        switch problem {
        case .signerPathNotHardened:
            return kitText("A conta Solana desta carteira usa um caminho de derivação que a rede não aceita. Nada foi montado.")
        case .invalidDestination:
            return kitText("Este não é um endereço Solana válido. Confira se copiou inteiro.")
        case .destinationIsOwner:
            return kitText("O destino é a própria carteira de origem.")
        case .zeroAmount:
            return kitText("Digite um valor maior que zero.")
        case .amountTooLarge:
            return kitText("Valor fora do que uma transação da Solana aceita.")
        case .staleNetworkState, .blockhashExpiring:
            return kitText("Os dados da rede venceram antes de o plano ficar pronto. Tente de novo.")
        case .invalidComputeUnitLimit:
            return kitText("A simulação da rede devolveu um consumo fora do normal. Tente de novo em instantes.")
        case .insufficientFunds:
            switch flow {
            case .sendToken: return kitText("Falta SOL para pagar a taxa da rede deste envio de token.")
            case .swap: return kitText("Saldo de SOL insuficiente para a troca e a taxa da rede.")
            default: return kitText("Saldo de SOL insuficiente para o valor e a taxa da rede.")
            }
        case .leavesBalanceBelowRent:
            return flow == .sendToken
                ? kitText("Depois da taxa, sobraria na conta menos SOL que a reserva mínima da rede. Deposite um pouco de SOL antes.")
                : kitText("Sobraria na conta menos SOL que a reserva mínima da rede. Use o Máx ou diminua o valor.")
        case .belowRentExemptMinimum:
            return kitText("Esta conta ainda não existe na Solana. O primeiro envio precisa cobrir a reserva mínima que a rede exige.")
        case .destinationIsTokenAccount:
            return tokenAccountDestination
        case .destinationOwnedByProgram:
            return programDestination
        case .destinationIsKnownProgram:
            return kitText("Este endereço é de um programa da rede, não de uma carteira. O valor ficaria preso.")
        case .destinationIsMint:
            return mintDestination
        case .destinationOffCurve:
            return kitText("Este endereço é de uma conta de programa, não de uma carteira comum. Esta versão não envia tokens para contas assim.")
        case .tokenAccountMismatch:
            return kitText("A conta de token lida da rede não confere. Nada foi montado.")
        case .tokenAccountFrozen:
            return kitText("A conta de token está congelada pelo emissor. A transferência não passaria.")
        case .insufficientTokenBalance:
            return kitText("Saldo do token insuficiente para este valor.")
        case .permanentDelegate, .transferHook, .defaultAccountStateFrozen, .unknownMintExtension:
            return issuerRules
        case .nonTransferable:
            return kitText("Este token não pode ser transferido.")
        case .tokenPaused:
            return kitText("O emissor pausou este token. A transferência não passaria.")
        case .transactionTooLarge:
            return kitText("A transação ficou grande demais para a rede Solana.")
        case .verificationFailed:
            return kitText("A transação montada não passou na conferência da carteira. Nada foi assinado.")
        }
    }

    // MARK: Planejador de troca

    static func text(_ problem: SolanaSwapError) -> String {
        switch problem {
        case .plan(let inner):
            return text(inner, .swap)
        case .sameAsset:
            return kitText("Escolha dois ativos diferentes para trocar.")
        case .zeroAmount:
            return kitText("Digite um valor maior que zero.")
        case .amountTooLarge:
            return kitText("Valor fora do que uma transação da Solana aceita.")
        case .invalidAsset:
            return kitText("Este ativo não é trocado por esta carteira na Solana.")
        case .slippageTooHigh:
            return kitText("A tolerância de preço passa do máximo que a carteira aceita na Solana. Escolha uma menor.")
        case .minimumBelowShown:
            return kitText("O preço mudou desde a cotação e o mínimo garantido ficou abaixo do mostrado. Confira o novo preço e tente de novo.")
        case .proposalMismatch, .route, .authorityNotOwner, .sourceNotOwnerAccount, .destinationNotOwnerAccount, .routeMintMismatch,
             .routeTokenProgramMismatch, .inAmountMismatch, .quotedOutMismatch, .slippageMismatch, .minimumMismatch, .zeroMinimum,
             .platformFee, .positiveSlippageFee, .unexpectedComputeBudgetInstruction, .unexpectedSetupInstruction,
             .unexpectedCleanupInstruction, .otherInstructions, .tipInstruction, .missingLookupTable, .compiledRouteChanged:
            return routeRefused
        case .boughtMintPermanentDelegate, .boughtMintTransferHook, .unknownMintExtension, .boughtMintDefaultFrozen:
            return issuerRules
        case .mintNonTransferable:
            return kitText("Este token não pode ser transferido.")
        case .mintPaused:
            return kitText("O emissor pausou este token. A troca não passaria.")
        case .sourceAccountMismatch, .destinationAccountMismatch:
            return kitText("A conta de token lida da rede não confere. Nada foi montado.")
        case .sourceAccountFrozen, .destinationAccountFrozen:
            return kitText("A conta de token está congelada pelo emissor. A troca não passaria.")
        case .insufficientTokenBalance:
            return kitText("Saldo insuficiente do ativo vendido.")
        case .insufficientFunds:
            return kitText("Saldo de SOL insuficiente para a troca e a taxa da rede.")
        case .leavesBalanceBelowRent:
            return kitText("A troca deixaria na conta menos SOL que a reserva mínima da rede. Diminua o valor.")
        case .simulationFailed, .simulationMissingAccount, .simulationWrongAccount, .simulationSpentTooMuch,
             .simulationReceivedTooLittle, .simulationNoComputeUnits, .simulationUnavailable:
            return swapSimulationFailed
        case .simulationTouchedOtherAccount:
            return kitText("A simulação mostrou outra conta de token sua perdendo saldo. Troca bloqueada. Nada foi assinado.")
        case .noPriceReference:
            return kitText("Sem preço de referência do mercado agora, esta troca fica bloqueada: a cotação da Jupiter não tem com o que ser comparada. Tente de novo em instantes.")
        case .priceFarFromReference(let deviation):
            return MarketReference.farText(deviationBps: deviation)
        }
    }

    // MARK: Leitura de contas

    static func text(_ problem: SolanaAccountParseError, _ flow: Flow) -> String {
        switch problem {
        case .notATokenAccount:
            return flow == .swap ? kitText("Esta carteira não tem saldo do ativo vendido.") : kitText("Esta carteira não tem conta deste token na Solana.")
        case .notAMint:
            return kitText("O token não foi reconhecido na rede Solana.")
        case .tokenAccountMismatch:
            return kitText("A conta de token lida da rede não confere. Nada foi montado.")
        case .ownerAssignedToProgram:
            return kitText("A conta da Solana desta carteira foi entregue a um programa, e o saldo dela não paga taxa nem pode sair. Só quem tem a senha da carteira faz isso: se não foi você, a senha vazou e esta carteira não é mais segura.")
        case .tokenAccountOwnerChanged:
            return kitText("A conta deste token na Solana foi passada para outro dono: alguém mudou o dono dela. O que entrasse nela iria para esse outro dono. Nada foi montado.")
        case .notALookupTable, .lookupTableDeactivated:
            return routeRefused
        case .malformed:
            return kitText("A rede Solana respondeu num formato inesperado. Tente de novo.")
        }
    }

    // MARK: Transmissao

    static func text(_ problem: SolanaBroadcastError) -> String {
        switch problem {
        case .wrongChain, .malformedTransaction:
            return kitText("A transação assinada não confere. Nada foi enviado.")
        case .preflightFailed:
            return kitText("A rede simulou a transação e recusou: ela falharia agora. Nada foi debitado.")
        case .rejected:
            return kitText("Nenhum provedor aceitou a transação. Nada foi debitado. Tente de novo.")
        }
    }

    static func text(_ failure: HTTPClient.Failure) -> String {
        switch failure {
        case .offline: return kitText("Sem conexão com a internet.")
        case .timeout: return kitText("A rede Solana demorou a responder. Tente de novo.")
        case .status(429): return kitText("Muitas consultas seguidas. Espere alguns segundos e tente de novo.")
        default: return kitText("Não foi possível falar com a rede Solana agora. Tente de novo.")
        }
    }

    // MARK: Textos repetidos

    static let tokenAccountDestination =
        kitText("Este endereço é uma conta de token, não uma carteira. Peça o endereço da carteira de quem vai receber.")
    static let mintDestination = kitText("Este endereço é o do próprio token, não de uma carteira. O valor ficaria preso.")
    static let programDestination = kitText("Este endereço é uma conta de programa, não uma carteira. O valor poderia ficar preso.")
    static let issuerRules = kitText("Este token tem regras do emissor que esta carteira não aceita.")
    static let routeRefused = kitText("A rota proposta pela Jupiter não passou na conferência da carteira. Nada foi assinado.")
    static let swapSimulationFailed = kitText("A simulação da troca não confirmou o resultado esperado. Nada foi assinado. Tente de novo em instantes.")
}
