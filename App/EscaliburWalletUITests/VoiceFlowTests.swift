import XCTest

/// Confirmacao por voz: gravar a frase (falar, corrigir digitando, falar de novo),
/// testar a frase, e a folha que pede a frase antes de uma operacao.
///
/// O simulador nao tem quem fale: `-voz-audio` toca no lugar do microfone os arquivos
/// de Fixtures (gerados com `say -v Luciana`), um por escuta, e o reconhecedor do
/// aparelho ouve de verdade. `testRealMicrophone` usa o microfone do Mac, para
/// conferir que abrir o microfone e permitir o reconhecimento nao derrubam o app.
final class VoiceFlowTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    let phrase = "minha casa tem janela amarela"
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    var right: String { fixtures.appendingPathComponent("voz-frase.m4a").path }
    var wrong: String { fixtures.appendingPathComponent("voz-outra.m4a").path }

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
            XCTAssertTrue(key.waitForExistence(timeout: 30), "tecla \(digit)")
            key.tap()
        }
    }

    /// Os pedidos de microfone e de reconhecimento de fala, quando aparecem.
    func allowPermissions(wait: TimeInterval = 3) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: wait) else { return }
            for label in ["OK", "Allow", "Permitir"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                break
            }
        }
    }

    func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Simulador sem modelo de fala no aparelho (visto no iOS 26 do iPhone 17; o 17.5 do
    /// SE tem): o app mostra que nao reconhece sem internet, e e isso que deve fazer. O
    /// resto do teste so tem sentido com o modelo, entao ele e pulado com o motivo.
    func skipWithoutOnDeviceSpeech(_ app: XCUIApplication) throws {
        let unavailable = NSPredicate(format: "label CONTAINS 'não reconhece fala sem internet' OR label CONTAINS 'sem internet não respondeu'")
        if app.staticTexts.matching(unavailable).firstMatch.waitForExistence(timeout: 6) {
            throw XCTSkip("Este simulador nao tem reconhecimento de fala no aparelho; o app avisou, como deve.")
        }
    }

    func testEnrollPhrase() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "voz", "-voz-audio", [right, wrong, right, right].joined(separator: ",")]
        app.launch()
        type(pin: "111111", in: app)

        let start = app.buttons["Começar a falar"]
        if !start.waitForExistence(timeout: 30) { try skipWithoutOnDeviceSpeech(app) }
        XCTAssertTrue(start.exists)
        start.tap()
        allowPermissions(wait: 1)
        try skipWithoutOnDeviceSpeech(app)
        // A transcricao ao vivo e conferida em testChallenge: aqui a arvore de
        // acessibilidade (a carteira inteira atras) demora mais que a frase, e a
        // foto sai antes de procurar qualquer coisa.
        sleep(1)
        shot("v1-gravar-ouvindo", app)

        // Para sozinho depois da frase e leva ao texto, que da para corrigir.
        XCTAssertTrue(app.staticTexts["Confira o que eu ouvi"].waitForExistence(timeout: 20))
        let field = element("voz-frase-campo", app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual((field.value as? String)?.lowercased(), phrase, "o reconhecedor deveria ouvir a frase do arquivo")
        // Toca no fim do texto, para o cursor ficar depois da ultima letra.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        field.typeText("minha casa")
        XCTAssertTrue(app.staticTexts["Use 3 palavras ou mais."].waitForExistence(timeout: 5))
        field.typeText(" tem janela amarela")
        shot("v2-gravar-corrigir", app)
        // O retorno do teclado fecha a edicao, sem quebrar a linha.
        field.typeText("\n")
        XCTAssertEqual(field.value as? String, phrase)
        app.buttons["Continuar"].tap()

        // A segunda fala errada nao grava; a certa grava.
        let speak = app.buttons["Falar a frase"]
        XCTAssertTrue(speak.waitForExistence(timeout: 5))
        speak.tap()
        let message = element("voz-mensagem", app)
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        XCTAssertTrue(message.label.hasPrefix("Não conferiu"), message.label)
        speak.tap()
        XCTAssertTrue(element("voz-gravada", app).waitForExistence(timeout: 20), "a frase deveria ficar gravada")

        // Testar a frase, sem contar tentativa.
        app.buttons["Testar a minha frase"].tap()
        let result = element("voz-teste", app)
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertTrue(result.label.hasPrefix("Conferiu"), result.label)
        shot("v6-gravada-e-testada", app)
    }

    func testChallenge() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "voz-conferir", "-voz-frase", phrase, "-voz-audio", "\(wrong),\(right)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Diga a sua frase de voz"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textFields.count == 0 && app.textViews.count == 0, "na conferencia nao pode ter campo de texto")

        let speak = app.buttons["Falar agora"]
        speak.tap()
        allowPermissions()
        try skipWithoutOnDeviceSpeech(app)
        XCTAssertTrue(app.staticTexts["voz-transcricao"].waitForExistence(timeout: 10), "a transcricao deveria aparecer ao vivo")
        shot("v3-conferir-ouvindo", app)
        let message = element("voz-mensagem", app)
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        XCTAssertEqual(message.label, "Não conferiu. Você tem mais 2 tentativas.")
        shot("v4-conferir-errou", app)

        speak.tap()
        let gone = NSPredicate(format: "exists == false")
        let closed = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: app.staticTexts["Diga a sua frase de voz"])], timeout: 25)
        XCTAssertEqual(closed, .completed, "a folha deveria fechar depois de conferir")
    }

    /// Microfone de verdade (o do Mac): abrir, ouvir e parar sem derrubar o app.
    func testRealMicrophone() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "voz"]
        app.launch()
        type(pin: "111111", in: app)
        let start = app.buttons["Começar a falar"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.tap()
        allowPermissions()
        XCTAssertTrue(app.staticTexts["Ouvindo"].waitForExistence(timeout: 10) || element("voz-mensagem", app).exists,
                      "deveria ouvir ou dizer por que nao")
        shot("v5-microfone-do-mac", app)
        let outcome = NSPredicate { _, _ in
            app.staticTexts["Confira o que eu ouvi"].exists || app.descendants(matching: .any)["voz-mensagem"].exists
        }
        let waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: outcome, object: nil)], timeout: 20)
        XCTAssertEqual(waited, .completed, "a escuta deveria terminar com o texto ou com um aviso")
        XCTAssertEqual(app.state, .runningForeground, "o app nao pode fechar")
    }
}
