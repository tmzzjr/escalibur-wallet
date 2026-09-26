import EscaliburCore
import Foundation

// Planejamento validado: da intencao do dono ("enviar X para Y") e do estado da
// rede (dados publicos, preenchidos por EscaliburNetwork) ate um `SigningPlan`.
//
// Tudo que vem de fora e tratado como possivelmente mentiroso: o preco de
// prioridade tem teto compilado, o blockhash tem prazo, o rent vem do chamador mas
// o resultado e conferido contra ele, e a mensagem que sai daqui ainda passa pelo
// verificador (o mesmo que confere mensagem de agregador) antes de virar plano.

// MARK: Estado publico que a camada de rede preenche

/// A conta do dono: o caminho SLIP-10 e a chave publica que ele gera. O assinador
/// confere que a chave derivada do caminho e esta, e recusa se nao for.
public struct SolanaOwner: Sendable, Equatable {
    public let path: DerivationPath
    public let publicKey: SolanaPublicKey

    public init(path: DerivationPath, publicKey: SolanaPublicKey) {
        self.path = path
        self.publicKey = publicKey
    }
}

/// O estado da rede para uma transacao do dono.
public struct SolanaNetworkState: Sendable, Equatable {
    /// `getLatestBlockhash` (commitment `confirmed` ou `finalized`).
    public let recentBlockhash: SolanaBlockhash
    /// `lastValidBlockHeight` da mesma resposta.
    public let lastValidBlockHeight: UInt64
    /// `getBlockHeight` no mesmo momento.
    public let currentBlockHeight: UInt64
    /// Quando as tres leituras acima foram feitas.
    public let fetchedAt: Date
    /// Saldo do dono em lamports (`getBalance`).
    public let balance: BigUInt
    /// `getMinimumBalanceForRentExemption(0)`: o minimo de uma conta de sistema sem
    /// dados. Muda com o tempo (a rede esta reduzindo o rent em 2026), por isso
    /// nunca e constante no codigo.
    public let rentExemptMinimum: BigUInt
    /// Preco de prioridade sugerido, em micro-lamports por CU
    /// (`getRecentPrioritizationFees` das contas gravaveis, percentil 50 a 75). A
    /// carteira aplica o teto de `SolanaLimits` por cima.
    public let suggestedComputeUnitPrice: UInt64
    /// `unitsConsumed * 1,1` de uma simulacao, se houver. Sem ela, vale o limite
    /// padrao compilado de cada tipo de envio.
    public let simulatedComputeUnits: UInt32?

    public init(
        recentBlockhash: SolanaBlockhash, lastValidBlockHeight: UInt64, currentBlockHeight: UInt64, fetchedAt: Date,
        balance: BigUInt, rentExemptMinimum: BigUInt, suggestedComputeUnitPrice: UInt64, simulatedComputeUnits: UInt32? = nil
    ) {
        self.recentBlockhash = recentBlockhash
        self.lastValidBlockHeight = lastValidBlockHeight
        self.currentBlockHeight = currentBlockHeight
        self.fetchedAt = fetchedAt
        self.balance = balance
        self.rentExemptMinimum = rentExemptMinimum
        self.suggestedComputeUnitPrice = suggestedComputeUnitPrice
        self.simulatedComputeUnits = simulatedComputeUnits
    }
}

/// Uma conta de token lida da cadeia (`getAccountInfo` com `jsonParsed`).
public struct SolanaTokenAccountState: Sendable, Equatable {
    public let address: SolanaPublicKey
    /// O dono da conta no nivel da cadeia: Token ou Token-2022.
    public let program: SolanaTokenProgram
    public let mint: SolanaPublicKey
    /// A carteira dona dos tokens (o campo `owner` do estado da conta de token).
    public let owner: SolanaPublicKey
    public let amount: BigUInt
    public let isFrozen: Bool

    public init(address: SolanaPublicKey, program: SolanaTokenProgram, mint: SolanaPublicKey, owner: SolanaPublicKey, amount: BigUInt, isFrozen: Bool) {
        self.address = address
        self.program = program
        self.mint = mint
        self.owner = owner
        self.amount = amount
        self.isFrozen = isFrozen
    }
}

