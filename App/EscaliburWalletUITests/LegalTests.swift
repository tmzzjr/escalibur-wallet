import XCTest

/// Os textos legais abrem do proprio app, a partir das boas-vindas.
final class LegalTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testPrivacyFromWelcome() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset"]
        app.launch()
        let link = app.links["Política de privacidade"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        XCTAssertTrue(app.staticTexts["Com quem o app fala"].waitForExistence(timeout: 5))
        shot("l1-privacidade", app)
        app.buttons["Fechar"].tap()
        app.links["Termos de uso"].tap()
        XCTAssertTrue(app.staticTexts["A sua responsabilidade"].waitForExistence(timeout: 5))
        shot("l2-termos", app)
    }
}
