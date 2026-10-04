import Foundation
import Testing
@testable import EscaliburNetwork

/// Mercado sem rede: respostas gravadas em 04/10/2026 (Fixtures/mercado), com o
/// CoinGecko cortado por 429 e o relogio do teste, para a reserva e o cache.
@Suite("Mercado: reserva e cache")
struct MarketFallbackTests {
    /// Rede de mentira por host e caminho; registra o que saiu.
    final class Fake: ReaderTransport, @unchecked Sendable {
        typealias Handler = @Sendable (URL) throws -> Data
        private let lock = NSLock()
        private var routes: [String: Handler] = [:]
        private var log: [URL] = []

        func on(_ key: String, _ handler: @escaping Handler) { lock.withLock { routes[key] = handler } }
        func on(_ key: String, fixture: String) throws {
            let data = try MarketFallbackTests.fixture(fixture)
            on(key) { _ in data }
        }
        func on(_ key: String, status: Int) { on(key) { _ in throw HTTPClient.Failure.status(status) } }
        var requests: [URL] { lock.withLock { log } }
        func count(_ host: String) -> Int { requests.filter { $0.host == host }.count }

        func send(_ request: ReaderRequest) async throws -> Data {
            let key = (request.url.host ?? "") + request.url.path
            let handler: Handler? = lock.withLock {
                log.append(request.url)
                return routes[key]
            }
            guard let handler else { throw HTTPClient.Failure.status(404) }
            return try handler(request.url)
        }
    }

