import XCTest

/// Ordem limite: os prazos que a CoW aceita, o teclado do preco-alvo e a folha de ordens
/// abertas, lida da rede.
final class LimitOrderTests: XCTestCase {
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

    func testValiditiesKeyboardAndOpenOrders() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "trocar"]
        app.launch()
        let limit = app.buttons["Limite"]
        XCTAssertTrue(limit.waitForExistence(timeout: 30))
        limit.tap()

        // O preco-alvo: "Pronto" fecha o teclado deste campo tambem.
        let price = app.textFields.element(boundBy: 1)
        XCTAssertTrue(price.waitForExistence(timeout: 10))
        price.tap()
        price.typeText("3000")
        let done = app.buttons["Pronto"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let until = Date().addingTimeInterval(5)
        while Date() < until, app.keyboards.count > 0 { usleep(200_000) }
        XCTAssertEqual(app.keyboards.count, 0, "o teclado do preco-alvo nao fechou")

        // Na CoW: so os prazos que o protocolo aceita, sem "Ate cancelar".
        app.swipeUp()
        XCTAssertTrue(app.buttons["30 dias"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["7 dias"].exists && app.buttons["1 dia"].exists)
        XCTAssertFalse(app.buttons["Até cancelar"].exists)
        shot("l1-prazos", app)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Ordens abertas"].waitForExistence(timeout: 5))
        let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nenhuma ordem aberta'")).firstMatch
        let retry = app.buttons["Tentar de novo"]
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Vende'")).firstMatch
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !(empty.exists || retry.exists || row.exists) { usleep(500_000) }
        shot("l2-ordens-abertas", app)
        XCTAssertTrue(empty.exists || retry.exists || row.exists, "a folha nao terminou de ler")
    }

    /// A lista de redes da troca mostra o logo de cada uma, e escolher troca a rede.
    func testNetworkPickerLists() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "trocar"]
        app.launch()
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rede:'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        let solana = app.buttons["Solana"].firstMatch
        XCTAssertTrue(solana.waitForExistence(timeout: 5))
        shot("l3-redes", app)
        solana.tap()
        XCTAssertTrue(app.buttons["Rede: Solana"].waitForExistence(timeout: 5))
    }

    /// Editar uma ordem aberta: a ordem limite abre com os valores dela e a faixa da edicao.
    func testEditOpenOrderPrefillsTheForm() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "editar-ordem"]
        app.launch()
        let banner = app.descendants(matching: .any)["editando-ordem"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "a faixa da edicao nao apareceu")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Editando a ordem de 0,5'")).firstMatch.exists)
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == '0,5' OR value == '0.5'")).firstMatch.exists, "o valor nao veio da ordem")
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == '3000'")).firstMatch.exists, "o preco nao veio da ordem")
        XCTAssertTrue(app.buttons["7 dias"].isSelected, "o prazo nao e o mais perto do que restava")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "l9-editar"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["desistir-edicao"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 3), "desistir nao tirou a faixa")
    }
}

