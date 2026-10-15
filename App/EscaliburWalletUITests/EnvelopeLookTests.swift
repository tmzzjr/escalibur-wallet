import XCTest

/// So para gravar em video (ESCALIBUR_VIDEO) o cartao cifrado do envelope: o "Como
/// funciona" do ruido e da senha que revela, a tela de abrir e a abertura de um envelope.
final class EnvelopeLookTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ESCALIBUR_VIDEO"] == nil, "so com ESCALIBUR_VIDEO")
    }

    func testHowItWorksThenOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "envelope-como", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Sem a senha, o arquivo é ruído"].waitForExistence(timeout: 30))
        sleep(4)
        app.buttons["Próximo"].tap()
        XCTAssertTrue(app.staticTexts["Só a sua senha abre"].waitForExistence(timeout: 5))
        sleep(10)
        app.buttons["Entendi"].tap()
        XCTAssertTrue(app.buttons["Escolher arquivo"].waitForExistence(timeout: 10))
        sleep(9)

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kit/Tests/EscaliburCoreTests/Fixtures/referencia-python.esclbr")
        app.terminate()
        app.launchArguments = ["-reset", "-demo", "-tela", "abrir", "-envelope", fixture.path]
        app.launch()
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d",
            XCUIElement.ElementType.secureTextField.rawValue, XCUIElement.ElementType.textField.rawValue
        )).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        sleep(2)
        field.tap()
        field.typeText("senha de referencia em python")
        app.buttons["Abrir envelope"].tap()
        XCTAssertTrue(app.staticTexts["Lacrado em Python"].waitForExistence(timeout: 60))
        sleep(6)
    }
}
