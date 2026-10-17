import EscaliburChains
import EscaliburCore
import Foundation

/// Um ERC-20 que o indexador diz que a conta tem. So o contrato e levado a serio: o
/// saldo e as casas exibidos sao relidos na rede (`BalanceService`), e nome e simbolo
/// sao os que o contrato declarou, que qualquer um escolhe.
struct IndexedToken: Sendable, Equatable {
    let contract: EVMAddress
    let name: String
    let symbol: String
    let decimals: Int?
    /// O indexador marcou como golpe (`reputation: "scam"` do Blockscout).
    let flagged: Bool
    /// A logo que a lista de tokens do CoinGecko da para o contrato (`TokenListScan`), no
    /// host de imagens do CoinGecko. Nunca a que o token declara.
    var logo: URL? = nil
}

/// Os indexadores publicos sem chave que dizem quais ERC-20 uma conta tem.
///
/// - Blockscout (`/api/v2/addresses/{a}/tokens?type=ERC-20`): Ethereum, Base, OP,
///   Arbitrum, Polygon, Linea, Unichain e Celo, as mesmas instancias do historico.
///   Paginado de 50 em 50; ate tres paginas.
/// - Routescan (`/v2/network/mainnet/evm/{chainId}/address/{a}/erc20-holdings`):
///   Avalanche e Plasma.
/// - Alchemy (`alchemy_getTokenBalances` e `alchemy_getTokenMetadata`, com chave da
///   Escalibur): Base, Arbitrum e Polygon, onde o Blockscout responde 403, e BNB Chain,
///   que nao tem indexador sem chave.
///
/// X Layer e Sonic nao tem indexador sem chave (conferido em 04/10/2026: nem Blockscout
/// nem Routescan atendem, e OKLink, Etherscan v2 e Ankr pedem chave). Nelas o que esta
/// fora da lista conferida e das moedas custom vem da lista do CoinGecko (`TokenListScan`).
enum TokenIndex {
    static let maxTokens = 150
    static let maxPages = 3

    static func fetch(_ provider: ProviderPool.Provider, owner: EVMAddress, transport: ReaderTransport) async throws -> [IndexedToken] {
        if provider.name == "alchemy" {
            return try await fetchAlchemy(provider.baseURL, owner: owner, transport: transport)
        }
        if provider.name == "routescan" {
            let url = provider.baseURL.adding(path: "address/\(owner.checksummed)/erc20-holdings").adding(query: [("limit", "100")])
            return try parseRoutescan(StrictJSON.parse(try await transport.send(.get(url, timeout: 20))))
        }
        var out: [IndexedToken] = []
        var extra: [(String, String)] = []
        for _ in 0..<maxPages {
            let url = provider.baseURL.adding(path: "addresses/\(owner.checksummed)/tokens").adding(query: [("type", "ERC-20")] + extra)
            let page = try parseBlockscout(StrictJSON.parse(try await transport.send(.get(url, timeout: 20))))
            out += page.tokens
            guard let next = page.next, !next.isEmpty, out.count < maxTokens else { break }
            extra = next
        }
        return out
    }

    /// Uma pagina do Blockscout. Item fora do formato e pulado; resposta sem `items` e
    /// erro.
    static func parseBlockscout(_ json: StrictJSON) throws -> (tokens: [IndexedToken], next: [(String, String)]?) {
        let items = try json.field("items", "tokens").array("tokens.items")
        let tokens: [IndexedToken] = items.compactMap { item in
            guard let token = try? item.field("token", "item"),
                  (try? token.field("type", "token").string("type")) == "ERC-20",
                  let hash = try? token.field("address_hash", "token").string("address_hash"),
                  let contract = try? EVMAddress(hash)
            else { return nil }
            let decimals = (try? token.field("decimals", "token").decimalString("decimals")).flatMap(\.uint64).flatMap { $0 <= 36 ? Int($0) : nil }
            return IndexedToken(
                contract: contract,
                name: token.optionalField("name").flatMap { try? $0.string("name") } ?? "",
                symbol: token.optionalField("symbol").flatMap { try? $0.string("symbol") } ?? "",
                decimals: decimals,
                flagged: token.optionalField("reputation").flatMap { try? $0.string("reputation") } == "scam"
            )
        }
        var next: [(String, String)]?
        if let params = json.optionalField("next_page_params")?.objectValue {
            next = params.sorted { $0.key < $1.key }.compactMap { key, value in
                switch value {
                case .string(let text): return (key, text)
                case .number(let text): return (key, text)
                case .bool(let flag): return (key, flag ? "true" : "false")
                default: return nil
                }
            }
        }
        return (tokens, next)
    }

