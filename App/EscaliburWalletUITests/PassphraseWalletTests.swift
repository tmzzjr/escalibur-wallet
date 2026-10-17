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
        // O passo a passo da passphrase, as quatro telas (16/10/2026).
        app.buttons["passphrase-como-funciona"].tap()
        XCTAssertTrue(app.staticTexts["Um cofre escondido nas mesmas palavras"].waitForExistence(timeout: 5))
        for index in 0..<4 {
            sleep(3)
            shot("q0-como-\(index + 1)", app)
            app.buttons[index < 3 ? "Próximo" : "Entendi"].tap()
        }
        XCTAssertTrue(app.staticTexts["Carteira com passphrase"].waitForExistence(timeout: 5))
        // Antes dos campos, a checagem do aparelho (pedido do dono, 16/10/2026).
        app.buttons["Continuar"].tap()
        app.passDeviceCheck()
        let entry = app.staticTexts["Digite a passphrase"].waitForExistence(timeout: 10)
        shot("q1b-digitar", app)
        XCTAssertTrue(entry)

        let fields = app.secureTextFields
        XCTAssertTrue(fields.element(boundBy: 0).waitForExistence(timeout: 5))
        fields.element(boundBy: 0).tap()
        fields.element(boundBy: 0).typeText("lanterna")
        // A repeticao aparece quando a primeira comeca a ser digitada (16/10/2026).
        let second = fields.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 5), "a repeticao deveria aparecer")
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

        // Vai direto para a Carteira, com a carteira nova em uso (17/10/2026).
        XCTAssertTrue(app.staticTexts["Carteira principal com passphrase"].waitForExistence(timeout: 30), "a carteira nova deveria abrir na Carteira")
        XCTAssertTrue(app.buttons["acao-receber"].exists, "deveria estar na tela Carteira")
        shot("q2-em-uso", app)
    }

    /// A folha da passphrase antes de mover saldo: a folga desligada, e ao ligar comeca em 5 minutos.
    func testPassphrasePromptGrace() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "passphrase-envio"]
        app.launch()
        let toggle = app.switches["passphrase-folga"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 30))
        XCTAssertEqual(toggle.value as? String, "0")
        shot("p1-passphrase-folga-desligada", app)
        toggle.switches.firstMatch.tap()
        let five = app.buttons["5 min"]
        XCTAssertTrue(five.waitForExistence(timeout: 5))
        XCTAssertTrue(five.isSelected)
        app.buttons["15 min"].tap()
        shot("p2-passphrase-folga-15", app)
    }
}
