import XCTest

/// Tudo o que a carteira tem: "Outros tokens", "Mostrar suspeitos" e a moeda custom
/// aparecendo na Carteira, em Receber e em Enviar. A carteira de teste (frase publica
/// "abandon ... about") recebe tokens de golpe de verdade na Base e na Tron, e tem o
/// "OpenAI" (sem cara de golpe) na Base: e ele que vira moeda custom aqui. Le a rede de
/// verdade, como os outros testes da carteira de teste.
final class CustomTokenTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }
    static let openAI = "0xd77cD3531c306204069684F48Af23F1213FE0165"

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = reset ? ["-reset", "-demo"] : ["-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["Receber"].firstMatch.waitForExistence(timeout: 30))
        return app
    }

    /// Rola a Carteira ate o elemento aparecer.
    func scroll(to element: XCUIElement, in app: XCUIApplication, tries: Int = 10) {
        for _ in 0..<tries where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    func testOtherTokensAndSuspicious() {
        let app = launch()
        let section = app.staticTexts["Outros tokens"]
        let suspicious = app.buttons["mostrar-suspeitos"]
        // A leitura das redes demora: espera o botao de suspeitos existir.
        let deadline = Date().addingTimeInterval(60)
        while !suspicious.exists && Date() < deadline { app.swipeUp(); sleep(1) }
        scroll(to: suspicious, in: app)
        XCTAssertTrue(suspicious.waitForExistence(timeout: 10))
        if section.exists { shot("c1-outros-tokens", app) }
        // Suspeitos ficam escondidos ate o toque.
        XCTAssertFalse(app.staticTexts["Suspeito"].exists)
        suspicious.tap()
        let badge = app.staticTexts["Suspeito"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        app.swipeUp()
        shot("c2-suspeitos", app)
        badge.tap()
        XCTAssertTrue(app.staticTexts["Por que está em suspeitos"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Qualquer pessoa cria um token'")).firstMatch.exists)
    }

    func testAddCustomCoinAppearsEverywhere() {
        let app = launch()
        let manage = app.buttons["gerenciar-ativos"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        manage.tap()
        let add = app.buttons["adicionar-moeda"]
        scroll(to: add, in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let base = app.buttons["Base"].firstMatch
        XCTAssertTrue(base.waitForExistence(timeout: 10))
        base.tap()
        let field = app.descendants(matching: .any)["campo-endereco"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot("m1-adicionar-moeda", app)
        field.tap()
        field.typeText(Self.openAI)
        app.buttons["ler-na-rede"].tap()
        let confirm = app.buttons["adicionar-a-carteira"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Não verificado pela Escalibur"].exists)
        shot("m2-previa", app)
        scroll(to: confirm, in: app)
        confirm.tap()
        // De volta a Gerenciar ativos, com a moeda na lista de moedas custom.
        XCTAssertTrue(app.buttons["Remover OpenAI"].waitForExistence(timeout: 10))
        shot("g1-gerenciar", app)

        // Carteira: a moeda aparece com o selo de custom.
        app.navigationBars.buttons.firstMatch.tap()
        // A linha da Carteira e um botao; o selo vai no rotulo dele.
        let custom = app.buttons.matching(NSPredicate(format: "label CONTAINS 'OpenAI' AND label CONTAINS 'Custom'")).firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !custom.exists && Date() < deadline { sleep(1) }
        scroll(to: custom, in: app)
        XCTAssertTrue(custom.waitForExistence(timeout: 10))

        // Receber: a moeda custom e uma linha propria, marcada. A moeda ficou salva:
        // reabre o app sem apagar.
        app.terminate()
        let again = launch(reset: false)
        receiveAndSend(again)
    }

    func receiveAndSend(_ app: XCUIApplication) {
        app.buttons["Receber"].firstMatch.tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("OpenAI")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Custom'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        shot("r5-receber-custom", app)
        row.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Quem envia tem de usar exatamente'")).firstMatch.waitForExistence(timeout: 10))
        app.terminate()

        // Enviar: aparece no seletor, com o selo, e abre o envio.
        let sendApp = launch(reset: false)
        sendApp.buttons["Enviar"].firstMatch.tap()
        sendFlow(sendApp)
    }

    func sendFlow(_ app: XCUIApplication) {
        let send = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Custom'")).firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 30))
        shot("e1-enviar-custom", app)
        send.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Enviar'")).firstMatch.waitForExistence(timeout: 10))
    }
}
