import EscaliburCore
import Foundation

// Troca na Solana pela Jupiter, com a mensagem montada no aparelho.
//
// O provedor propoe, a carteira decide (docs/seguranca.md §4.1 e §4.6). A resposta
// do `/swap/v2/build` traz instrucoes; nunca se assina a transacao pronta do
// `/swap` ou do `/order`, que seria assinar as cegas. O caminho:
//
//   1. `draft`: confere a proposta contra a intencao, fail-closed.
//      - Da proposta so a instrucao de rota entra na mensagem. Ela e decodificada
//        (JupiterRoute) e cada campo que importa e conferido: quem autoriza e o
//        dono; de onde sai e o ATA do dono para o mint vendido; para onde vai e o
//        ATA do dono para o mint comprado; valor de entrada, valor cotado,
//        tolerancia e minimo batem com a intencao e com a propria cotacao; taxa de
//        plataforma e taxa sobre ganho positivo iguais ao compilado (zero).
//      - As instrucoes de preparo e limpeza da proposta tem de ser identicas as
//        que a carteira montaria sozinha (criar ATA do dono, embrulhar e
//        desembrulhar SOL). A mensagem usa as da carteira. Qualquer outra coisa,
//        gorjeta, "otherInstructions", recusa.
//      - O orcamento de computacao da proposta e ignorado: preco de prioridade e
//        limite de CU sao da carteira, com teto compilado.
//      - As tabelas de enderecos vem da cadeia (dois RPCs), nunca do JSON.
//      - A mensagem v0 sai de `SolanaMessage.compileV0`, passa pelo verificador
//        comum (`SolanaMessageVerifier`: so programas da lista, pagador = dono, um
//        signatario, sem SetAuthority, Approve, CloseAccount para outro,
//        AdvanceNonceAccount) e a rota e decodificada de novo a partir da mensagem
//        compilada, para garantir que a compilacao nao mudou nenhuma conta.
//   2. A camada de rede simula o rascunho, pedindo o estado final das contas do dono.
//   3. `plan`: a simulacao tem de confirmar o efeito (sai no maximo o valor, entra
//      pelo menos o minimo, o SOL do dono nao cai alem de valor, taxa e rent). O
//      limite de CU vem do consumo simulado * 1,1, e so entao sai o `SigningPlan`.

/// O mint do SOL embrulhado (`spl_token::native_mint`). A Jupiter troca SOL por meio
/// dele: a transacao embrulha antes da rota e desembrulha no fim.
public enum SolanaWrappedSOL {
    public static let mint = SolanaPublicKey(constant: "So11111111111111111111111111111111111111112")
}

/// Um lado da troca: SOL ou um token, com o que a cadeia disse do mint.
public struct SolanaSwapAsset: Sendable, Equatable {
    public let mint: SolanaPublicKey
    public let isNativeSOL: Bool
    public let program: SolanaTokenProgram
    public let decimals: UInt8
    public let symbol: String
    /// O mint esta na lista curada da carteira.
    public let isVerified: Bool
    public let extensions: [SolanaMintExtension]

    /// Um token SPL ou Token-2022, com o mint lido da cadeia (`getAccountInfo`).
    public init(mint: SolanaPublicKey, program: SolanaTokenProgram, decimals: UInt8, symbol: String, isVerified: Bool, extensions: [SolanaMintExtension]) {
        self.mint = mint
        self.isNativeSOL = false
        self.program = program
        self.decimals = decimals
        self.symbol = symbol
        self.isVerified = isVerified
        self.extensions = extensions
    }

    private init(nativeSOL: Void) {
        self.mint = SolanaWrappedSOL.mint
        self.isNativeSOL = true
        self.program = .token
        self.decimals = 9
        self.symbol = "SOL"
        self.isVerified = true
        self.extensions = []
    }

    /// SOL, trocado por meio do SOL embrulhado.
    public static let sol = SolanaSwapAsset(nativeSOL: ())
}

/// O que o dono pediu na tela.
public struct SolanaSwapIntent: Sendable, Equatable {
    public let sell: SolanaSwapAsset
    public let buy: SolanaSwapAsset
    /// Nas unidades do mint vendido (lamports para SOL).
    public let amountIn: BigUInt
    public let slippageBps: UInt16
    /// O minimo que a tela mostrou antes de o dono tocar em Trocar, de uma cotacao
    /// anterior. A rota montada nao pode garantir menos que isso.
    public let minimumOutShown: BigUInt?

    public init(sell: SolanaSwapAsset, buy: SolanaSwapAsset, amountIn: BigUInt, slippageBps: UInt16, minimumOutShown: BigUInt? = nil) {
        self.sell = sell
        self.buy = buy
        self.amountIn = amountIn
        self.slippageBps = slippageBps
        self.minimumOutShown = minimumOutShown
    }
}

