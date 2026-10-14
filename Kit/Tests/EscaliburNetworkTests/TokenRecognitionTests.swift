import EscaliburChains
import Foundation
import Testing
@testable import EscaliburNetwork

/// Reconhecer um token pelo CoinGecko: so o contrato exato, com as casas certas, sem
/// aviso, sem colidir com a lista curada.
@Suite("Reconhecimento de token")
struct TokenRecognitionTests {
    static let now = Date(timeIntervalSince1970: 1_791_600_000)
    /// Um token fora da lista curada (o SHIB, exemplo antigo, entrou nela em 14/10/2026).
    static let floki = Asset(chainID: "ethereum", kind: .token(contract: "0xcf0C122c6b73ff809C693DB761e7BaeBe62b6a2E"), symbol: "FLOKI",
                             name: "FLOKI", decimals: 9, coingeckoID: nil, isStablecoin: false, origin: .discovered)
    static let image = URL(string: "https://coin-images.coingecko.com/coins/images/16746/large/PNG_image.png")!

    func identity(_ asset: Asset = Self.floki, id: String? = "floki", symbol: String? = "floki", name: String? = "FLOKI",
                  listed: String? = "0xcf0c122c6b73ff809c693db761e7baebe62b6a2e", decimals: Int? = 9,
                  preview: Bool? = false, notice: String? = nil, image: URL? = Self.image) -> TokenIdentity? {
        TokenRecognitionRules.identity(asset: asset, platform: "ethereum", id: id, symbol: symbol, name: name, listedContract: listed,
                                       listedDecimals: decimals, previewListing: preview, publicNotice: notice, image: image, now: Self.now)
    }

    @Test("FLOKI na Ethereum: reconhecido, com nome e simbolo do CoinGecko")
    func floki() throws {
        let found = try #require(identity())
        #expect(found.coingeckoID == "floki" && found.symbol == "FLOKI" && found.name == "FLOKI")
        #expect(found.contract == "0xcf0c122c6b73ff809c693db761e7baebe62b6a2e")
        #expect(found.image == Self.image)
        #expect(TokenRecognitionRules.isValid(found, for: Self.floki, now: Self.now.addingTimeInterval(86_400)))
    }

    @Test("Contrato diferente, casas diferentes, pre-listagem ou aviso publico: nao reconhece")
    func rejected() {
        #expect(identity(listed: "0x0000000000000000000000000000000000000001") == nil)
        #expect(identity(listed: nil) == nil)
        #expect(identity(decimals: 18) == nil)
        #expect(identity(decimals: nil) == nil)
        #expect(identity(preview: true) == nil)
        #expect(identity(notice: "This token may be a scam") == nil)
        #expect(identity(id: nil) == nil)
    }

    @Test("Id ou simbolo da lista curada, de moeda nativa ou protegido: fica em Outros tokens")
    func collisions() {
        #expect(identity(id: "tether", symbol: "usdt", name: "Tether") == nil)
        #expect(identity(id: "shiba-inu-fake", symbol: "ETH", name: "Ether") == nil)
        #expect(identity(id: "some-coin", symbol: "U\u{0405}DC", name: "USD Coin") == nil)
    }

    @Test("Nome do CoinGecko com link ou isca passa pelo filtro de golpe")
    func textFilter() {
        #expect(identity(name: "Claim at floki-airdrop.com") == nil)
    }

    @Test("Imagem fora do host do CoinGecko nao entra")
    func imageHost() throws {
        let found = try #require(identity(image: URL(string: "https://atacante.example/x.png")))
        #expect(found.image == nil)
    }

    @Test("O guardado expira em 7 dias e nao vale para outro contrato ou outra rede")
    func cache() throws {
        let found = try #require(identity())
        #expect(!TokenRecognitionRules.isValid(found, for: Self.floki, now: Self.now.addingTimeInterval(8 * 86_400)))
        let other = Asset(chainID: "base", kind: .token(contract: "0xcf0C122c6b73ff809C693DB761e7BaeBe62b6a2E"), symbol: "FLOKI",
                          name: "FLOKI", decimals: 9, coingeckoID: nil, isStablecoin: false, origin: .discovered)
        #expect(!TokenRecognitionRules.isValid(found, for: other, now: Self.now))
        #expect(!TokenRecognitionRules.isValid(found, for: Self.floki, now: Self.now.addingTimeInterval(-60)))
    }
}
