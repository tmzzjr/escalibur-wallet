import XCTest

/// A ponte para a Tron na tela (pedido do dono, 17/10/2026): Ethereum para a Tron, 1.000 USDT,
/// cotados ao vivo no contrato da Tether. Nada e assinado.
final class BridgeTronTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testBridgeToTronQuotes() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "ponte-tron"]
        app.launch()
        let fee = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Taxa da Tether'")).firstMatch
        XCTAssertTrue(fee.waitForExistence(timeout: 45), "a cotacao da Tether nao apareceu")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Chega na Tron'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Taxa de entrega na Tron'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Vai para a sua própria conta na Tron, desta mesma carteira"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ponte-tron"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
