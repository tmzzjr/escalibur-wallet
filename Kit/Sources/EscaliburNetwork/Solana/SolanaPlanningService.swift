import EscaliburChains
import EscaliburCore
import Foundation

/// O caminho completo da Solana ate o `SigningPlan`, para o app chamar.
///
/// Le o estado publico, pede a proposta (troca), simula e entrega ao planejador de
/// EscaliburChains, que e quem valida e monta. Aqui nao ha regra de seguranca
/// nova: so a ordem das leituras. O plano volta sem assinatura; assinar e
/// transmitir sao passos separados (EscaliburKeys e `SolanaBroadcaster`).
public actor SolanaPlanningService {
    public static let shared = SolanaPlanningService()

    let reader: SolanaNetworkReader
    let jupiter: JupiterClient

    public init(reader: SolanaNetworkReader = .shared, jupiter: JupiterClient = .shared) {
        self.reader = reader
        self.jupiter = jupiter
    }

    // MARK: Envio

    /// Envio de SOL: le destino e estado, planeja, simula para medir o CU e planeja
    /// de novo com o consumo medido. Simulacao que diz que a transacao falharia
    /// bloqueia; simulacao indisponivel nao bloqueia envio simples
    /// (docs/seguranca.md §4.9), e vale o limite padrao.
    public func planSendSOL(walletID: UUID, owner: SolanaOwner, to destination: String, lamports: BigUInt) async throws -> SigningPlan {
        let key = try? SolanaPublicKey(base58: destination)
        let account: SolanaDestinationAccount = if let key { try await reader.destinationAccount(key) } else { .nonexistent }
        let state = try await reader.networkState(owner: owner.publicKey, writableAccounts: key.map { [$0] } ?? [])
        let first = try SolanaPlanner.planSendSOL(walletID: walletID, owner: owner, to: destination, lamports: lamports, destination: account, network: state)
        guard let units = try await measure(first) else { return first }
        return try SolanaPlanner.planSendSOL(
            walletID: walletID, owner: owner, to: destination, lamports: lamports, destination: account, network: state.withSimulatedComputeUnits(units)
        )
    }

    /// Envio de token: mint e conta de origem, o que existe no destino e, se for
    /// carteira, o ATA dela.
    public func planSendToken(
        walletID: UUID, owner: SolanaOwner, to destination: String, mint: SolanaPublicKey, amount: BigUInt, allowOffCurveOwner: Bool = false
    ) async throws -> SigningPlan {
        let token = try await reader.tokenState(owner: owner.publicKey, mint: mint)
        let key = try? SolanaPublicKey(base58: destination)
        let account: SolanaDestinationAccount = if let key { try await reader.destinationAccount(key) } else { .nonexistent }
        var tokenAccount = SolanaDestinationTokenAccount.missing
        var writable = [token.source.address]
        if let key {
            switch account {
            case .nonexistent, .system:
                if key.isOnCurve || allowOffCurveOwner {
                    tokenAccount = try await reader.destinationTokenAccount(owner: key, mint: mint, program: token.program, allowOwnerOffCurve: allowOffCurveOwner)
                    if case .existing(let state) = tokenAccount { writable.append(state.address) }
                }
            case .tokenAccount(let state):
                writable.append(state.address)
            case .programOwned:
                break
            }
        }
        let state = try await reader.networkState(owner: owner.publicKey, writableAccounts: writable)
        func plan(_ network: SolanaNetworkState) throws -> SigningPlan {
            try SolanaPlanner.planSendToken(
                walletID: walletID, owner: owner, to: destination, amount: amount, token: token, destination: account,
                destinationTokenAccount: tokenAccount, allowOffCurveOwner: allowOffCurveOwner, network: network
            )
        }
        let first = try plan(state)
        guard let units = try await measure(first) else { return first }
        return try plan(state.withSimulatedComputeUnits(units))
    }

    /// Consumo simulado * 1,1 da transacao do plano. nil se a simulacao nao estava
    /// disponivel; erro se ela disse que a transacao falharia.
    func measure(_ plan: SigningPlan) async throws -> UInt32? {
        guard let transaction = plan.transactions.first as? SolanaTransaction else { return nil }
        let outcome: SolanaSimulationOutcome
        do {
            outcome = try await reader.simulate(transaction.message)
        } catch {
            return nil
        }
        guard outcome.succeeded else { throw SolanaSimulationFailure(error: outcome.error ?? "", logs: outcome.logs) }
        return outcome.suggestedComputeUnitLimit
    }

    // MARK: Troca

    /// Cotacao para a tela (antes de o dono decidir). Nada daqui vai para a transacao.
    public func quoteSwap(sellMint: SolanaPublicKey, buyMint: SolanaPublicKey, amountIn: UInt64, slippageBps: UInt16) async throws -> SolanaSwapQuote {
        try await jupiter.quote(inputMint: sellMint, outputMint: buyMint, amount: amountIn, slippageBps: slippageBps)
    }

    /// Troca pela Jupiter ate o `SigningPlan`: proposta (`/build`), tabelas lidas de
    /// dois RPCs, contas e estado, rascunho validado, simulacao e plano. Se a
    /// mensagem nao couber num pacote, pede rota com menos contas.
    /// `sellMint`/`buyMint` com o mint do SOL embrulhado significam SOL.
    ///
    /// `reference`: o preco de mercado de fora da Jupiter. O planejador recusa o par sem
    /// ele (fora dois stablecoins da lista) e a cotacao mais de 5% pior que ele.
    public func planSwap(
        walletID: UUID, owner: SolanaOwner, sellMint: SolanaPublicKey, buyMint: SolanaPublicKey, amountIn: BigUInt, slippageBps: UInt16,
        minimumOutShown: BigUInt? = nil, reference: TradeMarketReference = .none
    ) async throws -> SigningPlan {
        let sell = try await reader.swapAsset(mint: sellMint)
        let buy = try await reader.swapAsset(mint: buyMint)
        let intent = SolanaSwapIntent(
            sell: sell, buy: buy, amountIn: amountIn, slippageBps: slippageBps, minimumOutShown: minimumOutShown, reference: reference
        )
        guard let amount = amountIn.uint64 else { throw SolanaSwapError.amountTooLarge }
        let accounts = try await reader.swapAccounts(owner: owner.publicKey, sell: sell, buy: buy)
        var lastError: Error = SolanaSwapError.plan(.transactionTooLarge(0))
        for maxAccounts in [nil, 40, 28] as [Int?] {
            let draft: SolanaSwapDraft
            do {
                draft = try await self.draft(walletID: walletID, owner: owner, intent: intent, amount: amount, accounts: accounts, maxAccounts: maxAccounts)
            } catch SolanaSwapError.plan(.transactionTooLarge(let size)) {
                lastError = SolanaSwapError.plan(.transactionTooLarge(size))
                continue
            }
            let simulation = try await reader.simulate(draft.message, accounts: draft.simulationAccounts)
            return try SolanaSwapPlanner.plan(draft, simulation: simulation)
        }
        throw lastError
    }

    /// Proposta, tabelas, estado e rascunho. Separado para o teste ao vivo poder
    /// parar antes da simulacao.
    public func draft(
        walletID: UUID, owner: SolanaOwner, intent: SolanaSwapIntent, amount: UInt64, accounts: SolanaSwapAccounts, maxAccounts: Int? = nil
    ) async throws -> SolanaSwapDraft {
        let proposal = try await jupiter.build(
            inputMint: intent.sell.mint, outputMint: intent.buy.mint, amount: amount, slippageBps: intent.slippageBps, taker: owner.publicKey,
            maxAccounts: maxAccounts
        )
        let tables = try await reader.lookupTables(proposal.lookupTableAddresses)
        let writable = proposal.swapInstruction.accounts.filter(\.isWritable).map(\.publicKey)
        let state = try await reader.networkState(owner: owner.publicKey, writableAccounts: writable)
        return try SolanaSwapPlanner.draft(
            walletID: walletID, owner: owner, intent: intent, proposal: proposal, lookupTables: tables, accounts: accounts, network: state
        )
    }
}
