import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O que os motores da Solana pedem a rede.
///
/// Cada metodo e um repasse para o modulo de rede (`SolanaNetworkReader`,
/// `SolanaPlanningService`, `JupiterClient`, `SolanaBroadcaster`,
/// `SolanaHistoryReader`), sem regra propria: validar e montar continua com os
/// planejadores de EscaliburChains. O protocolo existe para os testes trocarem a
/// rede por respostas gravadas; em producao so existe `SolanaLiveNetwork`.
protocol SolanaEngineNetwork: Sendable {
    // MARK: Leitura

    func destinationAccount(_ address: SolanaPublicKey) async throws -> SolanaDestinationAccount
    func destinationTokenAccount(owner: SolanaPublicKey, mint: SolanaPublicKey, program: SolanaTokenProgram) async throws -> SolanaDestinationTokenAccount
    /// `getMinimumBalanceForRentExemption(0)`: o minimo de uma conta de sistema.
    func emptyAccountRentMinimum() async throws -> BigUInt
    func networkState(owner: SolanaPublicKey, writableAccounts: [SolanaPublicKey]) async throws -> SolanaNetworkState
    func tokenState(owner: SolanaPublicKey, mint: SolanaPublicKey) async throws -> SolanaTokenState

    // MARK: Envio

    func planSendSOL(walletID: UUID, owner: SolanaOwner, to destination: String, lamports: BigUInt) async throws -> SigningPlan
    func planSendToken(walletID: UUID, owner: SolanaOwner, to destination: String, mint: SolanaPublicKey, amount: BigUInt) async throws -> SigningPlan

    // MARK: Troca

    func swapAsset(mint: SolanaPublicKey) async throws -> SolanaSwapAsset
    func swapAccounts(owner: SolanaPublicKey, sell: SolanaSwapAsset, buy: SolanaSwapAsset) async throws -> SolanaSwapAccounts
    /// A proposta do `/swap/v2/build`, ainda sem nenhuma confianca.
    func swapProposal(
        sellMint: SolanaPublicKey, buyMint: SolanaPublicKey, amount: UInt64, slippageBps: UInt16, taker: SolanaPublicKey, maxAccounts: Int?
    ) async throws -> SolanaSwapProposal
    /// Cada tabela lida de dois RPCs que concordam.
    func lookupTables(_ addresses: [SolanaPublicKey]) async throws -> [SolanaAddressLookupTable]
    func planSwap(
        walletID: UUID, owner: SolanaOwner, sellMint: SolanaPublicKey, buyMint: SolanaPublicKey, amountIn: BigUInt, slippageBps: UInt16,
        minimumOutShown: BigUInt, reference: TradeMarketReference
    ) async throws -> SigningPlan

    // MARK: Transmissao e acompanhamento

    func send(_ signed: SignedTransaction) async throws -> SolanaBroadcastReceipt
    func signatureStatus(_ signature: String, searchHistory: Bool) async throws -> SolanaSignatureStatus?
    func blockHeight() async throws -> UInt64

    // MARK: Historico

    func recentActivity(owner: SolanaPublicKey, limit: Int) async throws -> [SolanaActivity]
}

/// A rede de verdade: as instancias compartilhadas do modulo de rede. O
/// `JupiterClient` e o mesmo do `SolanaPlanningService`, para o espacamento de
/// chamadas sem chave valer para a cotacao e para o plano juntos.
struct SolanaLiveNetwork: SolanaEngineNetwork {
    let reader: SolanaNetworkReader
    let planning: SolanaPlanningService
    let jupiter: JupiterClient
    let broadcaster: SolanaBroadcaster
    let history: SolanaHistoryReader

    init(
        reader: SolanaNetworkReader = .shared, planning: SolanaPlanningService = .shared, jupiter: JupiterClient = .shared,
        broadcaster: SolanaBroadcaster = .shared, history: SolanaHistoryReader = .shared
    ) {
        self.reader = reader
        self.planning = planning
        self.jupiter = jupiter
        self.broadcaster = broadcaster
        self.history = history
    }

