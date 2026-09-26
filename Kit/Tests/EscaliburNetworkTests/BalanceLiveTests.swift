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
    /// Polygon, Plasma, X Layer, Unichain) responde "USDT0" ou "USD₮0"; na Celo, "USD₮";
    /// na Avalanche, "USDt". A lista mostra "USDT" em todos.
    static let symbolAliases: [String: Set<String>] = [
        "USDT": ["USDT", "USD₮", "USDT0", "USD₮0", "USDt"],
    ]

    /// `symbol()` como string ABI (offset, tamanho, bytes).
    static func decodeString(_ hex: String) -> String? {
        guard let bytes = Hex.decode(String(hex.dropFirst(2))), bytes.count >= 64,
              let length = BigUInt(bigEndian: bytes[32..<64]).uint64, bytes.count >= 64 + Int(length)
        else { return nil }
        return String(bytes: bytes[64..<(64 + Int(length))], encoding: .utf8)
    }

    @Test("decimals() e symbol() de cada ERC-20 batem com a lista, em dois nos")
    func evmDecimals() async throws {
        for token in TokenRegistry.tokens {
            guard let chain = token.chain, chain.family == .evm, case .token(let contract) = token.kind else { continue }
            let providers = Array((Endpoints.evm[chain.id] ?? []).prefix(2))
            var answers: [Int] = []
            var symbols: [String] = []
            for provider in providers {
                let call: JSONValue = .object(["to": .string(contract), "data": .string("0x313ce567")])
                if let hex = try? await JSONRPC.call(provider.baseURL, method: "eth_call", params: [call, .string("latest")], as: String.self),
                   let value = BigUInt(hex: hex)?.uint64 {
                    answers.append(Int(value))
                }
                let symbolCall: JSONValue = .object(["to": .string(contract), "data": .string("0x95d89b41")])
                if let hex = try? await JSONRPC.call(provider.baseURL, method: "eth_call", params: [symbolCall, .string("latest")], as: String.self),
                   let symbol = Self.decodeString(hex) {
                    symbols.append(symbol)
                }
            }
            #expect(!answers.isEmpty, "\(chain.id) \(token.symbol): nenhum no respondeu")
            for answer in answers {
                #expect(answer == token.decimals, "\(chain.id) \(token.symbol) \(contract): cadeia diz \(answer), lista diz \(token.decimals)")
            }
            #expect(!symbols.isEmpty, "\(chain.id) \(token.symbol): symbol() sem resposta")
            let accepted = Self.symbolAliases[token.symbol] ?? [token.symbol]
            for symbol in symbols {
                #expect(accepted.contains(symbol), "\(chain.id) \(token.symbol) \(contract): cadeia diz \(symbol)")
            }
        }
    }

    @Test("Mints da Solana existem, pertencem ao programa de token e tem as casas da lista")
    func solanaMints() async throws {
        for token in TokenRegistry.tokens where token.chainID == "solana" {
            guard case .token(let mint) = token.kind else { continue }
            let result = try await JSONRPC.call(
                Endpoints.solana[0].baseURL, method: "getAccountInfo",
                params: [.string(mint), .object(["encoding": .string("jsonParsed")])], as: JSONValue.self
            )
            let value = result["value"]
            #expect(value != nil && value != .null, "\(token.symbol) \(mint): mint nao existe")
            let owner = value?["owner"]?.stringValue ?? ""
            #expect(owner == "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" || owner == "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb", "\(token.symbol): dono \(owner)")
            let decimals = value?["data"]?["parsed"]?["info"]?["decimals"]?.doubleValue
            #expect(decimals.map(Int.init) == token.decimals, "\(token.symbol): casas \(String(describing: decimals))")
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
