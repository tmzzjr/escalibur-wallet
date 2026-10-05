import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburWallet

/// O texto das notificacoes de preco e o arquivo dos alertas.
struct PriceAlertTextTests {
    let nbsp = "\u{00A0}"
    let bitcoin = WatchedCoin(id: "bitcoin", symbol: "btc", name: "Bitcoin")

    func quote(_ price: Double, _ change: Double?) throws -> Quote {
        try JSONDecoder().decode(Quote.self, from: Data(#"{"price":\#(price)\#(change.map { ",\"change24h\":\($0)" } ?? "")}"#.utf8))
    }

    @Test func crossingUp() throws {
        let text = PriceAlertText.describe(.crossedUp(level: 450_000), coin: bitcoin, quote: try quote(451_395, 2.11), currency: .brl)
        #expect(text.title == "Bitcoin passou de R$\(nbsp)450.000")
        #expect(text.body == "Agora R$\(nbsp)451.395,00, +2,11% em 24 h.")
    }

    @Test func crossingDownSmallLevel() throws {
        let text = PriceAlertText.describe(.crossedDown(level: 1.1), coin: WatchedCoin(id: "ripple", symbol: "xrp", name: "XRP"), quote: try quote(1.0942, nil), currency: .usd)
        #expect(text.title == "XRP caiu abaixo de US$\(nbsp)1,10")
        #expect(text.body == "Agora US$\(nbsp)1,09.")
    }

    @Test func move() throws {
        let down = PriceAlertText.describe(.moved(change: -12.34), coin: bitcoin, quote: try quote(400_000, -12.34), currency: .brl)
        #expect(down.title == "Bitcoin caiu 12,3% em 24 h")
        let up = PriceAlertText.describe(.moved(change: 10.05), coin: bitcoin, quote: try quote(400_000, 10.05), currency: .brl)
        #expect(up.title == "Bitcoin subiu 10,1% em 24 h")
    }

    /// O nome do provedor nunca vai para a tela bloqueada: lista do app, ou o simbolo
    /// filtrado.
    @Test func nameNeverFromProvider() {
        let fake = WatchedCoin(id: "bitcoin", symbol: "btc", name: "Bitcoin caiu 90%, saque agora")
        #expect(PriceAlertText.name(fake) == "Bitcoin")
        let unknown = WatchedCoin(id: "golpe-x", symbol: "<b>pepe🐸 http://x.co", name: "Abra este link")
        #expect(PriceAlertText.name(unknown) == "BPEPEHTTPX")
        #expect(PriceAlertText.name(WatchedCoin(id: "nada", symbol: "🐸", name: "x")) == "Moeda")
    }

    @Test func fileRoundTripAndErase() throws {
        var file = PriceAlertFile()
        file.enabled = true
        file.coins = [bitcoin]
        var memory = PriceAlertMemory()
        memory.lastPrice = 450_000
        file.memory["bitcoin"] = memory
        try PriceAlertStore.save(file)
        #expect(PriceAlertStore.load() == file)
        let values = try PriceAlertStore.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        PriceAlertStore.erase()
        #expect(PriceAlertStore.load() == PriceAlertFile())
    }
}