/// O que existe no endereco de destino digitado, pelo `owner` da conta na cadeia.
public enum SolanaDestinationAccount: Sendable, Equatable {
    /// `getAccountInfo` devolveu nulo: endereco nunca usado.
    case nonexistent
    /// Dono = System Program: uma carteira.
    case system(lamports: BigUInt)
    /// Dono = Token ou Token-2022: o endereco colado e uma conta de token, nao uma
    /// carteira.
    case tokenAccount(SolanaTokenAccountState)
    /// Qualquer outro dono (programa, conta de stake, conta de dados). Um mint
    /// tambem pertence ao Token Program, mas nao e conta de token: vai aqui.
    case programOwned(owner: SolanaPublicKey)
}

/// A conta de token do destino, quando o destino e uma carteira.
public enum SolanaDestinationTokenAccount: Sendable, Equatable {
    /// O ATA do destino ainda nao existe: o envio cria com CreateIdempotent e o
    /// dono paga o rent.
    case missing
    case existing(SolanaTokenAccountState)
}

/// Extensoes Token-2022 do mint que mudam o que um envio faz. A camada de rede
/// lista aqui as que conhece; extensao que ela nao reconhece vai como `unknown`,
/// e a carteira recusa. Extensoes so de exibicao (metadados, ponteiros de grupo,
/// autoridade de fechamento do mint) nao precisam aparecer.
public enum SolanaMintExtension: Sendable, Equatable {
    /// Taxa do emissor: a fracao que o programa retem na transferencia. Os valores
    /// sao os da epoca atual (`newerTransferFee` se ja vigente, senao `older`).
    case transferFee(basisPoints: UInt16, maximumFee: BigUInt)
    /// O emissor pode mover ou queimar os tokens de qualquer conta.
    case permanentDelegate
    /// Cada transferencia chama um programa do emissor, com contas extras.
    case transferHook
    /// O token nao pode ser transferido.
    case nonTransferable
    /// Contas novas nascem congeladas.
    case defaultAccountStateFrozen
    /// O emissor pausou o token.
    case paused
    case unknown(String)
}

/// O token a enviar e a conta do dono que o guarda.
public struct SolanaTokenState: Sendable, Equatable {
    public let mint: SolanaPublicKey
    /// O dono da conta do mint na cadeia.
    public let program: SolanaTokenProgram
    public let decimals: UInt8
    public let symbol: String
    /// O mint esta na lista curada da carteira. Mint falso com o simbolo de um token
    /// conhecido e golpe comum.
    public let isVerified: Bool
    public let extensions: [SolanaMintExtension]
    /// A conta de token do dono para este mint (o ATA dele).
    public let source: SolanaTokenAccountState
    /// `getMinimumBalanceForRentExemption(tamanho da conta de token deste mint)`:
    /// 165 bytes no Token; mais no Token-2022, conforme as extensoes.
    public let tokenAccountRentMinimum: BigUInt

    public init(
        mint: SolanaPublicKey, program: SolanaTokenProgram, decimals: UInt8, symbol: String, isVerified: Bool,
        extensions: [SolanaMintExtension], source: SolanaTokenAccountState, tokenAccountRentMinimum: BigUInt
    ) {
        self.mint = mint
        self.program = program
        self.decimals = decimals
        self.symbol = symbol
        self.isVerified = isVerified
        self.extensions = extensions
        self.source = source
        self.tokenAccountRentMinimum = tokenAccountRentMinimum
    }
}

// MARK: Recusas

public enum SolanaPlanError: Error, Equatable, Sendable {
    case signerPathNotHardened
    case invalidDestination(Address.Problem)
    case destinationIsOwner
    case zeroAmount
    case amountTooLarge
    /// O blockhash tem mais de 60 s ou esta a menos de `minRemainingBlocks` de vencer.
    case staleNetworkState
    case blockhashExpiring
    case invalidComputeUnitLimit(UInt32)
    case insufficientFunds(needed: BigUInt, available: BigUInt)
    /// Sobraria um saldo entre zero e o minimo de rent na conta do dono: a
    /// transacao falharia. Enviar tudo (sobra zero) ou deixar pelo menos o minimo.
    case leavesBalanceBelowRent(remainder: BigUInt, minimum: BigUInt)
    /// O destino nao existe (ou esta abaixo do minimo) e o valor nao o torna isento de rent.
    case belowRentExemptMinimum(minimum: BigUInt)
    /// Enviar SOL para uma conta de token deixa os lamports presos ao ciclo de vida
    /// daquela conta.
    case destinationIsTokenAccount
    case destinationOwnedByProgram(SolanaPublicKey)
    /// O destino e um dos programas da lista compilada, ou o proprio mint do token:
    /// o valor ficaria preso numa conta que nao devolve nada.
    case destinationIsKnownProgram
    case destinationIsMint
    /// Destino fora da curva num envio de token sem confirmacao explicita: pode ser
    /// um ATA colado, e o ATA de um ATA e irrecuperavel.
    case destinationOffCurve
    case tokenAccountMismatch
    case tokenAccountFrozen
    case insufficientTokenBalance(needed: BigUInt, available: BigUInt)
    case permanentDelegate
    case transferHook
    case nonTransferable
    case defaultAccountStateFrozen
    case tokenPaused
    case unknownMintExtension(String)
    case transactionTooLarge(Int)
    case verificationFailed(SolanaVerificationError)
}

