import XCTest

/// Mercado: ordenar por maior alta, maior queda e maior preco.
final class MarketSortTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testSortOptions() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "mercado"]
        app.launch()
        XCTAssertTrue(app.staticTexts["BTC"].waitForExistence(timeout: 30), "o mercado deveria carregar")
        for (option, name) in [("Maior queda", "k1-queda"), ("Maior alta", "k2-alta"), ("Maior preço", "k3-preco")] {
            let chip = app.buttons["ordem-\(option)"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), option)
            chip.tap()
            sleep(1)
            shot(name, app)
        }
        // Maior preco: o bitcoin vem antes do tether.
        let btc = app.staticTexts["BTC"].frame.minY
        let usdt = app.staticTexts["USDT"]
        if usdt.exists { XCTAssertLessThan(btc, usdt.frame.minY) }
    }
}
