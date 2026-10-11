import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// A lista completa de moedas da busca de Receber, lida de um recorte real de
/// `/coins/list?include_platform=true` com alguns casos montados (impostor, isca).
@Suite("Catalogo de moedas")
struct CoinCatalogTests {
    static func coins() throws -> [CatalogCoin] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/coingecko-coins-list.json")
        return try CoinCatalog.parse(try Data(contentsOf: url))
    }

    static func coin(_ id: String) throws -> CatalogCoin? { try coins().first { $0.id == id } }

    @Test("So redes que recebem token por endereco, contrato na forma da moeda custom")
    func networks() throws {
        let bonk = try #require(try Self.coin("bonk"))
        #expect(bonk.symbol == "BONK" && bonk.name == "Bonk")
        // Aptos e Neon EVM ficam de fora; a ordem e a das redes da carteira.
        let order = Chain.all.map(\.id)
        #expect(bonk.networks.map(\.chainID) == order.filter { ["ethereum", "bnb", "solana"].contains($0) })
        #expect(bonk.networks.first { $0.chainID == "ethereum" }?.contract == "0x1151cb3d861920e07a38e03eead12c32178567f6")
        #expect(bonk.networks.first { $0.chainID == "solana" }?.contract == "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263")
        #expect(try Self.coin("notcoin")?.networks.map(\.chainID) == ["ton"])
        #expect(try Self.coin("sun-token")?.networks.map(\.chainID) == ["tron"])
    }

    @Test("Moeda da lista: so as redes de fora da lista; USDT de outro id, isca e contrato invalido ficam de fora")
    func safety() throws {
        let pepe = try #require(try Self.coin("pepe"))
        #expect(Set(pepe.networks.map(\.chainID)) == ["arbitrum", "bnb"])
        let tether = try #require(try Self.coin("tether"))
        #expect(tether.networks.isEmpty)
        #expect(try Self.coin("bridged-usdt-impostor") == nil)
        #expect(try Self.coin("claim-token") == nil)
        #expect(try Self.coin("bad-contract")?.networks.isEmpty == true)
    }

    @Test("Moeda sem rede aqui (Hedera, so na Sui) continua na lista, sem rede para receber")
    func unsupported() throws {
        #expect(try Self.coin("hedera-hashgraph")?.isReceivable == false)
        #expect(try Self.coin("sui-only")?.isReceivable == false)
    }

    @Test("Busca: simbolo exato, depois prefixo, nome; dentro do grupo, pela posicao no mercado")
    func search() throws {
        let coins = try Self.coins()
        let toshi = CoinCatalog.search(coins, query: "toshi", rank: [:], limit: 10).map(\.id)
        #expect(toshi == ["toshi", "toshi-the-cat"])
        #expect(CoinCatalog.search(coins, query: "not", rank: [:], limit: 10).first?.id == "notcoin")
        #expect(CoinCatalog.search(coins, query: "token", rank: [:], limit: 10).map(\.id) == ["sun-token"])
        #expect(CoinCatalog.search(coins, query: "t", rank: [:], limit: 10).isEmpty)
        // Mesmo grupo (nome que contem "o"... prefixo de simbolo "TOSHI"): o rank decide.
        let ranked = CoinCatalog.search(coins, query: "tosh", rank: ["toshi-the-cat": 5, "toshi": 50], limit: 10).map(\.id)
        #expect(ranked == ["toshi-the-cat", "toshi"])
    }
}

@Suite("Catalogo de moedas ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"))
struct CoinCatalogLiveTests {
    @Test("A lista completa do CoinGecko chega, cabe no teto e tem milhares de moedas que a carteira recebe")
    func fetch() async throws {
        let started = Date()
        let coins = try await CoinCatalog.fetch()
        let elapsed = Date().timeIntervalSince(started)
        #expect(coins.count > 15_000)
        #expect(coins.filter(\.isReceivable).count > 10_000)
        #expect(coins.contains { $0.id == "bonk" && $0.isReceivable })
        print("catalogo: \(coins.count) moedas, \(coins.filter(\.isReceivable).count) recebiveis, \(elapsed) s")
    }
}
