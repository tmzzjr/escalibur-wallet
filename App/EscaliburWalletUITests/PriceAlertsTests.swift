import XCTest

/// Alertas de preco: ligar (com a permissao do iOS), escolher uma moeda, e o sino na
/// pagina da moeda aberta pelo mesmo caminho do toque numa notificacao.
final class PriceAlertsTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    /// A permissao de notificar aparece so na primeira vez neste simulador.
    func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Permitir", "Allow"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
    }

    func testEnableAndPickCoin() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "ajustes"]
        app.launch()
        let row = app.buttons["ajustes-alertas"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Desligados"].exists, "comeca desligado")
        row.tap()

        let toggle = app.switches["alertas-ligar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        shot("a1-desligado", app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        allowNotificationsIfAsked()
        XCTAssertTrue(app.staticTexts["Quando avisar"].waitForExistence(timeout: 10), "ligado, as regras aparecem")
        XCTAssertTrue(app.staticTexts["Moedas"].exists, "a lista comeca vazia")
        shot("a2-ligado", app)

        app.buttons["alertas-adicionar"].tap()
        let bitcoin = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bitcoin'")).firstMatch
        XCTAssertTrue(bitcoin.waitForExistence(timeout: 20), "a lista do Mercado na folha")
        bitcoin.tap()
        shot("a3-escolher", app)
        app.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Tirar Bitcoin dos alertas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Moedas, 1 moeda"].exists)
        shot("a4-lista", app)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["1 moeda"].waitForExistence(timeout: 5), "Ajustes mostra quantas moedas")
    }

    func testBellOnCoinPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "moeda"]
        app.launch()
        let bell = app.buttons["Avisar sobre o preço desta moeda"]
        XCTAssertTrue(bell.waitForExistence(timeout: 30), "a pagina do bitcoin abre pelo caminho do alerta, com o sino")
        bell.tap()
        allowNotificationsIfAsked()
        XCTAssertTrue(app.buttons["Desligar alertas desta moeda"].waitForExistence(timeout: 10))
        shot("a5-sino", app)
    }
}