// MARK: Planejamento

public enum SolanaPlanner {
    /// Tempo maximo entre a leitura do estado e o planejamento.
    public static let maxStateAge: TimeInterval = 60
    /// Blocos de folga exigidos ate o blockhash vencer (~12 s a 400 ms por bloco).
    public static let minRemainingBlocks: UInt64 = 30
    /// Estimativa pessimista do ritmo de blocos para descontar o tempo passado.
    static let secondsPerBlock: TimeInterval = 0.4

    /// Limites de CU padrao, com folga sobre o consumo medido (System Transfer 150
    /// CU; cada instrucao de Compute Budget 150; TransferChecked do Token alguns
    /// milhares; criacao de ATA dezenas de milhares, mais no Token-2022). Folga
    /// demais so custa quando ha prioridade, e a prioridade tem teto.
    public static let solTransferComputeUnits: UInt32 = 2_000
    public static func tokenTransferComputeUnits(_ program: SolanaTokenProgram, createsAccount: Bool) -> UInt32 {
        switch (program, createsAccount) {
        case (.token, false): return 30_000
        case (.token, true): return 70_000
        case (.token2022, false): return 60_000
        case (.token2022, true): return 130_000
        }
    }

    /// Aviso de taxa alta a partir desta fracao do valor enviado.
    static let highFeePercent: Double = 3

    // MARK: SOL

    /// Planeja um envio de SOL.
    public static func planSendSOL(
        walletID: UUID, owner: SolanaOwner, to destinationText: String, lamports: BigUInt,
        destination: SolanaDestinationAccount, network: SolanaNetworkState, now: Date = .now
    ) throws -> SigningPlan {
        try checkOwner(owner)
        try checkFreshness(network, now: now)
        let to = try parseDestination(destinationText, owner: owner)
        guard !lamports.isZero else { throw SolanaPlanError.zeroAmount }
        guard let amount = lamports.uint64 else { throw SolanaPlanError.amountTooLarge }

        var warnings = [PlanReview.Warning]()
        let destinationLamports: BigUInt
        switch destination {
        case .nonexistent: destinationLamports = BigUInt()
        case .system(let current): destinationLamports = current
        case .tokenAccount: throw SolanaPlanError.destinationIsTokenAccount
        case .programOwned(let programOwner): throw SolanaPlanError.destinationOwnedByProgram(programOwner)
        }
        // Conta nova (ou abaixo do minimo) so passa a existir com o minimo de rent.
        if destinationLamports + lamports < network.rentExemptMinimum {
            throw SolanaPlanError.belowRentExemptMinimum(minimum: network.rentExemptMinimum)
        }
        if destinationLamports.isZero {
            warnings.append(.activatesAccount(minimum: SolanaAmountText.sol(network.rentExemptMinimum)))
        }
        // Fora da curva: conta de programa (PDA), como um cofre multisig. Pode ser
        // legitimo, mas ninguem assina por ela com uma chave comum.
        if !to.isOnCurve { warnings.append(.destinationIsContract) }

        let units = try computeUnits(network, default: solTransferComputeUnits)
        let price = cappedPrice(network.suggestedComputeUnitPrice, units: units)
        let fee = networkFee(price: price, units: units)
        try checkRemainder(balance: network.balance, fee: fee, spend: lamports + fee, minimum: network.rentExemptMinimum)

        var instructions = [SolanaComputeBudgetInstruction.setComputeUnitLimit(units)]
        if price > 0 { instructions.append(SolanaComputeBudgetInstruction.setComputeUnitPrice(microLamports: price)) }
        instructions.append(SolanaSystemInstruction.transfer(from: owner.publicKey, to: to, lamports: amount))

        let transaction = try build(
            instructions: instructions, owner: owner, network: network,
            policy: SolanaVerificationPolicy(owner: owner.publicKey, allowedPrograms: [.computeBudget, .system], allowedRecipients: [to])
        )

        let feePercent = percent(fee, of: lamports)
        if feePercent > highFeePercent { warnings.append(.highFee(percentOfAmount: feePercent)) }
        var lines = [
            PlanReview.Line("Para", to.base58, verbatim: true),
            PlanReview.Line("Valor", SolanaAmountText.sol(lamports)),
            PlanReview.Line("Taxa da rede", SolanaAmountText.sol(fee)),
        ]
        let priority = fee - BigUInt(SolanaLimits.lamportsPerSignature)
        if !priority.isZero { lines.append(PlanReview.Line("Inclui prioridade", SolanaAmountText.sol(priority))) }
        lines.append(PlanReview.Line("Total", SolanaAmountText.sol(lamports + fee)))
        lines.append(PlanReview.Line("Saldo depois", SolanaAmountText.sol(network.balance - lamports - fee)))

        let review = PlanReview(kind: .send, title: "Enviar \(SolanaAmountText.sol(lamports))", lines: lines, warnings: warnings, recipient: to.base58)
        return SigningPlan(walletID: walletID, chain: .solana, review: review, transactions: [transaction], createdAt: now)
    }

