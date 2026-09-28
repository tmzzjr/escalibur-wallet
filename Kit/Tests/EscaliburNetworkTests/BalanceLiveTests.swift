import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra os nos reais. So com ESCALIBUR_REDE=1.
@Suite("Saldos ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"))
struct BalanceLiveTests {
    let service = BalanceService()

    @Test("Ethereum: nativo e tokens da lista")
    func ethereum() async throws {
        let balance = try await service.balance(chain: .ethereum, addresses: ["0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"])
        #expect(balance.holdings.first?.asset.kind == .native)
        #expect(!(balance.holdings.first?.amount.isZero ?? true))
    }

    @Test("Bitcoin pelo Esplora")
    func bitcoin() async throws {
        // Endereco do bloco genesis: recebe pequenas doacoes ate hoje.
        let balance = try await service.balance(chain: .bitcoin, addresses: ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"])
        #expect(!(balance.holdings.first?.amount.isZero ?? true))
    }

    @Test("XRP Ledger: conta existente e conta inexistente")
    func xrpl() async throws {
        let rich = try await service.balance(chain: .xrpl, addresses: ["rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"])
        #expect(rich.accountExists)
        let empty = try await service.balance(chain: .xrpl, addresses: ["rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3"])
        #expect(empty.accountExists == false || empty.holdings.count == 1)
    }

    @Test("Stellar, Solana, Tron")
    func others() async throws {
        let stellar = try await service.balance(chain: .stellar, addresses: ["GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"])
        #expect(stellar.chainID == "stellar")
        let solana = try await service.balance(chain: .solana, addresses: ["HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"])
        #expect(solana.holdings.first?.asset.symbol == "SOL")
        let tron = try await service.balance(chain: .tron, addresses: ["TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH"])
        #expect(tron.holdings.first?.asset.symbol == "TRX")
    }
}

/// A lista curada de tokens confere com a propria cadeia: cada contrato EVM responde
/// `decimals()` igual ao compilado e um `symbol()` que e o da lista ou um nome conhecido
/// do mesmo ativo, em dois nos diferentes.
@Suite("Lista de tokens contra a cadeia", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"))
struct TokenRegistryLiveTests {
    /// Os nomes que a cadeia usa para o mesmo ativo. O USDT0 da Tether (Arbitrum,
    /// Polygon, Plasma, X Layer, Unichain, Optimism) responde "USDT0" ou "USD₮0"; na Celo,
    /// "USD₮"; na Avalanche, "USDt". O LINK da Avalanche e o LINK.e da ponte que a
    /// Chainlink lista; o CAKE responde "Cake" e o XAUT, "XAUt".
    static let symbolAliases: [String: Set<String>] = [
        "USDT": ["USDT", "USD₮", "USDT0", "USD₮0", "USDt"],
        "LINK": ["LINK", "LINK.e"],
        "CAKE": ["Cake"],
        "XAUT": ["XAUt"],
    ]

    /// keccak256 do codigo executavel do Multicall3 (sem o trailer CBOR de metadados do
    /// solc), igual nas 13 redes em 27/09/2026. Na Linea so o hash de metadados muda.
    static let multicall3CodeHash = "51abac3e901750a3f73ad94b55bcf66bd323f31f8042408dfd36356373496e53"

    static func rpc(_ url: URL, _ method: String, _ params: [StrictJSON]) async throws -> StrictJSON {
        try await EVMReader.call(HTTPClient.shared, url, method, params)
    }

    /// Codigo sem o trailer de metadados: os dois ultimos bytes dizem o tamanho do CBOR.
    static func executable(_ code: [UInt8]) -> [UInt8] {
        guard code.count > 2 else { return code }
        let metadata = Int(code[code.count - 2]) << 8 | Int(code[code.count - 1])
        guard metadata + 2 < code.count else { return code }
        return Array(code.prefix(code.count - metadata - 2))
    }

    /// `symbol()` e `decimals()` de todos os tokens da rede num `aggregate3`, lidos em dois
    /// provedores diferentes (o proximo da lista entra se um falhar). O Multicall3 de cada
    /// provedor e conferido pelo codigo antes.
    @Test("decimals() e symbol() de cada ERC-20 batem com a lista, em dois nos, e o Multicall3 e o conferido")
    func evmDecimals() async throws {
        let symbolCall = try ABIFunction("symbol()").selector
        for chain in Chain.evmChains {
            let tokens = TokenRegistry.assets(on: chain).compactMap { asset -> (Asset, EVMAddress)? in
                guard case .token(let contract) = asset.kind, let address = try? EVMAddress(contract) else { return nil }
                return (asset, address)
            }
            guard !tokens.isEmpty else { continue }
            let calls = tokens.flatMap { [Multicall3.Call(target: $0.1, data: symbolCall), Multicall3.Call(target: $0.1, data: ERC20.decimals())] }
            let data = try Multicall3.aggregate3(calls)
            var answered = 0
            for provider in Endpoints.evm[chain.id] ?? [] where answered < 2 {
                do {
                    let code = try await Self.rpc(provider.baseURL, "eth_getCode", [.string(Multicall3.address.checksummed), .string("latest")]).hexData("code")
                    #expect(Hex.encode(Hash.keccak256(Self.executable(code))) == Self.multicall3CodeHash, "\(chain.id) \(provider.name): Multicall3")
                    let request: StrictJSON = .object(["to": .string(Multicall3.address.checksummed), "data": .string(Hex.encode(data, prefix: true))])
                    let returned = try await Self.rpc(provider.baseURL, "eth_call", [request, .string("latest")]).hexData("aggregate3")
                    let results = try Multicall3.decodeAggregate3(returned, expected: calls.count)
                    answered += 1
                    for (index, (asset, contract)) in tokens.enumerated() {
                        let label = "\(chain.id) \(provider.name) \(asset.symbol) \(contract.checksummed)"
                        guard let symbolData = results[2 * index], let decimalsData = results[2 * index + 1] else {
                            Issue.record("\(label): symbol() ou decimals() reverteu"); continue
                        }
                        let decimals = try ERC20.decodeDecimals(decimalsData)
                        #expect(Int(decimals) == asset.decimals, "\(label): cadeia diz \(decimals), lista diz \(asset.decimals)")
                        let symbol = try ABI.decode([.string], from: symbolData).first?.stringValue ?? ""
                        #expect((Self.symbolAliases[asset.symbol] ?? [asset.symbol]).contains(symbol), "\(label): cadeia diz \(symbol)")
                    }
                } catch {
                    Live.note("\(chain.id) \(provider.name): \(error)")
                }
            }
            #expect(answered == 2, "\(chain.id): so \(answered) provedor(es) responderam")
        }
    }

    @Test("Mints da Solana em dois RPCs: programa Token classico, casas da lista, sem extensao")
    func solanaMints() async throws {
        for token in TokenRegistry.tokens where token.chainID == "solana" {
            guard case .token(let mint) = token.kind else { continue }
            var answered = 0
            for provider in Endpoints.solana where answered < 2 {
                guard let result = try? await JSONRPC.call(
                    provider.baseURL, method: "getAccountInfo",
                    params: [.string(mint), .object(["encoding": .string("jsonParsed")])], as: JSONValue.self
                ) else { continue }
                answered += 1
                let value = result["value"]
                #expect(value != nil && value != .null, "\(token.symbol) \(mint): mint nao existe")
                // O historico e a troca derivam o ATA com o programa classico.
                #expect(value?["owner"]?.stringValue == "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", "\(token.symbol): dono")
                let info = value?["data"]?["parsed"]?["info"]
                #expect(info?["decimals"]?.doubleValue.map(Int.init) == token.decimals, "\(token.symbol): casas")
                #expect(info?["extensions"] == nil, "\(token.symbol): extensao Token-2022")
            }
            #expect(answered == 2, "\(token.symbol): so \(answered) RPC(s)")
        }
    }

    @Test("Emissores do XRP Ledger em dois servidores: a conta existe e nao cobra taxa de transferencia")
    func xrplIssuers() async throws {
        let transport = HTTPClient.shared
        for token in TokenRegistry.tokens where token.chainID == "xrpl" {
            guard case .issued(_, let issuer) = token.kind else { continue }
            var answered = 0
            for provider in Endpoints.xrpl where answered < 2 {
                guard let result = try? await XRPLReader.call(transport, provider.baseURL, "account_info", [
                    "account": .string(issuer), "ledger_index": .string("validated"),
                ]), let data = result.optionalField("account_data") else { continue }
                answered += 1
                #expect(data.optionalField("TransferRate") == nil, "\(token.symbol): TransferRate")
                #expect(data.optionalField("Domain") != nil, "\(token.symbol): sem Domain")
            }
            #expect(answered == 2, "\(token.symbol): so \(answered) servidor(es)")
        }
    }

    @Test("Contrato do USDT na Tron, emissor do USDC na Stellar e master do USDT na TON existem")
    func otherRegistries() async throws {
        let client = HTTPClient.shared
        for token in TokenRegistry.tokens {
            switch (token.chainID, token.kind) {
            case ("tron", .token(let contract)):
                let body: JSONValue = .object(["value": .string(contract), "visible": .bool(true)])
                let data = try await client.post(Endpoints.tron[0].baseURL.appendingPathComponent("wallet/getcontract"), json: try JSONEncoder().encode(body))
                let json = try JSONDecoder().decode(JSONValue.self, from: data)
                #expect(json["contract_address"] != nil, "\(token.symbol) \(contract): contrato nao existe")
            case ("stellar", .issued(let code, let issuer)):
                var components = URLComponents(url: Endpoints.stellar[0].baseURL.appendingPathComponent("assets"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "asset_code", value: code), URLQueryItem(name: "asset_issuer", value: issuer)]
                let json = try await client.getJSON(JSONValue.self, from: components.url!)
                #expect((json["_embedded"]?["records"]?.arrayValue ?? []).count == 1, "\(code) \(issuer): ativo nao existe")
            case ("ton", .token(let master)):
                let json = try await client.getJSON(JSONValue.self, from: Endpoints.ton[0].baseURL.appendingPathComponent("jettons/\(master)"))
                let decimals = json["metadata"]?["decimals"]?.stringValue.flatMap(Int.init)
                #expect(decimals == token.decimals, "\(token.symbol) \(master): casas \(String(describing: decimals))")
            default:
                continue
            }
        }
    }
}