/// As contas de token do dono que a troca toca, lidas da cadeia.
public struct SolanaSwapAccounts: Sendable, Equatable {
    /// O ATA do dono para o mint vendido. nil quando vende SOL.
    public let source: SolanaTokenAccountState?
    /// O ATA do dono para o mint comprado (o de SOL embrulhado quando compra SOL).
    public let destination: SolanaDestinationTokenAccount
    /// Rent de uma conta de token do mint comprado, pago se ela for criada.
    public let destinationRentMinimum: BigUInt
    /// Rent da conta temporaria de SOL embrulhado (165 bytes). Precisa estar no
    /// saldo durante a transacao e volta ao dono quando ela e fechada no fim.
    public let wrappedSOLRentMinimum: BigUInt

    public init(source: SolanaTokenAccountState?, destination: SolanaDestinationTokenAccount, destinationRentMinimum: BigUInt, wrappedSOLRentMinimum: BigUInt) {
        self.source = source
        self.destination = destination
        self.destinationRentMinimum = destinationRentMinimum
        self.wrappedSOLRentMinimum = wrappedSOLRentMinimum
    }
}

public enum SolanaSwapError: Error, Equatable, Sendable {
    case plan(SolanaPlanError)
    case sameAsset
    case zeroAmount
    case amountTooLarge
    case invalidAsset
    case slippageTooHigh(UInt16)
    /// A proposta diz outra coisa que a intencao (mint, valor, tolerancia, modo).
    case proposalMismatch(String)
    case route(JupiterRouteError)
    case authorityNotOwner(SolanaPublicKey)
    case sourceNotOwnerAccount(SolanaPublicKey)
    case destinationNotOwnerAccount(SolanaPublicKey)
    case routeMintMismatch
    case routeTokenProgramMismatch
    case inAmountMismatch(expected: UInt64, found: UInt64)
    case quotedOutMismatch(proposal: UInt64, route: UInt64)
    case slippageMismatch(expected: UInt16, found: UInt16)
    case minimumMismatch(proposal: UInt64, route: UInt64)
    case minimumBelowShown(shown: BigUInt, route: UInt64)
    case zeroMinimum
    case platformFee(UInt16)
    case positiveSlippageFee(UInt16)
    case unexpectedComputeBudgetInstruction(index: Int)
    case unexpectedSetupInstruction(index: Int)
    case unexpectedCleanupInstruction
    case otherInstructions(count: Int)
    case tipInstruction
    /// O mint comprado tem extensao que tira o controle do dono ou faria a troca falhar.
    case boughtMintPermanentDelegate
    case boughtMintTransferHook
    case mintNonTransferable
    case mintPaused
    case unknownMintExtension(String)
    case boughtMintDefaultFrozen
    case sourceAccountMismatch
    case sourceAccountFrozen
    case insufficientTokenBalance(needed: BigUInt, available: BigUInt)
    case destinationAccountMismatch
    case destinationAccountFrozen
    case insufficientFunds(needed: BigUInt, available: BigUInt)
    case leavesBalanceBelowRent(remainder: BigUInt, minimum: BigUInt)
    case missingLookupTable(SolanaPublicKey)
    case compiledRouteChanged
    case simulationFailed(String)
    case simulationMissingAccount(SolanaPublicKey)
    case simulationWrongAccount(SolanaPublicKey)
    case simulationSpentTooMuch(asset: String, spent: BigUInt, limit: BigUInt)
    case simulationReceivedTooLittle(asset: String, received: BigUInt, minimum: BigUInt)
    case simulationNoComputeUnits
}

/// O rascunho: a mensagem montada e conferida, pronta para simular. Nao e
/// assinavel; so `SolanaSwapPlanner.plan` transforma em `SigningPlan`.
public struct SolanaSwapDraft: Sendable {
    /// A mensagem do rascunho, com o limite maximo de CU (a simulacao mede o real).
    public let message: SolanaMessage
    /// Transacao com assinatura zerada, para `simulateTransaction` com `sigVerify: false`.
    public let simulationTransactionBase64: String
    /// As contas cujo estado final a simulacao deve devolver: o dono, o ATA do mint
    /// vendido (se for token) e o ATA do mint comprado (se for token).
    public let simulationAccounts: [SolanaPublicKey]
    /// O que a rota garante, decodificado dos bytes.
    public let route: JupiterRoute

    let walletID: UUID
    let owner: SolanaOwner
    let intent: SolanaSwapIntent
    let proposal: SolanaSwapProposal
    let lookupTables: [SolanaAddressLookupTable]
    let accounts: SolanaSwapAccounts
    let network: SolanaNetworkState
    let sourceAccount: SolanaPublicKey
    let destinationAccount: SolanaPublicKey
    let wrappedAccount: SolanaPublicKey?
    let createsDestination: Bool
    /// A maior taxa de rede que o rascunho pode cobrar (limite maximo de CU).
    let draftFee: BigUInt
}

