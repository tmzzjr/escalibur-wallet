import XCTest

/// O caminho da primeira abertura ate a carteira criada e conferida, no app de
/// verdade: nenhuma etapa simulada, nenhum atalho de depuracao alem de comecar do
/// zero (`-reset`).
final class OnboardingFlowTests: XCTestCase {
    let pin = "111111"
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

    /// PIN repetido diferente: os pontos apagam, a mensagem fica, e o voltar leva de
    /// "Repita" para "Escolha" e de la para a abertura.
    func testPINMismatchClearsDotsAndBackWorks() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["Começar"].waitForExistence(timeout: 15))
        app.buttons["Começar"].tap()
        XCTAssertTrue(app.staticTexts["Escolha um PIN"].waitForExistence(timeout: 5))
        type(pin: pin, in: app)
        XCTAssertTrue(app.staticTexts["Repita o PIN"].waitForExistence(timeout: 5))
        app.buttons["pin-voltar"].tap()
        XCTAssertTrue(app.staticTexts["Escolha um PIN"].waitForExistence(timeout: 5))
        type(pin: pin, in: app)
        XCTAssertTrue(app.staticTexts["Repita o PIN"].waitForExistence(timeout: 5))
        type(pin: "222222", in: app)
        XCTAssertTrue(app.staticTexts["Os dois não conferem. Escolha de novo."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Escolha um PIN"].exists)
        XCTAssertTrue(app.otherElements["0 de 6 dígitos"].exists || app.staticTexts["0 de 6 dígitos"].exists
                      || app.descendants(matching: .any)["0 de 6 dígitos"].exists, "os pontos nao apagaram")
        shot("02e-pin-diferente", app)
        // A mensagem continua enquanto o PIN novo e digitado.
        app.buttons.matching(identifier: "tecla-1").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Os dois não conferem. Escolha de novo."].exists)
        app.buttons["pin-voltar"].tap()
        XCTAssertTrue(app.buttons["Começar"].waitForExistence(timeout: 5))
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

        // O tour de quatro passos, logo depois do PIN.
        XCTAssertTrue(app.staticTexts["Só você é digno"].waitForExistence(timeout: 10))
        app.buttons["tour-continuar"].tap()
        XCTAssertTrue(app.staticTexts["A chave de tudo é sua"].waitForExistence(timeout: 5))
        sleep(4)
        shot("02b-tour-chave", app)
        app.buttons["tour-continuar"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'redes, um app só'")).firstMatch.waitForExistence(timeout: 5))
        sleep(2)
        shot("02c-tour-redes", app)
        app.buttons["tour-continuar"].tap()
        XCTAssertTrue(app.staticTexts["Só você assina"].waitForExistence(timeout: 5))
        sleep(6)
        shot("02d-tour-assinatura", app)
        app.buttons["tour-continuar"].tap()

        if app.buttons["Agora não"].waitForExistence(timeout: 8) {
            shot("03-face-id", app)
            app.buttons["Agora não"].tap()
        }

        XCTAssertTrue(app.buttons["Criar carteira nova"].waitForExistence(timeout: 10))
        shot("04-primeira-carteira", app)
        app.buttons["Criar carteira nova"].tap()

        XCTAssertTrue(app.buttons["Continuar"].waitForExistence(timeout: 5))
        shot("05-antes-das-palavras", app)
        app.buttons["Continuar"].tap()

        // Seguranca e responsabilidade: so segue com a caixa marcada.
        XCTAssertTrue(app.buttons["aceite-responsabilidade"].waitForExistence(timeout: 5))
        shot("05b-seguranca", app)
        app.buttons["aceite-responsabilidade"].tap()
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

        // Reabrir: o PIN errado e recusado, o certo destrava. No simulador o chaveiro
        // nao aplica a senha de aplicativo, entao isto exercita a camada interna.
        app.terminate()
        app.launchArguments = []
        app.launch()
        type(pin: "730584", in: app)
        XCTAssertTrue(app.staticTexts["PIN incorreto."].waitForExistence(timeout: 15))
        shot("09-pin-errado", app)
        type(pin: pin, in: app)
        XCTAssertTrue(app.staticTexts["Saldo total"].waitForExistence(timeout: 15))
    }
}
