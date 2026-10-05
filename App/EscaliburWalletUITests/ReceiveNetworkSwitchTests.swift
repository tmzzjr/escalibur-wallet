import XCTest

/// Tela do endereco: o seletor troca a rede sem voltar, e o texto acompanha.
final class ReceiveNetworkSwitchTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testSwitchNetworkOnAddressScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        let receive = app.buttons["Receber"].firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        sleep(6)
        receive.tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("USDC")
        let usdc = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'USDC'")).firstMatch
        XCTAssertTrue(usdc.waitForExistence(timeout: 10))
        usdc.tap()
        let ethereum = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ethereum'")).firstMatch
        XCTAssertTrue(ethereum.waitForExistence(timeout: 10))
        ethereum.tap()
        let selector = app.buttons["receber-rede"]
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["pela rede Ethereum"].exists)
        selector.tap()
        let base = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Base'")).firstMatch
        XCTAssertTrue(base.waitForExistence(timeout: 5))
        shot("r6-seletor-rede", app)
        base.tap()
        XCTAssertTrue(app.staticTexts["pela rede Base"].waitForExistence(timeout: 5), "a tela deveria mostrar a rede escolhida")
        shot("r7-rede-trocada", app)
    }
}
