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
    case geckoTerminal = "GeckoTerminal"
}

/// A pool de DEX de onde vem o preco de um token que o CoinGecko nao lista.
public struct DexPool: Sendable, Hashable {
    /// O nome do par, como a pool foi criada ("BNBFrog / WBNB"): texto de quem criou o
    /// token, limpo de controle e bidi e com tamanho limitado.
    public let name: String
    public let dex: String
    public let reserveUSD: Double
}

/// O grafico de um token fora da lista: pelo contrato no CoinGecko ou, se ele nao
/// lista, pela pool de DEX com mais liquidez no GeckoTerminal.
public struct TokenChart: Sendable, Hashable {
    public let snapshot: ChartSnapshot
    /// So no preco de DEX: a pool de onde ele vem.
    public let pool: DexPool?
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
    /// A logo de cada moeda que uma lista do CoinGecko ja trouxe. A lista de reserva do
    /// CoinPaprika vem sem logo (e o CDN dele recusa quem nao e navegador): com o CoinGecko
    /// em 429, a lista reusa estas, em vez de mostrar so as iniciais.
    private var knownImages: [String: URL] = [:]
    private var charts: [String: ChartSnapshot] = [:]
    /// A pool escolhida de cada token no GeckoTerminal (ou nenhuma), por 30 minutos.
    private var dexPools: [String: (at: Date, pool: (address: String, info: DexPool)?)] = [:]
    private var details: [String: MarketCoinDetails] = [:]
    private var paprikaLists: [String: (at: Date, tickers: [PaprikaTicker])] = [:]
    /// Id do CoinPaprika por id do CoinGecko, aprendido da lista do CoinPaprika.
    private var learnedPaprikaIDs: [String: String] = [:]
    private var geckoPausedUntil: Date?
    private var geckoPause: TimeInterval = 0
    /// Preco por contrato (moeda custom e token fora da lista), por moeda e por
    /// `Asset.id`. `nil` guardado: a fonte respondeu e nao tem preco para o contrato.
    private var tokenPrices: [String: [String: (at: Date, quote: Quote?)]] = [:]
    /// A ficha do CoinGecko por `Asset.id`; `.some(nil)`: nao listado.
    private var contractCoins: [String: ContractCoin?] = [:]
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
    static let geckoTerminal = URL(string: "https://api.geckoterminal.com/api/v2")!

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

    /// Quanto as duas fontes podem discordar para um preco valer como alerta.
    static let alertAgreement = 0.02

