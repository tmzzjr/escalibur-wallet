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
}
