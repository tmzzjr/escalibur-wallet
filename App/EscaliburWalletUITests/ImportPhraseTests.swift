import XCTest

/// Importar: a palavra e digitada na propria posicao, com as sugestoes da lista acima
/// do teclado, e o foco anda para a posicao seguinte sem tocar em nada.
final class ImportPhraseTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func focusedSlot(_ app: XCUIApplication, _ number: Int) -> Bool {
        let field = app.otherElements["palavra-\(number)"].textFields.firstMatch
        return field.waitForExistence(timeout: 3) && (field.value(forKey: "hasKeyboardFocus") as? Bool ?? false)
    }

    func testTypeInSlotWithSuggestions() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "adicionar"]
        app.launch()
        let option = app.staticTexts["Importar com a senha da carteira"]
        XCTAssertTrue(option.waitForExistence(timeout: 30))
        option.tap()

        // Antes de digitar, o aceite de responsabilidade. Com a carteira ainda
        // carregando atras, o primeiro toque as vezes chega antes da folha assentar.
        let accept = app.buttons["aceite-responsabilidade"]
        if !accept.waitForExistence(timeout: 8) { option.tap() }
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        accept.tap()
        app.buttons["Digitar as palavras"].tap()

        let first = app.otherElements["palavra-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        XCTAssertTrue(focusedSlot(app, 1), "tocar na posicao 1 nao abriu o teclado nela")
        app.typeText("aban")
        let suggestion = app.buttons["abandon"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "a sugestao nao apareceu acima do teclado")
        XCTAssertTrue(suggestion.isHittable)
        shot("i1-sugestao", app)
        suggestion.tap()
        XCTAssertTrue(focusedSlot(app, 2), "o foco nao passou para a posicao 2")

        // Espaco fecha a palavra e passa adiante, como no papel.
        for _ in 2...11 { app.typeText("abandon ") }
        XCTAssertTrue(focusedSlot(app, 12))
        app.typeText("about")
        app.typeText("\n")
        let importButton = app.buttons["Importar"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertTrue(importButton.isEnabled, "com as 12 palavras o Importar deveria liberar")
        shot("i2-preenchida", app)

        // Segurar uma posicao preenchida mostra a palavra e nao abre a edicao.
        app.otherElements["palavra-3"].press(forDuration: 0.8)
        XCTAssertFalse(focusedSlot(app, 3), "segurar nao deveria abrir a posicao para digitar")

        // Limpar, com o alerta do iPhone, esvazia as doze posicoes.
        app.buttons["limpar-palavras"].tap()
        let alert = app.alerts["Apagar as palavras digitadas?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Apagar"].tap()
        XCTAssertFalse(importButton.isEnabled, "depois de limpar, Importar volta a ficar desligado")
        XCTAssertFalse(app.buttons["limpar-palavras"].exists)
    }

    func type(pin: String, in app: XCUIApplication) {
        for digit in pin {
            let key = app.buttons.matching(identifier: "tecla-\(digit)").firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 10), "tecla \(digit)")
            key.tap()
        }
    }

    /// O caminho inteiro: digitar, conferir os enderecos, guardar com o PIN e cair na
    /// carteira nova. A carteira da demo aqui e sorteada (-vazia), para a frase publica
    /// de teste nao ser "ja importada".
    func testImportAllTheWayToSaved() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-vazia", "-tela", "adicionar"]
        app.launch()
        let option = app.staticTexts["Importar com a senha da carteira"]
        XCTAssertTrue(option.waitForExistence(timeout: 30))
        option.tap()
        let accept = app.buttons["aceite-responsabilidade"]
        if !accept.waitForExistence(timeout: 8) { option.tap() }
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        accept.tap()
        app.buttons["Digitar as palavras"].tap()
        let first = app.otherElements["palavra-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        for _ in 1...11 { app.typeText("abandon ") }
        app.typeText("about")
        app.typeText("\n")
        app.buttons["Importar"].tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Não foi possível importar'")).firstMatch
        let review = app.staticTexts["Confira antes de guardar"]
        XCTAssertTrue(review.waitForExistence(timeout: 15), failure.exists ? failure.label : "a conferencia nao apareceu")
        shot("i3-conferir", app)
        app.buttons["Guardar esta carteira"].tap()
        type(pin: "111111", in: app)
        let saved = app.staticTexts["Carteira 2"]
        XCTAssertTrue(saved.waitForExistence(timeout: 30), failure.exists ? failure.label : "a carteira importada nao virou a carteira em uso")
        shot("i4-guardada", app)
    }
}
