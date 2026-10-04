import Foundation
import Testing
@testable import EscaliburNetwork

/// Testes contra os provedores reais. So rodam com ESCALIBUR_REDE=1, para o CI
/// nao depender da internet nem gastar limite de API.
@Suite("Mercado ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"))
struct MarketLiveTests {
    @Test("Precos em BRL das moedas nativas")
    func quotes() async throws {
        let quotes = try await MarketService().quotes(ids: ["bitcoin", "ethereum", "solana", "ripple", "stellar", "tron", "the-open-network"], currency: "brl")
        #expect(quotes.count >= 6)
        #expect((quotes["bitcoin"]?.price ?? 0) > 10_000)
    }

    @Test("Lista de mercado com minigrafico")
    func markets() async throws {
        let coins = try await MarketService().markets(currency: "brl", perPage: 20)
        #expect(coins.count >= 10)
        #expect(coins.first?.sparkline.isEmpty == false)
    }

    @Test("Historico de 7 dias e contingencia da OKX")
    func chart() async throws {
        let points = try await MarketService().chart(id: "bitcoin", currency: "brl", range: .week)
        #expect(points.count > 50)
    }

    @Test("Logo passa pelas regras de tamanho e formato")
    func logo() async throws {
        let coins = try await MarketService().markets(currency: "usd", perPage: 5)
        let url = try #require(coins.first?.imageURL)
        let data = await ImageLoader().data(for: url)
        #expect(data != nil)
    }

    /// O CoinGecko cortado (como no IP que estourou a cota): tudo vem da reserva.
    struct GeckoBlocked: ReaderTransport {
        func send(_ request: ReaderRequest) async throws -> Data {
            if request.url.host == "api.coingecko.com" { throw HTTPClient.Failure.status(429) }
            return try await HTTPClient.shared.send(request)
        }
    }

    @Test("Sem CoinGecko: lista, cotacao, grafico e detalhe pela reserva")
    func reserve() async throws {
        let service = MarketService(transport: GeckoBlocked())
        let list = try await service.marketSnapshot(currency: "brl")
        #expect(list.source == .coinpaprika && list.coins.count >= 50)
        #expect(list.coins.first?.id == "bitcoin")
        let quotes = try await service.quotes(ids: ["bitcoin", "dogecoin", "litecoin"], currency: "brl")
        #expect(quotes.count == 3)
        let chart = try await service.chartSnapshot(id: "dogecoin", currency: "brl", range: .day)
        #expect(chart.source == .okx && chart.points.count > 50)
        let details = try await service.coinDetails(id: "dogecoin", currency: "brl")
        #expect(details.source == .coinpaprika && details.high24h != nil && details.about != nil)
    }

    @Test("Detalhe pelo CoinGecko")
    func details() async throws {
        let details = try await MarketService().coinDetails(id: "bitcoin", currency: "brl")
        #expect(details.maxSupply == 21_000_000 && details.allTimeHigh != nil && details.about != nil)
    }
}
