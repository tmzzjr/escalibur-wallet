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

/// O saldo de uma conta numa rede.
public struct ChainBalance: Sendable, Codable, Hashable {
    public let chainID: String
    public let holdings: [Holding]
    /// XRP Ledger, Stellar, Tron e TON: a conta so passa a existir no primeiro
    /// recebimento minimo. `false` muda o que a tela de receber diz.
    public let accountExists: Bool
    /// Tokens que chegaram e nao estao na lista curada. Escondidos por padrao: e o
    /// vetor de golpe mais comum (nome que aponta para site que pede a frase).
    public let unknownTokenCount: Int
    public let fetchedAt: Date
}

/// Leitura de saldo, so leitura, por rede.
///
/// Consulta endereco por endereco, nunca por xpub: mandar a xpub a um provedor
/// entregaria a carteira inteira (docs/seguranca.md §5.5).
public actor BalanceService {
    public static let shared = BalanceService()

    private let client: HTTPClient
    /// EVM e XRP Ledger: o mesmo cliente, pelo protocolo dos leitores (os testes trocam
    /// por respostas gravadas).
    private let transport: ReaderTransport
    private let evmProviders: [String: [ProviderPool.Provider]]
    private let xrplProviders: [ProviderPool.Provider]
    private var pools: [String: ProviderPool] = [:]

    public init(client: HTTPClient = .shared) {
        self.init(client: client, transport: client, evm: Endpoints.evm, xrpl: Endpoints.xrpl)
    }

    init(client: HTTPClient, transport: ReaderTransport, evm: [String: [ProviderPool.Provider]], xrpl: [ProviderPool.Provider]) {
        self.client = client
        self.transport = transport
        self.evmProviders = evm
        self.xrplProviders = xrpl
    }

    private func pool(_ key: String, _ providers: [ProviderPool.Provider]) -> ProviderPool {
        if let existing = pools[key] { return existing }
        let created = ProviderPool(providers)
        pools[key] = created
        return created
    }

    /// Saldo de uma rede. `addresses` tem um endereco, salvo nas redes UTXO, onde
    /// entram os enderecos de recebimento e troco ja usados.
    public func balance(chain: Chain, addresses: [String]) async throws -> ChainBalance {
        switch chain.family {
        case .evm: return try await evm(chain, address: addresses[0])
        case .utxo: return try await utxo(chain, addresses: addresses)
        case .solana: return try await solana(addresses[0])
        case .xrpl: return try await xrpl(addresses[0])
        case .stellar: return try await stellar(addresses[0])
        case .tron: return try await tron(addresses[0])
        case .ton: return try await ton(addresses[0])
        case .sui: return try await SuiReader.shared.displayBalance(owner: addresses[0])
        case .cardano: return try await CardanoReader.shared.displayBalance(owner: addresses[0])
        case .polkadot: return try await PolkadotReader.shared.displayBalance(owner: addresses[0])
        }
    }

    // MARK: EVM

    /// Duas chamadas por rede, quantos tokens a lista tiver: `eth_getBalance` e um
    /// `eth_call` ao Multicall3 com o `balanceOf` de todos os tokens da rede (um por lote
    /// de ate `Multicall3.maxCallsPerBatch`). Um token por `eth_call` multiplicaria as
    /// chamadas pelo tamanho da lista e esgotaria a cota dos RPCs gratuitos. So exibicao,
    /// com um provedor, como antes; o saldo de um envio vem do leitor de estado, em dois.
    private func evm(_ chain: Chain, address: String) async throws -> ChainBalance {
        let pool = pool(chain.id, evmProviders[chain.id] ?? [])
        let transport = self.transport
        let native: BigUInt = try await pool.first { provider in
            try await EVMReader.call(transport, provider.baseURL, "eth_getBalance", [.string(address), .string("latest")]).quantity("eth_getBalance")
        }
        var holdings = [Holding(asset: .native(chain), amount: native)]
        let listed: [(asset: Asset, contract: EVMAddress)] = TokenRegistry.assets(on: chain).compactMap { asset in
            guard case .token(let contract) = asset.kind, let address = try? EVMAddress(contract) else { return nil }
            return (asset, address)
        }
        if !listed.isEmpty, let owner = try? EVMAddress(address) {
            let amounts = await Self.tokenBalances(
                chain: chain, owner: owner, tokens: listed.map(\.contract), pool: pool, transport: transport
            )
            for (entry, amount) in zip(listed, amounts) {
                if let amount, !amount.isZero { holdings.append(Holding(asset: entry.asset, amount: amount)) }
            }
        }
        return ChainBalance(chainID: chain.id, holdings: holdings, accountExists: true, unknownTokenCount: 0, fetchedAt: .now)
    }

    /// O saldo de cada token, na ordem pedida; `nil` onde a leitura falhou. Lote que
    /// falha em todos os provedores deixa os seus tokens de fora, como o token que nao
    /// respondia deixava antes: a moeda nativa e os outros lotes continuam na tela.
    static func tokenBalances(
        chain: Chain, owner: EVMAddress, tokens: [EVMAddress], pool: ProviderPool, transport: ReaderTransport
    ) async -> [BigUInt?] {
        guard Multicall3.isDeployed(on: chain) else {
            // Rede sem Multicall3 conferido: um `eth_call` por token.
            var out: [BigUInt?] = []
            for token in tokens {
                out.append(try? await pool.first { provider in
                    try await Self.balanceOf(transport, provider.baseURL, token: token, owner: owner)
                })
            }
            return out
        }
        var out: [BigUInt?] = []
        for batch in Multicall3.balanceBatches(owner: owner, tokens: tokens) {
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

    private static func balanceOf(_ transport: ReaderTransport, _ url: URL, token: EVMAddress, owner: EVMAddress) async throws -> BigUInt {
        let request: StrictJSON = .object([
            "to": .string(token.checksummed), "data": .string(Hex.encode(ERC20.balanceOf(owner: owner), prefix: true)),
        ])
        let returned = try await EVMReader.call(transport, url, "eth_call", [request, .string("latest")]).hexData("balanceOf")
        do { return try ERC20.decodeUInt256(returned) } catch { throw ReaderError.malformed(field: "balanceOf") }
    }

    // MARK: UTXO

    private func utxo(_ chain: Chain, addresses: [String]) async throws -> ChainBalance {
        var total = BigUInt()
        if chain.id == "dogecoin" {
            let pool = pool("dogecoin", Endpoints.dogecoin)
            for address in addresses {
                let value: BigUInt = try await pool.first { provider in
                    if provider.name == "blockcypher" {
                        let json = try await self.client.getJSON(JSONValue.self, from: provider.baseURL.appendingPathComponent("addrs/\(address)/balance"))
                        guard let balance = json["final_balance"]?.doubleValue, balance >= 0 else { throw HTTPClient.Failure.invalidResponse }
                        return BigUInt(UInt64(balance))
                    }
                    let json = try await self.client.getJSON(JSONValue.self, from: provider.baseURL.appendingPathComponent("dashboards/address/\(address)"))
                    guard let balance = json["data"]?[address]?["address"]?["balance"]?.doubleValue, balance >= 0 else {
                        throw HTTPClient.Failure.invalidResponse
                    }
                    return BigUInt(UInt64(balance))
                }
                total = total + value
            }
        } else {
            let pool = pool(chain.id, Endpoints.esplora[chain.id] ?? [])
            for address in addresses {
                let value: BigUInt = try await pool.first { provider in
                    let json = try await self.client.getJSON(JSONValue.self, from: provider.baseURL.appendingPathComponent("address/\(address)"))
                    func net(_ stats: JSONValue?) -> Double {
                        (stats?["funded_txo_sum"]?.doubleValue ?? 0) - (stats?["spent_txo_sum"]?.doubleValue ?? 0)
                    }
                    let sats = net(json["chain_stats"]) + net(json["mempool_stats"])
                    return BigUInt(UInt64(max(0, sats)))
                }
                total = total + value
            }
        }
        return ChainBalance(chainID: chain.id, holdings: [Holding(asset: .native(chain), amount: total)], accountExists: true, unknownTokenCount: 0, fetchedAt: .now)
    }

    /// Quais enderecos ja receberam algo: a varredura de gap limit usa isto.
    public func hasHistory(chain: Chain, address: String) async throws -> Bool {
        let pool = pool(chain.id, Endpoints.esplora[chain.id] ?? [])
        return try await pool.first { provider in
            let json = try await self.client.getJSON(JSONValue.self, from: provider.baseURL.appendingPathComponent("address/\(address)"))
            let count = (json["chain_stats"]?["tx_count"]?.doubleValue ?? 0) + (json["mempool_stats"]?["tx_count"]?.doubleValue ?? 0)
            return count > 0
        }
    }

    // MARK: Solana

    private func solana(_ address: String) async throws -> ChainBalance {
        let pool = pool("solana", Endpoints.solana)
        let lamports: BigUInt = try await pool.first { provider in
            let result = try await JSONRPC.call(provider.baseURL, method: "getBalance", params: [.string(address), .object(["commitment": .string("confirmed")])], as: JSONValue.self)
            guard let value = result["value"]?.doubleValue, value >= 0 else { throw HTTPClient.Failure.invalidResponse }
            return BigUInt(UInt64(value))
        }
        var holdings = [Holding(asset: .native(.solana), amount: lamports)]
        var unknown = 0
        for program in ["TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"] {
            let accounts: [JSONValue] = (try? await pool.first { provider in
                let result = try await JSONRPC.call(
                    provider.baseURL, method: "getTokenAccountsByOwner",
                    params: [.string(address), .object(["programId": .string(program)]), .object(["encoding": .string("jsonParsed"), "commitment": .string("confirmed")])],
                    as: JSONValue.self
                )
                return result["value"]?.arrayValue ?? []
            }) ?? []
            for account in accounts {
                let info = account["account"]?["data"]?["parsed"]?["info"]
                guard let mint = info?["mint"]?.stringValue,
                      let raw = info?["tokenAmount"]?["amount"]?.stringValue, let amount = BigUInt(decimal: raw), !amount.isZero
                else { continue }
                if let asset = TokenRegistry.find(chainID: "solana", contract: mint) {
                    holdings.append(Holding(asset: asset, amount: amount))
                } else {
                    unknown += 1
                }
            }
        }
        return ChainBalance(chainID: "solana", holdings: holdings, accountExists: true, unknownTokenCount: unknown, fetchedAt: .now)
    }

    // MARK: XRP Ledger

    /// `account_info` e, com a conta existindo, `account_lines` no mesmo servidor: duas
    /// chamadas, quantos tokens emitidos a lista tiver. Linha de confianca so nasce por
    /// `TrustSet` do dono; a que nao esta na lista conta como token desconhecido.
    private func xrpl(_ address: String) async throws -> ChainBalance {
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
            var unknown = 0
            if let lines = try? await XRPLReader.call(transport, provider.baseURL, "account_lines", [
                "account": .string(address), "ledger_index": .string("validated"), "limit": .int(400),
            ]) {
                let (listed, others) = Self.trustLineHoldings(lines)
                holdings += listed
                unknown = others
            }
            return ChainBalance(chainID: "xrpl", holdings: holdings, accountExists: true, unknownTokenCount: unknown, fetchedAt: .now)
        }
    }

    /// Os saldos positivos das linhas de confianca que estao na lista curada (codigo e
    /// emissor iguais), e quantas linhas com saldo ficaram de fora dela. Saldo negativo
    /// e o lado de quem emite, e nao entra.
    static func trustLineHoldings(_ result: StrictJSON) -> (holdings: [Holding], unknown: Int) {
        guard result.optionalField("error") == nil, let lines = try? result.field("lines", "account_lines").array("account_lines.lines") else {
            return ([], 0)
        }
        let curated = TokenRegistry.assets(on: .xrpl)
        var holdings: [Holding] = []
        var unknown = 0
        for line in lines {
            guard let issuer = try? line.field("account", "line").string("line.account"),
                  let code = try? line.field("currency", "line").string("line.currency"),
                  let text = try? line.field("balance", "line").string("line.balance"),
                  let value = try? XRPLDecimal(text), !value.isNegative, !value.isZero
            else { continue }
            let asset = curated.first { asset in
                guard case .issued(let listedCode, let listedIssuer) = asset.kind else { return false }
                return listedIssuer == issuer && listedCode.uppercased() == code.uppercased()
            }
            guard let asset else { unknown += 1; continue }
            if let amount = value.units(decimals: asset.decimals, roundingUp: false), !amount.isZero {
                holdings.append(Holding(asset: asset, amount: amount))
            }
        }
        return (holdings, unknown)
    }

    // MARK: Stellar

    private func stellar(_ address: String) async throws -> ChainBalance {
        let pool = pool("stellar", Endpoints.stellar)
        return try await pool.first { provider in
            let url = provider.baseURL.appendingPathComponent("accounts/\(address)")
            let json: JSONValue
            do {
                json = try await self.client.getJSON(JSONValue.self, from: url)
            } catch HTTPClient.Failure.status(404) {
                return ChainBalance(chainID: "stellar", holdings: [Holding(asset: .native(.stellar), amount: BigUInt())], accountExists: false, unknownTokenCount: 0, fetchedAt: .now)
            }
            var holdings: [Holding] = []
            var unknown = 0
            for entry in json["balances"]?.arrayValue ?? [] {
                guard let text = entry["balance"]?.stringValue, let amount = Self.stroops(text) else { continue }
                if entry["asset_type"]?.stringValue == "native" {
                    holdings.insert(Holding(asset: .native(.stellar), amount: amount), at: 0)
                } else if let code = entry["asset_code"]?.stringValue, let issuer = entry["asset_issuer"]?.stringValue {
                    if let asset = TokenRegistry.tokens.first(where: { $0.chainID == "stellar" && $0.kind == .issued(code: code, issuer: issuer) }) {
                        if !amount.isZero { holdings.append(Holding(asset: asset, amount: amount)) }
                    } else {
                        unknown += 1
                    }
                }
            }
            return ChainBalance(chainID: "stellar", holdings: holdings, accountExists: true, unknownTokenCount: unknown, fetchedAt: .now)
        }
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

    private func tron(_ address: String) async throws -> ChainBalance {
        let pool = pool("tron", Endpoints.tron)
        return try await pool.first { provider in
            if provider.name == "trongrid" {
                let json = try await self.client.getJSON(JSONValue.self, from: provider.baseURL.appendingPathComponent("v1/accounts/\(address)"))
                guard let account = json["data"]?[0] else {
                    return ChainBalance(chainID: "tron", holdings: [Holding(asset: .native(.tron), amount: BigUInt())], accountExists: false, unknownTokenCount: 0, fetchedAt: .now)
                }
                var holdings = [Holding(asset: .native(.tron), amount: BigUInt(UInt64(max(0, account["balance"]?.doubleValue ?? 0))))]
                var unknown = 0
                for entry in account["trc20"]?.arrayValue ?? [] {
                    guard case .object(let pair) = entry, let (contract, value) = pair.first,
                          let raw = value.stringValue, let amount = BigUInt(decimal: raw), !amount.isZero else { continue }
                    if let asset = TokenRegistry.find(chainID: "tron", contract: contract) {
                        holdings.append(Holding(asset: asset, amount: amount))
                    } else {
                        unknown += 1
                    }
                }
                return ChainBalance(chainID: "tron", holdings: holdings, accountExists: true, unknownTokenCount: unknown, fetchedAt: .now)
            }
            let body: JSONValue = .object(["address": .string(address), "visible": .bool(true)])
            let data = try await self.client.post(provider.baseURL.appendingPathComponent("wallet/getaccount"), json: try JSONEncoder().encode(body))
            let json = try JSONDecoder().decode(JSONValue.self, from: data)
            let exists = json["address"] != nil
            let sun = BigUInt(UInt64(max(0, json["balance"]?.doubleValue ?? 0)))
            return ChainBalance(chainID: "tron", holdings: [Holding(asset: .native(.tron), amount: sun)], accountExists: exists, unknownTokenCount: 0, fetchedAt: .now)
        }
    }

    // MARK: TON

    private func ton(_ address: String) async throws -> ChainBalance {
        let pool = pool("ton", Endpoints.ton)
        return try await pool.first { provider in
            if provider.name == "tonapi" {
                let json = try await self.client.getJSON(JSONValue.self, from: provider.baseURL.appendingPathComponent("accounts/\(address)"))
                let nano = BigUInt(UInt64(max(0, json["balance"]?.doubleValue ?? 0)))
                let status = json["status"]?.stringValue ?? "nonexist"
                var holdings = [Holding(asset: .native(.ton), amount: nano)]
                if let jettons = try? await self.client.getJSON(JSONValue.self, from: provider.baseURL.appendingPathComponent("accounts/\(address)/jettons")) {
                    for entry in jettons["balances"]?.arrayValue ?? [] {
                        guard let master = entry["jetton"]?["address"]?.stringValue,
                              let raw = entry["balance"]?.stringValue, let amount = BigUInt(decimal: raw), !amount.isZero else { continue }
                        if let asset = TokenRegistry.tokens.first(where: { $0.chainID == "ton" && TONAddressMatcher.same($0, raw: master) }) {
                            holdings.append(Holding(asset: asset, amount: amount))
                        }
                    }
                }
                return ChainBalance(chainID: "ton", holdings: holdings, accountExists: status != "nonexist", unknownTokenCount: 0, fetchedAt: .now)
            }
            var components = URLComponents(url: provider.baseURL.appendingPathComponent("account"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "address", value: address)]
            let json = try await self.client.getJSON(JSONValue.self, from: components.url!)
            let nano = BigUInt(decimal: json["balance"]?.stringValue ?? "0") ?? BigUInt()
            return ChainBalance(chainID: "ton", holdings: [Holding(asset: .native(.ton), amount: nano)], accountExists: json["status"]?.stringValue != "nonexist", unknownTokenCount: 0, fetchedAt: .now)
        }
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