    /// Precos para os alertas de preco: so o que duas fontes confirmam agora.
    ///
    /// O CoinGecko da o preco e a variacao (os mesmos da tela); o CoinPaprika tem de
    /// concordar dentro de 2%. Sem cache e sem o ultimo preco bom: preco velho, ou de uma
    /// fonte so, nao vira aviso na tela bloqueada. Moeda que uma das fontes nao tem, ou
    /// em que elas discordam, fica de fora desta vez.
    public func alertQuotes(ids: [String], currency: String) async -> [String: Quote] {
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty,
              let primary = try? await fromGecko({ try await self.geckoQuotes(ids: unique, currency: currency) }),
              !primary.isEmpty
        else { return [:] }
        remember(primary, currency: currency)
        let wanted = primary.keys.sorted()
        var second: [String: Quote] = [:]
        if wanted.count <= 3, wanted.allSatisfy({ paprikaID(for: $0) != nil }) {
            second = (try? await paprikaQuotes(ids: wanted, currency: currency)) ?? [:]
        } else if let tickers = try? await paprikaTickers(currency: currency) {
            let byPaprika = Dictionary(tickers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in wanted {
                if let paprikaID = paprikaID(for: id), let quote = byPaprika[paprikaID]?.quote(currency) { second[id] = quote }
            }
        }
        var out: [String: Quote] = [:]
        for (id, quote) in primary {
            guard let other = second[id], abs(quote.price / other.price - 1) <= Self.alertAgreement else { continue }
            out[id] = quote
        }
        return out
    }

    private func remember(_ quotes: [String: Quote], currency: String) {
        let moment = now()
        for (id, quote) in quotes { prices[currency, default: [:]][id] = (moment, quote) }
    }

    private func geckoQuotes(ids: [String], currency: String) async throws -> [String: Quote] {
        // `precision=full`: sem ele o CoinGecko arredonda o preco para poucas casas, e o de
        // um token de fracao infima (BNB Frog, 9e-20 dolar) chega como 0.
        let url = Self.url(Self.gecko, "simple/price", [
            ("ids", ids.joined(separator: ",")), ("vs_currencies", currency), ("include_24hr_change", "true"), ("precision", "full"),
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

    /// A tabela feita a mao vale mais que a gerada (`PaprikaGeckoIDs.swift`).
    static let geckoIDs: [String: String] = Dictionary(paprikaIDs.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        .merging(generatedGeckoIDs) { hand, _ in hand }
    static let generatedPaprikaIDs: [String: String] = Dictionary(generatedGeckoIDs.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

    private func paprikaID(for geckoID: String) -> String? {
        Self.paprikaIDs[geckoID] ?? Self.generatedPaprikaIDs[geckoID] ?? learnedPaprikaIDs[geckoID]
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
        "ton": ("the-open-network", "toncoin-the-open-network"), "sui": ("sui", "sui-sui"), "aptos": ("aptos", "apt-aptos"),
        // NEAR: o contrato e o nome da conta; Cardano: politica seguida do nome em hex.
        // Conferidos no CoinGecko em 04/10/2026. A Asset Hub da Polkadot nao responde por
        // numero de ativo, e fica sem preco por contrato.
        "near": ("near-protocol", "near-near-protocol"), "cardano": ("cardano", "ada-cardano"),
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

    /// A ficha que o CoinGecko tem do contrato (`/coins/{plataforma}/contract/{contrato}`):
    /// so os campos que a carteira usa. Uma consulta por contrato por abertura do app,
    /// para a logo e o reconhecimento.
    struct ContractCoin: Decodable, Sendable {
        struct Images: Decodable, Sendable { let large: String?; let small: String? }
        struct Detail: Decodable, Sendable { let decimal_place: Int?; let contract_address: String? }
        let id: String?
        let symbol: String?
        let name: String?
        let image: Images?
        let platforms: [String: String?]?
        let detail_platforms: [String: Detail]?
        let preview_listing: Bool?
        let public_notice: String?
    }

    /// `nil`: o CoinGecko respondeu e nao lista o contrato. Erro: nao respondeu (429, sem
    /// rede), e vale perguntar de novo depois. A resposta fica na memoria ate o app fechar.
    func contractCoin(_ asset: Asset) async throws -> ContractCoin? {
        guard case .token(let contract) = asset.kind, let platform = Self.tokenPlatforms[asset.chainID] else { return nil }
        if let cached = contractCoins[asset.id] { return cached }
        let url = Self.url(Self.gecko, "coins/\(platform.gecko)/contract/\(contract)")
        do {
            let coin = try await fromGecko { try await self.get(ContractCoin.self, url) }
            contractCoins[asset.id] = .some(coin)
            return coin
        } catch HTTPClient.Failure.status(404) {
            contractCoins[asset.id] = .some(nil)
            return nil
        }
    }

    /// A imagem da moeda que o CoinGecko lista com este contrato, so se ela estiver num
    /// host de imagem do CoinGecko. `nil`: nao listado (ou a imagem nao serve).
    public func tokenImage(_ asset: Asset) async throws -> URL? {
        guard let coin = try await contractCoin(asset) else { return nil }
        let link = (coin.image?.large ?? coin.image?.small).flatMap(URL.init(string:))
        return link.flatMap { ImageLoader.isAllowed($0) ? $0 : nil }
    }

    /// O reconhecimento do contrato pelo CoinGecko, ja conferido por
    /// `TokenRecognitionRules`. `nil`: nao listado, ou listado sem passar nas regras.
    public func tokenIdentity(_ asset: Asset, now: Date = .now) async throws -> TokenIdentity? {
        guard let coin = try await contractCoin(asset), let platform = Self.tokenPlatforms[asset.chainID]?.gecko else { return nil }
        return TokenRecognitionRules.identity(
            asset: asset, platform: platform, id: coin.id, symbol: coin.symbol, name: coin.name,
            listedContract: coin.platforms?[platform] ?? nil, listedDecimals: coin.detail_platforms?[platform]?.decimal_place,
            previewListing: coin.preview_listing, publicNotice: coin.public_notice,
            image: (coin.image?.large ?? coin.image?.small).flatMap(URL.init(string:)), now: now
        )
    }

    private func geckoTokenQuote(_ platform: String, contract: String, currency: String) async throws -> Quote? {
        let url = Self.url(Self.gecko, "simple/token_price/\(platform)", [
            ("contract_addresses", contract), ("vs_currencies", currency), ("include_24hr_change", "true"), ("precision", "full"),
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
            ("sparkline", "true"), ("price_change_percentage", "24h"), ("precision", "full"),
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
        for coin in coins { if let image = coin.imageURL { knownImages[coin.id] = image } }
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
                id: id, symbol: Self.clean(ticker.symbol.uppercased()), name: Self.clean(ticker.name), imageURL: knownImages[id],
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

    /// O historico de um token pelo contrato (`/coins/{rede}/contract/{contrato}/market_chart`),
    /// para o que nao tem id na lista nem foi reconhecido: um token com aviso do CoinGecko
    /// continua sem reconhecimento (logo, nome e confianca), mas o grafico de preco e o do
    /// proprio contrato e pode aparecer. Sem contingencia da OKX: ela nao lista por contrato.
    public func contractChartSnapshot(_ asset: Asset, currency: String, range: ChartRange) async throws -> ChartSnapshot {
        guard case .token(let contract) = asset.kind, let platform = Self.tokenPlatforms[asset.chainID]?.gecko else {
            throw HTTPClient.Failure.invalidResponse
        }
        let key = "contrato:\(asset.id):\(currency):\(range.rawValue)"
        if let cached = charts[key], !cached.isStale, now().timeIntervalSince(cached.fetchedAt) < Self.chartLifetime(range) { return cached }
        do {
            let path = "coins/\(platform)/contract/\(TokenRecognitionRules.canonical(contract, chainID: asset.chainID))/market_chart"
            let points = try await fromGecko { try await self.geckoChart(path: path, currency: currency, range: range) }
            let fresh = ChartSnapshot(points: points, fetchedAt: now(), source: .coingecko, isStale: false)
            charts[key] = fresh
            return fresh
        } catch {
            guard let last = charts[key] else { throw error }
            let stale = ChartSnapshot(points: last.points, fetchedAt: last.fetchedAt, source: last.source, isStale: true)
            charts[key] = stale
            return stale
        }
    }

    /// O grafico de um token fora da lista: pelo contrato no CoinGecko; se o CoinGecko nao
    /// lista o contrato, pela pool de DEX com mais liquidez no GeckoTerminal. Erro de
    /// limite ou de rede sobe: a tela tenta de novo.
    ///
    /// As duas fontes sao perguntadas ao mesmo tempo e vale a primeira que responder: o
    /// CoinGecko sem chave fica de fora por minutos depois de um limite, e esperar por
    /// ele deixava o grafico de um token como o BNB Frog Inu demorando (relato do dono,
    /// 14/10/2026). A tela diz de qual fonte veio.
    public func tokenChart(_ asset: Asset, currency: String, range: ChartRange) async throws -> TokenChart {
        enum Answer: Sendable {
            case chart(TokenChart)
            /// A fonte respondeu que nao tem o token (CoinGecko sem o contrato, nenhuma
            /// pool com liquidez).
            case absent
            case failed(Error)
        }
        func classify(_ error: Error) -> Answer {
            switch error {
            case HTTPClient.Failure.status(404), HTTPClient.Failure.invalidResponse: return .absent
            default: return .failed(error)
            }
        }
        return try await withThrowingTaskGroup(of: Answer.self) { group in
            group.addTask {
                do { return .chart(TokenChart(snapshot: try await self.contractChartSnapshot(asset, currency: currency, range: range), pool: nil)) }
                catch { return classify(error) }
            }
            group.addTask {
                do { return .chart(try await self.dexChart(asset, currency: currency, range: range)) }
                catch { return classify(error) }
            }
            var absent = 0
            var lastError: Error?
            for try await answer in group {
                switch answer {
                case .chart(let chart):
                    group.cancelAll()
                    return chart
                case .absent:
                    absent += 1
                case .failed(let error):
                    lastError = error
                }
            }
            // As duas disseram que nao tem: sem grafico. Senao, limite ou rede: a tela tenta de novo.
            if absent == 2 { throw HTTPClient.Failure.status(404) }
            throw lastError ?? HTTPClient.Failure.status(404)
        }
    }

    /// As redes do GeckoTerminal (`/networks`, conferido em 12/10/2026). A Asset Hub da
    /// Polkadot nao esta la.
    static let geckoTerminalNetworks: [String: String] = [
        "ethereum": "eth", "bnb": "bsc", "polygon": "polygon_pos", "arbitrum": "arbitrum", "base": "base", "optimism": "optimism",
        "avalanche": "avax", "solana": "solana", "linea": "linea", "sonic": "sonic", "celo": "celo", "unichain": "unichain",
        "xlayer": "x-layer", "plasma": "plasma", "tron": "tron", "ton": "ton", "sui": "sui-network", "aptos": "aptos",
        "near": "near", "cardano": "cardano",
    ]

    /// Abaixo disso a pool e pequena demais: qualquer um cria uma pool com centavos e
    /// desenha o preco que quiser. Mesmo acima, o preco de DEX so desenha o grafico; o
    /// saldo total so usa preco de fonte que lista o contrato (`tokenQuotes`).
    static let dexMinimumReserveUSD: Double = 5_000

    /// O grafico pela pool de DEX com mais liquidez do token, em dolar convertido pela
    /// cotacao do USDT na moeda pedida, como a contingencia da OKX.
    public func dexChart(_ asset: Asset, currency: String, range: ChartRange) async throws -> TokenChart {
        guard case .token(let contract) = asset.kind, let network = Self.geckoTerminalNetworks[asset.chainID] else {
            throw HTTPClient.Failure.invalidResponse
        }
        let token = TokenRecognitionRules.canonical(contract, chainID: asset.chainID)
        let key = "dex:\(asset.id):\(currency):\(range.rawValue)"
        guard let pool = try await dexPool(network: network, token: token, assetID: asset.id) else { throw HTTPClient.Failure.status(404) }
        if let cached = charts[key], now().timeIntervalSince(cached.fetchedAt) < Self.chartLifetime(range) {
            return TokenChart(snapshot: cached, pool: pool.info)
        }
        let (timeframe, aggregate, limit, window): (String, String, Int, TimeInterval) = {
            switch range {
            case .day: return ("minute", "15", 96, 86_400)
            case .week: return ("hour", "1", 168, 7 * 86_400)
            case .month: return ("hour", "4", 180, 30 * 86_400)
            case .year: return ("day", "1", 365, 365 * 86_400)
            case .all: return ("day", "1", 1000, .infinity)
            }
        }()
        let url = Self.url(Self.geckoTerminal, "networks/\(network)/pools/\(pool.address)/ohlcv/\(timeframe)", [
            ("aggregate", aggregate), ("limit", String(limit)), ("currency", "usd"), ("token", token),
        ])
        let json = try await get(JSONValue.self, url)
        let rate = currency == "usd" ? 1 : (try await quotes(ids: ["tether"], currency: currency)["tether"]?.price ?? 0)
        guard rate > 0, let rows = json["data"]?["attributes"]?["ohlcv_list"]?.arrayValue else { throw HTTPClient.Failure.invalidResponse }
        let start = now().addingTimeInterval(-window)
        // As velas so existem quando houve negocio: 96 velas de 15 min podem cobrir dias.
        let points = rows.compactMap { row -> PricePoint? in
            guard let ts = row[0]?.doubleValue, let close = row[4]?.doubleValue, close.isFinite, close > 0 else { return nil }
            let time = Date(timeIntervalSince1970: ts)
            return time >= start ? PricePoint(time: time, price: close * rate) : nil
        }
        .sorted { $0.time < $1.time }
        let snapshot = ChartSnapshot(points: points, fetchedAt: now(), source: .geckoTerminal, isStale: false)
        charts[key] = snapshot
        return TokenChart(snapshot: snapshot, pool: pool.info)
    }

    /// A pool do token com mais liquidez, acima do minimo. `nil`: nenhuma serve.
    private func dexPool(network: String, token: String, assetID: String) async throws -> (address: String, info: DexPool)? {
        if let cached = dexPools[assetID], now().timeIntervalSince(cached.at) < 1800 { return cached.pool }
        let json = try await get(JSONValue.self, Self.url(Self.geckoTerminal, "networks/\(network)/tokens/\(token)/pools", [("page", "1")]))
        guard let list = json["data"]?.arrayValue else { throw HTTPClient.Failure.invalidResponse }
        let id = "\(network)_\(token)".lowercased()
        var best: (address: String, info: DexPool)?
        for entry in list {
            guard let attributes = entry["attributes"], let address = attributes["address"]?.stringValue,
                  let reserve = attributes["reserve_in_usd"]?.stringValue.flatMap(Double.init), reserve.isFinite,
                  reserve >= Self.dexMinimumReserveUSD, reserve > (best?.info.reserveUSD ?? 0)
            else { continue }
            let base = entry["relationships"]?["base_token"]?["data"]?["id"]?.stringValue?.lowercased()
            let quote = entry["relationships"]?["quote_token"]?["data"]?["id"]?.stringValue?.lowercased()
            guard base == id || quote == id else { continue }
            let dex = entry["relationships"]?["dex"]?["data"]?["id"]?.stringValue ?? ""
            best = (address, DexPool(name: Self.clean(attributes["name"]?.stringValue ?? ""), dex: Self.dexName(dex), reserveUSD: reserve))
        }
        dexPools[assetID] = (now(), best)
        return best
    }

    /// "pancakeswap_v2" vira "PancakeSwap v2".
    static func dexName(_ id: String) -> String {
        let known = ["pancakeswap": "PancakeSwap", "uniswap": "Uniswap", "sushiswap": "SushiSwap", "aerodrome": "Aerodrome",
                     "velodrome": "Velodrome", "raydium": "Raydium", "orca": "Orca", "meteora": "Meteora", "pumpswap": "PumpSwap",
                     "camelot": "Camelot", "quickswap": "QuickSwap", "traderjoe": "Trader Joe", "curve": "Curve", "balancer": "Balancer"]
        let words = id.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard let first = words.first else { return "DEX" }
        let rest = words.dropFirst().filter { !["bsc", "eth", "base", "arbitrum", "polygon", "avalanche", "solana"].contains($0) }
        return Self.clean(([known[first] ?? first.capitalized] + rest).joined(separator: " "))
    }

    /// O aviso publico que o CoinGecko poe no token deste contrato (risco de contrato,
    /// listagem em teste), em texto puro. `nil`: sem aviso ou sem listagem. Erro: o
    /// CoinGecko nao respondeu (limite), e a tela tenta de novo.
    public func contractNotice(_ asset: Asset) async throws -> String? {
        guard let coin = try await contractCoin(asset) else { return nil }
        let text = (coin.public_notice ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let clean = String(String(text.unicodeScalars.filter { !Self.forbidden.contains($0) }).prefix(400))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        return coin.preview_listing == true ? "Listed as a preview on CoinGecko." : nil
    }

    private func geckoChart(id: String, currency: String, range: ChartRange) async throws -> [PricePoint] {
        try await geckoChart(path: "coins/\(id)/market_chart", currency: currency, range: range)
    }

    private func geckoChart(path: String, currency: String, range: ChartRange) async throws -> [PricePoint] {
        let url = Self.url(Self.gecko, path, [("vs_currency", currency), ("days", range.days)])
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
        var details = try Self.parseGecko(json, id: id, currency: currency, at: now())
        // `/coins/{id}` nao aceita `precision`: preco de fracao infima chega como 0. O
        // preco vem do `simple/price` com precisao cheia, e a faixa do dia, do grafico.
        if details.price == nil {
            details.price = try? await geckoQuotes(ids: [id], currency: currency)[id]?.price
            if details.price != nil, details.high24h == nil || details.low24h == nil {
                let day = (try? await chartSnapshot(id: id, currency: currency, range: .day)).map { $0.points.map(\.price) } ?? []
                details.high24h = details.high24h ?? day.max()
                details.low24h = details.low24h ?? day.min()
            }
        }
        return details
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
    /// As logos da Trust Wallet tem 256 px e passam de 70 KB em algumas.
    static let maxBytes = 160 * 1024

    private var cache: [URL: Data] = [:]
    private var order: [URL] = []
    /// Logo que nao existe (404 da Trust Wallet, a maioria dos tokens): nao pede de novo
    /// nesta abertura do app.
    private var missing: Set<URL> = []

    /// Os hosts de logo do mercado, ou uma logo do repositorio da Trust Wallet (so o
    /// caminho das logos, nao qualquer arquivo do GitHub).
    public static func isAllowed(_ url: URL) -> Bool {
        (url.scheme == "https" && allowedHosts.contains(url.host ?? "")) || TokenLogos.isLogo(url)
    }

    public func data(for url: URL) async -> Data? {
        if let cached = cache[url] { return cached }
        guard Self.isAllowed(url), !missing.contains(url) else { return nil }
        let fetched: Data
        do {
            fetched = try await HTTPClient.shared.get(url, timeout: 8)
        } catch HTTPClient.Failure.status(404) {
            missing.insert(url)
            return nil
        } catch {
            return nil
        }
        let data = fetched
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
