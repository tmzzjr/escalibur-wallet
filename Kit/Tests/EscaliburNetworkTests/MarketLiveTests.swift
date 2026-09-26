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
}
