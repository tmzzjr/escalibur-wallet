import XCTest

/// A busca de Receber acha qualquer moeda da lista completa do CoinGecko: a moeda fora
/// da lista leva para a rede, o contrato e o Adicionar moeda; a de rede que a carteira
/// nao tem aparece sem endereco. So roda com ESCALIBUR_REDE=1 (baixa a lista).
final class ReceiveCatalogTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1", "so com rede")
    }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func openSearch(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let receive = app.buttons["Receber"].firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        sleep(4)
        receive.tap()
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(text)
        return search
    }

    func testAnyCoinLeadsToContractAndAdd() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        _ = openSearch(app, "bonk")
        // A lista completa pode esperar o limite por IP do CoinGecko passar.
        let bonk = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BONK, Bonk,'")).firstMatch
        XCTAssertTrue(bonk.waitForExistence(timeout: 200), "a Bonk da lista completa nao apareceu")
        shot("c1-busca-bonk", app)
        bonk.tap()
        let solana = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Solana'")).firstMatch
        XCTAssertTrue(solana.waitForExistence(timeout: 10))
        shot("c2-redes-bonk", app)
        solana.tap()
        XCTAssertTrue(app.staticTexts["Quem envia tem de usar exatamente este contrato:"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["pela rede Solana"].exists)
        shot("c3-endereco-bonk", app)
        app.swipeUp()
        let add = app.buttons["Adicionar BONK à carteira"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        shot("c4-adicionar", app)
        add.tap()
        sleep(8)
        shot("c5-conferir-moeda", app)
    }

    func testCoinWithoutNetworkHasNoAddress() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        _ = openSearch(app, "hedera")
        let note = app.staticTexts["Ainda não recebe aqui"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 200), "a Hedera deveria aparecer, sem endereco")
        shot("c6-sem-rede", app)
    }
}
