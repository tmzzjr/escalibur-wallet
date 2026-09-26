import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// As respostas gravadas em Fixtures/solana (origem de cada uma no LEIA-ME.txt),
/// lidas pelos mesmos decodificadores do modulo de rede.
enum SolanaEngineFixtures {
    static let toly = key("86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY")
    static let exchange = key("5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9")
    static let nova = key("5tFUx2GVxip3kMhdwHG1yPGP2gYMzAikagio3GgyLAZZ")
    static let usdcMint = key("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
    static let tolyUSDC = key("9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38")
    static let exchangeUSDC = key("FzbcyEZ9m8xjtergWgWDq7mfPoHEbboBF791B6cTpzbq")

    static let sol = Asset.native(.solana)
    static let usdc = TokenRegistry.tokens.first { $0.chainID == "solana" && $0.symbol == "USDC" }!
    static let usdt = TokenRegistry.tokens.first { $0.chainID == "solana" && $0.symbol == "USDT" }!

    static func key(_ text: String) -> SolanaPublicKey { try! SolanaPublicKey(base58: text) }

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solana"))
        return try Data(contentsOf: url)
    }

    static func rpc<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try SolanaRPC.decode(try data(name), method: name, as: T.self)
    }

    // MARK: Contas

    /// O que existe em cada endereco gravado, lido pelo parser do leitor.
    static func recordedAccounts() throws -> [SolanaPublicKey: SolanaDestinationAccount] {
        let files: [(String, SolanaPublicKey)] = [
            ("conta-toly", toly), ("conta-exchange", exchange), ("conta-nova", nova), ("conta-usdc-toly", tolyUSDC),
            ("conta-usdc-exchange", exchangeUSDC), ("conta-mint-usdc", usdcMint), ("conta-jupiter", SolanaProgramID.jupiterV6),
        ]
        var accounts = [SolanaPublicKey: SolanaDestinationAccount]()
        for (name, address) in files {
            let value = try rpc(name, as: RPCContextualOptional<RPCAccount>.self).value
            accounts[address] = try SolanaAccountParser.destination(value, address: address)
        }
        return accounts
    }

    static func tokenAccount(_ name: String, address: SolanaPublicKey) throws -> SolanaTokenAccountState {
        let value = try #require(try rpc(name, as: RPCContextualOptional<RPCAccount>.self).value)
        return try SolanaAccountParser.tokenAccount(value, address: address, program: .token)
    }

    static func usdcMintInfo() throws -> SolanaMintInfo {
        try SolanaAccountParser.mint(fromResponse: try data("conta-mint-usdc"), address: usdcMint)
    }

    static func rent(_ name: String) throws -> BigUInt { BigUInt(try rpc(name, as: UInt64.self)) }

    /// O USDC do toly, montado como `SolanaNetworkReader.tokenState` monta.
    static func tolyUSDCState(decimals: UInt8? = nil) throws -> SolanaTokenState {
        let mint = try usdcMintInfo()
        let read = decimals ?? mint.decimals
        return SolanaTokenState(
            mint: usdcMint, program: mint.program, decimals: read, symbol: "USDC", isVerified: Int(read) == usdc.decimals,
            extensions: mint.extensions, source: try tokenAccount("conta-usdc-toly", address: tolyUSDC),
            tokenAccountRentMinimum: try rent("rpc-rent-165")
        )
    }

    // MARK: Estado

    /// O estado gravado (blockhash, altura, rent, prioridade), lido agora: a idade do
    /// estado e o que o planejador confere, e aqui ela e zero.
    static func state(balance: BigUInt, now: Date = .now) throws -> SolanaNetworkState {
        let blockhash = try rpc("rpc-blockhash", as: RPCContextual<RPCBlockhash>.self).value
        let epoch = try rpc("rpc-epoca", as: RPCEpochInfo.self)
        let fees = try rpc("rpc-prioridade", as: [RPCPrioritizationFee].self).map(\.prioritizationFee)
        return SolanaNetworkState(
            recentBlockhash: try SolanaBlockhash(base58: blockhash.blockhash), lastValidBlockHeight: blockhash.lastValidBlockHeight,
            currentBlockHeight: epoch.blockHeight, fetchedAt: now, balance: balance, rentExemptMinimum: try rent("rpc-rent-0"),
            suggestedComputeUnitPrice: SolanaAccountParser.priorityFee(fees, percentile: 75)
        )
    }

    static func recordedBalance() throws -> BigUInt {
        BigUInt(try rpc("rpc-saldo-toly", as: RPCContextual<UInt64>.self).value)
    }

    static func lastValidBlockHeight() throws -> UInt64 {
        try rpc("rpc-blockhash", as: RPCContextual<RPCBlockhash>.self).value.lastValidBlockHeight
    }

    // MARK: Troca

    static func proposal(_ name: String) throws -> SolanaSwapProposal {
        try SolanaSwapProposal.decodeJupiterBuild(try data(name))
    }

    static func tables() throws -> [SolanaAddressLookupTable] {
        struct File: Decodable { let tables: [String: [String]] }
        let file = try JSONDecoder().decode(File.self, from: try data("tabelas"))
        return try file.tables.map { address, keys in
            SolanaAddressLookupTable(address: try SolanaPublicKey(base58: address), addresses: try keys.map { try SolanaPublicKey(base58: $0) })
        }
    }

    static func usdcSwapAsset(decimals: UInt8? = nil) throws -> SolanaSwapAsset {
        let mint = try usdcMintInfo()
        let read = decimals ?? mint.decimals
        return SolanaSwapAsset(mint: usdcMint, program: mint.program, decimals: read, symbol: "USDC", isVerified: Int(read) == usdc.decimals, extensions: mint.extensions)
    }

    // MARK: Historico e status

    static func activity(_ name: String, owner: SolanaPublicKey, status: String = "finalized") throws -> SolanaActivity {
        try #require(try SolanaActivityParser.activity(transactionResponse: try data(name), owner: owner, confirmationStatus: status))
    }

    /// As tres linhas gravadas de `getSignatureStatuses`: finalizada, falha, desconhecida.
    static func statuses() throws -> [SolanaSignatureStatus?] {
        try rpc("rpc-status", as: RPCContextual<[RPCSignatureStatus?]>.self).value.map { $0.map(SolanaSignatureStatus.init) }
    }

    // MARK: Contas do dono

    /// A conta como os metadados guardam: so dado publico.
    static func account(_ key: SolanaPublicKey) -> DerivedAccount {
        DerivedAccount(chainID: Chain.solana.id, path: DefaultPaths.path(for: .solana), address: key.base58, publicKey: key.bytes, accountXPub: nil)
    }

    /// Chave de teste da semente 0x5E repetida, a mesma das propostas gravadas da
    /// Jupiter. So existe nos testes, para assinar como o EscaliburKeys assinaria e
    /// reler o resultado.
    static func testSeed() -> SecureBytes {
        let seed = SecureBytes(capacity: 32)
        seed.replaceAll(with: [UInt8](repeating: 0x5E, count: 32))
        return seed
    }

    static func testKey() throws -> SolanaPublicKey {
        let seed = testSeed()
        defer { seed.wipe() }
        return try SolanaPublicKey(bytes: try Ed25519.publicKey(of: seed))
    }

    static func sign(_ plan: SigningPlan) throws -> SignedTransaction {
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        let request = try #require(transaction.signingRequests.first)
        let seed = testSeed()
        defer { seed.wipe() }
        let signature = try Ed25519.sign(request.payload, seed: seed)
        return try transaction.assemble(with: [ProducedSignature(bytes: signature)])
    }
}

