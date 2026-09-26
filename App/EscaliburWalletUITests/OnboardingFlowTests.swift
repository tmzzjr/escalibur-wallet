import XCTest

/// O caminho da primeira abertura ate a carteira criada e conferida, no app de
/// verdade: nenhuma etapa simulada, nenhum atalho de depuracao alem de comecar do
/// zero (`-reset`).
final class OnboardingFlowTests: XCTestCase {
    let pin = "482916"
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUp() {
        continueAfterFailure = false
    }

    func type(pin: String, in app: XCUIApplication) {
        for digit in pin {
            let key = app.buttons.matching(identifier: "tecla-\(digit)").firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 10), "tecla \(digit)")
            key.tap()
        }
    }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
    }

    func testCreateWalletFromScratch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset"]
        app.launch()

        XCTAssertTrue(app.buttons["Começar"].waitForExistence(timeout: 15))
        shot("01-boas-vindas", app)
        app.buttons["Começar"].tap()

        XCTAssertTrue(app.staticTexts["Escolha um PIN"].waitForExistence(timeout: 5))
        type(pin: pin, in: app)
        XCTAssertTrue(app.staticTexts["Repita o PIN"].waitForExistence(timeout: 5))
        shot("02-repita-pin", app)
        type(pin: pin, in: app)

        if app.buttons["Agora não"].waitForExistence(timeout: 8) {
            shot("03-face-id", app)
            app.buttons["Agora não"].tap()
        }

        XCTAssertTrue(app.buttons["Criar carteira nova"].waitForExistence(timeout: 10))
        shot("04-primeira-carteira", app)
        app.buttons["Criar carteira nova"].tap()

        XCTAssertTrue(app.buttons["Mostrar as palavras"].waitForExistence(timeout: 5))
        shot("05-antes-das-palavras", app)
        app.buttons["Mostrar as palavras"].tap()

        // Sem Face ID ligado, a folha do PIN confirma a gravacao.
        XCTAssertTrue(app.staticTexts["Confirme com o PIN"].waitForExistence(timeout: 10))
        type(pin: pin, in: app)

        var words: [Int: String] = [:]
        for group in 0..<4 {
            XCTAssertTrue(app.staticTexts["palavra-\(group * 3 + 1)"].waitForExistence(timeout: 15))
            for offset in 1...3 {
                let index = group * 3 + offset
                words[index] = app.staticTexts["palavra-\(index)"].label
            }
            if group == 0 { shot("06-placa-palavras", app) }
            if group < 3 { app.buttons["Próximas"].tap() } else { app.buttons["Já anotei as 12"].tap() }
        }
        XCTAssertEqual(words.count, 12)

        for _ in 0..<3 {
            let prompt = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Digite a palavra '")).firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            let position = Int(prompt.label.replacingOccurrences(of: "Digite a palavra ", with: "")) ?? 0
            let field = app.textFields.firstMatch
            field.tap()
            field.typeText(words[position] ?? "")
            app.buttons["Confirmar"].tap()
        }

        XCTAssertTrue(app.staticTexts["Carteira criada"].waitForExistence(timeout: 10))
        shot("07-carteira-criada", app)
        app.buttons["Ir para a carteira"].tap()

        XCTAssertTrue(app.staticTexts["Saldo total"].waitForExistence(timeout: 10))
        shot("08-carteira", app)
    }
}
