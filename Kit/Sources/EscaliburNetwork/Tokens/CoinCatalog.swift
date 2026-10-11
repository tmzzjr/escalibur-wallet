import EscaliburChains
import EscaliburCore
import Foundation

/// Uma moeda da lista completa do CoinGecko, com os contratos nas redes em que a
/// carteira recebe token por endereco.
public struct CatalogCoin: Codable, Sendable, Hashable, Identifiable {
    /// Uma rede em que a carteira recebe esta moeda, com o contrato fora da lista
    /// conferida.
    public struct Network: Codable, Sendable, Hashable {
        public let chainID: String
        /// O contrato como o CoinGecko escreve (minusculo na EVM), com o formato da rede
        /// conferido. A validacao completa (checksum, chave da rede) e a da moeda custom,
        /// `CustomToken.kind`, na hora de mostrar o endereco: as 20 mil moedas da lista
        /// nao passam todas pelo keccak a cada carga.
        public let contract: String

        public var chain: Chain? { Chain.find(chainID) }
    }

    /// O id do CoinGecko.
    public let id: String
    public let symbol: String
    public let name: String
    /// Onde a carteira recebe: EVM, Solana, Tron e TON, contrato valido e fora da lista.
    public let networks: [Network]

    public var isReceivable: Bool { !networks.isEmpty }
}

/// A lista completa de moedas do CoinGecko (`/coins/list?include_platform=true`, sem
/// chave): a busca de Receber acha qualquer moeda, como num app de carteira.
///
/// - Uma chamada para a lista inteira, a mesma para todo mundo: nao diz nada do dono. A
///   busca e local.
/// - So entra em rede onde a carteira recebe token por endereco e mostra o saldo (EVM,
///   Solana, Tron e TON, as redes de moeda custom por contrato). XRP Ledger e Stellar
///   pedem linha de confianca; Sui, Cardano, Polkadot, NEAR e Aptos ainda nao mostram
///   token fora da lista. Moeda so dessas redes, ou de redes que a carteira nao tem,
///   aparece na busca como ainda sem suporte, sem endereco.
/// - O contrato precisa ter o formato da rede, e o que ja esta na lista conferida fica de
///   fora: aparece pela lista, com o selo. Antes de virar endereco na tela, passa pela
///   validacao completa da moeda custom (`CustomToken.kind`).
/// - Nome e simbolo sao de quem listou: limpos, e fora quem tem link, isca ou caractere
///   escondido. Simbolo de stablecoin, de nativa ou da lista so com o id da lista: um
///   "USDT" de outro id nao aparece.
public enum CoinCatalog {
    public static let url = URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!
    /// A lista muda devagar: uma vez por dia basta.
    public static let lifetime: TimeInterval = 24 * 3600

    public static func fetch(client: HTTPClient = .shared) async throws -> [CatalogCoin] {
        let data = try await client.get(url, timeout: 30, maxBytes: HTTPClient.largeResponseBytes)
        return try parse(data)
    }

    /// A plataforma do CoinGecko de cada rede que recebe token por endereco.
    static let chains: [String: Chain] = {
        var out: [String: Chain] = [:]
        for (chainID, platform) in MarketService.tokenPlatforms {
            guard let chain = Chain.find(chainID), CustomToken.supports(chain), !CustomToken.usesIssuer(chain) else { continue }
            out[platform.gecko] = chain
        }
        return out
    }()

    /// Os contratos da lista conferida, como "rede:contrato" (minusculo na EVM).
    static let listedContracts: Set<String> = Set(TokenRegistry.tokens.compactMap { token -> String? in
        guard case .token(let contract) = token.kind, let chain = Chain.find(token.chainID) else { return nil }
        return "\(token.chainID):\(chain.family == .evm ? contract.lowercased() : contract)"
    })

    static let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    static let base64url = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    static let hex = Set("0123456789abcdef")

