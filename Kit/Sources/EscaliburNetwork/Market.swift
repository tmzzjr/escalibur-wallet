import EscaliburChains
import Foundation

/// Uma moeda na lista de mercado.
public struct MarketCoin: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let symbol: String
    public let name: String
    public let imageURL: URL?
    public let price: Double
    public let change24h: Double?
    public let marketCap: Double?
    public let volume24h: Double?
    public let rank: Int?
    public let sparkline: [Double]
}

public struct PricePoint: Sendable, Hashable, Codable {
    public let time: Date
    public let price: Double

    public init(time: Date, price: Double) {
        self.time = time
        self.price = price
    }
}

public struct Quote: Sendable, Hashable, Codable {
    public let price: Double
    public let change24h: Double?
}

public enum ChartRange: String, CaseIterable, Sendable, Identifiable {
    case day, week, month, year, all

    public var id: String { rawValue }

    /// O parametro `days` do CoinGecko.
    var days: String {
        switch self {
        case .day: return "1"
        case .week: return "7"
        case .month: return "30"
        case .year: return "365"
        case .all: return "max"
        }
    }
}

/// De onde veio um dado de mercado: a tela diz a fonte e a hora.
public enum MarketSource: String, Sendable, Codable, Hashable {
    case coingecko = "CoinGecko"
    case coinpaprika = "CoinPaprika"
    case okx = "OKX"
}

/// A lista de mercado com a hora e a fonte.
public struct MarketSnapshot: Sendable, Hashable {
    public let coins: [MarketCoin]
    public let fetchedAt: Date
    public let source: MarketSource
    /// As fontes falharam agora: e o ultimo dado bom, da hora `fetchedAt`.
    public let isStale: Bool
}

/// O historico de preco com a hora e a fonte.
public struct ChartSnapshot: Sendable, Hashable {
    public let points: [PricePoint]
    public let fetchedAt: Date
    public let source: MarketSource
    public let isStale: Bool
}

/// O que a pagina da moeda mostra alem do grafico, como as boas corretoras. Todo campo
/// pode faltar: a fonte nem sempre tem, e a tela mostra so o que veio.
public struct MarketCoinDetails: Sendable, Hashable, Codable {
    public let id: String
    public let currency: String
    public var price: Double?
    public var high24h: Double?
    public var low24h: Double?
    public var allTimeHigh: Double?
    public var allTimeHighDate: Date?
    /// Distancia do preco ate a maxima historica, em %, negativa abaixo dela.
    public var fromAllTimeHigh: Double?
    public var marketCap: Double?
    public var fullyDilutedValuation: Double?
    public var volume24h: Double?
    public var rank: Int?
    public var circulatingSupply: Double?
    public var totalSupply: Double?
    public var maxSupply: Double?
    /// A fonte diz que a emissao nao tem teto (CoinGecko `max_supply_infinite`).
    public var unlimitedSupply: Bool
    /// "Sobre", em texto puro e curto, sem links.
    public var about: String?
    public var aboutInPortuguese: Bool
    public let source: MarketSource
    public let fetchedAt: Date
    public var isStale: Bool
}

