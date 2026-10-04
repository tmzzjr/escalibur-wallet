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
}

/// Os indexadores publicos sem chave que dizem quais ERC-20 uma conta tem.
///
/// - Blockscout (`/api/v2/addresses/{a}/tokens?type=ERC-20`): Ethereum, Base, OP,
///   Arbitrum, Polygon, Linea, Unichain e Celo, as mesmas instancias do historico.
///   Paginado de 50 em 50; ate tres paginas.
/// - Routescan (`/v2/network/mainnet/evm/{chainId}/address/{a}/erc20-holdings`):
///   Avalanche e Plasma.
///
/// BNB Chain, X Layer e Sonic nao tem indexador sem chave (conferido em 04/10/2026:
/// nem Blockscout nem Routescan atendem, e BscScan, OKLink, Etherscan v2 e Ankr pedem
/// chave). Nelas aparecem so os tokens da lista e as moedas custom.
enum TokenIndex {
    static let maxTokens = 150
    static let maxPages = 3

    static func fetch(_ provider: ProviderPool.Provider, owner: EVMAddress, transport: ReaderTransport) async throws -> [IndexedToken] {
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
