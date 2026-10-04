import XCTest

/// Seguranca, carteira com 25ª palavra: nasce da carteira selecionada, com uma
/// confirmacao, e vira a carteira em uso.
final class PassphraseWalletTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func type(pin: String, in app: XCUIApplication) {
        for digit in pin {
            let key = app.buttons.matching(identifier: "tecla-\(digit)").firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 10), "tecla \(digit)")
            key.tap()
        }
    }

    func testCreatePassphraseWallet() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "ajustes"]
        app.launch()
        let security = app.staticTexts["Segurança"]
        XCTAssertTrue(security.waitForExistence(timeout: 30))
        security.tap()
        let row = app.staticTexts["Carteira com passphrase"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Carteira com passphrase"].waitForExistence(timeout: 5))
        shot("q1-25a", app)

        let fields = app.secureTextFields
        XCTAssertTrue(fields.element(boundBy: 0).waitForExistence(timeout: 5))
        fields.element(boundBy: 0).tap()
        fields.element(boundBy: 0).typeText("lanterna")
        let second = fields.element(boundBy: 1)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        // O toque logo depois de digitar no primeiro campo as vezes chega durante a
        // animacao do teclado; um segundo toque resolve, como faria a pessoa.
        var waited = XCTWaiter.Result.timedOut
        for _ in 0..<2 where waited != .completed {
            second.tap()
            waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: second)], timeout: 3)
        }
        XCTAssertEqual(waited, .completed, "tocar no segundo campo deveria pôr o teclado nele")
        second.typeText("lanterna")
        app.buttons["Abrir carteira"].tap()
        type(pin: "111111", in: app)

        // Volta para Seguranca; a carteira nova e a selecionada.
        XCTAssertTrue(app.staticTexts["Mudar o PIN"].waitForExistence(timeout: 30), "deveria voltar para Seguranca")
        app.buttons["Carteira"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Carteira principal com passphrase"].waitForExistence(timeout: 15), "a carteira nova deveria estar em uso")
        shot("q2-em-uso", app)
    }
}
