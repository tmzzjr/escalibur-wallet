import Foundation
import Testing
@testable import EscaliburNetwork

/// O preco que pode virar alerta: duas fontes, agora, concordando.
@Suite("Alertas de preco: duas fontes")
struct AlertQuotesTests {
    typealias Fake = MarketFallbackTests.Fake
    typealias Clock = MarketFallbackTests.Clock

    static let gecko = MarketFallbackTests.gecko
    static let paprika = MarketFallbackTests.paprika

    static func geckoPrice(_ prices: [String: Double]) -> Data {
        let body = prices.map { "\"\($0.key)\":{\"brl\":\($0.value),\"brl_24h_change\":3.5}" }.joined(separator: ",")
        return Data("{\(body)}".utf8)
    }

    static func ticker(_ id: String, _ price: Double) -> String {
        "{\"id\":\"\(id)\",\"name\":\"x\",\"symbol\":\"X\",\"rank\":1,\"quotes\":{\"BRL\":{\"price\":\(price),\"percent_change_24h\":3.4}}}"
    }

    @Test("As duas concordam: vale o preco e a variacao do CoinGecko")
    func agree() async {
        let fake = Fake(), clock = Clock()
        let price = Self.geckoPrice(["bitcoin": 612_000])
        fake.on(Self.gecko + "simple/price") { _ in price }
        let ticker = Data(Self.ticker("btc-bitcoin", 609_500).utf8)
        fake.on(Self.paprika + "tickers/btc-bitcoin") { _ in ticker }
        let quotes = await MarketFallbackTests.service(fake, clock).alertQuotes(ids: ["bitcoin"], currency: "brl")
        #expect(quotes["bitcoin"]?.price == 612_000)
        #expect(quotes["bitcoin"]?.change24h == 3.5)
    }

    @Test("Discordam mais de 2%: nada vira alerta")
    func disagree() async {
        let fake = Fake(), clock = Clock()
        let price = Self.geckoPrice(["bitcoin": 612_000, "dogecoin": 0.5])
        fake.on(Self.gecko + "simple/price") { _ in price }
        let btc = Data(Self.ticker("btc-bitcoin", 590_000).utf8)
        let doge = Data(Self.ticker("doge-dogecoin", 0.499).utf8)
        fake.on(Self.paprika + "tickers/btc-bitcoin") { _ in btc }
        fake.on(Self.paprika + "tickers/doge-dogecoin") { _ in doge }
        let quotes = await MarketFallbackTests.service(fake, clock).alertQuotes(ids: ["bitcoin", "dogecoin"], currency: "brl")
        #expect(quotes["bitcoin"] == nil)
        #expect(quotes["dogecoin"]?.price == 0.5)
    }

    @Test("Uma fonte so, ou nenhuma: nada, e nunca o ultimo preco guardado")
    func singleSource() async throws {
        let fake = Fake(), clock = Clock()
        let price = Self.geckoPrice(["bitcoin": 612_000])
        fake.on(Self.gecko + "simple/price") { _ in price }
        fake.on(Self.paprika + "tickers/btc-bitcoin", status: 500)
        let service = MarketFallbackTests.service(fake, clock)
        #expect(await service.alertQuotes(ids: ["bitcoin"], currency: "brl").isEmpty)

        // A tela tem o preco guardado; o alerta nao usa.
        _ = try await service.quotes(ids: ["bitcoin"], currency: "brl")
        clock.advance(120)
        fake.on(Self.gecko + "simple/price", status: 429)
        let ticker = Data(Self.ticker("btc-bitcoin", 612_100).utf8)
        fake.on(Self.paprika + "tickers/btc-bitcoin") { _ in ticker }
        #expect(await service.alertQuotes(ids: ["bitcoin"], currency: "brl").isEmpty)
    }

    @Test("Muitas moedas: a lista do CoinPaprika numa chamada so")
    func manyCoins() async {
        let fake = Fake(), clock = Clock()
        let price = Self.geckoPrice(["bitcoin": 612_000, "ethereum": 21_000, "solana": 1_000, "dogecoin": 0.5])
        fake.on(Self.gecko + "simple/price") { _ in price }
        let list = "[" + [Self.ticker("btc-bitcoin", 611_000), Self.ticker("eth-ethereum", 21_100),
                          Self.ticker("sol-solana", 1_001), Self.ticker("doge-dogecoin", 0.6)].joined(separator: ",") + "]"
        let data = Data(list.utf8)
        fake.on(Self.paprika + "tickers") { _ in data }
        let quotes = await MarketFallbackTests.service(fake, clock).alertQuotes(ids: ["bitcoin", "ethereum", "solana", "dogecoin"], currency: "brl")
        #expect(Set(quotes.keys) == ["bitcoin", "ethereum", "solana"])
        #expect(fake.count("api.coinpaprika.com") == 1)
    }
}
