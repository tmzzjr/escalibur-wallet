import XCTest

/// Envelope de ponta a ponta na interface: lacrar com as 6 palavras sorteadas, e abrir
/// o envelope de referencia lacrado em Python. As fotos pegam a animacao no meio.
final class EnvelopeFlowTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUp() {
        continueAfterFailure = false
    }

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

    /// Espera o elemento; se nao vier, deixa a foto da tela para o diagnostico.
    func wait(_ element: XCUIElement, _ timeout: TimeInterval, _ app: XCUIApplication, _ name: String) {
        if !element.waitForExistence(timeout: timeout) {
            shot("falha-\(name)", app)
            XCTFail("nao apareceu: \(name)")
        }
    }

    func passwordField(_ app: XCUIApplication) -> XCUIElement {
        let secure = app.secureTextFields.firstMatch
        return secure.exists ? secure : app.textFields.firstMatch
    }

    func testSeal() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "lacrar"]
        app.launch()
        let start = app.buttons["Continuar"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        sleep(1)
        shot("e1-lacrar", app)
        start.tap()
        // PIN errado dentro da operacao: o teclado volta com o aviso, e o certo segue.
        type(pin: "135790", in: app)
        wait(app.staticTexts["PIN incorreto."], 10, app, "pin-incorreto")
        shot("e0-pin-errado", app)
        type(pin: "111111", in: app)
        let words = app.staticTexts["palavras-envelope"]
        XCTAssertTrue(words.waitForExistence(timeout: 15))
        let password = words.label
        app.buttons["Anotei, continuar"].tap()
        let field = passwordField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(password)
        app.buttons["Lacrar envelope"].tap()
        wait(app.staticTexts["Lacrando o envelope"], 10, app, "lacrando")
        usleep(400_000)
        shot("e2-lacrando", app)
        XCTAssertTrue(app.staticTexts["Envelope lacrado"].waitForExistence(timeout: 60))
        sleep(2)
        shot("e3-lacrado", app)
    }

    func testOpenChoose() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "abrir"]
        app.launch()
        XCTAssertTrue(app.buttons["Escolher arquivo"].waitForExistence(timeout: 30))
        sleep(1)
        shot("e4-abrir", app)
    }

    func testOpenReference() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kit/Tests/EscaliburCoreTests/Fixtures/referencia-python.esclbr")
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "abrir", "-envelope", fixture.path]
        app.launch()
        sleep(4)
        let field = passwordField(app)
        wait(field, 30, app, "senha")
        field.tap()
        field.typeText("senha de referencia em python")
        app.buttons["Abrir envelope"].tap()
        // O envelope de referencia usa 64 MiB e abre em menos de um segundo: a foto
        // do meio sai quando der.
        shot("e5-abrindo", app)
        wait(app.staticTexts["Lacrado em Python"], 60, app, "aberto")
        sleep(2)
        shot("e6-aberto", app)
        XCTAssertTrue(app.buttons["Importar esta carteira"].exists)
    }
}
