import XCTest

/// Receber BTC mostra tambem o WBTC, e Receber ETH o WETH e o ETH da Binance, como
/// "Outras formas", cada uma com o nome do proprio token (pedido do dono, 15/10/2026).
final class ReceiveOtherFormsTests: XCTestCase {
    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots = ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
    }

    func testWrappedFormsInsideTheCoin() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        let receive = app.buttons["Receber"].firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        sleep(3)
        receive.tap()

        let btc = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BTC'")).firstMatch
        XCTAssertTrue(btc.waitForExistence(timeout: 10))
        btc.tap()
        XCTAssertTrue(app.staticTexts["Outras formas de BTC"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bitcoin'")).firstMatch.exists)
        let wbtc = app.buttons["outra-forma-WBTC-ethereum"]
        XCTAssertTrue(wbtc.exists)
        shot("receber-btc-formas", app)
        wbtc.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'WBTC'")).firstMatch.waitForExistence(timeout: 5))
        shot("receber-wbtc", app)

        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let eth = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'ETH,'")).firstMatch
        XCTAssertTrue(eth.waitForExistence(timeout: 10))
        eth.tap()
        XCTAssertTrue(app.staticTexts["Outras formas de ETH"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["outra-forma-ETH-bnb"].exists)
        app.swipeUp()
        shot("receber-eth-formas", app)
    }
}