public enum SolanaSwapPlanner {
    /// A taxa da Escalibur na troca, em pontos-base. **Compilada, hoje zero.** A
    /// rota tem de trazer exatamente este valor em `platform_fee_bps`; se um dia
    /// mudar, o mecanismo e a conta de taxa entram aqui, compilados, nunca da API.
    public static let escaliburFeeBps: UInt16 = 0
    /// Tolerancia maxima aceita, em pontos-base (5%). Acima disso o minimo garantido
    /// deixa de proteger o dono de verdade.
    public static let maxSlippageBps: UInt16 = 500
    /// Aviso de impacto de preco a partir deste porcento (declarado pelo provedor).
    static let priceImpactWarningPercent: Double = 1
    static let highFeePercent: Double = 3

    // MARK: Passo 1: rascunho

    public static func draft(
        walletID: UUID, owner: SolanaOwner, intent: SolanaSwapIntent, proposal: SolanaSwapProposal,
        lookupTables: [SolanaAddressLookupTable], accounts: SolanaSwapAccounts, network: SolanaNetworkState, now: Date = .now
    ) throws -> SolanaSwapDraft {
        do {
            try SolanaPlanner.checkOwner(owner)
            try SolanaPlanner.checkFreshness(network, now: now)
        } catch let error as SolanaPlanError {
            throw SolanaSwapError.plan(error)
        }
        let (sell, buy) = (intent.sell, intent.buy)
        try checkAsset(sell)
        try checkAsset(buy)
        guard sell.mint != buy.mint else { throw SolanaSwapError.sameAsset }
        guard !intent.amountIn.isZero else { throw SolanaSwapError.zeroAmount }
        guard let amountIn = intent.amountIn.uint64 else { throw SolanaSwapError.amountTooLarge }
        guard intent.slippageBps <= maxSlippageBps else { throw SolanaSwapError.slippageTooHigh(intent.slippageBps) }
        try checkExtensions(sell: sell, buy: buy, destination: accounts.destination)

        // A proposta tem de falar da mesma troca que o dono pediu.
        guard proposal.inputMint == sell.mint else { throw SolanaSwapError.proposalMismatch("mint vendido") }
        guard proposal.outputMint == buy.mint else { throw SolanaSwapError.proposalMismatch("mint comprado") }
        guard proposal.inAmount == amountIn else { throw SolanaSwapError.proposalMismatch("valor de entrada") }
        guard proposal.slippageBps == intent.slippageBps else { throw SolanaSwapError.proposalMismatch("tolerancia") }

        let me = owner.publicKey
        let sourceAccount = try ownerAccount(me, sell)
        let destinationAccount = try ownerAccount(me, buy)
        let wrappedAccount: SolanaPublicKey? = sell.isNativeSOL ? sourceAccount : (buy.isNativeSOL ? destinationAccount : nil)

        // Instrucoes da proposta que nao sao a rota: so as que a carteira montaria.
        try screen(proposal: proposal, owner: me, intent: intent, amountIn: amountIn, wrappedAccount: wrappedAccount, destinationAccount: destinationAccount)

        // A rota, decodificada e conferida.
        let route: JupiterRoute
        do {
            route = try JupiterRouteDecoder.decode(
                programID: proposal.swapInstruction.programID, accounts: proposal.swapInstruction.accounts.map(\.publicKey),
                data: proposal.swapInstruction.data
            )
        } catch let error as JupiterRouteError {
            throw SolanaSwapError.route(error)
        }
        try checkRoute(route, intent: intent, amountIn: amountIn, proposal: proposal, owner: me, source: sourceAccount, destination: destinationAccount)

        // Contas de token do dono.
        if !sell.isNativeSOL {
            guard let source = accounts.source, source.address == sourceAccount, source.mint == sell.mint, source.owner == me,
                  source.program == sell.program
            else { throw SolanaSwapError.sourceAccountMismatch }
            guard !source.isFrozen else { throw SolanaSwapError.sourceAccountFrozen }
            guard source.amount >= intent.amountIn else {
                throw SolanaSwapError.insufficientTokenBalance(needed: intent.amountIn, available: source.amount)
            }
        }
        let createsDestination: Bool
        switch accounts.destination {
        case .missing:
            createsDestination = !buy.isNativeSOL
        case .existing(let account):
            guard account.address == destinationAccount, account.mint == buy.mint, account.owner == me, account.program == buy.program else {
                throw SolanaSwapError.destinationAccountMismatch
            }
            guard !account.isFrozen else { throw SolanaSwapError.destinationAccountFrozen }
            createsDestination = false
        }

        // Tabelas: todas as que a proposta cita, com o conteudo lido da cadeia.
        var tables = [SolanaAddressLookupTable]()
        for address in proposal.lookupTableAddresses {
            guard let table = lookupTables.first(where: { $0.address == address }) else { throw SolanaSwapError.missingLookupTable(address) }
            tables.append(table)
        }

        // Rascunho com o limite maximo de CU: a simulacao mede o consumo real.
        let units = SolanaLimits.maxComputeUnitLimit
        let price = SolanaPlanner.cappedPrice(network.suggestedComputeUnitPrice, units: units)
        let draftFee = SolanaPlanner.networkFee(price: price, units: units)
        try checkBalance(
            network: network, fee: draftFee, amountIn: amountIn, sellsSOL: sell.isNativeSOL,
            permanentRent: createsDestination ? accounts.destinationRentMinimum : BigUInt(),
            temporaryRent: wrappedAccount == nil ? BigUInt() : accounts.wrappedSOLRentMinimum
        )
        let message = try compile(
            owner: me, intent: intent, amountIn: amountIn, route: route, swapInstruction: proposal.swapInstruction, tables: tables,
            units: units, price: price, wrappedAccount: wrappedAccount, destinationAccount: destinationAccount, network: network
        )
        // Falha cedo se nao couber num pacote.
        _ = try transaction(message, owner: owner, network: network)

        var simulationAccounts = [me]
        if !sell.isNativeSOL { simulationAccounts.append(sourceAccount) }
        if !buy.isNativeSOL { simulationAccounts.append(destinationAccount) }
        return SolanaSwapDraft(
            message: message, simulationTransactionBase64: SolanaSimulationEncoding.unsignedTransactionBase64(message),
            simulationAccounts: simulationAccounts, route: route, walletID: walletID, owner: owner, intent: intent, proposal: proposal,
            lookupTables: tables, accounts: accounts, network: network, sourceAccount: sourceAccount, destinationAccount: destinationAccount,
            wrappedAccount: wrappedAccount, createsDestination: createsDestination, draftFee: draftFee
        )
    }

