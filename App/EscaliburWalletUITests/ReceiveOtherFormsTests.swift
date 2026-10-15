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
        // O botao pelo identificador, e so depois de a carteira assentar: a lista de saldos
        // que chega mexe a tela, e um toque pelo texto caia numa linha de moeda.
        let receive = app.buttons["acao-receber"]
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        sleep(6)
        receive.tap()

        let btc = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BTC,'")).firstMatch
        if !btc.waitForExistence(timeout: 20) { shot("receber-sem-btc", app); print("ROTULOS:", app.buttons.allElementsBoundByIndex.prefix(25).map { $0.label }) }
        XCTAssertTrue(btc.exists)
        btc.tap()
        XCTAssertTrue(app.staticTexts["Outras formas de BTC"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bitcoin'")).firstMatch.exists)
        let wbtc = app.buttons["outra-forma-WBTC-ethereum"]
        XCTAssertTrue(wbtc.exists)
        XCTAssertTrue(app.buttons["outra-forma-BTCB-bnb"].exists)
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

        // XRP: a rede XRP Ledger como rede, e o XRP da Binance so em "Outras formas".
        app.navigationBars.buttons.firstMatch.tap()
        let xrp = app.buttons["XRP, XRP"]
        XCTAssertTrue(xrp.waitForExistence(timeout: 10))
        xrp.tap()
        XCTAssertTrue(app.staticTexts["Outras formas de XRP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["outra-forma-XRP-bnb"].exists)
        // A BNB nao e uma rede do XRP nativo: so aparece em "Outras formas".
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BNB Chain'")).firstMatch.exists)
        shot("receber-xrp-formas", app)
        app.buttons["outra-forma-XRP-bnb"].tap()
        XCTAssertTrue(app.staticTexts["XRP (Binance-Peg) · BEP-20"].waitForExistence(timeout: 5))
        shot("receber-xrp-binance", app)
    }
}