    /// A taxa de um envio de SOL com o estado dado, para a interface calcular o
    /// "enviar tudo" (saldo menos esta taxa deixa a conta zerada, o que e aceito).
    public static func sendSOLFee(network: SolanaNetworkState) throws -> BigUInt {
        let units = try computeUnits(network, default: solTransferComputeUnits)
        return networkFee(price: cappedPrice(network.suggestedComputeUnitPrice, units: units), units: units)
    }

    // MARK: Token SPL

    /// Planeja um envio de token SPL ou Token-2022.
    ///
    /// `destination` e o que existe no endereco digitado. Se for uma carteira (ou
    /// endereco novo), o token vai para o ATA dela, e `destinationTokenAccount` diz
    /// se esse ATA ja existe; se nao existir, a transacao o cria com
    /// CreateIdempotent e o dono paga `token.tokenAccountRentMinimum`. Se o endereco
    /// digitado ja for uma conta de token, ela e usada direto, depois de conferir
    /// mint e programa, e `destinationTokenAccount` e ignorado.
    ///
    /// `allowOffCurveOwner` so deve ser ligado quando o dono confirmou que o destino
    /// e uma conta de programa que recebe token (cofre multisig).
    public static func planSendToken(
        walletID: UUID, owner: SolanaOwner, to destinationText: String, amount: BigUInt, token: SolanaTokenState,
        destination: SolanaDestinationAccount, destinationTokenAccount: SolanaDestinationTokenAccount,
        allowOffCurveOwner: Bool = false, network: SolanaNetworkState, now: Date = .now
    ) throws -> SigningPlan {
        try checkOwner(owner)
        try checkFreshness(network, now: now)
        let to = try parseDestination(destinationText, owner: owner)
        guard to != token.mint else { throw SolanaPlanError.destinationIsMint }
        guard !amount.isZero else { throw SolanaPlanError.zeroAmount }
        guard let rawAmount = amount.uint64 else { throw SolanaPlanError.amountTooLarge }

        // Extensoes do mint: recusar o que tira o controle do dono ou faria o envio
        // falhar; avisar a taxa do emissor.
        var transferFee: (basisPoints: UInt16, maximumFee: BigUInt)?
        for ext in token.extensions {
            switch ext {
            case .permanentDelegate: throw SolanaPlanError.permanentDelegate
            case .transferHook: throw SolanaPlanError.transferHook
            case .nonTransferable: throw SolanaPlanError.nonTransferable
            case .paused: throw SolanaPlanError.tokenPaused
            case .unknown(let name): throw SolanaPlanError.unknownMintExtension(name)
            case .transferFee(let bps, let maximum): transferFee = (bps, maximum)
            case .defaultAccountStateFrozen: break  // so importa se a conta do destino for criada
            }
        }

        // A conta de origem tem de ser o ATA do dono para este mint e programa.
        let sourceAddress = try SolanaAssociatedToken.address(owner: owner.publicKey, mint: token.mint, tokenProgram: token.program)
        let source = token.source
        guard source.address == sourceAddress, source.mint == token.mint, source.owner == owner.publicKey,
              source.program == token.program
        else { throw SolanaPlanError.tokenAccountMismatch }
        guard !source.isFrozen else { throw SolanaPlanError.tokenAccountFrozen }
        guard source.amount >= amount else {
            throw SolanaPlanError.insufficientTokenBalance(needed: amount, available: source.amount)
        }

        var warnings = [PlanReview.Warning]()
        let recipientWallet: SolanaPublicKey
        let destinationAccount: SolanaPublicKey
        var createsAccount = false
        switch destination {
        case .tokenAccount(let account):
            // O dono colou uma conta de token: usar direto, nunca derivar o ATA dela.
            guard account.address == to, account.mint == token.mint, account.program == token.program else {
                throw SolanaPlanError.tokenAccountMismatch
            }
            guard !account.isFrozen else { throw SolanaPlanError.tokenAccountFrozen }
            recipientWallet = account.owner
            destinationAccount = to
        case .programOwned(let programOwner):
            throw SolanaPlanError.destinationOwnedByProgram(programOwner)
        case .nonexistent, .system:
            if !to.isOnCurve {
                guard allowOffCurveOwner else { throw SolanaPlanError.destinationOffCurve }
                warnings.append(.destinationIsContract)
            }
            let ata = try SolanaAssociatedToken.address(owner: to, mint: token.mint, tokenProgram: token.program, allowOwnerOffCurve: allowOffCurveOwner)
            switch destinationTokenAccount {
            case .missing:
                if token.extensions.contains(.defaultAccountStateFrozen) { throw SolanaPlanError.defaultAccountStateFrozen }
                createsAccount = true
            case .existing(let account):
                guard account.address == ata, account.mint == token.mint, account.owner == to, account.program == token.program else {
                    throw SolanaPlanError.tokenAccountMismatch
                }
                guard !account.isFrozen else { throw SolanaPlanError.tokenAccountFrozen }
            }
            recipientWallet = to
            destinationAccount = ata
        }
        guard recipientWallet != owner.publicKey, destinationAccount != sourceAddress else { throw SolanaPlanError.destinationIsOwner }

        let units = try computeUnits(network, default: tokenTransferComputeUnits(token.program, createsAccount: createsAccount))
        let price = cappedPrice(network.suggestedComputeUnitPrice, units: units)
        let fee = networkFee(price: price, units: units)
        let rent = createsAccount ? token.tokenAccountRentMinimum : BigUInt()
        try checkRemainder(balance: network.balance, fee: fee, spend: fee + rent, minimum: network.rentExemptMinimum)

        var instructions = [SolanaComputeBudgetInstruction.setComputeUnitLimit(units)]
        if price > 0 { instructions.append(SolanaComputeBudgetInstruction.setComputeUnitPrice(microLamports: price)) }
        var programs: Set<SolanaProgram> = [.computeBudget, token.program == .token ? .token : .token2022]
        if createsAccount {
            instructions.append(SolanaAssociatedTokenInstruction.createIdempotent(
                payer: owner.publicKey, associatedAccount: destinationAccount, owner: recipientWallet, mint: token.mint, tokenProgram: token.program
            ))
            programs.insert(.associatedToken)
        }
        instructions.append(SolanaTokenInstruction.transferChecked(
            tokenProgram: token.program, source: sourceAddress, mint: token.mint, destination: destinationAccount,
            owner: owner.publicKey, amount: rawAmount, decimals: token.decimals
        ))

        let transaction = try build(
            instructions: instructions, owner: owner, network: network,
            policy: SolanaVerificationPolicy(owner: owner.publicKey, allowedPrograms: programs, allowedRecipients: [destinationAccount])
        )

        let decimals = Int(token.decimals)
        var lines = [PlanReview.Line("Para", recipientWallet.base58, verbatim: true)]
        if case .tokenAccount = destination {
            lines.append(PlanReview.Line("Conta de token digitada", destinationAccount.base58, verbatim: true))
        } else {
            lines.append(PlanReview.Line("Conta de token do destino", destinationAccount.base58, verbatim: true))
        }
        lines.append(PlanReview.Line("Token", token.symbol))
        lines.append(PlanReview.Line("Mint", token.mint.base58, verbatim: true))
        lines.append(PlanReview.Line("Valor", SolanaAmountText.format(amount, decimals: decimals, symbol: token.symbol)))
        if let transferFee,
           case let withheld = issuerFee(amount: amount, basisPoints: transferFee.basisPoints, maximum: transferFee.maximumFee),
           !withheld.isZero {
            lines.append(PlanReview.Line("Taxa do emissor do token", SolanaAmountText.format(withheld, decimals: decimals, symbol: token.symbol)))
            lines.append(PlanReview.Line("O destino recebe", SolanaAmountText.format(amount - withheld, decimals: decimals, symbol: token.symbol)))
            warnings.append(.highFee(percentOfAmount: percent(withheld, of: amount)))
        }
        if createsAccount {
            lines.append(PlanReview.Line("Criação da conta de token do destino", SolanaAmountText.sol(rent)))
            warnings.append(.activatesAccount(minimum: SolanaAmountText.sol(rent)))
        }
        lines.append(PlanReview.Line("Taxa da rede", SolanaAmountText.sol(fee)))
        let priority = fee - BigUInt(SolanaLimits.lamportsPerSignature)
        if !priority.isZero { lines.append(PlanReview.Line("Inclui prioridade", SolanaAmountText.sol(priority))) }
        lines.append(PlanReview.Line("Saldo de SOL depois", SolanaAmountText.sol(network.balance - fee - rent)))
        if !token.isVerified { warnings.append(.unverifiedToken(symbol: token.symbol)) }

        let title = "Enviar \(SolanaAmountText.format(amount, decimals: decimals, symbol: token.symbol))"
        let review = PlanReview(kind: .send, title: title, lines: lines, warnings: warnings, recipient: recipientWallet.base58)
        return SigningPlan(walletID: walletID, chain: .solana, review: review, transactions: [transaction], createdAt: now)
    }

