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
            return flow == .swap ? swapSimulationFailed : "A simulação da rede diz que este envio falharia agora. Nada foi montado."
        case is ConsensusFailure:
            return "Os provedores da rede Solana não concordaram sobre os dados da transação. Nada foi montado. Tente de novo em instantes."
        case is SolanaInconsistentResponse:
            return "A rede Solana respondeu dados que não fecham. Tente de novo em instantes."
        case is SolanaSwapProposalError, is JupiterRouteError:
            return routeRefused
        case let failure as HTTPClient.Failure: return text(failure)
        case is SolanaRPCError:
            return "A rede Solana recusou a consulta. Tente de novo em instantes."
        default:
            return "Não foi possível falar com a rede Solana agora. Tente de novo."
        }
    }

    // MARK: Recusas dos motores

    static func text(_ problem: SolanaEngineProblem) -> String {
        switch problem {
        case .wrongChain: return "Este motor só atende a rede Solana."
        case .accountMismatch: return "A conta Solana desta carteira não confere com a chave guardada. Nada foi montado."
        case .assetNotSupported: return "Este ativo não é enviado nem trocado por esta carteira na Solana."
        case .tokenNotVerified: return "Os dados deste token na rede não conferem com a lista da carteira. Nada foi montado."
        case .invalidDestination: return "Este não é um endereço Solana válido. Confira se copiou inteiro."
        case .tagNotSupported: return "A rede Solana não usa tag nem memo de destino. Envie sem tag."
        case .destinationIsTokenAccount: return tokenAccountDestination
        case .destinationIsMint: return mintDestination
        case .destinationIsProgram: return programDestination
        case .planMismatch: return "O plano montado não confere com o pedido. Nada foi assinado."
        case .quoteMismatch: return "A cotação não confere com a troca pedida. Cote de novo."
        case .quoteExpired: return "A cotação venceu. Atualize o preço e tente de novo."
        case .slippageOutOfRange: return "A tolerância de preço passa do máximo que a carteira aceita na Solana. Escolha uma menor."
        case .amountOutOfRange: return "Valor fora do que uma transação da Solana aceita."
        case .priceImpactTooHigh: return "Esta troca perderia demais para o impacto no preço. Diminua o valor."
        case .nothingToSpend: return "Não há SOL suficiente para este envio depois da taxa da rede e da reserva mínima da conta."
        case .limitOrdersUnavailable: return "Ordem limite na Solana ainda não está disponível nesta versão."
        case .signedMismatch: return "A transação assinada não confere com o plano. Nada foi enviado."
        }
    }

    // MARK: Planejador de envio

    static func text(_ problem: SolanaPlanError, _ flow: Flow) -> String {
        switch problem {
        case .signerPathNotHardened:
            return "A conta Solana desta carteira usa um caminho de derivação que a rede não aceita. Nada foi montado."
        case .invalidDestination:
            return "Este não é um endereço Solana válido. Confira se copiou inteiro."
        case .destinationIsOwner:
            return "O destino é a própria carteira de origem."
        case .zeroAmount:
            return "Digite um valor maior que zero."
        case .amountTooLarge:
            return "Valor fora do que uma transação da Solana aceita."
        case .staleNetworkState, .blockhashExpiring:
            return "Os dados da rede venceram antes de o plano ficar pronto. Tente de novo."
        case .invalidComputeUnitLimit:
            return "A simulação da rede devolveu um consumo fora do normal. Tente de novo em instantes."
        case .insufficientFunds:
            switch flow {
            case .sendToken: return "Falta SOL para pagar a taxa da rede deste envio de token."
            case .swap: return "Saldo de SOL insuficiente para a troca e a taxa da rede."
            default: return "Saldo de SOL insuficiente para o valor e a taxa da rede."
            }
        case .leavesBalanceBelowRent:
            return flow == .sendToken
                ? "Depois da taxa, sobraria na conta menos SOL que a reserva mínima da rede. Deposite um pouco de SOL antes."
                : "Sobraria na conta menos SOL que a reserva mínima da rede. Use o Máx ou diminua o valor."
        case .belowRentExemptMinimum:
            return "Esta conta ainda não existe na Solana. O primeiro envio precisa cobrir a reserva mínima que a rede exige."
        case .destinationIsTokenAccount:
            return tokenAccountDestination
        case .destinationOwnedByProgram:
            return programDestination
        case .destinationIsKnownProgram:
            return "Este endereço é de um programa da rede, não de uma carteira. O valor ficaria preso."
        case .destinationIsMint:
            return mintDestination
        case .destinationOffCurve:
            return "Este endereço é de uma conta de programa, não de uma carteira comum. Esta versão não envia tokens para contas assim."
        case .tokenAccountMismatch:
            return "A conta de token lida da rede não confere. Nada foi montado."
        case .tokenAccountFrozen:
            return "A conta de token está congelada pelo emissor. A transferência não passaria."
        case .insufficientTokenBalance:
            return "Saldo do token insuficiente para este valor."
        case .permanentDelegate, .transferHook, .defaultAccountStateFrozen, .unknownMintExtension:
            return issuerRules
        case .nonTransferable:
            return "Este token não pode ser transferido."
        case .tokenPaused:
            return "O emissor pausou este token. A transferência não passaria."
        case .transactionTooLarge:
            return "A transação ficou grande demais para a rede Solana."
        case .verificationFailed:
            return "A transação montada não passou na conferência da carteira. Nada foi assinado."
        }
    }

    // MARK: Planejador de troca

    static func text(_ problem: SolanaSwapError) -> String {
        switch problem {
        case .plan(let inner):
            return text(inner, .swap)
        case .sameAsset:
            return "Escolha dois ativos diferentes para trocar."
        case .zeroAmount:
            return "Digite um valor maior que zero."
        case .amountTooLarge:
            return "Valor fora do que uma transação da Solana aceita."
        case .invalidAsset:
            return "Este ativo não é trocado por esta carteira na Solana."
        case .slippageTooHigh:
            return "A tolerância de preço passa do máximo que a carteira aceita na Solana. Escolha uma menor."
        case .minimumBelowShown:
            return "O preço mudou desde a cotação e o mínimo garantido ficou abaixo do mostrado. Confira o novo preço e tente de novo."
        case .proposalMismatch, .route, .authorityNotOwner, .sourceNotOwnerAccount, .destinationNotOwnerAccount, .routeMintMismatch,
             .routeTokenProgramMismatch, .inAmountMismatch, .quotedOutMismatch, .slippageMismatch, .minimumMismatch, .zeroMinimum,
             .platformFee, .positiveSlippageFee, .unexpectedComputeBudgetInstruction, .unexpectedSetupInstruction,
             .unexpectedCleanupInstruction, .otherInstructions, .tipInstruction, .missingLookupTable, .compiledRouteChanged:
            return routeRefused
        case .boughtMintPermanentDelegate, .boughtMintTransferHook, .unknownMintExtension, .boughtMintDefaultFrozen:
            return issuerRules
        case .mintNonTransferable:
            return "Este token não pode ser transferido."
        case .mintPaused:
            return "O emissor pausou este token. A troca não passaria."
        case .sourceAccountMismatch, .destinationAccountMismatch:
            return "A conta de token lida da rede não confere. Nada foi montado."
        case .sourceAccountFrozen, .destinationAccountFrozen:
            return "A conta de token está congelada pelo emissor. A troca não passaria."
        case .insufficientTokenBalance:
            return "Saldo insuficiente do ativo vendido."
        case .insufficientFunds:
            return "Saldo de SOL insuficiente para a troca e a taxa da rede."
        case .leavesBalanceBelowRent:
            return "A troca deixaria na conta menos SOL que a reserva mínima da rede. Diminua o valor."
        case .simulationFailed, .simulationMissingAccount, .simulationWrongAccount, .simulationSpentTooMuch,
             .simulationReceivedTooLittle, .simulationNoComputeUnits:
            return swapSimulationFailed
        case .simulationTouchedOtherAccount:
            return "A simulação mostrou outra conta de token sua perdendo saldo. Troca bloqueada. Nada foi assinado."
        case .noPriceReference:
            return "Sem preço de referência do mercado agora, esta troca fica bloqueada: a cotação da Jupiter não tem com o que ser comparada. Tente de novo em instantes."
        case .priceFarFromReference(let deviation):
            return MarketReference.farText(deviationBps: deviation)
        }
    }

    // MARK: Leitura de contas

    static func text(_ problem: SolanaAccountParseError, _ flow: Flow) -> String {
        switch problem {
        case .notATokenAccount:
            return flow == .swap ? "Esta carteira não tem saldo do ativo vendido." : "Esta carteira não tem conta deste token na Solana."
        case .notAMint:
            return "O token não foi reconhecido na rede Solana."
        case .tokenAccountMismatch:
            return "A conta de token lida da rede não confere. Nada foi montado."
        case .notALookupTable, .lookupTableDeactivated:
            return routeRefused
        case .malformed:
            return "A rede Solana respondeu num formato inesperado. Tente de novo."
        }
    }

    // MARK: Transmissao

    static func text(_ problem: SolanaBroadcastError) -> String {
        switch problem {
        case .wrongChain, .malformedTransaction:
            return "A transação assinada não confere. Nada foi enviado."
        case .preflightFailed:
            return "A rede simulou a transação e recusou: ela falharia agora. Nada foi debitado."
        case .rejected:
            return "Nenhum provedor aceitou a transação. Nada foi debitado. Tente de novo."
        }
    }

    static func text(_ failure: HTTPClient.Failure) -> String {
        switch failure {
        case .offline: return "Sem conexão com a internet."
        case .timeout: return "A rede Solana demorou a responder. Tente de novo."
        case .status(429): return "Muitas consultas seguidas. Espere alguns segundos e tente de novo."
        default: return "Não foi possível falar com a rede Solana agora. Tente de novo."
        }
    }

    // MARK: Textos repetidos

    static let tokenAccountDestination =
        "Este endereço é uma conta de token, não uma carteira. Peça o endereço da carteira de quem vai receber."
    static let mintDestination = "Este endereço é o do próprio token, não de uma carteira. O valor ficaria preso."
    static let programDestination = "Este endereço é uma conta de programa, não uma carteira. O valor poderia ficar preso."
    static let issuerRules = "Este token tem regras do emissor que esta carteira não aceita."
    static let routeRefused = "A rota proposta pela Jupiter não passou na conferência da carteira. Nada foi assinado."
    static let swapSimulationFailed = "A simulação da troca não confirmou o resultado esperado. Nada foi assinado. Tente de novo em instantes."
}
