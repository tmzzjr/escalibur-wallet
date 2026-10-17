import XCTest

/// As telas ajustadas em 16/10/2026 a pedido do dono: o icone preto no tour, o cofre da
/// carteira com passphrase, a tela do teclado proprio, a chapa que vira, o envelope do
/// "Guardar" e a confirmacao antes de ver a senha, que nao desmarca mais.
final class TodayLookTests: XCTestCase {
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

    func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", screen]
        app.launch()
        return app
    }

    func testTourBadge() {
        let app = launch("promessa")
        XCTAssertTrue(app.staticTexts["Uma chave para todas as suas moedas"].waitForExistence(timeout: 30))
        sleep(3)
        shot("t1-tour", app)
    }

    func testSettingsScreens() {
        let app = launch("ajustes")
        let security = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Segurança'")).firstMatch
        XCTAssertTrue(security.waitForExistence(timeout: 30))
        security.tap()
        app.tapWhenEnabled(app.buttons["ajustes-teclado"])
        XCTAssertTrue(app.switches["teclado-proprio"].waitForExistence(timeout: 10))
        sleep(3)
        shot("t2-teclado", app)
        app.navigationBars.buttons.firstMatch.tap()
        let passphrase = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Carteira com passphrase'")).firstMatch
        app.swipeUp()
        XCTAssertTrue(passphrase.waitForExistence(timeout: 10))
        passphrase.tap()
        sleep(2)
        shot("t3-passphrase", app)
    }

    func testPlateFlipsBack() {
        let app = launch("palavras")
        XCTAssertTrue(app.buttons["ver-todas-palavras"].waitForExistence(timeout: 30))
        app.buttons["ver-todas-palavras"].tap()
        XCTAssertTrue(app.buttons["copiar-palavras"].waitForExistence(timeout: 5))
        // Sair e voltar esconde as palavras: a chapa vira para o verso.
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()
        let again = app.buttons["Mostrar de novo"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        sleep(1)
        shot("t4-verso", app)
        again.tap()
        usleep(250_000)
        shot("t5-virando", app)
        sleep(1)
        shot("t6-frente", app)
        XCTAssertTrue(app.staticTexts["palavra-1"].exists)
    }

    func testSealIntro() {
        let app = launch("lacrar")
        XCTAssertTrue(app.buttons["Continuar"].waitForExistence(timeout: 30))
        usleep(1_500_000)
        shot("t7-guardar-aberto", app)
        sleep(2)
        shot("t8-guardar-pixel", app)
    }

    /// Tocar rapido depois do PIN nao cai mais na lista do "estou ciente".
    func testRevealDoesNotUntickAfterPIN() {
        let app = launch("revelar")
        XCTAssertTrue(app.staticTexts["Ninguém da Escalibur vai pedir suas palavras"].waitForExistence(timeout: 20))
        let rows = app.buttons.matching(NSPredicate(format: "label IN %@", ["Quem tem as palavras tem o saldo", "A Escalibur nunca pede as palavras", "Devo ver as palavras sozinho, longe de câmeras"]))
        for index in 0..<rows.count { rows.element(boundBy: index).tap() }
        app.tapWhenEnabled(app.buttons["Ver as palavras"])
        for digit in "111111" {
            let key = app.buttons.matching(identifier: "tecla-\(digit)").firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 10))
            key.tap()
        }
        // Um toque a mais, rapido, no lugar da lista.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let words = app.buttons["ver-todas-palavras"]
        XCTAssertTrue(words.waitForExistence(timeout: 20), "as palavras nao abriram depois do PIN")
    }
}
