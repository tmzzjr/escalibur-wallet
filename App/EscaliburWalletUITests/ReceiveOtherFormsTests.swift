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
        XCTAssertTrue(app.buttons["outra-forma-WBTC-ethereum"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["outra-forma-ETH-bnb"].waitForExistence(timeout: 5))
        app.swipeUp()
        shot("receber-eth-formas", app)

        // XRP: a rede XRP Ledger como rede, e o XRP da Binance so em "Outras formas".
        app.navigationBars.buttons.firstMatch.tap()
        let xrp = app.buttons["XRP, XRP"]
        XCTAssertTrue(xrp.waitForExistence(timeout: 10))
        xrp.tap()
        // Na mesma lista de redes, a BNB Chain diz que e o XRP da Binance.
        XCTAssertTrue(app.buttons["outra-forma-XRP-bnb"].waitForExistence(timeout: 5))
        shot("receber-xrp-formas", app)
        app.buttons["outra-forma-XRP-bnb"].tap()
        XCTAssertTrue(app.staticTexts["XRP (Binance-Peg) · BEP-20"].waitForExistence(timeout: 5))
        shot("receber-xrp-binance", app)

        // SOL: a Solana e a BNB Chain (BEP-20) na mesma lista.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let sol = app.buttons["SOL, Solana"]
        XCTAssertTrue(sol.waitForExistence(timeout: 10))
        sol.tap()
        XCTAssertTrue(app.buttons["outra-forma-SOL-bnb"].waitForExistence(timeout: 5))
        shot("receber-sol-redes", app)
    }
}