    // MARK: Passo 2: plano

    /// Com a simulacao do rascunho confirmando o efeito, monta a transacao final
    /// (limite de CU medido) e devolve o plano.
    public static func plan(_ draft: SolanaSwapDraft, simulation: SolanaSimulationOutcome, now: Date = .now) throws -> SigningPlan {
        do {
            try SolanaPlanner.checkFreshness(draft.network, now: now)
        } catch let error as SolanaPlanError {
            throw SolanaSwapError.plan(error)
        }
        guard simulation.succeeded else { throw SolanaSwapError.simulationFailed(simulation.error ?? "") }
        guard let units = simulation.suggestedComputeUnitLimit else { throw SolanaSwapError.simulationNoComputeUnits }
        try checkSimulation(draft, simulation)

        let intent = draft.intent
        let me = draft.owner.publicKey
        guard let amountIn = intent.amountIn.uint64 else { throw SolanaSwapError.amountTooLarge }
        let price = SolanaPlanner.cappedPrice(draft.network.suggestedComputeUnitPrice, units: units)
        let fee = SolanaPlanner.networkFee(price: price, units: units)
        let permanentRent = draft.createsDestination ? draft.accounts.destinationRentMinimum : BigUInt()
        try checkBalance(
            network: draft.network, fee: fee, amountIn: amountIn, sellsSOL: intent.sell.isNativeSOL, permanentRent: permanentRent,
            temporaryRent: draft.wrappedAccount == nil ? BigUInt() : draft.accounts.wrappedSOLRentMinimum
        )
        let message = try compile(
            owner: me, intent: intent, amountIn: amountIn, route: draft.route, swapInstruction: draft.proposal.swapInstruction,
            tables: draft.lookupTables, units: units, price: price, wrappedAccount: draft.wrappedAccount,
            destinationAccount: draft.destinationAccount, network: draft.network
        )
        let transaction = try transaction(message, owner: draft.owner, network: draft.network)
        let review = makeReview(draft, fee: fee, permanentRent: permanentRent)
        return SigningPlan(walletID: draft.walletID, chain: .solana, review: review, transactions: [transaction], createdAt: now)
    }

    // MARK: Conferencias

    static func checkAsset(_ asset: SolanaSwapAsset) throws {
        if asset.isNativeSOL {
            guard asset == .sol else { throw SolanaSwapError.invalidAsset }
        } else {
            // SOL embrulhado como "token" entraria sem o embrulho/desembrulho que a
            // carteira sabe conferir: a troca de SOL passa sempre por `.sol`.
            guard asset.mint != SolanaWrappedSOL.mint, SolanaProgram(id: asset.mint) == nil else { throw SolanaSwapError.invalidAsset }
        }
    }