    /// A taxa que o Token-2022 retem: teto(valor * bps / 10000), limitada ao maximo
    /// (`TransferFee::calculate_fee`).
    public static func issuerFee(amount: BigUInt, basisPoints: UInt16, maximum: BigUInt) -> BigUInt {
        guard basisPoints > 0, !amount.isZero else { return BigUInt() }
        let raw = (amount * BigUInt(basisPoints) + BigUInt(9_999)) / BigUInt(10_000)
        return raw < maximum ? raw : maximum
    }

    // MARK: Conferencias comuns

    static func checkOwner(_ owner: SolanaOwner) throws {
        // SLIP-10 Ed25519 so deriva endurecido; um caminho com indice normal nunca
        // gera a chave que o dono espera.
        guard owner.path.isFullyHardened, !owner.path.components.isEmpty else { throw SolanaPlanError.signerPathNotHardened }
    }

    static func checkFreshness(_ network: SolanaNetworkState, now: Date) throws {
        let elapsed = now.timeIntervalSince(network.fetchedAt)
        // Alguns segundos de relogio adiantado sao tolerados; estado do futuro, nao.
        guard elapsed >= -5, elapsed <= maxStateAge else { throw SolanaPlanError.staleNetworkState }
        let passed = UInt64(max(0, elapsed) / secondsPerBlock)
        let (estimated, overflow) = network.currentBlockHeight.addingReportingOverflow(passed + minRemainingBlocks)
        guard !overflow, network.lastValidBlockHeight >= estimated else { throw SolanaPlanError.blockhashExpiring }
    }