    /// Alchemy: todos os ERC-20 que a conta ja teve, com o saldo de agora, 100 por pagina
    /// (`alchemy_getTokenBalances`); dos que tem saldo, nome, simbolo e casas num lote
    /// JSON-RPC so (`alchemy_getTokenMetadata`). Sem o lote, os tokens vem sem nome. A
    /// logo que o provedor manda nunca e usada: a de um golpe e parte da isca.
    static func fetchAlchemy(_ url: URL, owner: EVMAddress, transport: ReaderTransport) async throws -> [IndexedToken] {
        var held: [EVMAddress] = []
        var pageKey: String?
        for _ in 0..<maxPages {
            var params: [StrictJSON] = [.string(owner.checksummed), .string("erc20")]
            if let pageKey { params.append(.object(["pageKey": .string(pageKey)])) }
            let page = try parseAlchemyBalances(try await EVMReader.call(transport, url, "alchemy_getTokenBalances", params))
            held += page.held
            guard let next = page.next, held.count < maxTokens else { break }
            pageKey = next
        }
        held = Array(held.prefix(maxTokens))
        guard !held.isEmpty else { return [] }
        let batch: StrictJSON = .array(held.enumerated().map { id, contract in
            .object([
                "jsonrpc": .string("2.0"), "id": .int(id), "method": .string("alchemy_getTokenMetadata"),
                "params": .array([.string(contract.checksummed)]),
            ])
        })
        let metadata = (try? StrictJSON.parse(try await transport.send(.post(url, batch)))).map(parseAlchemyMetadata) ?? [:]
        return held.enumerated().map { id, contract in
            let facts = metadata[id]
            return IndexedToken(contract: contract, name: facts?.name ?? "", symbol: facts?.symbol ?? "", decimals: facts?.decimals, flagged: false)
        }
    }

    /// Uma pagina de `alchemy_getTokenBalances`: so os contratos com saldo maior que zero
    /// (os zerados sao os que a conta ja teve). Saldo com erro ou nulo e pulado.
    static func parseAlchemyBalances(_ result: StrictJSON) throws -> (held: [EVMAddress], next: String?) {
        let items = try result.field("tokenBalances", "saldos").array("saldos.tokenBalances")
        let held: [EVMAddress] = items.compactMap { item in
            guard let text = try? item.field("contractAddress", "item").string("contractAddress"), let contract = try? EVMAddress(text),
                  let amount = try? item.optionalField("tokenBalance")?.quantity("tokenBalance"), !amount.isZero
            else { return nil }
            return contract
        }
        let next = result.optionalField("pageKey").flatMap { try? $0.string("pageKey") }
        return (held, next.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// As respostas do lote de `alchemy_getTokenMetadata`, pelo `id` de cada pedido.
    static func parseAlchemyMetadata(_ json: StrictJSON) -> [Int: (name: String, symbol: String, decimals: Int?)] {
        guard let answers = try? json.array("metadados") else { return [:] }
        var out: [Int: (name: String, symbol: String, decimals: Int?)] = [:]
        for answer in answers {
            guard let id = (try? answer.field("id", "id").uint64("id")).flatMap({ Int(exactly: $0) }),
                  let result = answer.optionalField("result")
            else { continue }
            let decimals = (try? result.optionalField("decimals")?.unsigned("decimals")).flatMap { $0 }.flatMap(\.uint64).flatMap { $0 <= 36 ? Int($0) : nil }
            out[id] = (
                result.optionalField("name").flatMap { try? $0.string("name") } ?? "",
                result.optionalField("symbol").flatMap { try? $0.string("symbol") } ?? "",
                decimals
            )
        }
        return out
    }

    static func parseRoutescan(_ json: StrictJSON) throws -> [IndexedToken] {
        let items = try json.field("items", "holdings").array("holdings.items")
        return items.compactMap { item in
            guard let hash = try? item.field("tokenAddress", "item").string("tokenAddress"), let contract = try? EVMAddress(hash) else {
                return nil
            }
            let decimals = (try? item.field("tokenDecimals", "item").unsigned("tokenDecimals")).flatMap(\.uint64).flatMap { $0 <= 36 ? Int($0) : nil }
            return IndexedToken(
                contract: contract,
                name: item.optionalField("tokenName").flatMap { try? $0.string("tokenName") } ?? "",
                symbol: item.optionalField("tokenSymbol").flatMap { try? $0.string("tokenSymbol") } ?? "",
                decimals: decimals, flagged: false
            )
        }
    }
}
