import EscaliburChains
import EscaliburCore
import Foundation

/// Quanto de um ativo uma conta tem, nas unidades da rede.
public struct Holding: Sendable, Codable, Hashable {
    public let asset: Asset
    public let amount: BigUInt

    public init(asset: Asset, amount: BigUInt) {
        self.asset = asset
        self.amount = amount
    }
}

/// Um token que esta na conta e nao esta na lista conferida nem nas moedas custom.
///
/// Aparece em "Outros tokens", com o selo de nao verificado, fora do total enquanto nao
/// houver preco por contrato numa fonte confiavel. Com algum motivo de suspeita
/// (`TokenSafety`), fica atras de "Mostrar suspeitos".
public struct UnlistedHolding: Sendable, Codable, Hashable {
    /// `origin == .discovered`; nome e simbolo ja limpos para a tela.
    public let asset: Asset
    public let amount: BigUInt
    public let reasons: [TokenSafety.Reason]

    public init(asset: Asset, amount: BigUInt, reasons: [TokenSafety.Reason]) {
        self.asset = asset
        self.amount = amount
        self.reasons = reasons
    }

    public var isSuspicious: Bool { !reasons.isEmpty }

    /// Os motivos sao calculados no texto cru (caractere invisivel so aparece nele); a
    /// tela recebe o texto limpo.
    static func make(
        chain: Chain, kind: Asset.Kind, symbol rawSymbol: String, name rawName: String, decimals: Int, amount: BigUInt,
        flagged: Bool = false
    ) -> UnlistedHolding {
        let reasons = TokenSafety.reasons(
            symbol: rawSymbol, name: rawName, chainID: chain.id, kind: kind, amount: amount, decimals: decimals,
            unsolicited: TokenSafety.arrivesUnsolicited(chain), flaggedBySource: flagged
        )
        let symbol = TokenSafety.clean(rawSymbol, limit: TokenSafety.symbolLimit)
        let name = TokenSafety.clean(rawName, limit: TokenSafety.nameLimit)
        let shownSymbol = symbol.isEmpty ? CustomToken.fallbackSymbol(kind) : symbol
        let asset = Asset(
            chainID: chain.id, kind: kind, symbol: shownSymbol, name: name.isEmpty ? shownSymbol : name,
            decimals: decimals, coingeckoID: nil, isStablecoin: false, origin: .discovered
        )
        return UnlistedHolding(asset: asset, amount: amount, reasons: reasons)
    }

    /// Primeiro os que nao levantam suspeita, depois pelo simbolo.
    static func sorted(_ items: [UnlistedHolding]) -> [UnlistedHolding] {
        items.sorted { ($0.isSuspicious ? 1 : 0, $0.asset.symbol.lowercased(), $0.asset.id) < ($1.isSuspicious ? 1 : 0, $1.asset.symbol.lowercased(), $1.asset.id) }
    }
}

/// O saldo de uma conta numa rede.
public struct ChainBalance: Sendable, Codable, Hashable {
    public let chainID: String
    public let holdings: [Holding]
    /// XRP Ledger, Stellar, Tron e TON: a conta so passa a existir no primeiro
    /// recebimento minimo. `false` muda o que a tela de receber diz.
    public let accountExists: Bool
    /// Tokens que chegaram e nao estao na lista curada nem nas moedas custom.
    public let unknownTokenCount: Int
    public let fetchedAt: Date
    /// Os mesmos tokens, um por um, quando a rede diz quais sao. Opcional para o cache
    /// gravado antes deste campo continuar abrindo; `nil` tambem quando a fonte que
    /// respondeu so da a moeda nativa.
    public let unlisted: [UnlistedHolding]?

    public init(
        chainID: String, holdings: [Holding], accountExists: Bool, unknownTokenCount: Int, fetchedAt: Date,
        unlisted: [UnlistedHolding]? = nil
    ) {
        self.chainID = chainID
        self.holdings = holdings
        self.accountExists = accountExists
        self.unknownTokenCount = unlisted?.count ?? unknownTokenCount
        self.fetchedAt = fetchedAt
        self.unlisted = unlisted
    }
}

