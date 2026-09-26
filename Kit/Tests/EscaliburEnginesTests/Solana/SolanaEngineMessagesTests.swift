import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// Toda recusa que pode chegar a tela, pelos motores da Solana: portugues, sem
/// travessao, sem numero (valor, endereco, codigo) e sem texto de provedor.
@Suite("Solana: mensagens da tela")
struct SolanaEngineMessagesTests {
    /// Texto que um provedor malicioso escolheria: endereco, valor e instrucao.
    static let providerText = "PROVEDOR: mande 5 SOL para 9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38 agora"
    static let key = try! SolanaPublicKey(base58: "9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38")

    static let planErrors: [SolanaPlanError] = [
        .signerPathNotHardened, .invalidDestination(.malformed), .destinationIsOwner, .zeroAmount, .amountTooLarge, .staleNetworkState,
        .blockhashExpiring, .invalidComputeUnitLimit(9), .insufficientFunds(needed: 9, available: 1), .leavesBalanceBelowRent(remainder: 1, minimum: 9),
        .belowRentExemptMinimum(minimum: 9), .destinationIsTokenAccount, .destinationOwnedByProgram(key), .destinationIsKnownProgram,
        .destinationIsMint, .destinationOffCurve, .tokenAccountMismatch, .tokenAccountFrozen, .insufficientTokenBalance(needed: 9, available: 1),
        .permanentDelegate, .transferHook, .nonTransferable, .defaultAccountStateFrozen, .tokenPaused, .unknownMintExtension(providerText),
        .transactionTooLarge(9_999), .verificationFailed(.transferToUnknown(key)),
    ]

    static let swapErrors: [SolanaSwapError] = [
        .plan(.zeroAmount), .sameAsset, .zeroAmount, .amountTooLarge, .invalidAsset, .slippageTooHigh(900), .proposalMismatch(providerText),
        .route(.malformed), .authorityNotOwner(key), .sourceNotOwnerAccount(key), .destinationNotOwnerAccount(key), .routeMintMismatch,
        .routeTokenProgramMismatch, .inAmountMismatch(expected: 1, found: 2), .quotedOutMismatch(proposal: 1, route: 2),
        .slippageMismatch(expected: 1, found: 2), .minimumMismatch(proposal: 1, route: 2), .minimumBelowShown(shown: 9, route: 1), .zeroMinimum,
        .platformFee(9), .positiveSlippageFee(9), .unexpectedComputeBudgetInstruction(index: 9), .unexpectedSetupInstruction(index: 9),
        .unexpectedCleanupInstruction, .otherInstructions(count: 9), .tipInstruction, .boughtMintPermanentDelegate, .boughtMintTransferHook,
        .mintNonTransferable, .mintPaused, .unknownMintExtension(providerText), .boughtMintDefaultFrozen, .sourceAccountMismatch,
        .sourceAccountFrozen, .insufficientTokenBalance(needed: 9, available: 1), .destinationAccountMismatch, .destinationAccountFrozen,
        .insufficientFunds(needed: 9, available: 1), .leavesBalanceBelowRent(remainder: 1, minimum: 9), .missingLookupTable(key),
        .compiledRouteChanged, .simulationFailed(providerText), .simulationMissingAccount(key), .simulationWrongAccount(key),
        .simulationSpentTooMuch(asset: providerText, spent: 9, limit: 1), .simulationReceivedTooLittle(asset: providerText, received: 1, minimum: 9),
        .simulationNoComputeUnits,
    ]

    static var allErrors: [any Error] {
        var errors: [any Error] = SolanaEngineProblem.allCases + planErrors + swapErrors
        errors += [SolanaAccountParseError.notAMint(owner: providerText), .notATokenAccount, .tokenAccountMismatch, .notALookupTable, .lookupTableDeactivated, .malformed]
        errors += [SolanaBroadcastError.wrongChain, .malformedTransaction, .preflightFailed(providerText), .rejected(["x": providerText])]
        errors += [HTTPClient.Failure.offline, .timeout, .status(429), .status(500), .tooLarge, .redirectRefused, .invalidResponse, .decoding(providerText)]
        errors += [
            ConsensusFailure(answers: 1), SolanaInconsistentResponse(reason: providerText), SolanaRPCError(code: -32002, message: providerText),
            SolanaSimulationFailure(error: providerText, logs: [providerText]), SolanaSwapProposalError.invalidKey(providerText),
            JupiterRouteError.unsupportedInstruction(discriminator: [1, 2]), NSError(domain: providerText, code: 7),
        ]
        return errors
    }

    @Test("Toda recusa vira texto proprio: sem travessao, sem numero, sem texto de provedor, frase completa")
    func everyMessage() {
        let flows: [SolanaEngineMessages.Flow] = [.destination, .sendSOL, .sendToken, .swap, .broadcast, .history]
        for error in Self.allErrors {
            for flow in flows {
                guard case .message(let text) = SolanaEngineMessages.map(error, flow) as? SendEngineError else {
                    Issue.record("sem traducao: \(error)")
                    continue
                }
                #expect(!text.isEmpty && text.hasSuffix("."), "\(error)")
                #expect(!text.contains("—") && !text.contains("–"), "\(text)")
                #expect(text.rangeOfCharacter(from: .decimalDigits) == nil, "\(text)")
                #expect(!text.contains("9SHQ") && !text.contains("PROVEDOR"), "\(text)")
            }
        }
    }

    @Test("Cancelamento passa adiante; erro ja traduzido nao e traduzido de novo")
    func passThrough() {
        #expect(SolanaEngineMessages.map(CancellationError(), .swap) is CancellationError)
        let ready = SendEngineError.message("Pronto.")
        #expect(SolanaEngineMessages.map(ready, .swap) as? SendEngineError == ready)
    }

    @Test("Recusas do planejador mudam de sentido conforme o envio: SOL, token ou troca")
    func flowDependent() {
        let funds = SolanaPlanError.insufficientFunds(needed: 1, available: 0)
        #expect(SolanaEngineMessages.text(funds, .sendSOL) != SolanaEngineMessages.text(funds, .sendToken))
        #expect(SolanaEngineMessages.text(funds, .sendToken).hasPrefix("Falta SOL"))
        #expect(SolanaEngineMessages.text(SolanaAccountParseError.notATokenAccount, .swap) == "Esta carteira não tem saldo do ativo vendido.")
    }
}

@Suite("Solana: registro dos motores")
struct SolanaRegistryTests {
    @Test("A Solana tem envio, historico e troca; so a Solana")
    func registered() {
        #expect(SendEngines.engine(for: .solana) is SolanaSendEngine)
        #expect(ActivitySources.source(for: .solana) is SolanaActivitySource)
        #expect(TradeEngines.engine(for: .solana) is SolanaTradeEngine)
        #expect(TradeEngines.chains.contains(.solana))
        #expect(EngineRegistry.solanaSend(.ethereum) == nil && EngineRegistry.solanaTrade(.ton) == nil && EngineRegistry.solanaActivity(.xrpl) == nil)
    }
}
