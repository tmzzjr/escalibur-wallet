@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// O historico EVM: a pagina real do Blockscout da Base (Binance 8, gravada em
/// 26/09/2026) pelo leitor de verdade, e a triagem de suspeitos com itens montados.
@Suite("Motor EVM: atividade")
struct EVMActivityTests {
    typealias A = EVMTestAccounts

    static let usdc = TokenRegistry.find(chainID: "base", contract: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")!

    static func source(_ transport: EVMFixtureTransport) -> EVMActivitySource {
        let reader = EVMReader(transport: transport, rpc: [:], history: ["base": testProviders("blockscout")], privateRelays: [])
        return EVMActivitySource(chain: .base, reader: reader)!
    }

    static func blockscout() throws -> EVMFixtureTransport {
        let transactions = try EVMFixtures.data("blockscout-transactions-base-binance8")
        let tokens = try EVMFixtures.data("blockscout-token-transfers-base-binance8")
        return EVMFixtureTransport([{ call in
            let path = call.request.url.path
            if path.hasSuffix("/transactions") { return transactions }
            if path.hasSuffix("/token-transfers") { return tokens }
            return nil
        }])
    }

    @Test("Pagina real da Base: tokens de golpe e po ficam de fora, o recebimento real e as chamadas do dono aparecem")
    func recordedPage() async throws {
        let transport = try Self.blockscout()
        let entries = try await Self.source(transport).history(chain: .base, account: A.binance8(on: .base), usage: nil)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.chainID == "base" && $0.asset.map { EVMActivityScreen.isListed($0, chain: .base) } == true })
        // 0,00037342 ETH de 0xaF20290f...20c9: recebimento de verdade, acima do po. O
        // "EṬH" do sosia 0xaF2007aD...20c9 e o po de 0x2652742D...1008 nao chegam aqui.
        let received = entries.filter { $0.direction == .received }
        #expect(received.count == 1)
        #expect(received.first?.amount == BigUInt(373_420_000_000_000))
        #expect(received.first?.counterparty == "0xaF20290fb8717d456C0c7c6A1C758976d94820c9")
        #expect(received.allSatisfy { !$0.suspicious })
        // As chamadas do dono (sem valor nativo, tokens fora da lista) aparecem como
        // "outro", com a taxa, e nunca como suspeitas.
        let calls = entries.filter { $0.direction == .other }
        #expect(!calls.isEmpty && calls.allSatisfy { !$0.suspicious && $0.fee != nil && $0.status == .confirmed })
        // O endereco vai no caminho do GET do indexador (nao ha consulta por POST).
        #expect(transport.calls.allSatisfy { $0.request.method == .get })
    }

    @Test("Triagem: valor zero, token fora da lista, po de desconhecido e endereco parecido ficam escondidos")
    func screening() throws {
        let owner = A.binance8
        let friend = "0x28C6c06298d514Db089934071355E5743bf21d60"
        // Mesmas pontas do amigo, meio diferente: o sosia que manda centavos.
        let lookalike = "0x28c6c0" + String(repeating: "5", count: 28) + "f21d60"
        let stranger = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        let fake = Asset(chainID: "base", kind: .token(contract: "0x58bDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B"), symbol: "USDC",
                         name: "USD Coin", decimals: 6, coingeckoID: nil, isStablecoin: true)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func item(_ id: String, _ direction: ActivityItem.Direction, _ asset: Asset, _ amount: BigUInt, _ counterparty: String?) -> ActivityItem {
            ActivityItem(id: id, chainID: "base", direction: direction, asset: asset, amount: amount, counterparty: counterparty,
                         date: now, status: .confirmed, fee: nil, hash: "0x" + id, explorerURL: nil)
        }
        let page = ActivityPage(chainID: "base", items: [
            item("01", .sent, Self.usdc, 50_000_000, friend),
            item("02", .received, Self.usdc, 1_000, lookalike),         // 0,001 USDC do sosia
            item("03", .received, Self.usdc, 0, stranger),              // valor zero
            item("04", .received, fake, 5_000_000, stranger),           // token fora da lista
            item("05", .received, Self.usdc, 5_000, stranger),          // po de desconhecido
            item("06", .received, Self.usdc, 5_000, friend),            // pouco, mas de quem o dono conhece
            item("07", .received, Self.usdc, 20_000_000, stranger),     // recebimento normal
            item("08", .received, Self.usdc, 20_000_000, lookalike),    // valor alto, mesmo assim do sosia
            item("09", .sent, Self.usdc, 0, lookalike),                 // o que o dono assinou aparece sempre
            item("10", .other, .native(.base), 0, "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
        ], suspicious: SuspiciousSummary())
        let entries = EVMActivityScreen.entries(page, owner: owner, chain: .base)
        let hidden = Set(entries.filter(\.suspicious).map(\.id))
        #expect(hidden == ["02", "03", "04", "05", "08"])
        #expect(entries.count == page.items.count)
        let first = try #require(entries.first)
        #expect(first.direction == .sent && first.asset == Self.usdc && first.amount == 50_000_000 && first.status == .confirmed)
    }

    @Test("BNB Chain: o historico diz que ainda nao existe, sem lista vazia fingindo")
    func bnbUnavailable() async throws {
        let source = try #require(ActivitySources.source(for: .bnb))
        #expect(source is EVMUnavailableActivitySource)
        await #expect(throws: SendEngineError.unavailable("O histórico da BNB Chain ainda não está disponível nesta versão.")) {
            _ = try await source.history(chain: .bnb, account: A.binance8(on: .bnb), usage: nil)
        }
    }

    @Test("Registro: as sete redes EVM tem envio e historico; troca fora da Avalanche; ordem limite fora da OP")
    func registry() throws {
        for chain in Chain.evmChains {
            #expect(SendEngines.engine(for: chain) is EVMSendEngine, "\(chain.id)")
            #expect(ActivitySources.source(for: chain) != nil, "\(chain.id)")
        }
        #expect(TradeEngines.engine(for: .avalanche) == nil)
        let optimism = try #require(TradeEngines.engine(for: .optimism))
        #expect(!optimism.supportsLimitOrders)
        #expect(optimism.limitCustodyNote == "Ordens limite ainda não estão disponíveis na Optimism.")
        for chain in [Chain.ethereum, .base, .arbitrum, .polygon, .bnb] {
            let engine = try #require(TradeEngines.engine(for: chain), "\(chain.id)")
            #expect(engine.supportsLimitOrders, "\(chain.id)")
            #expect(engine.limitCustodyNote == "O valor fica na sua carteira até a ordem executar. Você pode cancelar a qualquer momento.")
        }
        // So as EVM: outras familias registram troca nos proprios arquivos.
        #expect(TradeEngines.chains.filter { $0.family == .evm }.map(\.id) == ["ethereum", "base", "arbitrum", "optimism", "polygon", "bnb"])
    }
}
