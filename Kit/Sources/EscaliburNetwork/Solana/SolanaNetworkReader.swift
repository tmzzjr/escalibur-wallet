import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura do estado da Solana que os planejadores precisam, so dados publicos.
///
/// Cada leitura vai ao primeiro provedor que responde, com contingencia pelo
/// `ProviderPool`. As tabelas de enderecos, que trocariam o destino de uma troca sem
/// mudar um byte da mensagem, vem de dois RPCs concordando (docs/seguranca.md §5.5).
/// Consulta endereco por endereco; nada de chave, frase ou caminho passa por aqui.
public actor SolanaNetworkReader {
    public static let shared = SolanaNetworkReader()

    /// Blockhash com mais folga que isto ate vencer indica altura de bloco errada
    /// (o blockhash vale ~150 blocos).
    static let maxBlockhashWindow: UInt64 = 300

    let client: HTTPClient
    let pool: ProviderPool

    public init(client: HTTPClient = .shared, providers: [ProviderPool.Provider] = Endpoints.solana) {
        self.client = client
        self.pool = ProviderPool(providers)
    }

    // MARK: Chamadas

    func call<T: Decodable & Sendable>(_ method: String, _ params: [JSONValue], as type: T.Type = T.self) async throws -> T {
        let client = self.client
        return try await pool.first { provider in
            try await SolanaRPC.call(provider.baseURL, method, params, as: T.self, client: client)
        }
    }

    func accountInfo(_ address: SolanaPublicKey, encoding: String = "jsonParsed") async throws -> RPCAccount? {
        let result: RPCContextualOptional<RPCAccount> = try await call(
            "getAccountInfo", [.string(address.base58), .object(["encoding": .string(encoding), "commitment": .string("confirmed")])]
        )
        return result.value
    }

    // MARK: Estado para uma transacao

    /// Blockhash e `lastValidBlockHeight`, altura de bloco, saldo, rent minimo de
    /// uma conta vazia e o preco de prioridade (percentil 50 a 75 de
    /// `getRecentPrioritizationFees` sobre as contas gravaveis).
    ///
    /// A altura vem de `getEpochInfo` do MESMO no que deu o blockhash, e a janela e
    /// conferida: em 26/09/2026 um dos provedores publicos devolvia o slot no lugar
    /// da altura em `getBlockHeight` com `commitment`, o que faria todo blockhash
    /// parecer vencido (ou, ao contrario, eterno).
    public func networkState(
        owner: SolanaPublicKey, writableAccounts: [SolanaPublicKey] = [], feePercentile: Int = 75, simulatedComputeUnits: UInt32? = nil
    ) async throws -> SolanaNetworkState {
        let fetchedAt = Date()
        let client = self.client
        async let blockhash: (RPCBlockhash, UInt64) = pool.first { provider in
            let latest: RPCContextual<RPCBlockhash> = try await SolanaRPC.call(
                provider.baseURL, "getLatestBlockhash", [.object(["commitment": .string("confirmed")])], client: client
            )
            let epoch: RPCEpochInfo = try await SolanaRPC.call(
                provider.baseURL, "getEpochInfo", [.object(["commitment": .string("confirmed")])], client: client
            )
            try Self.checkWindow(lastValid: latest.value.lastValidBlockHeight, current: epoch.blockHeight)
            return (latest.value, epoch.blockHeight)
        }
        async let balance: RPCContextual<UInt64> = call("getBalance", [.string(owner.base58), .object(["commitment": .string("confirmed")])])
        async let rent: UInt64 = call("getMinimumBalanceForRentExemption", [.number(0)])
        let accounts = Array(Set([owner] + writableAccounts).map(\.base58).sorted().prefix(128))
        async let fees: [RPCPrioritizationFee] = call("getRecentPrioritizationFees", [.array(accounts.map { .string($0) })])

        let (hash, height) = try await blockhash
        return SolanaNetworkState(
            recentBlockhash: try SolanaBlockhash(base58: hash.blockhash), lastValidBlockHeight: hash.lastValidBlockHeight,
            currentBlockHeight: height, fetchedAt: fetchedAt, balance: BigUInt(try await balance.value),
            rentExemptMinimum: BigUInt(try await rent),
            suggestedComputeUnitPrice: SolanaAccountParser.priorityFee((try await fees).map(\.prioritizationFee), percentile: feePercentile),
            simulatedComputeUnits: simulatedComputeUnits
        )
    }

    static func checkWindow(lastValid: UInt64, current: UInt64) throws {
        guard current <= lastValid, lastValid - current <= maxBlockhashWindow else {
            throw SolanaInconsistentResponse(reason: "altura de bloco fora da janela do blockhash")
        }
    }

    /// Altura de bloco atual (para saber se um blockhash ja venceu).
    public func blockHeight() async throws -> UInt64 {
        let epoch: RPCEpochInfo = try await call("getEpochInfo", [.object(["commitment": .string("confirmed")])])
        return epoch.blockHeight
    }

    public func rentExemptMinimum(dataSize: Int) async throws -> BigUInt {
        BigUInt(try await call("getMinimumBalanceForRentExemption", [.number(Double(dataSize))], as: UInt64.self))
    }

    // MARK: Simulacao

    /// `simulateTransaction` da mensagem, sem assinatura (`sigVerify: false`) e com o
    /// blockhash trocado pelo no (`replaceRecentBlockhash`), pedindo o estado final
    /// de `accounts`.
    public func simulate(_ message: SolanaMessage, accounts: [SolanaPublicKey] = []) async throws -> SolanaSimulationOutcome {
        try await simulate(base64: SolanaSimulationEncoding.unsignedTransactionBase64(message), accounts: accounts)
    }

    public func simulate(base64 transaction: String, accounts: [SolanaPublicKey]) async throws -> SolanaSimulationOutcome {
        var config: [String: JSONValue] = [
            "encoding": .string("base64"), "sigVerify": .bool(false), "replaceRecentBlockhash": .bool(true),
            "commitment": .string("confirmed"),
        ]
        if !accounts.isEmpty {
            config["accounts"] = .object(["encoding": .string("base64"), "addresses": .array(accounts.map { .string($0.base58) })])
        }
        let result: RPCContextual<RPCSimulation> = try await call("simulateTransaction", [.string(transaction), .object(config)])
        return try Self.outcome(result.value, accounts: accounts)
    }

    static func outcome(_ value: RPCSimulation, accounts: [SolanaPublicKey]) throws -> SolanaSimulationOutcome {
        var snapshots = [SolanaAccountSnapshot]()
        if !accounts.isEmpty {
            let returned = value.accounts ?? []
            guard returned.count == accounts.count else { throw SolanaInconsistentResponse(reason: "simulacao devolveu contas a menos") }
            for (address, account) in zip(accounts, returned) {
                guard let account else { snapshots.append(.missing(address)); continue }
                guard let bytes = account.data.bytes else { throw SolanaInconsistentResponse(reason: "conta simulada sem base64") }
                snapshots.append(SolanaAccountSnapshot.parse(
                    address: address, lamports: account.lamports, programOwner: try SolanaAccountParser.key(account.owner), data: bytes
                ))
            }
        }
        let error = value.err.flatMap { $0.isNull ? nil : $0.compactText }
        return SolanaSimulationOutcome(error: error, unitsConsumed: value.unitsConsumed, accounts: snapshots, logs: value.logs ?? [])
    }

    /// Consumo simulado * 1,1, o valor que `SolanaNetworkState.simulatedComputeUnits` espera.
    public func simulatedComputeUnits(for message: SolanaMessage) async throws -> UInt32 {
        let outcome = try await simulate(message)
        guard outcome.succeeded else { throw SolanaSimulationFailure(error: outcome.error ?? "", logs: outcome.logs) }
        guard let units = outcome.suggestedComputeUnitLimit else { throw SolanaInconsistentResponse(reason: "simulacao sem consumo") }
        return units
    }

    /// O estado atual de contas (lamports, dono, token), em base64.
    public func snapshots(_ addresses: [SolanaPublicKey]) async throws -> [SolanaAccountSnapshot] {
        guard !addresses.isEmpty else { return [] }
        let result: RPCContextual<[RPCAccount?]> = try await call(
            "getMultipleAccounts", [.array(addresses.map { .string($0.base58) }), .object(["encoding": .string("base64"), "commitment": .string("confirmed")])]
        )
        guard result.value.count == addresses.count else { throw SolanaInconsistentResponse(reason: "contas a menos") }
        return try zip(addresses, result.value).map { address, account in
            guard let account else { return .missing(address) }
            guard let bytes = account.data.bytes else { throw SolanaInconsistentResponse(reason: "conta sem base64") }
            return SolanaAccountSnapshot.parse(address: address, lamports: account.lamports, programOwner: try SolanaAccountParser.key(account.owner), data: bytes)
        }
    }

    // MARK: Destino e tokens

    /// O que existe no endereco digitado: inexistente, carteira, conta de token (com
    /// o mint) ou conta de programa.
    public func destinationAccount(_ address: SolanaPublicKey) async throws -> SolanaDestinationAccount {
        try SolanaAccountParser.destination(try await accountInfo(address), address: address)
    }

    /// O ATA de `owner` para o mint: existe? E de quem diz ser?
    public func destinationTokenAccount(owner: SolanaPublicKey, mint: SolanaPublicKey, program: SolanaTokenProgram, allowOwnerOffCurve: Bool = false) async throws -> SolanaDestinationTokenAccount {
        let ata = try SolanaAssociatedToken.address(owner: owner, mint: mint, tokenProgram: program, allowOwnerOffCurve: allowOwnerOffCurve)
        guard let account = try await accountInfo(ata) else { return .missing }
        let state = try SolanaAccountParser.tokenAccount(account, address: ata, program: program)
        guard state.mint == mint, state.owner == owner else { throw SolanaAccountParseError.tokenAccountMismatch }
        return .existing(state)
    }

    /// O mint: programa, casas e extensoes Token-2022.
    public func mintInfo(_ mint: SolanaPublicKey) async throws -> SolanaMintInfo {
        let client = self.client
        let body = try SolanaRPC.body("getAccountInfo", [.string(mint.base58), .object(["encoding": .string("jsonParsed"), "commitment": .string("confirmed")])])
        let data = try await pool.first { provider in try await client.post(provider.baseURL, json: body) }
        return try SolanaAccountParser.mint(fromResponse: data, address: mint)
    }

    /// O token a enviar: mint, conta de origem do dono (o ATA) e o rent de uma conta
    /// de token deste mint. Simbolo e "curado" vem da lista compilada, nunca da rede.
    public func tokenState(owner: SolanaPublicKey, mint: SolanaPublicKey) async throws -> SolanaTokenState {
        let info = try await mintInfo(mint)
        guard case .existing(let source) = try await destinationTokenAccount(owner: owner, mint: mint, program: info.program) else {
            throw SolanaAccountParseError.notATokenAccount
        }
        let rent = try await rentExemptMinimum(dataSize: info.tokenAccountSize)
        let curated = TokenRegistry.find(chainID: Chain.solana.id, contract: mint.base58)
        return SolanaTokenState(
            mint: mint, program: info.program, decimals: info.decimals, symbol: curated?.symbol ?? Self.shortSymbol(mint),
            isVerified: curated != nil && curated?.decimals == Int(info.decimals), extensions: info.extensions, source: source,
            tokenAccountRentMinimum: rent
        )
    }

    /// Um lado de troca: SOL (mint do SOL embrulhado) ou um token lido da cadeia.
    public func swapAsset(mint: SolanaPublicKey) async throws -> SolanaSwapAsset {
        if mint == SolanaWrappedSOL.mint { return .sol }
        let info = try await mintInfo(mint)
        let curated = TokenRegistry.find(chainID: Chain.solana.id, contract: mint.base58)
        return SolanaSwapAsset(
            mint: mint, program: info.program, decimals: info.decimals, symbol: curated?.symbol ?? Self.shortSymbol(mint),
            isVerified: curated != nil && curated?.decimals == Int(info.decimals), extensions: info.extensions
        )
    }

    /// As contas de token do dono que a troca toca.
    public func swapAccounts(owner: SolanaPublicKey, sell: SolanaSwapAsset, buy: SolanaSwapAsset) async throws -> SolanaSwapAccounts {
        var source: SolanaTokenAccountState?
        if !sell.isNativeSOL {
            guard case .existing(let account) = try await destinationTokenAccount(owner: owner, mint: sell.mint, program: sell.program) else {
                throw SolanaAccountParseError.notATokenAccount
            }
            source = account
        }
        let destination = try await destinationTokenAccount(owner: owner, mint: buy.mint, program: buy.program)
        let wrappedRent = try await rentExemptMinimum(dataSize: 165)
        // SOL embrulhado e Token: 165 bytes. Token-2022: depende das extensoes do mint.
        var destinationRent = wrappedRent
        if buy.program == .token2022 {
            destinationRent = try await rentExemptMinimum(dataSize: try await mintInfo(buy.mint).tokenAccountSize)
        }
        let guarded = try await snapshots(Self.guardedAccounts(owner: owner, excluding: [sell.mint, buy.mint]))
        return SolanaSwapAccounts(
            source: source, destination: destination, destinationRentMinimum: destinationRent, wrappedSOLRentMinimum: wrappedRent,
            guarded: guarded
        )
    }

    /// As contas de token do dono nos mints da lista curada, fora os dois lados da
    /// troca: a simulacao confere que nenhuma perde saldo. Os mints da lista (USDC, USDT
    /// e JUP) sao do programa Token classico, e o ATA e derivado com ele.
    static func guardedAccounts(owner: SolanaPublicKey, excluding: [SolanaPublicKey]) -> [SolanaPublicKey] {
        TokenRegistry.tokens.compactMap { asset -> SolanaPublicKey? in
            guard asset.chainID == Chain.solana.id, case .token(let contract) = asset.kind,
                  let mint = try? SolanaPublicKey(base58: contract), !excluding.contains(mint)
            else { return nil }
            return try? SolanaAssociatedToken.address(owner: owner, mint: mint, tokenProgram: .token)
        }
    }

    /// Token fora da lista nao ganha nome vindo da rede: aparece pelo inicio do mint.
    static func shortSymbol(_ mint: SolanaPublicKey) -> String {
        String(mint.base58.prefix(4)) + "…"
    }

    // MARK: Tabelas de enderecos

    /// Cada tabela lida de dois RPCs diferentes, que tem de concordar (a mesma lista,
    /// ou uma prefixo da outra). Sem dois concordando, falha.
    public func lookupTables(_ addresses: [SolanaPublicKey]) async throws -> [SolanaAddressLookupTable] {
        var tables = [SolanaAddressLookupTable]()
        let providers = await pool.available()
        let client = self.client
        for address in addresses {
            var answers = [SolanaAddressLookupTable]()
            var agreed: SolanaAddressLookupTable?
            for provider in providers where agreed == nil {
                do {
                    let result: RPCContextualOptional<RPCAccount> = try await SolanaRPC.call(
                        provider.baseURL, "getAccountInfo",
                        [.string(address.base58), .object(["encoding": .string("base64"), "commitment": .string("confirmed")])], client: client
                    )
                    let table = try SolanaAccountParser.lookupTable(result.value, address: address)
                    agreed = answers.lazy.compactMap { SolanaAccountParser.agree($0, table) }.first
                    answers.append(table)
                } catch {
                    await pool.reportFailure(provider)
                }
            }
            guard let agreed else { throw ConsensusFailure(answers: answers.count) }
            tables.append(agreed)
        }
        return tables
    }
}

/// A simulacao rejeitou a transacao.
public struct SolanaSimulationFailure: Error, Sendable, Equatable {
    public let error: String
    public let logs: [String]
}

extension SolanaNetworkState {
    /// O mesmo estado, com o consumo simulado de uma mensagem ja montada.
    public func withSimulatedComputeUnits(_ units: UInt32?) -> SolanaNetworkState {
        SolanaNetworkState(
            recentBlockhash: recentBlockhash, lastValidBlockHeight: lastValidBlockHeight, currentBlockHeight: currentBlockHeight,
            fetchedAt: fetchedAt, balance: balance, rentExemptMinimum: rentExemptMinimum,
            suggestedComputeUnitPrice: suggestedComputeUnitPrice, simulatedComputeUnits: units
        )
    }
}