    static func checkExtensions(sell: SolanaSwapAsset, buy: SolanaSwapAsset, destination: SolanaDestinationTokenAccount) throws {
        for ext in sell.extensions {
            switch ext {
            case .nonTransferable: throw SolanaSwapError.mintNonTransferable
            case .paused: throw SolanaSwapError.mintPaused
            case .unknown(let name): throw SolanaSwapError.unknownMintExtension(name)
            // Vender um token com delegado permanente ou hook e se livrar dele; a
            // simulacao confere que o efeito e o esperado.
            case .permanentDelegate, .transferHook, .transferFee, .defaultAccountStateFrozen: break
            }
        }
        for ext in buy.extensions {
            switch ext {
            // O emissor poderia mover ou queimar o que o dono acabou de comprar.
            case .permanentDelegate: throw SolanaSwapError.boughtMintPermanentDelegate
            // Cada transferencia chamaria um programa do emissor, fora da lista.
            case .transferHook: throw SolanaSwapError.boughtMintTransferHook
            case .nonTransferable: throw SolanaSwapError.mintNonTransferable
            case .paused: throw SolanaSwapError.mintPaused
            case .unknown(let name): throw SolanaSwapError.unknownMintExtension(name)
            case .defaultAccountStateFrozen:
                if case .missing = destination { throw SolanaSwapError.boughtMintDefaultFrozen }
            case .transferFee: break  // aviso na revisao; o minimo e conferido na simulacao
            }
        }
    }

    static func ownerAccount(_ owner: SolanaPublicKey, _ asset: SolanaSwapAsset) throws -> SolanaPublicKey {
        do {
            return try SolanaAssociatedToken.address(owner: owner, mint: asset.mint, tokenProgram: asset.program)
        } catch {
            // Dono fora da curva nao tem ATA derivavel sem risco de prender o token.
            throw SolanaSwapError.plan(.destinationOffCurve)
        }
    }

    /// As instrucoes que a carteira montaria para preparar e limpar a troca. As
    /// da proposta tem de estar entre estas (identicas, byte a byte e papel a papel).
    static func expectedSetup(owner: SolanaPublicKey, intent: SolanaSwapIntent, amountIn: UInt64, wrappedAccount: SolanaPublicKey?, destinationAccount: SolanaPublicKey) -> [SolanaInstruction] {
        var setup = [SolanaInstruction]()
        if intent.sell.isNativeSOL, let wrapped = wrappedAccount {
            setup.append(SolanaAssociatedTokenInstruction.createIdempotent(
                payer: owner, associatedAccount: wrapped, owner: owner, mint: SolanaWrappedSOL.mint, tokenProgram: .token
            ))
            setup.append(SolanaSystemInstruction.transfer(from: owner, to: wrapped, lamports: amountIn))
            setup.append(SolanaSwapInstructions.syncNative(account: wrapped))
        }
        setup.append(SolanaAssociatedTokenInstruction.createIdempotent(
            payer: owner, associatedAccount: destinationAccount, owner: owner, mint: intent.buy.mint, tokenProgram: intent.buy.program
        ))
        return setup
    }

    static func screen(
        proposal: SolanaSwapProposal, owner: SolanaPublicKey, intent: SolanaSwapIntent, amountIn: UInt64,
        wrappedAccount: SolanaPublicKey?, destinationAccount: SolanaPublicKey
    ) throws {
        guard proposal.tipInstruction == nil else { throw SolanaSwapError.tipInstruction }
        guard proposal.otherInstructions.isEmpty else { throw SolanaSwapError.otherInstructions(count: proposal.otherInstructions.count) }
        for (index, ix) in proposal.computeBudgetInstructions.enumerated() where ix.programID != SolanaProgramID.computeBudget {
            throw SolanaSwapError.unexpectedComputeBudgetInstruction(index: index)
        }
        let expected = expectedSetup(owner: owner, intent: intent, amountIn: amountIn, wrappedAccount: wrappedAccount, destinationAccount: destinationAccount)
        var seen = [SolanaInstruction]()
        for (index, ix) in proposal.setupInstructions.enumerated() {
            guard expected.contains(ix), !seen.contains(ix) else { throw SolanaSwapError.unexpectedSetupInstruction(index: index) }
            seen.append(ix)
        }
        if let cleanup = proposal.cleanupInstruction {
            guard let wrapped = wrappedAccount, cleanup == SolanaSwapInstructions.closeAccount(account: wrapped, destination: owner, authority: owner) else {
                throw SolanaSwapError.unexpectedCleanupInstruction
            }
        }
    }

