import XCTest

/// Esqueci o PIN: a explicacao em passos e o alerta do proprio iPhone antes de apagar.
final class ForgotPINTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testForgotPINExplainsAndAsksBeforeErasing() {
        let setup = XCUIApplication()
        setup.launchArguments = ["-reset", "-demo"]
        setup.launch()
        XCTAssertTrue(setup.staticTexts["Carteira principal"].waitForExistence(timeout: 30))
        setup.terminate()

        // Sem -demo o app abre trancado, pedindo o PIN.
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        let forgot = app.buttons["Esqueci o PIN"]
        XCTAssertTrue(forgot.waitForExistence(timeout: 15))
        forgot.tap()
        XCTAssertTrue(app.staticTexts["Não existe redefinir o PIN"].waitForExistence(timeout: 5))
        shot("p1-esqueci", app)

        app.buttons["Apagar as carteiras deste iPhone"].tap()
        let alert = app.alerts["Apagar as carteiras deste iPhone?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "a confirmacao deveria ser o alerta do iPhone")
        XCTAssertTrue(alert.buttons["Apagar permanentemente"].exists)
        shot("p2-alerta", app)
        alert.buttons["Cancelar"].tap()
        XCTAssertTrue(app.staticTexts["Não existe redefinir o PIN"].waitForExistence(timeout: 5), "cancelar nao pode apagar nada")
    }
}
