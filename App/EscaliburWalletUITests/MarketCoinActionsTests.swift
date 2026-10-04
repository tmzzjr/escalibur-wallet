import XCTest

/// Pagina da moeda no Mercado: tocar no preco troca a moeda; Comprar e Vender (quando a
/// carteira tem a moeda) levam a Trocar com a moeda escolhida.
final class MarketCoinActionsTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testBuySellAndCurrencyToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "mercado"]
        app.launch()
        let xrp = app.staticTexts["XRP"].firstMatch
        XCTAssertTrue(xrp.waitForExistence(timeout: 30), "o mercado deveria carregar")
        xrp.tap()
        let sell = app.buttons["Vender"]
        XCTAssertTrue(sell.waitForExistence(timeout: 20), "a carteira de teste tem XRP: Vender deveria aparecer")
        XCTAssertTrue(app.buttons["Comprar XRP"].exists)
        let brl = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'R$'")).firstMatch
        XCTAssertTrue(brl.waitForExistence(timeout: 10))
        brl.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'US$'")).firstMatch.waitForExistence(timeout: 5),
                      "tocar no preco deveria mostrar em dolar")
        shot("c1-moeda-dolar", app)
        sell.tap()
        XCTAssertTrue(app.staticTexts["Você paga"].waitForExistence(timeout: 10), "Vender deveria abrir Trocar")
        shot("c2-vender-xrp", app)
    }
}