    static func checkRoute(
        _ route: JupiterRoute, intent: SolanaSwapIntent, amountIn: UInt64, proposal: SolanaSwapProposal, owner: SolanaPublicKey,
        source: SolanaPublicKey, destination: SolanaPublicKey
    ) throws {
        guard route.userTransferAuthority == owner else { throw SolanaSwapError.authorityNotOwner(route.userTransferAuthority) }
        guard route.sourceTokenAccount == source else { throw SolanaSwapError.sourceNotOwnerAccount(route.sourceTokenAccount) }
        guard route.destinationTokenAccount == destination else { throw SolanaSwapError.destinationNotOwnerAccount(route.destinationTokenAccount) }
        if let optional = route.optionalDestination, optional != destination {
            throw SolanaSwapError.destinationNotOwnerAccount(optional)
        }
        guard route.sourceMint == intent.sell.mint, route.destinationMint == intent.buy.mint else { throw SolanaSwapError.routeMintMismatch }
        guard route.sourceTokenProgram == intent.sell.program.programID, route.destinationTokenProgram == intent.buy.program.programID else {
            throw SolanaSwapError.routeTokenProgramMismatch
        }
        guard route.inAmount == amountIn else { throw SolanaSwapError.inAmountMismatch(expected: amountIn, found: route.inAmount) }
        guard route.quotedOutAmount == proposal.outAmount else {
            throw SolanaSwapError.quotedOutMismatch(proposal: proposal.outAmount, route: route.quotedOutAmount)
        }
        guard route.slippageBps == intent.slippageBps else { throw SolanaSwapError.slippageMismatch(expected: intent.slippageBps, found: route.slippageBps) }
        guard route.platformFeeBps == escaliburFeeBps else { throw SolanaSwapError.platformFee(route.platformFeeBps) }
        guard route.positiveSlippageBps == 0 else { throw SolanaSwapError.positiveSlippageFee(route.positiveSlippageBps) }
        let minimum = route.minimumOut
        guard minimum > 0 else { throw SolanaSwapError.zeroMinimum }
        guard minimum == proposal.otherAmountThreshold else {
            throw SolanaSwapError.minimumMismatch(proposal: proposal.otherAmountThreshold, route: minimum)
        }
        if let shown = intent.minimumOutShown, BigUInt(minimum) < shown {
            throw SolanaSwapError.minimumBelowShown(shown: shown, route: minimum)
        }
    }

    /// Saldo de SOL: no pico precisa cobrir taxa, valor (se vende SOL), rent da
    /// conta criada e o rent temporario do SOL embrulhado; no fim o dono fica com
    /// pelo menos o minimo de rent (a troca nunca zera a conta).
    static func checkBalance(
        network: SolanaNetworkState, fee: BigUInt, amountIn: UInt64, sellsSOL: Bool, permanentRent: BigUInt, temporaryRent: BigUInt
    ) throws {
        let spend = fee + permanentRent + (sellsSOL ? BigUInt(amountIn) : BigUInt())
        let peak = spend + temporaryRent
        guard network.balance >= peak else { throw SolanaSwapError.insufficientFunds(needed: peak, available: network.balance) }
        let remainder = network.balance - spend
        guard remainder >= network.rentExemptMinimum else {
            throw SolanaSwapError.leavesBalanceBelowRent(remainder: remainder, minimum: network.rentExemptMinimum)
        }
    }

    /// Monta a mensagem v0 com as instrucoes da carteira e a rota conferida, passa
    /// pelo verificador comum e confere que a rota compilada e a mesma.
    static func compile(
        owner: SolanaPublicKey, intent: SolanaSwapIntent, amountIn: UInt64, route: JupiterRoute, swapInstruction: SolanaInstruction,
        tables: [SolanaAddressLookupTable], units: UInt32, price: UInt64, wrappedAccount: SolanaPublicKey?,
        destinationAccount: SolanaPublicKey, network: SolanaNetworkState
    ) throws -> SolanaMessage {
        var instructions = [SolanaComputeBudgetInstruction.setComputeUnitLimit(units)]
        if price > 0 { instructions.append(SolanaComputeBudgetInstruction.setComputeUnitPrice(microLamports: price)) }
        instructions += expectedSetup(owner: owner, intent: intent, amountIn: amountIn, wrappedAccount: wrappedAccount, destinationAccount: destinationAccount)
        instructions.append(swapInstruction)
        if let wrapped = wrappedAccount {
            instructions.append(SolanaSwapInstructions.closeAccount(account: wrapped, destination: owner, authority: owner))
        }

        let message: SolanaMessage
        do {
            message = try SolanaMessage.compileV0(payer: owner, instructions: instructions, recentBlockhash: network.recentBlockhash, lookupTables: tables)
        } catch {
            throw SolanaSwapError.plan(.transactionTooLarge(0))
        }
        var programs: Set<SolanaProgram> = [.computeBudget, .associatedToken, .jupiterV6]
        if wrappedAccount != nil { programs.formUnion([.system, .token]) }
        var recipients = Set<SolanaPublicKey>()
        if intent.sell.isNativeSOL, let wrapped = wrappedAccount { recipients.insert(wrapped) }
        let verified: SolanaVerifiedMessage
        do {
            verified = try SolanaMessageVerifier.verify(
                message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: programs, allowedRecipients: recipients), lookupTables: tables
            )
        } catch let error as SolanaVerificationError {
            throw SolanaSwapError.plan(.verificationFailed(error))
        }

