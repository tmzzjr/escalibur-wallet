import EscaliburChains
import Foundation
import Testing
@testable import EscaliburNetwork

/// Reconhecer um token pelo CoinGecko: so o contrato exato, com as casas certas, sem
/// aviso, sem colidir com a lista curada.
@Suite("Reconhecimento de token")
struct TokenRecognitionTests {
    static let now = Date(timeIntervalSince1970: 1_791_600_000)
    static let shib = Asset(chainID: "ethereum", kind: .token(contract: "0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE"), symbol: "SHIB",
                            name: "SHIBA INU", decimals: 18, coingeckoID: nil, isStablecoin: false, origin: .discovered)
    static let image = URL(string: "https://coin-images.coingecko.com/coins/images/11939/large/shiba.png")!

    func identity(_ asset: Asset = Self.shib, id: String? = "shiba-inu", symbol: String? = "shib", name: String? = "Shiba Inu",
                  listed: String? = "0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce", decimals: Int? = 18,
                  preview: Bool? = false, notice: String? = nil, image: URL? = Self.image) -> TokenIdentity? {
        TokenRecognitionRules.identity(asset: asset, platform: "ethereum", id: id, symbol: symbol, name: name, listedContract: listed,
                                       listedDecimals: decimals, previewListing: preview, publicNotice: notice, image: image, now: Self.now)
    }

    @Test("SHIB na Ethereum: reconhecida, com nome e simbolo do CoinGecko")
    func shiba() throws {
        let found = try #require(identity())
        #expect(found.coingeckoID == "shiba-inu" && found.symbol == "SHIB" && found.name == "Shiba Inu")
        #expect(found.contract == "0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce")
        #expect(found.image == Self.image)
        #expect(TokenRecognitionRules.isValid(found, for: Self.shib, now: Self.now.addingTimeInterval(86_400)))
    }

    @Test("Contrato diferente, casas diferentes, pre-listagem ou aviso publico: nao reconhece")
    func rejected() {
        #expect(identity(listed: "0x0000000000000000000000000000000000000001") == nil)
        #expect(identity(listed: nil) == nil)
        #expect(identity(decimals: 9) == nil)
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
        #expect(identity(name: "Claim at shib-airdrop.com") == nil)
    }

    @Test("Imagem fora do host do CoinGecko nao entra")
    func imageHost() throws {
        let found = try #require(identity(image: URL(string: "https://atacante.example/x.png")))
        #expect(found.image == nil)
    }

    @Test("O guardado expira em 7 dias e nao vale para outro contrato ou outra rede")
    func cache() throws {
        let found = try #require(identity())
        #expect(!TokenRecognitionRules.isValid(found, for: Self.shib, now: Self.now.addingTimeInterval(8 * 86_400)))
        let other = Asset(chainID: "base", kind: .token(contract: "0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE"), symbol: "SHIB",
                          name: "SHIB", decimals: 18, coingeckoID: nil, isStablecoin: false, origin: .discovered)
        #expect(!TokenRecognitionRules.isValid(found, for: other, now: Self.now))
        #expect(!TokenRecognitionRules.isValid(found, for: Self.shib, now: Self.now.addingTimeInterval(-60)))
    }
}
