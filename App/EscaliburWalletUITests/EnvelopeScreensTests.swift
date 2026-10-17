import XCTest

/// As telas do envelope desenhadas de novo em 16/10/2026: o "Como funciona" (pixels caindo
/// no envelope, a senha errada que nao abre, a senha certa), o comeco do lacre e o aviso de
/// senha fraca com o botao de segurar.
final class EnvelopeScreensTests: XCTestCase {
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

    func testHowItWorksPages() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "envelope-como", "0"]
        app.launch()
        XCTAssertTrue(app.staticTexts["As palavras viram um arquivo cifrado"].waitForExistence(timeout: 30))
        usleep(1_400_000)
        shot("v0-pixels-voando", app)
        sleep(3)
        shot("v0-lacrado", app)
        app.buttons["Próximo"].tap()
        XCTAssertTrue(app.staticTexts["Sem a senha, o arquivo é ruído"].waitForExistence(timeout: 5))
        usleep(2_150_000)
        shot("v1-senha-errada", app)
        app.buttons["Próximo"].tap()
        XCTAssertTrue(app.staticTexts["Só a sua senha abre"].waitForExistence(timeout: 5))
        sleep(4)
        shot("v2-senha-certa", app)
    }

    func testSealIntroAndWeakPassword() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "lacrar"]
        app.launch()
        let start = app.buttons["Continuar"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        sleep(3)
        shot("v3-guardar", app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'decifrador'")).firstMatch.exists)
        start.tap()
        app.passDeviceCheck()
        for digit in "111111" {
            let key = app.buttons.matching(identifier: "tecla-\(digit)").firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 10))
            key.tap()
        }
        let mine = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Criar a minha'")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 15))
        mine.tap()
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d",
            XCUIElement.ElementType.secureTextField.rawValue, XCUIElement.ElementType.textField.rawValue
        )).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("12345")
        sleep(1)
        shot("v4-cursor", app)
        app.buttons["Continuar"].tap()
        let sheet = app.otherElements["senha-fraca"]
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Esta senha cai em'")).firstMatch.waitForExistence(timeout: 10) || sheet.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sem você saber'")).firstMatch.exists)
        sleep(1)
        shot("v5-senha-fraca", app)
        // Segurando, o vermelho enche com a ponta reta.
        let hold = app.staticTexts["Segure para usar mesmo assim"]
        if hold.exists {
            hold.press(forDuration: 1.0)
        }
    }
}