    /// O formato do contrato na rede, sem checksum: barato para 30 mil contratos.
    static func shape(_ raw: String, chain: Chain) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        switch chain.family {
        case .evm:
            let lower = text.lowercased()
            guard lower.count == 42, lower.hasPrefix("0x") else { return nil }
            let body = lower.dropFirst(2)
            guard body.allSatisfy(hex.contains), body.contains(where: { $0 != "0" }) else { return nil }
            return lower
        case .solana:
            return (32...44).contains(text.count) && text.allSatisfy(base58.contains) ? text : nil
        case .tron:
            return text.count == 34 && text.hasPrefix("T") && text.allSatisfy(base58.contains) ? text : nil
        case .ton:
            if text.count == 48, text.allSatisfy(base64url.contains) { return text }
            if text.count == 66, text.hasPrefix("0:"), text.dropFirst(2).lowercased().allSatisfy(hex.contains) { return text }
            return nil
        default:
            return nil
        }
    }

    static func parse(_ data: Data) throws -> [CatalogCoin] {
        struct Raw: Decodable {
            let id: String
            let symbol: String
            let name: String
            let platforms: [String: String?]?
        }
        let raws: [Raw]
        do { raws = try JSONDecoder().decode([Raw].self, from: data) } catch { throw HTTPClient.Failure.decoding("lista de moedas") }
        let listedIDs = Set(TokenRegistry.tokens.compactMap(\.coingeckoID) + Chain.all.map(\.coingeckoID))
        let order = Dictionary(Chain.all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return raws.compactMap { raw -> CatalogCoin? in
            guard !raw.id.isEmpty, raw.id.count <= 120 else { return nil }
            let symbol = TokenSafety.clean(raw.symbol.uppercased(), limit: TokenSafety.symbolLimit)
            let name = TokenSafety.clean(raw.name, limit: TokenSafety.nameLimit)
            guard !symbol.isEmpty, !name.isEmpty, TokenSafety.textReasons(symbol: raw.symbol, name: raw.name).isEmpty else { return nil }
            let listed = listedIDs.contains(raw.id)
            guard listed || !TokenSafety.isProtectedAnywhere(symbol) else { return nil }
            var networks: [CatalogCoin.Network] = []
            for (platform, contract) in (raw.platforms ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let contract, let chain = chains[platform], let shaped = shape(contract, chain: chain),
                      !listedContracts.contains("\(chain.id):\(shaped)")
                else { continue }
                networks.append(.init(chainID: chain.id, contract: shaped))
            }
            networks.sort { (order[$0.chainID] ?? .max) < (order[$1.chainID] ?? .max) }
            return CatalogCoin(id: raw.id, symbol: symbol, name: name, networks: networks)
        }
    }

    /// As moedas que casam com a busca, das mais provaveis para as menos: simbolo exato,
    /// simbolo que comeca com o texto, nome que comeca, nome que contem; dentro de cada
    /// grupo, pela posicao no mercado (`rank`, menor primeiro) e pelo nome mais curto.
    public static func search(_ coins: [CatalogCoin], query: String, rank: [String: Int], limit: Int) -> [CatalogCoin] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return [] }
        let upper = text.uppercased()
        let lower = text.lowercased()
        var scored: [(score: Int, rank: Int, length: Int, coin: CatalogCoin)] = []
        for coin in coins {
            let score: Int
            if coin.symbol == upper {
                score = 0
            } else if coin.symbol.hasPrefix(upper) {
                score = 1
            } else {
                let name = coin.name.lowercased()
                if name.hasPrefix(lower) {
                    score = 2
                } else if name.contains(lower) || coin.id.contains(lower) {
                    score = 3
                } else {
                    continue
                }
            }
            scored.append((score, rank[coin.id] ?? .max, coin.name.count, coin))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.rank != b.rank { return a.rank < b.rank }
            if a.length != b.length { return a.length < b.length }
            return a.coin.id < b.coin.id
        }
        return scored.prefix(limit).map(\.coin)
    }
}
