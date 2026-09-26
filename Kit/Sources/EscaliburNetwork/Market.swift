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

/// Precos, lista de mercado e historico, com contingencia entre provedores.
///
/// Preco serve para exibir e para checagem de sanidade de cotacao, **nunca** para
/// calcular o minimo garantido de um swap (docs/seguranca.md §5.4). Por isso um
/// provedor de preco mentindo muda um numero na tela, e nada mais.
///
/// Primario: CoinGecko (API publica). Contingencia: CoinPaprika para preco, e OKX
/// (candles publicos em USDT) para historico das moedas principais.
public actor MarketService {
    public static let shared = MarketService()

    private let client: HTTPClient
    private var quoteCache: [String: (Date, [String: Quote])] = [:]
    private var marketCache: [String: (Date, [MarketCoin])] = [:]
    private var chartCache: [String: (Date, [PricePoint])] = [:]

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    static let gecko = URL(string: "https://api.coingecko.com/api/v3")!
    static let paprika = URL(string: "https://api.coinpaprika.com/v1")!
    static let okx = URL(string: "https://www.okx.com/api/v5")!

    // MARK: Precos

    /// Preco e variacao de 24 h por id do CoinGecko, na moeda pedida ("brl", "usd").
    public func quotes(ids: [String], currency: String) async throws -> [String: Quote] {
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty else { return [:] }
        let key = currency + ":" + unique.joined(separator: ",")
        if let (at, cached) = quoteCache[key], Date().timeIntervalSince(at) < 30 { return cached }
        do {
            var components = URLComponents(url: Self.gecko.appendingPathComponent("simple/price"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "ids", value: unique.joined(separator: ",")),
                URLQueryItem(name: "vs_currencies", value: currency),
                URLQueryItem(name: "include_24hr_change", value: "true"),
            ]
            let raw = try await client.getJSON([String: [String: Double?]].self, from: components.url!)
            var out: [String: Quote] = [:]
            for (id, values) in raw {
                guard let price = values[currency] ?? nil, price.isFinite, price > 0 else { continue }
                out[id] = Quote(price: price, change24h: values["\(currency)_24h_change"] ?? nil)
            }
            quoteCache[key] = (Date(), out)
            return out
        } catch {
            let fallback = try await paprikaQuotes(ids: unique, currency: currency)
            quoteCache[key] = (Date(), fallback)
            return fallback
        }
    }

    private func paprikaQuotes(ids: [String], currency: String) async throws -> [String: Quote] {
        var out: [String: Quote] = [:]
        let upper = currency.uppercased()
        for id in ids {
            guard let paprikaID = Self.paprikaIDs[id] else { continue }
            var components = URLComponents(url: Self.paprika.appendingPathComponent("tickers/\(paprikaID)"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "quotes", value: upper)]
            guard let json = try? await client.getJSON(JSONValue.self, from: components.url!),
                  let quote = json["quotes"]?[upper], let price = quote["price"]?.doubleValue, price > 0
            else { continue }
            out[id] = Quote(price: price, change24h: quote["percent_change_24h"]?.doubleValue)
        }
        guard !out.isEmpty else { throw HTTPClient.Failure.offline }
        return out
    }

    /// Ids equivalentes no CoinPaprika, so para as moedas que a carteira lista.
    static let paprikaIDs: [String: String] = [
        "bitcoin": "btc-bitcoin", "ethereum": "eth-ethereum", "solana": "sol-solana", "ripple": "xrp-xrp",
        "stellar": "xlm-stellar", "tron": "trx-tron", "the-open-network": "ton-toncoin", "litecoin": "ltc-litecoin",
        "dogecoin": "doge-dogecoin", "tether": "usdt-tether", "usd-coin": "usdc-usd-coin", "binancecoin": "bnb-binance-coin",
        "avalanche-2": "avax-avalanche", "polygon-ecosystem-token": "pol-polygon-ecosystem-token",
        "wrapped-bitcoin": "wbtc-wrapped-bitcoin", "dai": "dai-dai", "chainlink": "link-chainlink",
        "uniswap": "uni-uniswap", "arbitrum": "arb-arbitrum", "optimism": "op-optimism", "jupiter-exchange-solana": "jup-jupiter",
    ]

    // MARK: Lista de mercado

    /// As maiores moedas por capitalizacao, com minigrafico de 7 dias.
    public func markets(currency: String, perPage: Int = 100) async throws -> [MarketCoin] {
        if let (at, cached) = marketCache[currency], Date().timeIntervalSince(at) < 60 { return cached }
        var components = URLComponents(url: Self.gecko.appendingPathComponent("coins/markets"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: currency),
            URLQueryItem(name: "order", value: "market_cap_desc"),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "sparkline", value: "true"),
            URLQueryItem(name: "price_change_percentage", value: "24h"),
        ]
        let raw = try await client.getJSON([GeckoMarket].self, from: components.url!)
        let coins = raw.compactMap { item -> MarketCoin? in
            guard let price = item.current_price, price.isFinite, price > 0 else { return nil }
            let image = item.image.flatMap(URL.init(string:)).flatMap { ImageLoader.isAllowed($0) ? $0 : nil }
            return MarketCoin(
                id: item.id, symbol: item.symbol.uppercased(), name: Self.clean(item.name), imageURL: image,
                price: price, change24h: item.price_change_percentage_24h, marketCap: item.market_cap,
                volume24h: item.total_volume, rank: item.market_cap_rank,
                sparkline: item.sparkline_in_7d?.price.filter(\.isFinite) ?? []
            )
        }
        marketCache[currency] = (Date(), coins)
        return coins
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
        let forbidden = CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200B}\u{200E}\u{200F}")
            .union(.controlCharacters)
        return String(String(text.unicodeScalars.filter { !forbidden.contains($0) }).prefix(40))
    }

    // MARK: Historico

    public func chart(id: String, currency: String, range: ChartRange) async throws -> [PricePoint] {
        let key = "\(id):\(currency):\(range.rawValue)"
        let ttl: TimeInterval = range == .day ? 120 : 600
        if let (at, cached) = chartCache[key], Date().timeIntervalSince(at) < ttl { return cached }
        do {
            var components = URLComponents(url: Self.gecko.appendingPathComponent("coins/\(id)/market_chart"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "vs_currency", value: currency),
                URLQueryItem(name: "days", value: range.days),
            ]
            let raw = try await client.getJSON(GeckoChart.self, from: components.url!)
            let points = raw.prices.compactMap { pair -> PricePoint? in
                guard pair.count == 2, pair[1].isFinite, pair[1] > 0 else { return nil }
                return PricePoint(time: Date(timeIntervalSince1970: pair[0] / 1000), price: pair[1])
            }
            chartCache[key] = (Date(), points)
            return points
        } catch {
            let points = try await okxChart(id: id, currency: currency, range: range)
            chartCache[key] = (Date(), points)
            return points
        }
    }

    private struct GeckoChart: Decodable { let prices: [[Double]] }

    /// Contingencia de historico: candles publicos da OKX em USDT, convertidos pela
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
        var components = URLComponents(url: Self.okx.appendingPathComponent("market/history-candles"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "instId", value: "\(symbol)-USDT"),
            URLQueryItem(name: "bar", value: bar),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let json = try await client.getJSON(JSONValue.self, from: components.url!)
        let rate = currency == "usd" ? 1 : (try await quotes(ids: ["tether"], currency: currency)["tether"]?.price ?? 0)
        guard rate > 0, let rows = json["data"]?.arrayValue else { throw HTTPClient.Failure.invalidResponse }
        return rows.compactMap { row -> PricePoint? in
            guard let ts = row[0]?.stringValue.flatMap(Double.init), let close = row[4]?.stringValue.flatMap(Double.init) else { return nil }
            return PricePoint(time: Date(timeIntervalSince1970: ts / 1000), price: close * rate)
        }
        .sorted { $0.time < $1.time }
    }

    static let okxSymbols: [String: String] = [
        "bitcoin": "BTC", "ethereum": "ETH", "solana": "SOL", "ripple": "XRP", "stellar": "XLM", "tron": "TRX",
        "the-open-network": "TON", "litecoin": "LTC", "dogecoin": "DOGE", "binancecoin": "BNB", "avalanche-2": "AVAX",
        "polygon-ecosystem-token": "POL", "chainlink": "LINK", "uniswap": "UNI", "arbitrum": "ARB", "optimism": "OP",
    ]
}

/// Baixa logos da lista de mercado, com as regras de docs/seguranca.md §5.4: so
/// hosts conhecidos, so PNG ou JPEG (decodificador de imagem e superficie de ataque
/// dentro do processo que assina), tamanho limitado, cache so em memoria.
public actor ImageLoader {
    public static let shared = ImageLoader()
    static let allowedHosts: Set<String> = ["coin-images.coingecko.com", "assets.coingecko.com"]
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