    static func parseDestination(_ text: String, owner: SolanaOwner) throws -> SolanaPublicKey {
        switch Address.validate(text, for: .solana) {
        case .failure(let problem): throw SolanaPlanError.invalidDestination(problem)
        case .success(let destination):
            guard let key = try? SolanaPublicKey(base58: destination.address) else {
                throw SolanaPlanError.invalidDestination(.malformed)
            }
            guard key != owner.publicKey else { throw SolanaPlanError.destinationIsOwner }
            guard SolanaProgram(id: key) == nil else { throw SolanaPlanError.destinationIsKnownProgram }
            return key
        }
    }

    static func computeUnits(_ network: SolanaNetworkState, default fallback: UInt32) throws -> UInt32 {
        guard let simulated = network.simulatedComputeUnits else { return fallback }
        guard simulated > 0, simulated <= SolanaLimits.maxComputeUnitLimit else {
            throw SolanaPlanError.invalidComputeUnitLimit(simulated)
        }
        return simulated
    }

    /// O preco sugerido, limitado pelo teto por CU e depois pelo teto da taxa de
    /// prioridade da transacao inteira.
    static func cappedPrice(_ suggested: UInt64, units: UInt32) -> UInt64 {
        var price = min(suggested, SolanaLimits.maxComputeUnitPrice)
        if SolanaLimits.priorityFee(microLamportsPerUnit: price, units: units) > BigUInt(SolanaLimits.maxPriorityFeeLamports) {
            price = SolanaLimits.maxPriorityFeeLamports * 1_000_000 / UInt64(units)
        }
        return price
    }