        // Uma so rota, e a mesma que foi conferida, lida da mensagem compilada.
        let loaded: SolanaLoadedAddresses
        do { loaded = try message.resolveLookups(tables) } catch { throw SolanaSwapError.compiledRouteChanged }
        let keys = message.accountKeys(loaded: loaded)
        let routes = message.instructions.filter { keys[Int($0.programIDIndex)] == SolanaProgramID.jupiterV6 }
        guard routes.count == 1, verified.actions.filter({ if case .jupiter = $0 { return true }; return false }).count == 1 else {
            throw SolanaSwapError.compiledRouteChanged
        }
        let compiledRoute = try? JupiterRouteDecoder.decode(
            programID: SolanaProgramID.jupiterV6, accounts: routes[0].accountIndexes.map { keys[Int($0)] }, data: routes[0].data
        )
        guard compiledRoute == route else { throw SolanaSwapError.compiledRouteChanged }
        return message
    }

    static func transaction(_ message: SolanaMessage, owner: SolanaOwner, network: SolanaNetworkState) throws -> SolanaTransaction {
        do {
            return try SolanaTransaction(message: message, signerPath: owner.path, signer: owner.publicKey, lastValidBlockHeight: network.lastValidBlockHeight)
        } catch SolanaTransactionProblem.tooLarge(let size) {
            throw SolanaSwapError.plan(.transactionTooLarge(size))
        } catch {
            throw SolanaSwapError.plan(.verificationFailed(.feePayerNotOwner(message.feePayer)))
        }
    }

    /// A simulacao tem de mostrar o efeito que a rota promete nas contas do dono.
    static func checkSimulation(_ draft: SolanaSwapDraft, _ simulation: SolanaSimulationOutcome) throws {
        let intent = draft.intent
        let me = draft.owner.publicKey
        func snapshot(_ address: SolanaPublicKey) throws -> SolanaAccountSnapshot {
            guard let found = simulation.accounts.first(where: { $0.address == address }) else { throw SolanaSwapError.simulationMissingAccount(address) }
            return found
        }
        let minimum = BigUInt(draft.route.minimumOut)

        // SOL do dono.
        let ownerAfter = try snapshot(me)
        guard ownerAfter.exists else { throw SolanaSwapError.simulationWrongAccount(me) }
        let before = draft.network.balance
        let after = BigUInt(ownerAfter.lamports)
        let permanentRent = draft.createsDestination ? draft.accounts.destinationRentMinimum : BigUInt()
        let costs = draft.draftFee + permanentRent
        if intent.buy.isNativeSOL {
            // Entra pelo menos o minimo, descontadas taxa e rent.
            guard after + costs >= before + minimum else {
                let received = (after + costs).subtractingReportingUnderflow(before) ?? BigUInt()
                throw SolanaSwapError.simulationReceivedTooLittle(asset: "SOL", received: received, minimum: minimum)
            }
        } else {
            let limit = costs + (intent.sell.isNativeSOL ? intent.amountIn : BigUInt())
            if let spent = before.subtractingReportingUnderflow(after), spent > limit {
                throw SolanaSwapError.simulationSpentTooMuch(asset: "SOL", spent: spent, limit: limit)
            }
        }

        // Token vendido: sai no maximo o valor.
        if !intent.sell.isNativeSOL, let source = draft.accounts.source {
            let account = try snapshot(draft.sourceAccount)
            guard account.exists, account.tokenMint == intent.sell.mint, account.tokenOwner == me, let amount = account.tokenAmount else {
                throw SolanaSwapError.simulationWrongAccount(draft.sourceAccount)
            }
            if let spent = source.amount.subtractingReportingUnderflow(BigUInt(amount)), spent > intent.amountIn {
                throw SolanaSwapError.simulationSpentTooMuch(asset: intent.sell.symbol, spent: spent, limit: intent.amountIn)
            }
        }

        // Token comprado: entra pelo menos o minimo, na conta do dono.
        if !intent.buy.isNativeSOL {
            let account = try snapshot(draft.destinationAccount)
            guard account.exists, account.tokenMint == intent.buy.mint, account.tokenOwner == me, let amount = account.tokenAmount else {
                throw SolanaSwapError.simulationWrongAccount(draft.destinationAccount)
            }
            var previous = BigUInt()
            if case .existing(let state) = draft.accounts.destination { previous = state.amount }
            let received = BigUInt(amount).subtractingReportingUnderflow(previous) ?? BigUInt()
            guard received >= minimum else {
                throw SolanaSwapError.simulationReceivedTooLittle(asset: intent.buy.symbol, received: received, minimum: minimum)
            }
        }
    }

    // MARK: Revisao

    static func makeReview(_ draft: SolanaSwapDraft, fee: BigUInt, permanentRent: BigUInt) -> PlanReview {
        let intent = draft.intent
        let (sell, buy) = (intent.sell, intent.buy)
        let sellText = SolanaAmountText.format(intent.amountIn, decimals: Int(sell.decimals), symbol: sell.symbol)
        let minimumText = SolanaAmountText.format(BigUInt(draft.route.minimumOut), decimals: Int(buy.decimals), symbol: buy.symbol)
        let quotedText = SolanaAmountText.format(BigUInt(draft.route.quotedOutAmount), decimals: Int(buy.decimals), symbol: buy.symbol)

        var lines = [
            PlanReview.Line("Sai", sellText),
            PlanReview.Line("Entra, no mínimo", minimumText),
            PlanReview.Line("Estimativa", quotedText),
            PlanReview.Line("Preço", priceText(draft)),
            PlanReview.Line("Tolerância de preço", percentText(bps: intent.slippageBps)),
            PlanReview.Line("Taxa da rede", SolanaAmountText.sol(fee)),
        ]
        let priority = fee - BigUInt(SolanaLimits.lamportsPerSignature)
        if !priority.isZero { lines.append(PlanReview.Line("Inclui prioridade", SolanaAmountText.sol(priority))) }
        if !permanentRent.isZero {
            lines.append(PlanReview.Line("Criação da sua conta de \(buy.symbol)", SolanaAmountText.sol(permanentRent)))
        }
        lines.append(PlanReview.Line("Escalibur", "Sem taxa da Escalibur"))
        lines.append(PlanReview.Line("Provedor", draft.proposal.provider))
        if buy.isNativeSOL {
            lines.append(PlanReview.Line("Recebe em", draft.owner.publicKey.base58, verbatim: true))
        } else {
            lines.append(PlanReview.Line("Mint comprado", buy.mint.base58, verbatim: true))
            lines.append(PlanReview.Line("Recebe na sua conta de token", draft.destinationAccount.base58, verbatim: true))
        }

        var warnings = [PlanReview.Warning]()
        if !buy.isVerified { warnings.append(.unverifiedToken(symbol: buy.symbol)) }
        if !permanentRent.isZero { warnings.append(.activatesAccount(minimum: SolanaAmountText.sol(permanentRent))) }
        if let impact = draft.proposal.priceImpactPercent, impact > priceImpactWarningPercent {
            warnings.append(.highPriceImpact(percent: impact))
        }
        if sell.isNativeSOL {
            let feePercent = SolanaPlanner.percent(fee, of: intent.amountIn)
            if feePercent > highFeePercent { warnings.append(.highFee(percentOfAmount: feePercent)) }
        }
        for case .transferFee(let bps, _) in buy.extensions {
            // O emissor retem uma fracao a cada transferencia; o minimo acima ja e
            // conferido na simulacao, na conta do dono.
            lines.append(PlanReview.Line("Taxa do emissor de \(buy.symbol)", "até " + percentText(bps: bps)))
            warnings.append(.highFee(percentOfAmount: Double(bps) / 100))
        }
        return PlanReview(kind: .swap, title: "Trocar \(sellText) por \(buy.symbol)", lines: lines, warnings: warnings)
    }

    /// "1 SOL ≈ 121,6612 USDC", calculado da cotacao decodificada, truncado nas
    /// casas do token comprado. So exibicao.
    static func priceText(_ draft: SolanaSwapDraft) -> String {
        let (sell, buy) = (draft.intent.sell, draft.intent.buy)
        let scaled = BigUInt(draft.route.quotedOutAmount) * BigUInt.power(of: 10, Int(sell.decimals)) / BigUInt(draft.route.inAmount)
        return "1 \(sell.symbol) ≈ \(SolanaAmountText.format(scaled, decimals: Int(buy.decimals), symbol: buy.symbol))"
    }

    /// 50 -> "0,5%".
    static func percentText(bps: UInt16) -> String {
        let text = SolanaAmountText.format(BigUInt(bps), decimals: 2, symbol: "")
        return text.trimmingCharacters(in: .whitespaces) + "%"
    }
}

