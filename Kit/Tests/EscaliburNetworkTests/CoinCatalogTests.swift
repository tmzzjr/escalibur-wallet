import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// A busca de Receber no CoinGecko: respostas reais gravadas de `/search?query=bonk`,
/// `/coins/bonk` e `/coins/hedera-hashgraph` (11/10/2026), e casos montados (impostor,
/// isca, id que nao cabe na URL).
@Suite("Busca de moedas")
struct CoinCatalogTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    @Test("Busca real: a Bonk primeiro, com posicao no mercado e logo do host do CoinGecko")
    func search() throws {
        let results = try CoinCatalog.parseSearch(try Self.fixture("coingecko-search-bonk"))
        let first = try #require(results.first)
        #expect(first.id == "bonk" && first.symbol == "BONK" && first.name == "Bonk" && first.rank != nil)
        #expect(first.image?.host == "coin-images.coingecko.com")
        #expect(results.count > 5)
    }

    @Test("Reserva do CoinPaprika: id com prefixo, simbolo protegido fora, contratos por rede com a BNB em bnb-bnb")
    func paprikaReserve() throws {
        let search = Data("""
        {"currencies":[
          {"id":"purpe-purple-pepe","name":"Purple Pepe","symbol":"PURPE","rank":1074,"is_active":true},
          {"id":"usdt-fake","name":"Tether","symbol":"USDT","rank":0,"is_active":true},
          {"id":"dead-coin","name":"Dead","symbol":"DEAD","rank":0,"is_active":false}
        ]}
        """.utf8)
        let results = try CoinCatalog.parsePaprikaSearch(search)
        // O PEPE da lista verificada nao viria daqui: simbolo protegido so com o id da lista.
        #expect(results.map(\.id) == ["paprika:purpe-purple-pepe"])
        #expect(results.first?.rank == 1074)
        let coin = Data("""
        {"id":"purpe-purple-pepe","symbol":"PURPE","name":"Purple Pepe","contracts":[
          {"contract":"0x25d887ce7a35172c62febfd67a1856f20faebb00","platform":"bnb-bnb"},
          {"contract":"0x25d887ce7a35172c62febfd67a1856f20faebb00","platform":"arb-arbitrum"},
          {"contract":"nao-e-contrato","platform":"eth-ethereum"}
        ]}
        """.utf8)
        let parsed = try CoinCatalog.parsePaprikaCoin(coin, id: "paprika:purpe-purple-pepe")
        #expect(parsed.networks.map(\.chainID).sorted() == ["arbitrum", "bnb"])
        #expect(throws: (any Error).self) { try CoinCatalog.parsePaprikaCoin(coin, id: "paprika:outra") }
    }

    @Test("Busca: isca, simbolo protegido de outro id, id que nao cabe na URL e repetido ficam de fora")
    func searchSafety() throws {
        let json = #"""
        {"coins":[
          {"id":"tether","name":"Tether","symbol":"USDT","market_cap_rank":3,"thumb":"https://coin-images.coingecko.com/a.png"},
          {"id":"usdt-impostor","name":"Bridged USDT","symbol":"USDT","market_cap_rank":null,"thumb":null},
          {"id":"claim-token","name":"Claim at rewards-site.com","symbol":"RWD","market_cap_rank":null,"thumb":null},
          {"id":"../../etc","name":"Path","symbol":"PATH","market_cap_rank":null,"thumb":null},
          {"id":"toshi","name":"Toshi","symbol":"TOSHI","market_cap_rank":500,"thumb":"https://atacante.example/x.png"},
          {"id":"toshi","name":"Toshi","symbol":"TOSHI","market_cap_rank":500,"thumb":null}
        ]}
        """#
        let results = try CoinCatalog.parseSearch(Data(json.utf8))
        #expect(results.map(\.id) == ["tether", "toshi"])
        #expect(results[1].image == nil)
    }

    @Test("Moeda real (Bonk): so redes que recebem token por endereco, contrato com o formato da rede, aviso publico marcado")
    func coin() throws {
        let bonk = try CoinCatalog.parseCoin(try Self.fixture("coingecko-coin-bonk"), id: "bonk")
        let order = Chain.all.map(\.id)
        #expect(bonk.networks.map(\.chainID) == order.filter { ["ethereum", "bnb", "solana", "arbitrum", "polygon", "unichain"].contains($0) })
        #expect(bonk.networks.first { $0.chainID == "ethereum" }?.contract == "0x1151cb3d861920e07a38e03eead12c32178567f6")
        #expect(bonk.networks.first { $0.chainID == "solana" }?.contract == "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263")
        // Aptos e Neon EVM ficam de fora; o aviso do CoinGecko sobre o ataque fica marcado.
        #expect(!bonk.networks.contains { $0.chainID == "aptos" })
        #expect(bonk.hasNotice)
    }

    @Test("Moeda sem contrato aqui (Hedera): sem rede para receber; outra moeda no lugar recusa")
    func coinWithoutNetwork() throws {
        let hedera = try CoinCatalog.parseCoin(try Self.fixture("coingecko-coin-hedera"), id: "hedera-hashgraph")
        #expect(!hedera.isReceivable)
        #expect(throws: (any Error).self) { try CoinCatalog.parseCoin(try Self.fixture("coingecko-coin-bonk"), id: "hedera-hashgraph") }
    }

    @Test("Moeda da lista: so as redes de fora da lista; contrato invalido fica de fora")
    func listedCoin() throws {
        let json = #"""
        {"id":"pepe","symbol":"pepe","name":"Pepe","platforms":{
          "ethereum":"0x6982508145454ce325ddbe47a25d4ec3d2311933",
          "binance-smart-chain":"0x25d887ce7a35172c62febfd67a1856f20faebb00",
          "arbitrum-one":"not-an-address","": ""},
         "public_notice":null,"preview_listing":false}
        """#
        let pepe = try CoinCatalog.parseCoin(Data(json.utf8), id: "pepe")
        #expect(pepe.networks.map(\.chainID) == ["bnb"])
        #expect(!pepe.hasNotice)
    }
}

@Suite("Busca de moedas ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"))
struct CoinCatalogLiveTests {
    @Test("Buscar e abrir uma moeda: duas chamadas pequenas")
    func searchAndOpen() async throws {
        let results = try await CoinCatalog.search("bonk")
        #expect(results.first?.id == "bonk")
        let bonk = try await CoinCatalog.coin(id: "bonk")
        #expect(bonk.networks.contains { $0.chainID == "solana" })
    }
}