    /// Relogio que o teste adianta.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_791_133_200)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/mercado") else {
            throw HTTPClient.Failure.status(404)
        }
        return try Data(contentsOf: url)
    }

    static let gecko = "api.coingecko.com/api/v3/"
    static let paprika = "api.coinpaprika.com/v1/"

    static func service(_ fake: Fake, _ clock: Clock) -> MarketService {
        MarketService(transport: fake, now: { clock.now })
    }

    // MARK: Lista

    @Test("Lista: com o CoinGecko em 429, a do CoinPaprika; e o CoinGecko fica de fora por um tempo")
    func listFallback() async throws {
        let fake = Fake(), clock = Clock()
        fake.on(Self.gecko + "coins/markets", status: 429)
        try fake.on(Self.paprika + "tickers", fixture: "paprika-tickers")
        let service = Self.service(fake, clock)

        let snapshot = try await service.marketSnapshot(currency: "brl")
        #expect(snapshot.source == .coinpaprika && !snapshot.isStale)
        #expect(snapshot.coins.map(\.id) == ["bitcoin", "ethereum", "tether", "binancecoin", "ripple", "usd-coin"])
        #expect(snapshot.coins.first?.symbol == "BTC" && snapshot.coins.first?.rank == 1)
        #expect(snapshot.coins.allSatisfy { $0.imageURL == nil && $0.marketCap != nil })
        #expect(await service.geckoPaused() == clock.now.addingTimeInterval(60))

        // 30 s depois a tela pede de novo: o CoinGecko ainda esta de fora e nem e chamado,
        // e a lista do CoinPaprika (1,4 MB) vale um minuto.
        clock.advance(30)
        let geckoCalls = fake.count("api.coingecko.com")
        let again = try await service.marketSnapshot(currency: "brl")
        #expect(again.source == .coinpaprika)
        #expect(fake.count("api.coingecko.com") == geckoCalls)
        #expect(fake.count("api.coinpaprika.com") == 1)

        // A lista preenche as cotacoes: o preco do bitcoin sai sem nova chamada.
        let quotes = try await service.quotes(ids: ["bitcoin"], currency: "brl")
        #expect(quotes["bitcoin"]?.price == snapshot.coins.first?.price)
        #expect(fake.requests.count == geckoCalls + 1)
    }

    @Test("Sem as duas fontes, a ultima lista boa volta, com a hora dela")
    func listStale() async throws {
        let fake = Fake(), clock = Clock()
        try fake.on(Self.gecko + "coins/markets", fixture: "gecko-markets")
        let service = Self.service(fake, clock)
        let first = try await service.marketSnapshot(currency: "brl")
        #expect(first.source == .coingecko && first.coins.count == 3 && first.coins.first?.sparkline.isEmpty == false)

        // Dentro da validade (25 s) nao ha chamada nova.
        clock.advance(20)
        _ = try await service.marketSnapshot(currency: "brl")
        #expect(fake.requests.count == 1)

        clock.advance(20)
        fake.on(Self.gecko + "coins/markets", status: 500)
        fake.on(Self.paprika + "tickers", status: 500)
        let stale = try await service.marketSnapshot(currency: "brl")
        #expect(stale.isStale && stale.fetchedAt == first.fetchedAt && stale.coins == first.coins)
        // Outra moeda, sem nada guardado: ai sim, erro.
        await #expect(throws: HTTPClient.Failure.self) { try await service.marketSnapshot(currency: "usd") }
    }

    // MARK: Cotacoes

    @Test("Cotacoes: uma chamada para o que falta, 30 s de validade, ultimo preco bom quando as fontes falham")
    func quotesCache() async throws {
        let fake = Fake(), clock = Clock()
        try fake.on(Self.gecko + "simple/price", fixture: "gecko-price")
        let service = Self.service(fake, clock)
        let ids = ["bitcoin", "dogecoin", "litecoin"]
        let first = try await service.quotes(ids: ids, currency: "brl")
        #expect(first["dogecoin"]?.price == 0.496019 && first.count == 3)
        _ = try await service.quotes(ids: ["dogecoin"], currency: "brl")
        #expect(fake.requests.count == 1)

        // Vencida, com o CoinGecko em 429: o CoinPaprika, uma moeda por chamada.
        clock.advance(31)
        fake.on(Self.gecko + "simple/price", status: 429)
        try fake.on(Self.paprika + "tickers/doge-dogecoin", fixture: "paprika-ticker-doge")
        let fallback = try await service.quotes(ids: ["dogecoin"], currency: "brl")
        #expect(fallback["dogecoin"]?.price == 0.49592777325919163)

        // Tudo fora: cada moeda volta com o ultimo preco bom, nenhuma some.
        clock.advance(31)
        fake.on(Self.paprika + "tickers/doge-dogecoin", status: 500)
        let stale = try await service.quotes(ids: ids, currency: "brl")
        #expect(stale.count == 3 && stale["bitcoin"]?.price == 444_495 && stale["dogecoin"]?.price == 0.49592777325919163)
    }

    // MARK: Detalhe

    @Test("Detalhe pelo CoinGecko: 24 h, maxima historica, oferta, valor diluido e Sobre em ingles")
    func detailsGecko() async throws {
        let fake = Fake(), clock = Clock()
        try fake.on(Self.gecko + "coins/dogecoin", fixture: "gecko-coin-doge")
        let service = Self.service(fake, clock)
        let details = try await service.coinDetails(id: "dogecoin", currency: "brl")
        #expect(details.source == .coingecko)
        #expect(details.high24h == 0.493337 && details.low24h == 0.482258)
        #expect(details.allTimeHigh == 3.83 && details.fromAllTimeHigh == -87.04956)
        #expect(details.allTimeHighDate == ISO8601DateFormatter().date(from: "2021-05-07T21:08:23Z"))
        #expect(details.circulatingSupply == 156_185_966_383.70523 && details.totalSupply == 156_186_716_383.7052)
        #expect(details.maxSupply == nil && details.unlimitedSupply)
        #expect(details.fullyDilutedValuation == 77_462_828_858 && details.rank == 12)
        let about = try #require(details.about)
        #expect(!details.aboutInPortuguese && about.hasPrefix("Dogecoin is an open-source digital currency"))
        #expect(about.count <= 601 && about.hasSuffix("."))

        // Dentro de 5 min, do cache.
        clock.advance(200)
        _ = try await service.coinDetails(id: "dogecoin", currency: "brl")
        #expect(fake.requests.count == 1)
    }

    @Test("Detalhe com descricao em portugues: ela vem primeiro")
    func detailsPortuguese() throws {
        var text = String(decoding: try Self.fixture("gecko-coin-doge"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"pt\": \"\"", with: "\"pt\": \"<p>O Dogecoin nasceu como piada em 2013.</p>\"")
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let details = try MarketService.parseGecko(json, id: "dogecoin", currency: "brl", at: .now)
        #expect(details.aboutInPortuguese && details.about == "O Dogecoin nasceu como piada em 2013.")
    }

    @Test("Detalhe sem CoinGecko: CoinPaprika, com maxima e minima de 24 h tiradas do grafico da OKX")
    func detailsPaprika() async throws {
        let fake = Fake(), clock = Clock()
        fake.on(Self.gecko + "coins/dogecoin", status: 429)
        try fake.on(Self.paprika + "tickers/doge-dogecoin", fixture: "paprika-ticker-doge")
        try fake.on(Self.paprika + "tickers/usdt-tether", fixture: "paprika-ticker-usdt")
        try fake.on(Self.paprika + "coins/doge-dogecoin", fixture: "paprika-coin-doge")
        try fake.on("www.okx.com/api/v5/market/history-candles", fixture: "okx-candles-doge-day")
        let service = Self.service(fake, clock)
        let details = try await service.coinDetails(id: "dogecoin", currency: "brl")
        #expect(details.source == .coinpaprika && details.rank == 12)
        let price = try #require(details.price)
        let high = try #require(details.high24h), low = try #require(details.low24h)
        #expect(low < high && low > price * 0.8 && high < price * 1.2)
        // max_supply 0 no CoinPaprika e "sem dado", nao "sem teto".
        #expect(details.maxSupply == nil && !details.unlimitedSupply)
        #expect(details.totalSupply == 155_723_666_384)
        let circulating = try #require(details.circulatingSupply)
        #expect(abs(circulating * price - (details.marketCap ?? 0)) < 1)
        #expect(details.about?.hasPrefix("Dogecoin (DOGE) is a cryptocurrency") == true && !details.aboutInPortuguese)
        // O CoinGecko foi chamado uma vez so: o 429 o tirou das chamadas seguintes.
        #expect(fake.count("api.coingecko.com") == 1)
    }

    @Test("Campo que falta nao quebra o detalhe; resposta de outra moeda e recusada")
    func detailsMissingFields() throws {
        let bare = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"x","market_data":{"current_price":{"brl":null}}}"#.utf8))
        let details = try MarketService.parseGecko(bare, id: "x", currency: "brl", at: .now)
        #expect(details.price == nil && details.high24h == nil && details.about == nil && details.rank == nil && !details.unlimitedSupply)
        #expect(throws: HTTPClient.Failure.self) { try MarketService.parseGecko(bare, id: "y", currency: "brl", at: .now) }
    }

    @Test("Sobre: sem HTML, sem entidades, sem controles, cortado no fim de uma frase")
    func aboutText() throws {
        let raw = "<a href=\"https://x.example\">Bitcoin</a> &amp; a rede\u{202E}.\r\n\n\n\nSegundo   paragrafo."
        #expect(MarketService.about(raw) == "Bitcoin & a rede.\n\nSegundo paragrafo.")
        #expect(MarketService.about("  <p></p> ") == nil)
        let long = String(repeating: "Uma frase curta de exemplo. ", count: 40)
        let cut = try #require(MarketService.about(long))
        #expect(cut.count <= 601 && cut.hasSuffix("exemplo."))
    }
}
