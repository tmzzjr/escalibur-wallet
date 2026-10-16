import XCTest

/// So para gravar em video (ESCALIBUR_VIDEO) as telas redesenhadas em 15/10/2026: antes
/// das palavras, as palavras (os botoes jogando a carta, a chapa inclinando, a copia), o
/// lacre do envelope, a ponte e os enderecos salvos vazios.
final class DesignPassLookTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ESCALIBUR_VIDEO"] == nil, "so com ESCALIBUR_VIDEO")
    }

    private func launch(_ screen: String, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-reset"] : []) + ["-demo", "-tela", screen]
        app.launch()
        return app
    }

    func testPass() {
        var app = launch("criar")
        XCTAssertTrue(app.staticTexts["Antes de ver as palavras"].waitForExistence(timeout: 30))
        sleep(6)
        app.terminate()

        app = launch("palavras")
        let next = app.buttons["Próximas"]
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        sleep(2)
        next.tap()
        sleep(2)
        next.tap()
        sleep(2)
        app.buttons["Anteriores"].tap()
        sleep(2)
        app.buttons["ver-todas-palavras"].tap()
        sleep(2)
        let plate = app.staticTexts["palavra-3"]
        let center = plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 70, dy: -30)), withVelocity: 120, thenHoldForDuration: 1.2)
        sleep(2)
        if app.buttons["copiar-palavras"].exists {
            app.buttons["copiar-palavras"].tap()
            sleep(6)
        }
        app.terminate()

        app = launch("lacrando")
        sleep(14)
        app.terminate()

        app = launch("ponte")
        sleep(5)
        app.terminate()
    }
}
