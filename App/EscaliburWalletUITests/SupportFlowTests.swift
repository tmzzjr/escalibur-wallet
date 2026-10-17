import XCTest

/// Suporte: o questionario que vira chamado por e-mail, sem o endereco na tela, e o texto
/// com cara de senha da carteira que nao sai (pedido do dono, 16/10/2026).
final class SupportFlowTests: XCTestCase {
    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots = ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
    }

    func testTicketFormAndPhraseGuard() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "ajustes"]
        app.launch()
        let support = app.buttons["ajustes-suporte"]
        var tries = 0
        while !support.waitForExistence(timeout: 3) && tries < 8 { app.swipeUp(); tries += 1 }
        support.tap()
        XCTAssertTrue(app.staticTexts["Fale com o suporte"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["thomaz@xtech.international"].exists, "o endereco nao aparece na tela")
        let send = app.buttons["suporte-enviar"]
        XCTAssertFalse(send.isEnabled)
        app.buttons["suporte-assunto-transfer"].tap()
        XCTAssertTrue(app.staticTexts["Em qual rede?"].waitForExistence(timeout: 5))
        let text = app.textViews["suporte-texto"]
        text.tap()
        text.typeText("Mandei USDT e ainda nao chegou do outro lado.")
        // Sem o e-mail conferido, nao sai.
        XCTAssertFalse(send.isEnabled)
        let email = app.textFields["suporte-email"]
        email.tap()
        email.typeText("pessoa@exemplo.com")
        let again = app.textFields["suporte-email-repita"]
        again.tap()
        again.typeText("pessoa@exemplo.co")
        XCTAssertTrue(app.staticTexts["Os dois e-mails não conferem."].waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled)
        again.typeText("m")
        XCTAssertTrue(send.isEnabled)
        text.tap()
        shot("s1-suporte", app)
        // Doze palavras da lista: o chamado nao sai.
        text.typeText(" ocean figure velvet canyon ripple lamp orbit meadow")
        XCTAssertTrue(app.staticTexts["Isto parece a senha da carteira"].waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled)
        shot("s2-suporte-senha", app)
    }
}