    func destinationAccount(_ address: SolanaPublicKey) async throws -> SolanaDestinationAccount {
        try await reader.destinationAccount(address)
    }

    func destinationTokenAccount(owner: SolanaPublicKey, mint: SolanaPublicKey, program: SolanaTokenProgram) async throws -> SolanaDestinationTokenAccount {
        try await reader.destinationTokenAccount(owner: owner, mint: mint, program: program)
    }

    func emptyAccountRentMinimum() async throws -> BigUInt {
        try await reader.rentExemptMinimum(dataSize: 0)
    }

    func networkState(owner: SolanaPublicKey, writableAccounts: [SolanaPublicKey]) async throws -> SolanaNetworkState {
        try await reader.networkState(owner: owner, writableAccounts: writableAccounts)
    }

    func tokenState(owner: SolanaPublicKey, mint: SolanaPublicKey) async throws -> SolanaTokenState {
        try await reader.tokenState(owner: owner, mint: mint)
    }

    func planSendSOL(walletID: UUID, owner: SolanaOwner, to destination: String, lamports: BigUInt) async throws -> SigningPlan {
        try await planning.planSendSOL(walletID: walletID, owner: owner, to: destination, lamports: lamports)
    }

    func planSendToken(walletID: UUID, owner: SolanaOwner, to destination: String, mint: SolanaPublicKey, amount: BigUInt) async throws -> SigningPlan {
        // Destino fora da curva (conta de programa) fica recusado: o contrato de envio
        // nao tem como o dono confirmar que aquela conta recebe token.
        try await planning.planSendToken(walletID: walletID, owner: owner, to: destination, mint: mint, amount: amount, allowOffCurveOwner: false)
    }

    func swapAsset(mint: SolanaPublicKey) async throws -> SolanaSwapAsset {
        try await reader.swapAsset(mint: mint)
    }

    func swapAccounts(owner: SolanaPublicKey, sell: SolanaSwapAsset, buy: SolanaSwapAsset) async throws -> SolanaSwapAccounts {
        try await reader.swapAccounts(owner: owner, sell: sell, buy: buy)
    }

    func swapProposal(
        sellMint: SolanaPublicKey, buyMint: SolanaPublicKey, amount: UInt64, slippageBps: UInt16, taker: SolanaPublicKey, maxAccounts: Int?
    ) async throws -> SolanaSwapProposal {
        try await jupiter.build(inputMint: sellMint, outputMint: buyMint, amount: amount, slippageBps: slippageBps, taker: taker, maxAccounts: maxAccounts)
    }

    func lookupTables(_ addresses: [SolanaPublicKey]) async throws -> [SolanaAddressLookupTable] {
        try await reader.lookupTables(addresses)
    }

    func planSwap(
        walletID: UUID, owner: SolanaOwner, sellMint: SolanaPublicKey, buyMint: SolanaPublicKey, amountIn: BigUInt, slippageBps: UInt16,
        minimumOutShown: BigUInt, reference: TradeMarketReference
    ) async throws -> SigningPlan {
        try await planning.planSwap(
            walletID: walletID, owner: owner, sellMint: sellMint, buyMint: buyMint, amountIn: amountIn, slippageBps: slippageBps,
            minimumOutShown: minimumOutShown, reference: reference
        )
    }

    func send(_ signed: SignedTransaction) async throws -> SolanaBroadcastReceipt {
        try await broadcaster.send(signed)
    }

    func signatureStatus(_ signature: String, searchHistory: Bool) async throws -> SolanaSignatureStatus? {
        try await broadcaster.status(of: signature, searchHistory: searchHistory)
    }

    func blockHeight() async throws -> UInt64 {
        try await reader.blockHeight()
    }

    func recentActivity(owner: SolanaPublicKey, limit: Int) async throws -> [SolanaActivity] {
        try await history.recentActivity(owner: owner, limit: limit)
    }
}