/// A rede gravada: responde com as fixtures e entrega a montagem aos planejadores de
/// verdade (`SolanaPlanner`, `SolanaSwapPlanner`), na mesma ordem do
/// `SolanaPlanningService`. Registra o que o motor pediu, para o teste conferir.
actor RecordedSolanaNetwork: SolanaEngineNetwork {
    private typealias F = SolanaEngineFixtures

    var accounts: [SolanaPublicKey: SolanaDestinationAccount]
    var balance: BigUInt
    var tokenStates: [SolanaPublicKey: SolanaTokenState] = [:]
    var swapAssets: [SolanaPublicKey: SolanaSwapAsset] = [:]
    var swapAccountsValue: SolanaSwapAccounts?
    var proposals: [String: SolanaSwapProposal] = [:]
    /// Propostas que o plano recebe antes das gravadas, uma por pedido.
    var planProposals: [SolanaSwapProposal] = []
    var tables: [SolanaAddressLookupTable] = []
    /// Na primeira proposta, as tabelas chegam vazias: a mensagem nao cabe num pacote.
    var tablesTooSmallOnFirstProposal = false
    var recentStatuses: [String: SolanaSignatureStatus] = [:]
    var historyStatuses: [String: SolanaSignatureStatus] = [:]
    var statusFails = false
    var height: UInt64 = 0
    var sendError: (any Error)?
    var activities: [SolanaActivity] = []

    private(set) var sent: [SignedTransaction] = []
    private(set) var plannedLamports: [BigUInt] = []
    private(set) var shownMinimums: [BigUInt] = []
    private(set) var requestedRouteLimits: [Int?] = []
    private(set) var statusQueries: [Bool] = []

    init(balance: BigUInt) throws {
        self.accounts = try F.recordedAccounts()
        self.balance = balance
    }

    // MARK: Ajustes do teste

    func setBalance(_ value: BigUInt) { balance = value }
    func setAccount(_ address: SolanaPublicKey, _ account: SolanaDestinationAccount) { accounts[address] = account }
    func setTokenState(_ state: SolanaTokenState) { tokenStates[state.mint] = state }
    func setSwapAsset(_ asset: SolanaSwapAsset) { swapAssets[asset.mint] = asset }
    func setSwapAccounts(_ value: SolanaSwapAccounts) { swapAccountsValue = value }
    func setProposal(_ proposal: SolanaSwapProposal) { proposals[Self.pair(proposal.inputMint, proposal.outputMint)] = proposal }
    func queuePlanProposals(_ value: [SolanaSwapProposal]) { planProposals = value }
    func setTables(_ value: [SolanaAddressLookupTable]) { tables = value }
    func setTablesTooSmallOnFirstProposal() { tablesTooSmallOnFirstProposal = true }
    func setStatus(_ id: String, recent: SolanaSignatureStatus?, history: SolanaSignatureStatus?) {
        recentStatuses[id] = recent
        historyStatuses[id] = history
    }
    func setStatusFails(_ value: Bool) { statusFails = value }
    func setHeight(_ value: UInt64) { height = value }
    func setSendError(_ error: (any Error)?) { sendError = error }
    func setActivities(_ value: [SolanaActivity]) { activities = value }

    static func pair(_ sell: SolanaPublicKey, _ buy: SolanaPublicKey) -> String { sell.base58 + ">" + buy.base58 }

    // MARK: Leitura

    func destinationAccount(_ address: SolanaPublicKey) async throws -> SolanaDestinationAccount {
        accounts[address] ?? .nonexistent
    }

    func destinationTokenAccount(owner: SolanaPublicKey, mint: SolanaPublicKey, program: SolanaTokenProgram) async throws -> SolanaDestinationTokenAccount {
        let ata = try SolanaAssociatedToken.address(owner: owner, mint: mint, tokenProgram: program)
        guard case .tokenAccount(let state) = accounts[ata] else { return .missing }
        return .existing(state)
    }

    func emptyAccountRentMinimum() async throws -> BigUInt { try F.rent("rpc-rent-0") }

    func networkState(owner: SolanaPublicKey, writableAccounts: [SolanaPublicKey]) async throws -> SolanaNetworkState {
        try F.state(balance: balance)
    }

    func tokenState(owner: SolanaPublicKey, mint: SolanaPublicKey) async throws -> SolanaTokenState {
        guard let state = tokenStates[mint] else { throw SolanaAccountParseError.notATokenAccount }
        return state
    }

    // MARK: Envio

    func planSendSOL(walletID: UUID, owner: SolanaOwner, to destination: String, lamports: BigUInt) async throws -> SigningPlan {
        plannedLamports.append(lamports)
        let account = (try? SolanaPublicKey(base58: destination)).flatMap { accounts[$0] } ?? .nonexistent
        return try SolanaPlanner.planSendSOL(
            walletID: walletID, owner: owner, to: destination, lamports: lamports, destination: account, network: try F.state(balance: balance)
        )
    }

    func planSendToken(walletID: UUID, owner: SolanaOwner, to destination: String, mint: SolanaPublicKey, amount: BigUInt) async throws -> SigningPlan {
        let token = try await tokenState(owner: owner.publicKey, mint: mint)
        let key = try? SolanaPublicKey(base58: destination)
        let account = key.flatMap { accounts[$0] } ?? .nonexistent
        var tokenAccount = SolanaDestinationTokenAccount.missing
        if let key, key.isOnCurve {
            switch account {
            case .nonexistent, .system: tokenAccount = try await destinationTokenAccount(owner: key, mint: mint, program: token.program)
            case .tokenAccount, .programOwned: break
            }
        }
        return try SolanaPlanner.planSendToken(
            walletID: walletID, owner: owner, to: destination, amount: amount, token: token, destination: account,
            destinationTokenAccount: tokenAccount, network: try F.state(balance: balance)
        )
    }

    // MARK: Troca

    func swapAsset(mint: SolanaPublicKey) async throws -> SolanaSwapAsset {
        if mint == SolanaWrappedSOL.mint { return .sol }
        guard let asset = swapAssets[mint] else { throw SolanaAccountParseError.notAMint(owner: "") }
        return asset
    }

    func swapAccounts(owner: SolanaPublicKey, sell: SolanaSwapAsset, buy: SolanaSwapAsset) async throws -> SolanaSwapAccounts {
        guard let value = swapAccountsValue else { throw SolanaAccountParseError.notATokenAccount }
        return value
    }

    func swapProposal(
        sellMint: SolanaPublicKey, buyMint: SolanaPublicKey, amount: UInt64, slippageBps: UInt16, taker: SolanaPublicKey, maxAccounts: Int?
    ) async throws -> SolanaSwapProposal {
        requestedRouteLimits.append(maxAccounts)
        guard let proposal = proposals[Self.pair(sellMint, buyMint)] else { throw SolanaSwapProposalError.malformed("sem gravacao") }
        return proposal
    }

    /// Tabela sem gravacao responde como o leitor sem dois RPCs concordando.
    func lookupTables(_ addresses: [SolanaPublicKey]) async throws -> [SolanaAddressLookupTable] {
        try addresses.map { address in
            guard let table = tables.first(where: { $0.address == address }) else { throw ConsensusFailure(answers: 1) }
            if tablesTooSmallOnFirstProposal && requestedRouteLimits.count == 1 { return SolanaAddressLookupTable(address: address, addresses: []) }
            return table
        }
    }

    func planSwap(
        walletID: UUID, owner: SolanaOwner, sellMint: SolanaPublicKey, buyMint: SolanaPublicKey, amountIn: BigUInt, slippageBps: UInt16,
        minimumOutShown: BigUInt
    ) async throws -> SigningPlan {
        shownMinimums.append(minimumOutShown)
        let intent = SolanaSwapIntent(
            sell: try await swapAsset(mint: sellMint), buy: try await swapAsset(mint: buyMint), amountIn: amountIn, slippageBps: slippageBps,
            minimumOutShown: minimumOutShown
        )
        let queued = planProposals.isEmpty ? nil : planProposals.removeFirst()
        guard let proposal = queued ?? proposals[Self.pair(sellMint, buyMint)], let accounts = swapAccountsValue else {
            throw SolanaSwapProposalError.malformed("sem gravacao")
        }
        let draft = try SolanaSwapPlanner.draft(
            walletID: walletID, owner: owner, intent: intent, proposal: proposal, lookupTables: tables, accounts: accounts,
            network: try F.state(balance: balance)
        )
        return try SolanaSwapPlanner.plan(draft, simulation: Self.honestSimulation(draft))
    }

    /// Uma simulacao que mostra exatamente o que a rota promete nas contas do dono.
    static func honestSimulation(_ draft: SolanaSwapDraft) -> SolanaSimulationOutcome {
        let owner = draft.owner.publicKey
        let intent = draft.intent
        let minimum = draft.route.minimumOut
        var lamports = draft.network.balance.uint64! - SolanaLimits.lamportsPerSignature
        if intent.sell.isNativeSOL { lamports -= intent.amountIn.uint64! }
        if intent.buy.isNativeSOL { lamports += minimum }
        var accounts = [SolanaAccountSnapshot(address: owner, exists: true, lamports: lamports, programOwner: SolanaProgramID.system)]
        if let source = draft.accounts.source {
            accounts.append(SolanaAccountSnapshot(
                address: source.address, exists: true, lamports: 2_039_280, programOwner: SolanaProgramID.token,
                tokenMint: intent.sell.mint, tokenOwner: owner, tokenAmount: source.amount.uint64! - intent.amountIn.uint64!
            ))
        }
        if !intent.buy.isNativeSOL {
            var previous: UInt64 = 0
            if case .existing(let state) = draft.accounts.destination { previous = state.amount.uint64! }
            accounts.append(SolanaAccountSnapshot(
                address: draft.destinationAccount, exists: true, lamports: 2_039_280, programOwner: SolanaProgramID.token,
                tokenMint: intent.buy.mint, tokenOwner: owner, tokenAmount: previous + minimum
            ))
        }
        return SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: accounts)
    }

    // MARK: Transmissao

    func send(_ signed: SignedTransaction) async throws -> SolanaBroadcastReceipt {
        sent.append(signed)
        if let sendError { throw sendError }
        return SolanaBroadcastReceipt(signature: signed.id, acceptedBy: ["gravado"], rejections: [:])
    }

    func signatureStatus(_ signature: String, searchHistory: Bool) async throws -> SolanaSignatureStatus? {
        statusQueries.append(searchHistory)
        if statusFails { throw HTTPClient.Failure.timeout }
        return searchHistory ? (historyStatuses[signature] ?? recentStatuses[signature]) : recentStatuses[signature]
    }

    func blockHeight() async throws -> UInt64 { height }

    // MARK: Historico

    func recentActivity(owner: SolanaPublicKey, limit: Int) async throws -> [SolanaActivity] { Array(activities.prefix(limit)) }
}
