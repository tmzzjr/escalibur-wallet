import XCTest

/// Enderecos salvos: vazio, salvar com a sugestao de rede, cartao na lista, apagar.
final class SavedAddressesTests: XCTestCase {
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

    func testSaveAndRemove() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "ajustes"]
        app.launch()
        let row = app.staticTexts["Endereços salvos"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        XCTAssertTrue(app.staticTexts["Nenhum endereço salvo"].waitForExistence(timeout: 5))
        shot("s1-vazio", app)

        app.buttons["Salvar um endereço"].tap()
        let fields = app.textFields
        XCTAssertTrue(fields.element(boundBy: 0).waitForExistence(timeout: 5))
        fields.element(boundBy: 0).tap()
        fields.element(boundBy: 0).typeText("Corretora")
        fields.element(boundBy: 1).tap()
        // Endereco Solana com a rede ainda em Bitcoin: o app sugere a Solana.
        fields.element(boundBy: 1).typeText("7cVfgArCheMR6Cs4t6vz5rfnqd56vZq4ndaBrY5xkxXy")
        let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Parece um endereço da Solana'")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "deveria sugerir a Solana")
        shot("s2-sugestao", app)
        suggestion.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Endereço válido na Solana'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Salvar"].tap()
        type(pin: "111111", in: app)
        XCTAssertTrue(app.staticTexts["Corretora"].waitForExistence(timeout: 15), "o endereco salvo deveria aparecer na lista")
        shot("s3-lista", app)

        app.buttons["Opções de Corretora"].tap()
        app.buttons["Apagar"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Apagar"].tap()
        XCTAssertTrue(app.staticTexts["Nenhum endereço salvo"].waitForExistence(timeout: 5))
    }
}