    static func networkFee(price: UInt64, units: UInt32) -> BigUInt {
        BigUInt(SolanaLimits.lamportsPerSignature) + SolanaLimits.priorityFee(microLamportsPerUnit: price, units: units)
    }

    /// O saldo do dono depois da transacao tem de ser zero ou pelo menos o minimo
    /// de rent. O validador confere duas vezes: depois de cobrar a taxa (a conta nao
    /// pode passar de isenta para pagante) e no fim da execucao.
    static func checkRemainder(balance: BigUInt, fee: BigUInt, spend: BigUInt, minimum: BigUInt) throws {
        guard let remainder = balance.subtractingReportingUnderflow(spend) else {
            throw SolanaPlanError.insufficientFunds(needed: spend, available: balance)
        }
        guard remainder.isZero || remainder >= minimum else {
            throw SolanaPlanError.leavesBalanceBelowRent(remainder: remainder, minimum: minimum)
        }
        let afterFee = balance - fee
        guard afterFee.isZero || afterFee >= minimum else {
            throw SolanaPlanError.leavesBalanceBelowRent(remainder: afterFee, minimum: minimum)
        }
    }

    /// Compila, confere com o verificador e embrulha na transacao assinavel.
    static func build(
        instructions: [SolanaInstruction], owner: SolanaOwner, network: SolanaNetworkState, policy: SolanaVerificationPolicy
    ) throws -> SolanaTransaction {
        // Formato legado: cabe tudo que a carteira envia sem tabela de enderecos, e
        // o historico da conta fica legivel por RPC sem `maxSupportedTransactionVersion`.
        let message = try SolanaMessage.compileLegacy(payer: owner.publicKey, instructions: instructions, recentBlockhash: network.recentBlockhash)
        do {
            _ = try SolanaMessageVerifier.verify(message, policy: policy)
        } catch let error as SolanaVerificationError {
            throw SolanaPlanError.verificationFailed(error)
        }
        do {
            return try SolanaTransaction(
                message: message, signerPath: owner.path, signer: owner.publicKey, lastValidBlockHeight: network.lastValidBlockHeight
            )
        } catch SolanaTransactionProblem.tooLarge(let size) {
            throw SolanaPlanError.transactionTooLarge(size)
        }
    }

    /// Percentual so para exibicao (o aviso de taxa alta). Nunca entra na transacao.
    static func percent(_ part: BigUInt, of whole: BigUInt) -> Double {
        guard !whole.isZero else { return 0 }
        let basisPoints = (part * BigUInt(1_000_000)) / whole
        return Double(basisPoints.uint64 ?? UInt64.max) / 10_000
    }
}

/// Valores em texto para a revisao: virgula decimal, ponto de milhar, sem
/// arredondar, zeros a direita cortados. "1,5 SOL", "0,000005 SOL", "1.250 USDC".
/// Diferente do `Fmt.crypto` do app, nunca corta casas: a revisao mostra o valor
/// exato que vai na transacao, ate o ultimo lamport.
public enum SolanaAmountText {
    public static func sol(_ lamports: BigUInt) -> String {
        format(lamports, decimals: 9, symbol: "SOL")
    }

    public static func format(_ value: BigUInt, decimals: Int, symbol: String) -> String {
        let digits = value.decimalString
        guard decimals > 0 else { return "\(grouped(digits)) \(symbol)" }
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let integer = grouped(String(padded.dropLast(decimals)))
        var fraction = String(padded.suffix(decimals))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? "\(integer) \(symbol)" : "\(integer),\(fraction) \(symbol)"
    }

    /// Milhar com ponto, como no pt_BR: "1.234.567".
    static func grouped(_ digits: String) -> String {
        var out = ""
        for (index, c) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(".") }
            out.append(c)
        }
        return out
    }
}
