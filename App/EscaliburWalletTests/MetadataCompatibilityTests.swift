import EscaliburChains
import EscaliburEngines
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburWallet

/// Um arquivo de metadados gravado pela versao 1.0 tem de abrir em toda versao depois
/// dela. O Codable sintetizado ignora valor padrao: um campo novo nao opcional faria o
/// arquivo antigo falhar com `keyNotFound`, e o dono cairia em "Nao foi possivel
/// destravar" sem saida alem de apagar tudo. Campo novo entra como opcional (ou com
/// decodificacao propria), e este teste pega quem esquecer.
@Suite("Metadados da 1.0 abrem nas versoes seguintes")
struct MetadataCompatibilityTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/metadados-1.0.json")

    @Test("O arquivo da 1.0 decodifica, com os campos que ele tinha")
    func decodesVersionOne() throws {
        let data = try Data(contentsOf: Self.fixture)
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        #expect(metadata.wallets.count == 2)
        #expect(metadata.wallets[0].name == "Carteira principal")
        #expect(metadata.wallets[0].accounts.first?.chainID == "ethereum")
        #expect(metadata.wallets[1].isWatchOnly)
        #expect(metadata.contacts.first?.tag == "123")
        #expect(metadata.settings.currency == "usd")
        #expect(metadata.settings.voice.enabled)
        #expect(metadata.sentTo["ethereum"]?.count == 1)
        #expect(metadata.balanceCache.values.first?["ethereum"]?.accountExists == true)
        #expect(metadata.quoteCache["bitcoin"]?.price == 100_000)
        #expect(metadata.pendingEVM?.values.first?.first?.nonce == 7)
        #expect(metadata.responsibilityAccepted == nil)
        #expect(metadata.responsibilityVersion == nil)
    }

    @Test("O aceite de responsabilidade grava e volta: data e versao do texto")
    func responsibilityRoundTrip() throws {
        var metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: Self.fixture))
        let when = Date(timeIntervalSince1970: 1_790_000_900)
        metadata.responsibilityAccepted = when
        metadata.responsibilityVersion = ResponsibilityView.version
        let back = try JSONDecoder().decode(Metadata.self, from: JSONEncoder().encode(metadata))
        #expect(back.responsibilityAccepted == when)
        #expect(back.responsibilityVersion == ResponsibilityView.version)
        #expect(back.wallets == metadata.wallets)
    }

    /// Gera o arquivo uma vez, na versao 1.0: `ESCALIBUR_GRAVAR_METADADOS=1`. Depois
    /// disso o arquivo fica congelado no repositorio e nunca mais e regravado.
    @Test("Gerador do arquivo da 1.0", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_GRAVAR_METADADOS"] == "1"))
    func writeVersionOne() throws {
        let account = DerivedAccount(chainID: "ethereum", path: DefaultPaths.path(for: .ethereum),
                                     address: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", publicKey: [UInt8](repeating: 2, count: 33), accountXPub: nil)
        var main = WalletMeta(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Carteira principal",
                              kind: .phrase(wordCount: 12), origin: .created, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                              accounts: [account], fingerprint: "73c5da0a", hasPassphrase: false)
        main.backupConfirmedAt = Date(timeIntervalSince1970: 1_790_000_100)
        main.envelopeSealedAt = Date(timeIntervalSince1970: 1_790_000_200)
        main.hiddenAssetIDs = ["ethereum:0xdead"]
        main.utxoUsage = ["bitcoin": UTXOUsage(receiveUsed: 3, changeUsed: 1)]
        let watch = WalletMeta(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Acompanhar",
                               kind: .watch(chainID: "ethereum"), origin: .watch, createdAt: Date(timeIntervalSince1970: 1_790_000_300),
                               accounts: [account], fingerprint: nil, hasPassphrase: false)
        var metadata = Metadata()
        metadata.wallets = [main, watch]
        metadata.selectedWalletID = main.id
        metadata.contacts = [Contact(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, name: "Exchange",
                                     chainID: "xrpl", address: "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", tag: "123")]
        metadata.settings.currency = "usd"
        metadata.settings.totalUnit = "btc"
        metadata.settings.favoriteCoins = ["solana"]
        metadata.settings.hideBalances = true
        metadata.settings.autoLockSeconds = 30
        metadata.settings.disabledChainIDs = ["celo"]
        metadata.settings.voice.enabled = true
        metadata.settings.voice.onSendAboveFiat = 1000
        metadata.sentTo = ["ethereum": ["0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"]]
        let balance = try JSONDecoder().decode(ChainBalance.self, from: Data(
            #"{"chainID":"ethereum","holdings":[],"accountExists":true,"unknownTokenCount":2,"fetchedAt":780000000}"#.utf8))
        metadata.balanceCache = [main.id: ["ethereum": balance]]
        metadata.quoteCache = ["bitcoin": try JSONDecoder().decode(Quote.self, from: Data(#"{"price":100000,"change24h":1.5}"#.utf8))]
        metadata.cachedAt = Date(timeIntervalSince1970: 1_790_000_400)
        metadata.pendingEVM = [NonceQueue.key(wallet: main.id, chain: .ethereum, address: account.address):
                                [PendingEVMTransaction(nonce: 7, hash: "0xabc", sentAt: Date(timeIntervalSince1970: 1_790_000_500))]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: Self.fixture)
    }
}
