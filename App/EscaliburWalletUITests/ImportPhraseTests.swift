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
    }
}
