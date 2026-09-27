import XCTest

/// Receber: moeda, depois rede, depois endereco.
final class ReceiveFlowTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testCoinThenNetworkThenAddress() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        let receive = app.buttons["Receber"].firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        receive.tap()
        let usdt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'USDT'")).firstMatch
        XCTAssertTrue(usdt.waitForExistence(timeout: 10))
        shot("r1-moedas", app)
        usdt.tap()
        let tron = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tron'")).firstMatch
        XCTAssertTrue(tron.waitForExistence(timeout: 10))
        shot("r2-redes", app)
        tron.tap()
        XCTAssertTrue(app.staticTexts["Receber USDT"].waitForExistence(timeout: 10))
        shot("r3-endereco", app)
    }

    /// Token emitido (RLUSD no XRP Ledger): a tela avisa da linha de confianca.
    func testIssuedTokenTrustLineNote() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        let receive = app.buttons["Receber"].firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        receive.tap()
        let rlusd = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'RLUSD'")).firstMatch
        if !rlusd.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(rlusd.waitForExistence(timeout: 10))
        rlusd.tap()
        let xrpl = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'XRP Ledger'")).firstMatch
        if xrpl.waitForExistence(timeout: 5) { xrpl.tap() }
        XCTAssertTrue(app.staticTexts["Receber RLUSD"].waitForExistence(timeout: 10))
        app.swipeUp()
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Para receber RLUSD, esta conta precisa antes de uma linha de confiança'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        shot("r4-rlusd-linha", app)
    }
}