/// Instrucoes de conta de token que a troca usa (mesmo layout no Token e no
/// Token-2022; aqui sempre no Token, onde vive o SOL embrulhado).
public enum SolanaSwapInstructions {
    static let syncNativeTag: UInt8 = 17
    static let closeAccountTag: UInt8 = 9

    /// `SyncNative`: acerta o saldo do SOL embrulhado com os lamports da conta.
    public static func syncNative(account: SolanaPublicKey) -> SolanaInstruction {
        SolanaInstruction(programID: SolanaProgramID.token, accounts: [SolanaAccountMeta(account, isSigner: false, isWritable: true)], data: [syncNativeTag])
    }

    /// `CloseAccount`: fecha a conta e manda os lamports (rent e, no SOL embrulhado,
    /// o saldo) para `destination`. Contas: [conta, destino, autoridade (assina)].
    public static func closeAccount(account: SolanaPublicKey, destination: SolanaPublicKey, authority: SolanaPublicKey) -> SolanaInstruction {
        SolanaInstruction(
            programID: SolanaProgramID.token,
            accounts: [
                SolanaAccountMeta(account, isSigner: false, isWritable: true),
                SolanaAccountMeta(destination, isSigner: false, isWritable: true),
                SolanaAccountMeta(authority, isSigner: true, isWritable: false),
            ],
            data: [closeAccountTag]
        )
    }
}