/// Leitura de saldo, so leitura, por rede.
///
/// Consulta endereco por endereco, nunca por xpub: mandar a xpub a um provedor
/// entregaria a carteira inteira (docs/seguranca.md §5.5).
///
/// Mostra tudo o que a conta tem: os tokens da lista conferida, as moedas custom do dono
/// e, onde a rede ou um indexador sem chave diz quais sao, os outros (`unlisted`), cada um
/// com os motivos de suspeita calculados aqui. Nas redes EVM o indexador so diz quais
/// contratos a conta tem: o saldo e as casas decimais exibidos sao relidos na propria
/// rede (`balanceOf` e `decimals` pelo Multicall3), nunca confiados ao indexador.
public actor BalanceService {
    public static let shared = BalanceService()

    private let client: HTTPClient
    /// Todas as leituras passam por aqui (os testes trocam por respostas gravadas).
    private let transport: ReaderTransport
    private let evmProviders: [String: [ProviderPool.Provider]]
    private let xrplProviders: [ProviderPool.Provider]
    /// Indexador de tokens EVM sem chave, por rede (`Endpoints.evmTokenIndex`).
    private let tokenIndex: [String: ProviderPool.Provider]
    private let solanaProviders: [ProviderPool.Provider]
    private let tronProviders: [ProviderPool.Provider]
    private let tonProviders: [ProviderPool.Provider]
    private let stellarProviders: [ProviderPool.Provider]
    private var pools: [String: ProviderPool] = [:]
    /// Nome, simbolo e casas de TRC-20 fora da lista, lidos uma vez por sessao: tres
    /// chamadas por token, e a TronGrid sem chave corta acima de ~2 por segundo.
    private var tronMetadata: [String: (name: String, symbol: String, decimals: Int)] = [:]

    public init(client: HTTPClient = .shared) {
        self.init(
            client: client, transport: client, evm: Endpoints.evm, xrpl: Endpoints.xrpl, tokenIndex: Endpoints.evmTokenIndex,
            solana: Endpoints.solana, tron: Endpoints.tron, ton: Endpoints.ton, stellar: Endpoints.stellar
        )
    }

    init(
        client: HTTPClient, transport: ReaderTransport, evm: [String: [ProviderPool.Provider]], xrpl: [ProviderPool.Provider],
        tokenIndex: [String: ProviderPool.Provider] = [:], solana: [ProviderPool.Provider] = Endpoints.solana,
        tron: [ProviderPool.Provider] = Endpoints.tron, ton: [ProviderPool.Provider] = Endpoints.ton,
        stellar: [ProviderPool.Provider] = Endpoints.stellar
    ) {
        self.client = client
        self.transport = transport
        self.evmProviders = evm
        self.xrplProviders = xrpl
        self.tokenIndex = tokenIndex
        self.solanaProviders = solana
        self.tronProviders = tron
        self.tonProviders = ton
        self.stellarProviders = stellar
    }

    private func pool(_ key: String, _ providers: [ProviderPool.Provider]) -> ProviderPool {
        if let existing = pools[key] { return existing }
        let created = ProviderPool(providers)
        pools[key] = created
        return created
    }

    /// Saldo de uma rede. `addresses` tem um endereco, salvo nas redes UTXO, onde
    /// entram os enderecos de recebimento e troco ja usados. `custom`: as moedas custom
    /// do dono (as de outras redes sao ignoradas aqui).
    public func balance(chain: Chain, addresses: [String], custom: [Asset] = []) async throws -> ChainBalance {
        let mine = custom.filter { $0.chainID == chain.id && $0.isCustom && TokenRegistry.listed(chainID: chain.id, kind: $0.kind) == nil }
        switch chain.family {
        case .evm: return try await evm(chain, address: addresses[0], custom: mine)
        case .utxo: return try await utxo(chain, addresses: addresses)
        case .solana: return try await solana(addresses[0], custom: mine)
        case .xrpl: return try await xrpl(addresses[0], custom: mine)
        case .stellar: return try await stellar(addresses[0], custom: mine)
        case .tron: return try await tron(addresses[0], custom: mine)
        case .ton: return try await ton(addresses[0], custom: mine)
        case .sui: return try await SuiReader.shared.displayBalance(owner: addresses[0])
        case .cardano: return try await CardanoReader.shared.displayBalance(owner: addresses[0])
        case .polkadot: return try await PolkadotReader.shared.displayBalance(owner: addresses[0])
        case .near: return try await NEARReader.shared.displayBalance(owner: addresses[0])
        case .aptos: return try await AptosReader.shared.displayBalance(owner: addresses[0])
        }
    }

    // MARK: Transporte

    private func getJSON(_ url: URL, timeout: TimeInterval = 10) async throws -> StrictJSON {
        try StrictJSON.parse(try await transport.send(.get(url, timeout: timeout)))
    }

    private func postJSON(_ url: URL, _ body: StrictJSON) async throws -> StrictJSON {
        try StrictJSON.parse(try await transport.send(.post(url, body)))
    }

    // MARK: EVM

    /// A moeda nativa (`eth_getBalance`) e um `eth_call` ao Multicall3 com o `balanceOf`
    /// de todos os tokens: os da lista, as moedas custom e os que o indexador diz que a
    /// conta tem (um lote a cada `Multicall3.maxCallsPerBatch`). Para os descobertos com
    /// saldo, mais um lote com o `decimals()`. Um token por `eth_call` multiplicaria as
    /// chamadas pelo tamanho da lista e esgotaria a cota dos RPCs gratuitos. So exibicao,
    /// com um provedor; o saldo de um envio vem do leitor de estado, em dois.
    private func evm(_ chain: Chain, address: String, custom: [Asset]) async throws -> ChainBalance {
        let pool = pool(chain.id, evmProviders[chain.id] ?? [])
        let transport = self.transport
        let native: BigUInt = try await pool.first { provider in
            try await EVMReader.call(transport, provider.baseURL, "eth_getBalance", [.string(address), .string("latest")]).quantity("eth_getBalance")
        }
        var holdings = [Holding(asset: .native(chain), amount: native)]
        guard let owner = try? EVMAddress(address) else {
            return ChainBalance(chainID: chain.id, holdings: holdings, accountExists: true, unknownTokenCount: 0, fetchedAt: .now)
        }
        var known = Set<String>()
        var entries: [(asset: Asset, contract: EVMAddress)] = []
        for asset in TokenRegistry.assets(on: chain) + custom {
            guard case .token(let contract) = asset.kind, let address = try? EVMAddress(contract),
                  known.insert(address.checksummed.lowercased()).inserted
            else { continue }
            entries.append((asset, address))
        }
        let indexed = await discoverEVM(chain, owner: owner, excluding: known)
        let amounts = await Self.tokenBalances(
            chain: chain, owner: owner, tokens: entries.map(\.contract) + indexed.map(\.contract), pool: pool, transport: transport
        )
        for (entry, amount) in zip(entries, amounts.prefix(entries.count)) {
            if let amount, !amount.isZero { holdings.append(Holding(asset: entry.asset, amount: amount)) }
        }
        guard tokenIndex[chain.id] != nil else {
            return ChainBalance(chainID: chain.id, holdings: holdings, accountExists: true, unknownTokenCount: 0, fetchedAt: .now)
        }
        let held: [(token: IndexedToken, amount: BigUInt)] = zip(indexed, amounts.dropFirst(entries.count)).compactMap { token, amount in
            guard let amount, !amount.isZero else { return nil }
            return (token, amount)
        }
        let places = await Self.uint256Calls(
            chain: chain, calls: held.map { Multicall3.Call(target: $0.token.contract, data: ERC20.decimals()) }, pool: pool, transport: transport
        )
        let unlisted = zip(held, places).map { entry, onChain -> UnlistedHolding in
            // As casas lidas na rede valem; as do indexador so na falta delas.
            let decimals = onChain.flatMap(\.uint64).flatMap { $0 <= 36 ? Int($0) : nil } ?? entry.token.decimals ?? 0
            return .make(
                chain: chain, kind: .token(contract: entry.token.contract.checksummed), symbol: entry.token.symbol, name: entry.token.name,
                decimals: decimals, amount: entry.amount, flagged: entry.token.flagged
            )
        }
        return ChainBalance(
            chainID: chain.id, holdings: holdings, accountExists: true, unknownTokenCount: 0, fetchedAt: .now,
            unlisted: UnlistedHolding.sorted(unlisted)
        )
    }

    /// Os contratos ERC-20 que o indexador diz que a conta tem, menos os ja conhecidos.
    /// Indexador fora do ar nao derruba o saldo: a lista e as moedas custom continuam.
    private func discoverEVM(_ chain: Chain, owner: EVMAddress, excluding known: Set<String>) async -> [IndexedToken] {
        guard let provider = tokenIndex[chain.id] else { return [] }
        let found = (try? await TokenIndex.fetch(provider, owner: owner, transport: transport)) ?? []
        var seen = known
        return Array(found.filter { seen.insert($0.contract.checksummed.lowercased()).inserted }.prefix(TokenIndex.maxTokens))
    }

    /// O saldo de cada token, na ordem pedida; `nil` onde a leitura falhou. Lote que
    /// falha em todos os provedores deixa os seus tokens de fora, como o token que nao
    /// respondia deixava antes: a moeda nativa e os outros lotes continuam na tela.
    static func tokenBalances(
        chain: Chain, owner: EVMAddress, tokens: [EVMAddress], pool: ProviderPool, transport: ReaderTransport
    ) async -> [BigUInt?] {
        await uint256Calls(
            chain: chain, calls: tokens.map { Multicall3.Call(target: $0, data: ERC20.balanceOf(owner: owner)) }, pool: pool, transport: transport
        )
    }

    /// Chamadas que devolvem um `uint256` (`balanceOf`, `decimals`), em lotes do
    /// Multicall3; sem ele, uma por `eth_call`. `nil` onde a chamada falhou.
    static func uint256Calls(
        chain: Chain, calls: [Multicall3.Call], pool: ProviderPool, transport: ReaderTransport
    ) async -> [BigUInt?] {
        guard !calls.isEmpty else { return [] }
        guard Multicall3.isDeployed(on: chain) else {
            // Rede sem Multicall3 conferido: um `eth_call` por chamada.
            var out: [BigUInt?] = []
            for call in calls {
                out.append(try? await pool.first { provider in
                    let request: StrictJSON = .object([
                        "to": .string(call.target.checksummed), "data": .string(Hex.encode(call.data, prefix: true)),
                    ])
                    let returned = try await EVMReader.call(transport, provider.baseURL, "eth_call", [request, .string("latest")]).hexData("eth_call")
                    do { return try ERC20.decodeUInt256(returned) } catch { throw ReaderError.malformed(field: "eth_call") }
                })
            }
            return out
        }
        var out: [BigUInt?] = []
        let batches = stride(from: 0, to: calls.count, by: Multicall3.maxCallsPerBatch).map {
            Array(calls[$0..<min($0 + Multicall3.maxCallsPerBatch, calls.count)])
        }
        for batch in batches {
            let amounts: [BigUInt?]? = try? await pool.first { provider in
                let data = try Multicall3.aggregate3(batch)
                let request: StrictJSON = .object([
                    "to": .string(Multicall3.address.checksummed), "data": .string(Hex.encode(data, prefix: true)),
                ])
                let returned = try await EVMReader.call(transport, provider.baseURL, "eth_call", [request, .string("latest")]).hexData("aggregate3")
                do { return try Multicall3.decodeBalances(returned, expected: batch.count) } catch { throw ReaderError.malformed(field: "aggregate3") }
            }
            out += amounts ?? Array(repeating: nil, count: batch.count)
        }
        return out
    }

    // MARK: UTXO

    /// Pelo `UTXOReader`: a mesma lista de provedores, a mesma contingencia e o mesmo
    /// banco por rede da varredura e do envio (Litecoin e Dogecoin tem cinco e quatro
    /// fontes; antes o saldo do Litecoin dependia so do litecoinspace).
    private func utxo(_ chain: Chain, addresses: [String]) async throws -> ChainBalance {
        let reader = try UTXOReader(chain: chain, transport: utxoTransport)
        let total = try await reader.balance(addresses: addresses)
        return ChainBalance(
            chainID: chain.id, holdings: [Holding(asset: .native(chain), amount: BigUInt(total))],
            accountExists: true, unknownTokenCount: 0, fetchedAt: .now
        )
    }

    private var utxoTransport: ChainReaderTransport {
        PacedChainTransport(base: HTTPReaderTransport(client: client), intervals: Endpoints.utxoPacing)
    }

    /// Quais enderecos ja receberam algo: a varredura de gap limit usa isto.
    public func hasHistory(chain: Chain, address: String) async throws -> Bool {
        try await UTXOReader(chain: chain, transport: utxoTransport).isUsed(address)
    }

    // MARK: Solana

    /// SOL, e as contas de token do dono nos dois programas (Token e Token-2022). As
    /// casas decimais vem da propria conta de token na rede. Nome e simbolo dos mints
    /// fora da lista: a conta de metadados da Metaplex de cada um, numa chamada so.
    private func solana(_ address: String, custom: [Asset]) async throws -> ChainBalance {
        let pool = pool("solana", solanaProviders)
        let transport = self.transport
        let lamports: BigUInt = try await pool.first { provider in
            let result = try await EVMReader.call(transport, provider.baseURL, "getBalance", [.string(address), .object(["commitment": .string("confirmed")])])
            return try result.field("value", "getBalance").unsigned("getBalance.value")
        }
        var holdings = [Holding(asset: .native(.solana), amount: lamports)]
        var unknown: [SolanaHeldToken] = []
        for program in [SolanaTokenProgram.token, .token2022] {
            let accounts: [StrictJSON] = (try? await pool.first { provider in
                let result = try await EVMReader.call(transport, provider.baseURL, "getTokenAccountsByOwner", [
                    .string(address), .object(["programId": .string(program.programID.base58)]),
                    .object(["encoding": .string("jsonParsed"), "commitment": .string("confirmed")]),
                ])
                return try result.field("value", "getTokenAccountsByOwner").array("getTokenAccountsByOwner.value")
            }) ?? []
            for held in Self.solanaTokens(accounts) {
                if let asset = TokenRegistry.listed(chainID: Chain.solana.id, kind: .token(contract: held.mint)) {
                    holdings.append(Holding(asset: asset, amount: held.amount))
                } else if let asset = custom.first(where: { $0.kind == .token(contract: held.mint) }) {
                    holdings.append(Holding(asset: asset, amount: held.amount))
                } else {
                    unknown.append(held)
                }
            }
        }
        let names = await solanaMetadata(unknown.map(\.mint), pool: pool)
        let unlisted = unknown.map { held in
            UnlistedHolding.make(
                chain: .solana, kind: .token(contract: held.mint), symbol: names[held.mint]?.symbol ?? "",
                name: names[held.mint]?.name ?? "", decimals: held.decimals, amount: held.amount
            )
        }
        return ChainBalance(
            chainID: "solana", holdings: holdings, accountExists: true, unknownTokenCount: 0, fetchedAt: .now,
            unlisted: UnlistedHolding.sorted(unlisted)
        )
    }

    struct SolanaHeldToken: Equatable {
        let mint: String
        let amount: BigUInt
        let decimals: Int
    }

    /// As contas de token com saldo, da resposta `jsonParsed`. Conta fora do formato e
    /// pulada, nunca vira zero.
    static func solanaTokens(_ accounts: [StrictJSON]) -> [SolanaHeldToken] {
        accounts.compactMap { account in
            guard let info = try? account.field("account", "a").field("data", "a").field("parsed", "a").field("info", "a"),
                  let mint = try? info.field("mint", "info").string("mint"), (try? SolanaPublicKey(base58: mint)) != nil,
                  let tokenAmount = try? info.field("tokenAmount", "info"),
                  let amount = try? tokenAmount.field("amount", "tokenAmount").decimalString("amount"), !amount.isZero,
                  let decimals = try? tokenAmount.field("decimals", "tokenAmount").uint64("decimals"), decimals <= 36
            else { return nil }
            return SolanaHeldToken(mint: mint, amount: amount, decimals: Int(decimals))
        }
    }

    /// Nome e simbolo da Metaplex para cada mint, numa chamada `getMultipleAccounts`. A
    /// conta de metadados e o endereco derivado de ("metadata", programa, mint); a
    /// resposta so vale se o mint gravado nela for o perguntado.
    private func solanaMetadata(_ mints: [String], pool: ProviderPool) async -> [String: (name: String, symbol: String)] {
        let keys: [(mint: SolanaPublicKey, pda: SolanaPublicKey)] = mints.prefix(100).compactMap { text in
            guard let mint = try? SolanaPublicKey(base58: text), let pda = SolanaMetaplex.metadataAddress(mint: mint) else { return nil }
            return (mint, pda)
        }
        guard !keys.isEmpty else { return [:] }
        let transport = self.transport
        let values: [StrictJSON] = (try? await pool.first { provider in
            let result = try await EVMReader.call(transport, provider.baseURL, "getMultipleAccounts", [
                .array(keys.map { .string($0.pda.base58) }), .object(["encoding": .string("base64"), "commitment": .string("confirmed")]),
            ])
            return try result.field("value", "getMultipleAccounts").array("getMultipleAccounts.value")
        }) ?? []
        var out: [String: (name: String, symbol: String)] = [:]
        for (key, value) in zip(keys, values) {
            guard let data = try? value.field("data", "v").array("data").first?.string("data"),
                  let bytes = Data(base64Encoded: data), let parsed = SolanaMetaplex.parse([UInt8](bytes)), parsed.mint == key.mint
            else { continue }
            out[key.mint.base58] = (parsed.name, parsed.symbol)
        }
        return out
    }

    // MARK: XRP Ledger

    /// `account_info` e, com a conta existindo, `account_lines` no mesmo servidor: duas
    /// chamadas, quantos tokens a conta tiver. Linha de confianca so nasce por
    /// `TrustSet` do dono: aqui nada chega sem ele pedir.
    private func xrpl(_ address: String, custom: [Asset]) async throws -> ChainBalance {
        let pool = pool("xrpl", xrplProviders)
        let transport = self.transport
        return try await pool.first { provider in
            let info = try await XRPLReader.call(transport, provider.baseURL, "account_info", [
                "account": .string(address), "ledger_index": .string("validated"),
            ])
            if let error = info.optionalField("error") {
                guard (try? error.string("account_info.error")) == "actNotFound" else { throw HTTPClient.Failure.invalidResponse }
                return ChainBalance(chainID: "xrpl", holdings: [Holding(asset: .native(.xrpl), amount: BigUInt())], accountExists: false, unknownTokenCount: 0, fetchedAt: .now)
            }
            let drops = try info.field("account_data", "account_info").field("Balance", "account_info.account_data")
                .decimalString("account_info.account_data.Balance")
            var holdings = [Holding(asset: .native(.xrpl), amount: drops)]
            var unlisted: [UnlistedHolding]?
            if let lines = try? await XRPLReader.call(transport, provider.baseURL, "account_lines", [
                "account": .string(address), "ledger_index": .string("validated"), "limit": .int(400),
            ]) {
                let read = Self.trustLineHoldings(lines, custom: custom)
                holdings += read.holdings
                unlisted = read.unlisted
            }
            return ChainBalance(
                chainID: "xrpl", holdings: holdings, accountExists: true, unknownTokenCount: 0, fetchedAt: .now,
                unlisted: unlisted.map(UnlistedHolding.sorted)
            )
        }
    }

    /// Casas com que a carteira mostra um token do XRP Ledger fora da lista. O ledger
    /// guarda o valor em decimal de ate 15 algarismos, sem casas fixas por token; seis e
    /// o que a lista usa para os tokens dela.
    public static let xrplDisplayDecimals = 6

    /// Os saldos positivos das linhas de confianca: os da lista curada (codigo e emissor
    /// iguais), os das moedas custom e os outros. Saldo negativo e o lado de quem emite,
    /// e nao entra.
    static func trustLineHoldings(_ result: StrictJSON, custom: [Asset] = []) -> (holdings: [Holding], unlisted: [UnlistedHolding]) {
        guard result.optionalField("error") == nil, let lines = try? result.field("lines", "account_lines").array("account_lines.lines") else {
            return ([], [])
        }
        var holdings: [Holding] = []
        var unlisted: [UnlistedHolding] = []
        for line in lines {
            guard let issuer = try? line.field("account", "line").string("line.account"),
                  let code = try? line.field("currency", "line").string("line.currency"),
                  let text = try? line.field("balance", "line").string("line.balance"),
                  let value = try? XRPLDecimal(text), !value.isNegative, !value.isZero
            else { continue }
            let kind = Asset.Kind.issued(code: code, issuer: issuer)
            let known = TokenRegistry.listed(chainID: Chain.xrpl.id, kind: kind) ?? custom.first { asset in
                guard case .issued(let customCode, let customIssuer) = asset.kind else { return false }
                return customIssuer == issuer && customCode.uppercased() == code.uppercased()
            }
            if let asset = known {
                if let amount = value.units(decimals: asset.decimals, roundingUp: false), !amount.isZero {
                    holdings.append(Holding(asset: asset, amount: amount))
                }
                continue
            }
            guard let amount = value.units(decimals: xrplDisplayDecimals, roundingUp: false), !amount.isZero else { continue }
            let symbol = CustomToken.xrplSymbol(code)
            unlisted.append(.make(chain: .xrpl, kind: kind, symbol: symbol, name: symbol, decimals: xrplDisplayDecimals, amount: amount))
        }
        return (holdings, unlisted)
    }

    // MARK: Stellar

    private func stellar(_ address: String, custom: [Asset]) async throws -> ChainBalance {
        let pool = pool("stellar", stellarProviders)
        return try await pool.first { provider in
            let json: StrictJSON
            do {
                json = try await self.getJSON(provider.baseURL.appendingPathComponent("accounts/\(address)"))
            } catch HTTPClient.Failure.status(404) {
                return ChainBalance(chainID: "stellar", holdings: [Holding(asset: .native(.stellar), amount: BigUInt())], accountExists: false, unknownTokenCount: 0, fetchedAt: .now)
            }
            let read = Self.stellarBalances(json, custom: custom)
            return ChainBalance(
                chainID: "stellar", holdings: read.holdings, accountExists: true, unknownTokenCount: 0, fetchedAt: .now,
                unlisted: UnlistedHolding.sorted(read.unlisted)
            )
        }
    }

    /// Os saldos de uma conta da Horizon: XLM primeiro, depois os ativos da lista e as
    /// moedas custom, e os outros a parte. Todo ativo da Stellar tem 7 casas.
    static func stellarBalances(_ json: StrictJSON, custom: [Asset] = []) -> (holdings: [Holding], unlisted: [UnlistedHolding]) {
        var holdings: [Holding] = []
        var unlisted: [UnlistedHolding] = []
        let entries = (try? json.field("balances", "account").array("balances")) ?? []
        for entry in entries {
            guard let text = try? entry.field("balance", "b").string("balance"), let amount = stroops(text) else { continue }
            let type = try? entry.field("asset_type", "b").string("asset_type")
            if type == "native" {
                holdings.insert(Holding(asset: .native(.stellar), amount: amount), at: 0)
                continue
            }
            guard let code = try? entry.field("asset_code", "b").string("asset_code"),
                  let issuer = try? entry.field("asset_issuer", "b").string("asset_issuer"), !amount.isZero
            else { continue }
            let kind = Asset.Kind.issued(code: code, issuer: issuer)
            if let asset = TokenRegistry.tokens.first(where: { $0.chainID == "stellar" && $0.kind == kind }) ?? custom.first(where: { $0.kind == kind }) {
                holdings.append(Holding(asset: asset, amount: amount))
            } else {
                unlisted.append(.make(chain: .stellar, kind: kind, symbol: code, name: code, decimals: 7, amount: amount))
            }
        }
        return (holdings, unlisted)
    }

    /// "12.3456789" para stroops, sem ponto flutuante.
    static func stroops(_ text: String) -> BigUInt? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 7 else { return nil }
        return BigUInt(decimal: String(parts[0]) + fraction + String(repeating: "0", count: 7 - fraction.count))
    }

    // MARK: Tron

    /// TronGrid: TRX e a lista `trc20` da conta, que traz todo TRC-20 com saldo. Fora da
    /// lista e das moedas custom, nome, simbolo e casas vem do proprio contrato
    /// (`name()`, `symbol()`, `decimals()`), uma vez por sessao. Sem a TronGrid, o no
    /// comum so da o TRX, e as moedas custom sao lidas por `balanceOf`.
    private func tron(_ address: String, custom: [Asset]) async throws -> ChainBalance {
        let pool = pool("tron", tronProviders)
        return try await pool.first { provider in
            if provider.name == "trongrid" {
                let json = try await self.getJSON(provider.baseURL.appendingPathComponent("v1/accounts/\(address)"))
                guard let account = try? json.field("data", "accounts").array("data").first else {
                    return ChainBalance(chainID: "tron", holdings: [Holding(asset: .native(.tron), amount: BigUInt())], accountExists: false, unknownTokenCount: 0, fetchedAt: .now)
                }
                let sun = (try? account.field("balance", "account").unsigned("balance")) ?? BigUInt()
                var holdings = [Holding(asset: .native(.tron), amount: sun)]
                var unknown: [(contract: String, amount: BigUInt)] = []
                for (contract, amount) in Self.trc20Entries(account) {
                    if let asset = TokenRegistry.find(chainID: "tron", contract: contract), contract == Self.contractText(asset) {
                        holdings.append(Holding(asset: asset, amount: amount))
                    } else if let asset = custom.first(where: { $0.kind == .token(contract: contract) }) {
                        holdings.append(Holding(asset: asset, amount: amount))
                    } else {
                        unknown.append((contract, amount))
                    }
                }
                var unlisted: [UnlistedHolding] = []
                for entry in unknown.prefix(30) {
                    let facts = await self.tronFacts(entry.contract)
                    unlisted.append(.make(
                        chain: .tron, kind: .token(contract: entry.contract), symbol: facts?.symbol ?? "", name: facts?.name ?? "",
                        decimals: facts?.decimals ?? 0, amount: entry.amount
                    ))
                }
                return ChainBalance(
                    chainID: "tron", holdings: holdings, accountExists: true, unknownTokenCount: 0, fetchedAt: .now,
                    unlisted: UnlistedHolding.sorted(unlisted)
                )
            }
            let body: StrictJSON = .object(["address": .string(address), "visible": .bool(true)])
            let json = try await self.postJSON(provider.baseURL.appendingPathComponent("wallet/getaccount"), body)
            let exists = json.optionalField("address") != nil
            let sun = (try? json.field("balance", "account").unsigned("balance")) ?? BigUInt()
            var holdings = [Holding(asset: .native(.tron), amount: sun)]
            if exists, let owner = TronAddress(base58: address) {
                for asset in custom {
                    guard case .token(let contract) = asset.kind,
                          let amount = try? await self.trc20Balance(provider, contract: contract, owner: owner), !amount.isZero
                    else { continue }
                    holdings.append(Holding(asset: asset, amount: amount))
                }
            }
            return ChainBalance(chainID: "tron", holdings: holdings, accountExists: exists, unknownTokenCount: 0, fetchedAt: .now)
        }
    }

    static func contractText(_ asset: Asset) -> String? {
        if case .token(let contract) = asset.kind { return contract }
        return nil
    }

    /// `trc20` da TronGrid: uma lista de objetos de um campo, contrato para saldo em texto.
    static func trc20Entries(_ account: StrictJSON) -> [(contract: String, amount: BigUInt)] {
        let list = (try? account.field("trc20", "account").array("trc20")) ?? []
        return list.compactMap { entry in
            guard let fields = entry.objectValue, fields.count == 1, let (contract, value) = fields.first,
                  TronAddress(base58: contract) != nil, let amount = try? value.decimalString("trc20"), !amount.isZero
            else { return nil }
            return (contract, amount)
        }
    }

    /// Nome, simbolo e casas de um TRC-20, pelos nos que nao sao a TronGrid primeiro.
    private func tronFacts(_ contract: String) async -> (name: String, symbol: String, decimals: Int)? {
        if let cached = tronMetadata[contract] { return cached }
        let providers = Endpoints.tronContingency + tronProviders.filter { $0.name != "trongrid" } + tronProviders.filter { $0.name == "trongrid" }
        for provider in providers {
            guard let decimals = try? await tronConstant(provider, contract: contract, selector: "decimals()").flatMap({ BigUInt(bigEndian: $0).uint64 }),
                  decimals <= 36
            else { continue }
            let symbol = (try? await tronConstant(provider, contract: contract, selector: "symbol()")).flatMap { $0.flatMap(CustomToken.decodeABIText) } ?? ""
            let name = (try? await tronConstant(provider, contract: contract, selector: "name()")).flatMap { $0.flatMap(CustomToken.decodeABIText) } ?? ""
            let facts = (name: name, symbol: symbol, decimals: Int(decimals))
            tronMetadata[contract] = facts
            return facts
        }
        return nil
    }

    private func tronConstant(_ provider: ProviderPool.Provider, contract: String, selector: String, parameter: String? = nil) async throws -> [UInt8]? {
        var body: [String: StrictJSON] = [
            "owner_address": .string(contract), "contract_address": .string(contract),
            "function_selector": .string(selector), "visible": .bool(true),
        ]
        if let parameter { body["parameter"] = .string(parameter) }
        let json = try await TronReader.post(transport, provider, "wallet/triggerconstantcontract", body)
        return try TronReader.parseConstantCall(json, field: selector).word
    }

    private func trc20Balance(_ provider: ProviderPool.Provider, contract: String, owner: TronAddress) async throws -> BigUInt {
        guard let word = try await tronConstant(provider, contract: contract, selector: "balanceOf(address)", parameter: Hex.encode(TRC20.addressWord(owner))),
              let value = TRC20.decodeUint256(word)
        else { throw ReaderError.malformed(field: "balanceOf") }
        return value
    }

    // MARK: TON

    /// tonapi: TON e os jettons da conta, com nome, simbolo, casas e a marca de lista
    /// negra da propria tonapi. Sem a tonapi, a toncenter so da o TON.
    private func ton(_ address: String, custom: [Asset]) async throws -> ChainBalance {
        let pool = pool("ton", tonProviders)
        return try await pool.first { provider in
            if provider.name == "tonapi" {
                let json = try await self.getJSON(provider.baseURL.appendingPathComponent("accounts/\(address)"))
                let nano = (try? json.field("balance", "account").integer("balance")) ?? BigUInt()
                let status = (try? json.field("status", "account").string("status")) ?? "nonexist"
                var holdings = [Holding(asset: .native(.ton), amount: nano)]
                var unlisted: [UnlistedHolding]?
                if let jettons = try? await self.getJSON(provider.baseURL.appendingPathComponent("accounts/\(address)/jettons")) {
                    let read = Self.tonJettons(jettons, custom: custom)
                    holdings += read.holdings
                    unlisted = UnlistedHolding.sorted(read.unlisted)
                }
                return ChainBalance(
                    chainID: "ton", holdings: holdings, accountExists: status != "nonexist", unknownTokenCount: 0, fetchedAt: .now,
                    unlisted: unlisted
                )
            }
            var components = URLComponents(url: provider.baseURL.appendingPathComponent("account"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "address", value: address)]
            let json = try await self.getJSON(components.url!)
            let nano = (try? json.field("balance", "account").integer("balance")) ?? BigUInt()
            let status = try? json.field("status", "account").string("status")
            return ChainBalance(chainID: "ton", holdings: [Holding(asset: .native(.ton), amount: nano)], accountExists: status != "nonexist", unknownTokenCount: 0, fetchedAt: .now)
        }
    }

    /// `/accounts/{a}/jettons` da tonapi. O mestre vem cru (`0:hex`); a lista e as
    /// moedas custom guardam a forma amigavel, e a comparacao e pelo hash.
    static func tonJettons(_ json: StrictJSON, custom: [Asset] = []) -> (holdings: [Holding], unlisted: [UnlistedHolding]) {
        var holdings: [Holding] = []
        var unlisted: [UnlistedHolding] = []
        let entries = (try? json.field("balances", "jettons").array("balances")) ?? []
        for entry in entries {
            guard let jetton = try? entry.field("jetton", "b"), let master = try? jetton.field("address", "jetton").string("address"),
                  let amount = try? entry.field("balance", "b").decimalString("balance"), !amount.isZero,
                  case .success(let parsed) = TONAddress.parse(master)
            else { continue }
            if let asset = TokenRegistry.tokens.first(where: { $0.chainID == "ton" && TONAddressMatcher.same($0, raw: master) })
                ?? custom.first(where: { TONAddressMatcher.same($0, raw: master) }) {
                holdings.append(Holding(asset: asset, amount: amount))
                continue
            }
            let decimals = (try? jetton.field("decimals", "jetton").integer("decimals")).flatMap(\.uint64).flatMap { $0 <= 36 ? Int($0) : nil } ?? 9
            let symbol = (try? jetton.field("symbol", "jetton").string("symbol")) ?? ""
            let name = (try? jetton.field("name", "jetton").string("name")) ?? ""
            let verification = try? jetton.field("verification", "jetton").string("verification")
            unlisted.append(.make(
                chain: .ton, kind: .token(contract: parsed.address.friendly(bounceable: true)), symbol: symbol, name: name,
                decimals: decimals, amount: amount, flagged: verification == "blacklist"
            ))
        }
        return (holdings, unlisted)
    }
}

/// A tonapi devolve o master do jetton em formato raw (`0:<hex>`); a lista curada
/// guarda o formato amigavel. A comparacao exata fica com o modulo TON quando ele
/// existir; ate la, compara pelo hash de 32 bytes contido nos dois formatos.
enum TONAddressMatcher {
    static func same(_ asset: Asset, raw: String) -> Bool {
        guard case .token(let friendly) = asset.kind else { return false }
        let base = friendly.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let decoded = Data(base64Encoded: base), decoded.count == 36 else { return false }
        let hash = decoded[2..<34].map { String(format: "%02x", $0) }.joined()
        return raw.lowercased().hasSuffix(hash)
    }
}