/// Precos, lista de mercado, historico e detalhe, com contingencia entre provedores e
/// cache.
///
/// Preco serve para exibir e para checagem de sanidade de cotacao, **nunca** para
/// calcular o minimo garantido de um swap (docs/seguranca.md §5.4). Por isso um
/// provedor de preco mentindo muda um numero na tela, e nada mais.
///
/// Primario: CoinGecko (API publica, que corta o IP com 429 quando a cota acaba).
/// Reserva: CoinPaprika (lista, cotacoes e detalhe, sem chave) e OKX (velas publicas em
/// USDT) para o grafico. Depois de um 429 o CoinGecko fica de fora por um tempo que
/// dobra a cada recusa (1 a 10 min), e as leituras vao direto a reserva.
///
/// Cache: cotacao por moeda vale 30 s (a lista do Mercado tambem preenche), a lista 25
/// s (a tela pede a cada 30 s, so com a aba na frente), o grafico de 24 h 2 min e os
/// outros 10, o detalhe 5 min. Quando as fontes falham, volta o ultimo dado bom, com a
/// hora dele, em vez de nada.
public actor MarketService {
    public static let shared = MarketService()

    private let transport: ReaderTransport
    private let now: @Sendable () -> Date

    private var prices: [String: [String: (at: Date, quote: Quote)]] = [:]
    private var lists: [String: MarketSnapshot] = [:]
    private var charts: [String: ChartSnapshot] = [:]
    private var details: [String: MarketCoinDetails] = [:]
    private var paprikaLists: [String: (at: Date, tickers: [PaprikaTicker])] = [:]
    /// Id do CoinPaprika por id do CoinGecko, aprendido da lista do CoinPaprika.
    private var learnedPaprikaIDs: [String: String] = [:]
    private var geckoPausedUntil: Date?
    private var geckoPause: TimeInterval = 0
    /// Preco por contrato (moeda custom e token fora da lista), por moeda e por
    /// `Asset.id`. `nil` guardado: a fonte respondeu e nao tem preco para o contrato.
    private var tokenPrices: [String: [String: (at: Date, quote: Quote?)]] = [:]
    /// Contrato para id do CoinPaprika, por plataforma: a reserva do preco por contrato.
    private var paprikaContracts: [String: (at: Date, ids: [String: String])] = [:]

    static let quoteLifetime: TimeInterval = 30
    static let listLifetime: TimeInterval = 25
    static let detailLifetime: TimeInterval = 300
    static func chartLifetime(_ range: ChartRange) -> TimeInterval { range == .day ? 120 : 600 }

    public init(client: HTTPClient = .shared) {
        self.init(transport: client)
    }

    init(transport: ReaderTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    static let gecko = URL(string: "https://api.coingecko.com/api/v3")!
    static let paprika = URL(string: "https://api.coinpaprika.com/v1")!
    static let okx = URL(string: "https://www.okx.com/api/v5")!

    // MARK: Rede

    private func get<T: Decodable>(_ type: T.Type, _ url: URL, timeout: TimeInterval = 10) async throws -> T {
        let data = try await transport.send(ReaderRequest(method: .get, url: url, timeout: timeout))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPClient.Failure.decoding(String(describing: type))
        }
    }

    private static func url(_ base: URL, _ path: String, _ query: [(String, String)] = []) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return components.url!
    }

    /// O CoinGecko, se nao estiver de castigo. Um 429 poe de castigo, e o tempo dobra a
    /// cada recusa seguida; uma resposta boa zera.
    private func fromGecko<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        if let until = geckoPausedUntil, now() < until { throw HTTPClient.Failure.status(429) }
        do {
            let value = try await operation()
            geckoPause = 0
            geckoPausedUntil = nil
            return value
        } catch HTTPClient.Failure.status(429) {
            geckoPause = min(max(geckoPause * 2, 60), 600)
            geckoPausedUntil = now().addingTimeInterval(geckoPause)
            throw HTTPClient.Failure.status(429)
        }
    }

    /// So para os testes: ate quando o CoinGecko esta de fora.
    func geckoPaused() -> Date? { geckoPausedUntil }

    // MARK: Precos

    /// Preco e variacao de 24 h por id do CoinGecko, na moeda pedida ("brl", "usd").
    ///
    /// O que esta no cache ha menos de 30 s nao e pedido de novo; o resto vai numa
    /// chamada so. Se as duas fontes falham, o id volta com o ultimo preco bom (a
    /// carteira nao perde o preco de uma moeda por uma consulta que falhou).
    public func quotes(ids: [String], currency: String) async throws -> [String: Quote] {
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty else { return [:] }
        let moment = now()
        let known = prices[currency] ?? [:]
        var out: [String: Quote] = [:]
        var missing: [String] = []
        for id in unique {
            if let entry = known[id], moment.timeIntervalSince(entry.at) < Self.quoteLifetime { out[id] = entry.quote } else { missing.append(id) }
        }
        guard !missing.isEmpty else { return out }
        var fetched: [String: Quote]?
        do {
            fetched = try await fromGecko { try await self.geckoQuotes(ids: missing, currency: currency) }
        } catch {
            fetched = try? await paprikaQuotes(ids: missing, currency: currency)
        }
        if let fetched, !fetched.isEmpty {
            remember(fetched, currency: currency)
            out.merge(fetched) { $1 }
        }
        for id in missing where out[id] == nil {
            if let stale = known[id] { out[id] = stale.quote }
        }
        guard !out.isEmpty else { throw HTTPClient.Failure.offline }
        return out
    }

    private func remember(_ quotes: [String: Quote], currency: String) {
        let moment = now()
        for (id, quote) in quotes { prices[currency, default: [:]][id] = (moment, quote) }
    }

    private func geckoQuotes(ids: [String], currency: String) async throws -> [String: Quote] {
        let url = Self.url(Self.gecko, "simple/price", [
            ("ids", ids.joined(separator: ",")), ("vs_currencies", currency), ("include_24hr_change", "true"),
        ])
        let raw = try await get([String: [String: Double?]].self, url)
        var out: [String: Quote] = [:]
        for (id, values) in raw {
            guard let price = values[currency] ?? nil, price.isFinite, price > 0 else { continue }
            out[id] = Quote(price: price, change24h: values["\(currency)_24h_change"] ?? nil)
        }
        return out
    }

    /// Poucas moedas: uma chamada por moeda (`/tickers/{id}`, rapida). Muitas: a lista
    /// inteira do CoinPaprika numa chamada so (1,4 MB), guardada por um minuto.
    private func paprikaQuotes(ids: [String], currency: String) async throws -> [String: Quote] {
        var out: [String: Quote] = [:]
        if ids.count <= 3 {
            for id in ids {
                guard let paprikaID = paprikaID(for: id) else { continue }
                let url = Self.url(Self.paprika, "tickers/\(paprikaID)", [("quotes", currency.uppercased())])
                guard let ticker = try? await get(PaprikaTicker.self, url), let quote = ticker.quote(currency) else { continue }
                out[id] = quote
            }
        } else {
            let tickers = try await paprikaTickers(currency: currency)
            let byPaprika = Dictionary(tickers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in ids {
                if let paprikaID = paprikaID(for: id), let quote = byPaprika[paprikaID]?.quote(currency) { out[id] = quote }
            }
        }
        guard !out.isEmpty else { throw HTTPClient.Failure.offline }
        return out
    }

    /// Ids equivalentes no CoinPaprika das moedas que a carteira lista. As outras sao
    /// achadas pela lista do CoinPaprika (`btc-bitcoin` vira `bitcoin`).
    static let paprikaIDs: [String: String] = [
        "bitcoin": "btc-bitcoin", "ethereum": "eth-ethereum", "solana": "sol-solana", "ripple": "xrp-xrp",
        "stellar": "xlm-stellar", "tron": "trx-tron", "the-open-network": "ton-toncoin", "litecoin": "ltc-litecoin",
        "dogecoin": "doge-dogecoin", "tether": "usdt-tether", "usd-coin": "usdc-usd-coin", "binancecoin": "bnb-binance-coin",
        "avalanche-2": "avax-avalanche", "polygon-ecosystem-token": "pol-polygon-ecosystem-token",
        "wrapped-bitcoin": "wbtc-wrapped-bitcoin", "dai": "dai-dai", "chainlink": "link-chainlink",
        "uniswap": "uni-uniswap", "arbitrum": "arb-arbitrum", "optimism": "op-optimism", "jupiter-exchange-solana": "jup-jupiter",
        "plasma": "xpl-plasma", "okb": "okb-okb", "sonic-3": "s-sonic", "celo": "celo-celo",
        "cardano": "ada-cardano", "polkadot": "dot-polkadot", "near": "near-near-protocol", "aptos": "apt-aptos", "sui": "sui-sui",
    ]

    static let geckoIDs: [String: String] = Dictionary(paprikaIDs.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

    private func paprikaID(for geckoID: String) -> String? {
        Self.paprikaIDs[geckoID] ?? learnedPaprikaIDs[geckoID]
    }

    /// O id do CoinGecko que corresponde a um do CoinPaprika: o da tabela, ou o nome
    /// depois do simbolo (`ada-cardano` vira `cardano`), que e o do CoinGecko na
    /// maioria das moedas. So serve para a lista de reserva e os favoritos.
    static func geckoID(forPaprika id: String) -> String {
        if let known = geckoIDs[id] { return known }
        guard let dash = id.firstIndex(of: "-") else { return id }
        return String(id[id.index(after: dash)...])
    }

    private func paprikaTickers(currency: String) async throws -> [PaprikaTicker] {
        if let cached = paprikaLists[currency], now().timeIntervalSince(cached.at) < 60 { return cached.tickers }
        let url = Self.url(Self.paprika, "tickers", [("quotes", currency.uppercased())])
        let tickers = try await get([PaprikaTicker].self, url, timeout: 20)
        paprikaLists[currency] = (now(), tickers)
        for ticker in tickers {
            let guess = Self.geckoID(forPaprika: ticker.id)
            if Self.paprikaIDs[guess] == nil, learnedPaprikaIDs[guess] == nil { learnedPaprikaIDs[guess] = ticker.id }
        }
        return tickers
    }

    struct PaprikaTicker: Decodable, Sendable {
        struct Values: Decodable, Sendable {
            let price: Double?
            let volume_24h: Double?
            let market_cap: Double?
            let percent_change_24h: Double?
            let ath_price: Double?
            let ath_date: String?
            let percent_from_price_ath: Double?
        }
        let id: String
        let name: String
        let symbol: String
        let rank: Int?
        let total_supply: Double?
        let max_supply: Double?
        let quotes: [String: Values]?

        func values(_ currency: String) -> Values? { quotes?[currency.uppercased()] }

        func quote(_ currency: String) -> Quote? {
            guard let values = values(currency), let price = values.price, price.isFinite, price > 0 else { return nil }
            return Quote(price: price, change24h: values.percent_change_24h)
        }
    }

    // MARK: Preco por contrato

    /// A plataforma de cada rede no CoinGecko (`/asset_platforms`, conferido em
    /// 04/10/2026) e no CoinPaprika (`/contracts`). Sem plataforma no CoinPaprika, a rede
    /// fica so com o CoinGecko.
    static let tokenPlatforms: [String: (gecko: String, paprika: String?)] = [
        "ethereum": ("ethereum", "eth-ethereum"), "base": ("base", "base-base"), "arbitrum": ("arbitrum-one", "arb-arbitrum"),
        "optimism": ("optimistic-ethereum", "op-optimism"), "polygon": ("polygon-pos", "matic-polygon"),
        "bnb": ("binance-smart-chain", "bnb-binance-coin"), "avalanche": ("avalanche", "avax-avalanche"), "plasma": ("plasma", nil),
        "xlayer": ("x-layer", "okb-okb"), "linea": ("linea", "linea-linea"), "unichain": ("unichain", "uni-uniswap"),
        "sonic": ("sonic", "s-sonic"), "celo": ("celo", "celo-celo"), "solana": ("solana", "sol-solana"), "tron": ("tron", "trx-tron"),
        "ton": ("the-open-network", "toncoin-the-open-network"),
    ]

    static let tokenPriceLifetime: TimeInterval = 300
    /// "Sem preco" vale meia hora: o CoinGecko sem chave aceita um contrato por chamada
    /// e poucas chamadas por minuto, e a maioria dos tokens que chegam sozinhos nunca vai
    /// ter preco.
    static let tokenMissLifetime: TimeInterval = 1800
    /// Contratos novos consultados por vez; os outros ficam para a proxima atualizacao.
    static let tokenLookupsPerCall = 6

    /// Preco por endereco de contrato, numa fonte que lista o contrato: o CoinGecko
    /// (`simple/token_price/{plataforma}`) e, com ele fora (429, sem rede), o CoinPaprika
    /// (contrato para moeda em `/contracts/{plataforma}`, preco em `/tickers/{id}`). Nunca
    /// pelo simbolo: qualquer um cria um "USDC". Devolve por `Asset.id`; o que nao tem
    /// preco nao aparece.
    public func tokenQuotes(_ assets: [Asset], currency: String) async -> [String: Quote] {
        let moment = now()
        var out: [String: Quote] = [:]
        var pending: [Asset] = []
        var seen = Set<String>()
        for asset in assets where seen.insert(asset.id).inserted {
            guard case .token = asset.kind, Self.tokenPlatforms[asset.chainID] != nil else { continue }
            if let cached = tokenPrices[currency]?[asset.id],
               moment.timeIntervalSince(cached.at) < (cached.quote == nil ? Self.tokenMissLifetime : Self.tokenPriceLifetime) {
                if let quote = cached.quote { out[asset.id] = quote }
                continue
            }
            pending.append(asset)
        }
        for asset in pending.prefix(Self.tokenLookupsPerCall) {
            guard let answer = await tokenQuote(asset, currency: currency) else {
                // As duas fontes falharam: o ultimo preco bom, se houver, e nada se guarda.
                if let stale = tokenPrices[currency]?[asset.id]?.quote { out[asset.id] = stale }
                continue
            }
            tokenPrices[currency, default: [:]][asset.id] = (moment, answer.quote)
            if let quote = answer.quote { out[asset.id] = quote }
        }
        return out
    }

    /// `nil`: nenhuma fonte respondeu. `quote == nil`: a fonte respondeu sem preco.
    private func tokenQuote(_ asset: Asset, currency: String) async -> (quote: Quote?, Void)? {
        guard case .token(let contract) = asset.kind, let platform = Self.tokenPlatforms[asset.chainID] else { return nil }
        do {
            // O CoinGecko respondeu: com ou sem preco, e a resposta.
            return (try await fromGecko { try await self.geckoTokenQuote(platform.gecko, contract: contract, currency: currency) }, ())
        } catch {
            // Fora do ar ou de castigo: a reserva.
        }
        guard let paprikaPlatform = platform.paprika else { return nil }
        return try? await (paprikaTokenQuote(paprikaPlatform, contract: contract, currency: currency), ())
    }

    private func geckoTokenQuote(_ platform: String, contract: String, currency: String) async throws -> Quote? {
        let url = Self.url(Self.gecko, "simple/token_price/\(platform)", [
            ("contract_addresses", contract), ("vs_currencies", currency), ("include_24hr_change", "true"),
        ])
        let raw = try await get([String: [String: Double?]].self, url)
        return Self.tokenQuote(raw, contract: contract, currency: currency)
    }

    /// A resposta do CoinGecko vem com o contrato como chave (minusculo na EVM).
    static func tokenQuote(_ raw: [String: [String: Double?]], contract: String, currency: String) -> Quote? {
        guard let values = raw.first(where: { $0.key.lowercased() == contract.lowercased() })?.value,
              let price = values[currency] ?? nil, price.isFinite, price > 0
        else { return nil }
        return Quote(price: price, change24h: values["\(currency)_24h_change"] ?? nil)
    }

    private func paprikaTokenQuote(_ platform: String, contract: String, currency: String) async throws -> Quote? {
        let ids: [String: String]
        if let cached = paprikaContracts[platform], now().timeIntervalSince(cached.at) < 6 * 3600 {
            ids = cached.ids
        } else {
            struct Entry: Decodable { let address: String; let id: String; let active: Bool? }
            let list = try await get([Entry].self, Self.url(Self.paprika, "contracts/\(platform)"), timeout: 20)
            ids = Dictionary(list.filter { $0.active != false }.map { ($0.address.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
            paprikaContracts[platform] = (now(), ids)
        }
        guard let id = ids[contract.lowercased()] else { return nil }
        let ticker = try await get(PaprikaTicker.self, Self.url(Self.paprika, "tickers/\(id)", [("quotes", currency.uppercased())]))
        return ticker.quote(currency)
    }

    // MARK: Lista de mercado

    /// As maiores moedas por capitalizacao, com minigrafico de 7 dias.
    public func markets(currency: String, perPage: Int = 100) async throws -> [MarketCoin] {
        try await marketSnapshot(currency: currency, perPage: perPage).coins
    }

    /// A lista com a fonte e a hora. CoinGecko; sem ele, a lista do CoinPaprika (sem
    /// minigrafico e sem logo de fora); sem os dois, a ultima boa, marcada como antiga.
    public func marketSnapshot(currency: String, perPage: Int = 100) async throws -> MarketSnapshot {
        let key = "\(currency):\(perPage)"
        if let cached = lists[key], !cached.isStale, now().timeIntervalSince(cached.fetchedAt) < Self.listLifetime { return cached }
        let fresh: MarketSnapshot
        do {
            let coins = try await fromGecko { try await self.geckoMarkets(currency: currency, perPage: perPage) }
            fresh = MarketSnapshot(coins: coins, fetchedAt: now(), source: .coingecko, isStale: false)
        } catch {
            do {
                let coins = try await paprikaMarkets(currency: currency, perPage: perPage)
                fresh = MarketSnapshot(coins: coins, fetchedAt: now(), source: .coinpaprika, isStale: false)
            } catch {
                guard let last = lists[key] else { throw error }
                let stale = MarketSnapshot(coins: last.coins, fetchedAt: last.fetchedAt, source: last.source, isStale: true)
                lists[key] = stale
                return stale
            }
        }
        lists[key] = fresh
        remember(Dictionary(fresh.coins.map { ($0.id, Quote(price: $0.price, change24h: $0.change24h)) }, uniquingKeysWith: { a, _ in a }), currency: currency)
        return fresh
    }

    private func geckoMarkets(currency: String, perPage: Int) async throws -> [MarketCoin] {
        let url = Self.url(Self.gecko, "coins/markets", [
            ("vs_currency", currency), ("order", "market_cap_desc"), ("per_page", String(perPage)), ("page", "1"),
            ("sparkline", "true"), ("price_change_percentage", "24h"),
        ])
        let raw = try await get([GeckoMarket].self, url)
        let coins = raw.compactMap { item -> MarketCoin? in
            guard let price = item.current_price, price.isFinite, price > 0 else { return nil }
            let image = item.image.flatMap(URL.init(string:)).flatMap { ImageLoader.isAllowed($0) ? $0 : nil }
            return MarketCoin(
                id: item.id, symbol: Self.clean(item.symbol.uppercased()), name: Self.clean(item.name), imageURL: image,
                price: price, change24h: item.price_change_percentage_24h, marketCap: item.market_cap,
                volume24h: item.total_volume, rank: item.market_cap_rank,
                sparkline: item.sparkline_in_7d?.price.filter(\.isFinite) ?? []
            )
        }
        guard !coins.isEmpty else { throw HTTPClient.Failure.invalidResponse }
        return coins
    }

    private func paprikaMarkets(currency: String, perPage: Int) async throws -> [MarketCoin] {
        let tickers = try await paprikaTickers(currency: currency)
        let ranked = tickers.filter { ($0.rank ?? 0) > 0 }.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
        var seen = Set<String>()
        let coins = ranked.compactMap { ticker -> MarketCoin? in
            guard let values = ticker.values(currency), let price = values.price, price.isFinite, price > 0 else { return nil }
            let id = Self.geckoID(forPaprika: ticker.id)
            guard seen.insert(id).inserted else { return nil }
            return MarketCoin(
                id: id, symbol: Self.clean(ticker.symbol.uppercased()), name: Self.clean(ticker.name), imageURL: nil,
                price: price, change24h: values.percent_change_24h, marketCap: values.market_cap,
                volume24h: values.volume_24h, rank: ticker.rank, sparkline: []
            )
        }
        guard !coins.isEmpty else { throw HTTPClient.Failure.invalidResponse }
        return Array(coins.prefix(perPage))
    }

    private struct GeckoMarket: Decodable {
        struct Sparkline: Decodable { let price: [Double] }
        let id: String
        let symbol: String
        let name: String
        let image: String?
        let current_price: Double?
        let market_cap: Double?
        let market_cap_rank: Int?
        let total_volume: Double?
        let price_change_percentage_24h: Double?
        let sparkline_in_7d: Sparkline?
    }

    /// Nome vindo de fora: sem controles, sem bidi, tamanho limitado.
    static func clean(_ text: String) -> String {
        String(String(text.unicodeScalars.filter { !forbidden.contains($0) }).prefix(40))
    }

    static let forbidden = CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200B}\u{200E}\u{200F}")
        .union(.controlCharacters)

    // MARK: Historico

    public func chart(id: String, currency: String, range: ChartRange) async throws -> [PricePoint] {
        try await chartSnapshot(id: id, currency: currency, range: range).points
    }

    /// O historico com fonte e hora. CoinGecko; sem ele, as velas da OKX; sem os dois, o
    /// ultimo bom, marcado como antigo.
    public func chartSnapshot(id: String, currency: String, range: ChartRange) async throws -> ChartSnapshot {
        let key = "\(id):\(currency):\(range.rawValue)"
        if let cached = charts[key], !cached.isStale, now().timeIntervalSince(cached.fetchedAt) < Self.chartLifetime(range) { return cached }
        let fresh: ChartSnapshot
        do {
            let points = try await fromGecko { try await self.geckoChart(id: id, currency: currency, range: range) }
            fresh = ChartSnapshot(points: points, fetchedAt: now(), source: .coingecko, isStale: false)
        } catch {
            do {
                let points = try await okxChart(id: id, currency: currency, range: range)
                fresh = ChartSnapshot(points: points, fetchedAt: now(), source: .okx, isStale: false)
            } catch {
                guard let last = charts[key] else { throw error }
                let stale = ChartSnapshot(points: last.points, fetchedAt: last.fetchedAt, source: last.source, isStale: true)
                charts[key] = stale
                return stale
            }
        }
        charts[key] = fresh
        return fresh
    }

    private func geckoChart(id: String, currency: String, range: ChartRange) async throws -> [PricePoint] {
        let url = Self.url(Self.gecko, "coins/\(id)/market_chart", [("vs_currency", currency), ("days", range.days)])
        let raw = try await get(GeckoChart.self, url)
        let points = raw.prices.compactMap { pair -> PricePoint? in
            guard pair.count == 2, pair[1].isFinite, pair[1] > 0 else { return nil }
            return PricePoint(time: Date(timeIntervalSince1970: pair[0] / 1000), price: pair[1])
        }
        guard !points.isEmpty else { throw HTTPClient.Failure.invalidResponse }
        return points
    }

    private struct GeckoChart: Decodable { let prices: [[Double]] }

    /// Contingencia de historico: velas publicas da OKX em USDT, convertidas pela
    /// cotacao do USDT na moeda pedida.
    private func okxChart(id: String, currency: String, range: ChartRange) async throws -> [PricePoint] {
        guard let symbol = Self.okxSymbols[id] else { throw HTTPClient.Failure.offline }
        let (bar, limit): (String, Int) = {
            switch range {
            case .day: return ("15m", 96)
            case .week: return ("1H", 168)
            case .month: return ("4H", 180)
            case .year: return ("1D", 300)
            case .all: return ("1W", 300)
            }
        }()
        let url = Self.url(Self.okx, "market/history-candles", [("instId", "\(symbol)-USDT"), ("bar", bar), ("limit", String(limit))])
        let json = try await get(JSONValue.self, url)
        let rate = currency == "usd" ? 1 : (try await quotes(ids: ["tether"], currency: currency)["tether"]?.price ?? 0)
        guard rate > 0, let rows = json["data"]?.arrayValue else { throw HTTPClient.Failure.invalidResponse }
        let points = rows.compactMap { row -> PricePoint? in
            guard let ts = row[0]?.stringValue.flatMap(Double.init), let close = row[4]?.stringValue.flatMap(Double.init),
                  close.isFinite, close > 0 else { return nil }
            return PricePoint(time: Date(timeIntervalSince1970: ts / 1000), price: close * rate)
        }
        .sorted { $0.time < $1.time }
        guard !points.isEmpty else { throw HTTPClient.Failure.invalidResponse }
        return points
    }

    static let okxSymbols: [String: String] = [
        "bitcoin": "BTC", "ethereum": "ETH", "solana": "SOL", "ripple": "XRP", "stellar": "XLM", "tron": "TRX",
        "the-open-network": "TON", "litecoin": "LTC", "dogecoin": "DOGE", "binancecoin": "BNB", "avalanche-2": "AVAX",
        "polygon-ecosystem-token": "POL", "chainlink": "LINK", "uniswap": "UNI", "arbitrum": "ARB", "optimism": "OP",
        "plasma": "XPL", "okb": "OKB", "sonic-3": "S", "celo": "CELO", "cardano": "ADA", "polkadot": "DOT",
        "near": "NEAR", "aptos": "APT", "sui": "SUI",
    ]

    // MARK: Detalhe da moeda

    /// Maxima e minima de 24 h, maxima historica, oferta, valor totalmente diluido e um
    /// "Sobre" curto. Pedido so quando a pagina da moeda abre, e guardado por 5 min.
    ///
    /// CoinGecko (`/coins/{id}`, sem tickers e sem dados de comunidade); sem ele, o
    /// CoinPaprika (`/tickers/{id}` e `/coins/{id}`), com maxima e minima de 24 h tiradas
    /// do grafico do dia. Sem os dois, o ultimo bom, marcado como antigo.
    public func coinDetails(id: String, currency: String) async throws -> MarketCoinDetails {
        let key = "\(id):\(currency)"
        if let cached = details[key], !cached.isStale, now().timeIntervalSince(cached.fetchedAt) < Self.detailLifetime { return cached }
        let fresh: MarketCoinDetails
        do {
            fresh = try await fromGecko { try await self.geckoDetails(id: id, currency: currency) }
        } catch {
            do {
                fresh = try await paprikaDetails(id: id, currency: currency)
            } catch {
                guard var last = details[key] else { throw error }
                last.isStale = true
                details[key] = last
                return last
            }
        }
        details[key] = fresh
        return fresh
    }

    private func geckoDetails(id: String, currency: String) async throws -> MarketCoinDetails {
        let url = Self.url(Self.gecko, "coins/\(id)", [
            ("localization", "true"), ("tickers", "false"), ("market_data", "true"),
            ("community_data", "false"), ("developer_data", "false"), ("sparkline", "false"),
        ])
        let json = try await get(JSONValue.self, url)
        return try Self.parseGecko(json, id: id, currency: currency, at: now())
    }

    static func parseGecko(_ json: JSONValue, id: String, currency: String, at: Date) throws -> MarketCoinDetails {
        guard json["id"]?.stringValue == id, let market = json["market_data"] else { throw HTTPClient.Failure.invalidResponse }
        func money(_ field: String) -> Double? { positive(market[field]?[currency]?.doubleValue) }
        let portuguese = json["description"]?["pt"]?.stringValue.flatMap(about)
        let english = json["description"]?["en"]?.stringValue.flatMap(about)
        return MarketCoinDetails(
            id: id, currency: currency, price: money("current_price"),
            high24h: money("high_24h"), low24h: money("low_24h"),
            allTimeHigh: money("ath"), allTimeHighDate: market["ath_date"]?[currency]?.stringValue.flatMap(isoDate),
            fromAllTimeHigh: finite(market["ath_change_percentage"]?[currency]?.doubleValue),
            marketCap: money("market_cap"), fullyDilutedValuation: money("fully_diluted_valuation"),
            volume24h: money("total_volume"),
            rank: (market["market_cap_rank"]?.doubleValue ?? json["market_cap_rank"]?.doubleValue).flatMap(rank),
            circulatingSupply: positive(market["circulating_supply"]?.doubleValue),
            totalSupply: positive(market["total_supply"]?.doubleValue),
            maxSupply: positive(market["max_supply"]?.doubleValue),
            unlimitedSupply: market["max_supply_infinite"]?.boolValue == true,
            about: portuguese ?? english, aboutInPortuguese: portuguese != nil,
            source: .coingecko, fetchedAt: at, isStale: false
        )
    }

    private func paprikaDetails(id: String, currency: String) async throws -> MarketCoinDetails {
        if paprikaID(for: id) == nil { _ = try? await paprikaTickers(currency: currency) }
        guard let paprikaID = paprikaID(for: id) else { throw HTTPClient.Failure.offline }
        let ticker = try await get(PaprikaTicker.self, Self.url(Self.paprika, "tickers/\(paprikaID)", [("quotes", currency.uppercased())]))
        guard ticker.id == paprikaID, let values = ticker.values(currency) else { throw HTTPClient.Failure.invalidResponse }
        struct Coin: Decodable { let id: String; let description: String? }
        let coin = try? await get(Coin.self, Self.url(Self.paprika, "coins/\(paprikaID)"))
        // Maxima e minima de 24 h: o CoinPaprika sem chave nao tem; saem do grafico do dia.
        let day = try? await chartSnapshot(id: id, currency: currency, range: .day)
        let dayPrices = day.map { $0.points.map(\.price) } ?? []
        var details = Self.parsePaprika(ticker, values: values, currency: currency, at: now())
        details.high24h = dayPrices.max()
        details.low24h = dayPrices.min()
        details.about = coin.flatMap { $0.id == paprikaID ? $0.description : nil }.flatMap(Self.about)
        return details
    }

    static func parsePaprika(_ ticker: PaprikaTicker, values: PaprikaTicker.Values, currency: String, at: Date) -> MarketCoinDetails {
        let price = positive(values.price)
        let cap = positive(values.market_cap)
        // O CoinPaprika calcula a capitalizacao pela oferta em circulacao: a conta volta.
        let circulating = price.flatMap { p in cap.map { $0 / p } }
        let maxSupply = positive(ticker.max_supply)
        let total = positive(ticker.total_supply)
        return MarketCoinDetails(
            id: geckoID(forPaprika: ticker.id), currency: currency, price: price, high24h: nil, low24h: nil,
            allTimeHigh: positive(values.ath_price), allTimeHighDate: values.ath_date.flatMap(isoDate),
            fromAllTimeHigh: finite(values.percent_from_price_ath),
            marketCap: cap, fullyDilutedValuation: price.flatMap { p in (maxSupply ?? total).map { $0 * p } },
            volume24h: positive(values.volume_24h), rank: ticker.rank.flatMap { $0 > 0 ? $0 : nil },
            circulatingSupply: circulating, totalSupply: total, maxSupply: maxSupply, unlimitedSupply: false,
            about: nil, aboutInPortuguese: false, source: .coinpaprika, fetchedAt: at, isStale: false
        )
    }

    static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func rank(_ value: Double) -> Int? {
        guard value.isFinite, value >= 1, value < 1_000_000 else { return nil }
        return Int(value)
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// O "Sobre" que a tela mostra: texto puro (sem HTML e sem links, que nao sao
    /// tocaveis por enquanto), sem controles nem bidi, nos primeiros paragrafos ate
    /// cerca de 600 caracteres, cortado no fim de uma frase.
    static func about(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, plain) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        text = String(text.unicodeScalars.filter { $0 == "\n" || !forbidden.contains($0) })
        text = text.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n\\s*\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let limit = 600
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let end = head.range(of: ". ", options: .backwards) ?? head.range(of: ".\n", options: .backwards), head.distance(from: head.startIndex, to: end.lowerBound) > 200 {
            return String(head[..<end.lowerBound]) + "."
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Baixa logos da lista de mercado, com as regras de docs/seguranca.md §5.4: so
/// hosts conhecidos, so PNG ou JPEG (decodificador de imagem e superficie de ataque
/// dentro do processo que assina), tamanho limitado, cache so em memoria.
public actor ImageLoader {
    public static let shared = ImageLoader()
    /// De onde as logos podem vir. Entram no hosts.lock e na Politica de privacidade
    /// como qualquer outro endereco.
    static let origins = ["https://coin-images.coingecko.com", "https://assets.coingecko.com"]
    static let allowedHosts: Set<String> = Set(origins.compactMap { URL(string: $0)?.host })
    static let maxBytes = 96 * 1024

    private var cache: [URL: Data] = [:]
    private var order: [URL] = []

    public static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && allowedHosts.contains(url.host ?? "")
    }

    public func data(for url: URL) async -> Data? {
        if let cached = cache[url] { return cached }
        guard Self.isAllowed(url), let data = try? await HTTPClient.shared.get(url, timeout: 8) else { return nil }
        guard data.count <= Self.maxBytes, Self.isPNGOrJPEG(data) else { return nil }
        cache[url] = data
        order.append(url)
        if order.count > 300 { cache[order.removeFirst()] = nil }
        return data
    }

    static func isPNGOrJPEG(_ data: Data) -> Bool {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data.prefix(8))
        return bytes == png || bytes.starts(with: [0xFF, 0xD8, 0xFF])
    }
}
