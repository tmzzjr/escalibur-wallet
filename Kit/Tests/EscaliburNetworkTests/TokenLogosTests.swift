import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// A logo de token fora da lista: pasta do contrato exato no repositorio da Trust
/// Wallet, e nada alem do caminho das logos.
@Suite("Logos de token pelo contrato")
struct TokenLogosTests {
    static let root = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/"

    static func asset(_ chain: Chain, _ kind: Asset.Kind) -> Asset {
        Asset(chainID: chain.id, kind: kind, symbol: "X", name: "X", decimals: 6, coingeckoID: nil, isStablecoin: false, origin: .discovered)
    }

    func token(_ chain: Chain, _ contract: String) -> Asset { Self.asset(chain, .token(contract: contract)) }

    @Test("EVM vai no EIP-55, em qualquer caixa que o indexador mande")
    func evm() {
        let lower = token(.ethereum, "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
        #expect(TokenLogos.url(for: lower)?.absoluteString == Self.root + "ethereum/assets/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/logo.png")
        #expect(TokenLogos.url(for: token(.bnb, "0x55d398326f99059ff775485246999027b3197955"))?.absoluteString.contains("/smartchain/assets/0x55d398326f99059fF775485246999027B3197955/") == true)
        #expect(TokenLogos.url(for: token(.avalanche, "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e"))?.absoluteString.contains("/avalanchec/") == true)
    }

    @Test("Outras redes no formato do repositorio")
    func others() {
        #expect(TokenLogos.url(for: token(.solana, "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"))?.absoluteString == Self.root + "solana/assets/EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v/logo.png")
        let stellar = Self.asset(.stellar, .issued(code: "USDC", issuer: "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"))
        #expect(TokenLogos.url(for: stellar)?.absoluteString == Self.root + "stellar/assets/USDC-GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN/logo.png")
        let xrpl = Self.asset(.xrpl, .issued(code: "XPM", issuer: "rXPMxBeefHGxx2K7g5qmmWq3gFsgawkoa"))
        #expect(TokenLogos.url(for: xrpl)?.absoluteString == Self.root + "ripple/assets/XPM.rXPMxBeefHGxx2K7g5qmmWq3gFsgawkoa/logo.png")
    }

    @Test("Rede sem pasta, moeda nativa e contrato montado para escapar do caminho: nada")
    func refused() {
        #expect(TokenLogos.url(for: token(.unichain, "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")) == nil)
        #expect(TokenLogos.url(for: .native(.ethereum)) == nil)
        #expect(TokenLogos.url(for: token(.solana, "../../../../evil/repo/main/x")) == nil)
        #expect(TokenLogos.url(for: token(.solana, "abc/def")) == nil)
        #expect(TokenLogos.url(for: token(.solana, "abc def")) == nil)
        #expect(TokenLogos.url(for: token(.ethereum, "nao-e-endereco")) == nil)
    }

    @Test("O carregador so aceita o caminho das logos do repositorio, nao qualquer arquivo do GitHub")
    func loaderScope() {
        #expect(ImageLoader.isAllowed(URL(string: Self.root + "ethereum/assets/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/logo.png")!))
        #expect(!ImageLoader.isAllowed(URL(string: "https://raw.githubusercontent.com/atacante/repo/main/logo.png")!))
        #expect(!ImageLoader.isAllowed(URL(string: Self.root + "ethereum/info/logo.svg")!))
        #expect(!ImageLoader.isAllowed(URL(string: "http://raw.githubusercontent.com/trustwallet/assets/master/blockchains/x/logo.png")!))
        #expect(ImageLoader.isAllowed(URL(string: "https://assets.coingecko.com/coins/images/1/large/bitcoin.png")!))
    }
}

@Suite("Logo que vem com o token")
struct TokenListLogoTests {
    @Test("A lista do CoinGecko traz a logo grande, so no host de imagens do CoinGecko")
    func listLogo() throws {
        let json = #"""
        {"tokens":[
          {"chainId":56,"address":"0x64da67a12a46f1ddf337393e2da12ed0a507ad3d","name":"BNB Frog Inu","symbol":"BNBFROG","decimals":18,
           "logoURI":"https://assets.coingecko.com/coins/images/12345/thumb/frog.png?1700000000"},
          {"chainId":56,"address":"0x0000000000000000000000000000000000000001","name":"Outro","symbol":"OUT","decimals":18,
           "logoURI":"https://atacante.example/logo.png"}
        ]}
        """#
        let tokens = try TokenListScan.parse(Data(json.utf8), chain: .bnb)
        #expect(tokens[0].logo?.absoluteString == "https://assets.coingecko.com/coins/images/12345/large/frog.png?1700000000")
        #expect(tokens[1].logo == nil)
    }

    @Test("Token suspeito nao ganha logo, mesmo com ela na lista")
    func suspiciousHasNoLogo() throws {
        let logo = try #require(URL(string: "https://assets.coingecko.com/coins/images/1/large/x.png"))
        let kind = Asset.Kind.token(contract: "0x64DA67A12a46F1DDF337393E2DA12eD0A507AD3D")
        let clean = UnlistedHolding.make(chain: .bnb, kind: kind, symbol: "BNBFROG", name: "BNB Frog Inu", decimals: 18,
                                         amount: BigUInt.power(of: 10, 20), logo: logo)
        #expect(clean.logo == logo)
        let bait = UnlistedHolding.make(chain: .bnb, kind: kind, symbol: "FROG", name: "Claim at frog-drop.com", decimals: 18,
                                        amount: BigUInt.power(of: 10, 20), logo: logo)
        #expect(bait.logo == nil)
    }

    @Test("Logo ja conhecida sai na hora, sem consulta")
    func remembered() async throws {
        let resolver = TokenLogoResolver()
        let asset = Asset(chainID: "bnb", kind: .token(contract: "0x64DA67A12a46F1DDF337393E2DA12eD0A507AD3D"), symbol: "BNBFROG",
                          name: "BNB Frog Inu", decimals: 18, coingeckoID: nil, isStablecoin: false, origin: .discovered)
        let logo = try #require(URL(string: "https://assets.coingecko.com/coins/images/1/large/x.png"))
        await resolver.remember(logo, for: asset.id)
        #expect(await resolver.logo(for: asset) == logo)
        #expect(await resolver.known()[asset.id] == logo)
    }
}
