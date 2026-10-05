import EscaliburChains
import Foundation
import Testing
@testable import EscaliburNetwork

/// A logo pelo CoinGecko: so a imagem da moeda listada com o contrato, e so no host de
/// imagens do CoinGecko.
@Suite("Logo de token pelo CoinGecko")
struct TokenImageTests {
    typealias Fake = MarketFallbackTests.Fake
    static let sweat = Asset(chainID: "near", kind: .token(contract: "token.sweat"), symbol: "SWEAT", name: "SWEAT",
                             decimals: 18, coingeckoID: nil, isStablecoin: false, origin: .discovered)
    static let path = "api.coingecko.com/api/v3/coins/near-protocol/contract/token.sweat"

    func service(_ fake: Fake) -> MarketService { MarketFallbackTests.service(fake, MarketFallbackTests.Clock()) }

    @Test("Listado: a imagem grande, no host do CoinGecko")
    func listed() async throws {
        let fake = Fake()
        let body = Data(#"{"id":"sweatcoin","image":{"small":"https://coin-images.coingecko.com/coins/images/25057/small/s.png","large":"https://coin-images.coingecko.com/coins/images/25057/large/s.png"}}"#.utf8)
        fake.on(Self.path) { _ in body }
        let url = try await service(fake).tokenImage(Self.sweat)
        #expect(url?.absoluteString == "https://coin-images.coingecko.com/coins/images/25057/large/s.png")
    }

    @Test("Imagem fora dos hosts de imagem: nada")
    func foreignHost() async throws {
        let fake = Fake()
        let body = Data(#"{"id":"x","image":{"large":"https://atacante.example/logo.png"}}"#.utf8)
        fake.on(Self.path) { _ in body }
        #expect(try await service(fake).tokenImage(Self.sweat) == nil)
    }

    @Test("Nao listado responde nil; limite do CoinGecko e erro, para perguntar depois")
    func missingAndLimited() async throws {
        let fake = Fake()
        fake.on(Self.path, status: 404)
        #expect(try await service(fake).tokenImage(Self.sweat) == nil)
        let limited = Fake()
        limited.on(Self.path, status: 429)
        await #expect(throws: HTTPClient.Failure.self) { try await service(limited).tokenImage(Self.sweat) }
    }

    @Test("Moeda nativa e rede sem plataforma no CoinGecko: nem pergunta")
    func notAsked() async throws {
        let fake = Fake()
        #expect(try await service(fake).tokenImage(.native(.ethereum)) == nil)
        #expect(fake.requests.isEmpty)
    }
}
