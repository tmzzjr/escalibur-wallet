import XCTest

/// A aba Trocar cota de verdade, na carteira publica de teste (sem saldo): nada e
/// assinado, porque sem saldo o botao de revisar nao liga. So roda com
/// ESCALIBUR_REDE=1, porque fala com os provedores reais.
final class TradeQuoteTests: XCTestCase {
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

    func testBaseQuote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "trocar"]
        app.launch()

        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rede:'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        shot("t0-trocar", app)
        menu.tap()
        let base = app.buttons["Base"].firstMatch
        XCTAssertTrue(base.waitForExistence(timeout: 5))
        base.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("0,01")
        shot("t0b-carregando", app)
        let next = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nova cotação'")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 40), "a cotacao nao chegou")
        shot("t1-cotacao-base", app)
        app.buttons["Pronto"].tap()
        shot("t2-cotacao-base-detalhe", app)
    }

    /// XRP por RLUSD no livro do XRP Ledger: a cotacao vem do livro, e o plano, sem
    /// assinar, nunca pode cair na recusa de "nao confere com o pedido". A carteira
    /// publica de teste tem a conta do XRP Ledger tomada (chave mestra desativada por
    /// quem pos outra chave), e a recusa propria disso tambem vale como chegada.
    func testXRPLPlanReview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "trocar"]
        app.launch()
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rede:'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        let xrpl = app.buttons["XRP Ledger"].firstMatch
        XCTAssertTrue(xrpl.waitForExistence(timeout: 5), "o XRP Ledger nao apareceu nas redes de troca")
        xrpl.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("1")
        let next = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nova cotação'")).firstMatch
        if !next.waitForExistence(timeout: 40) {
            app.buttons["Pronto"].tap()
            shot("t4-falha-cotacao-xrpl", app)
            XCTFail("a cotacao nao chegou: " + app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | "))
            return
        }
        app.buttons["Pronto"].tap()
        shot("t4-cotacao-xrpl", app)
        let review = app.buttons["Revisar troca"]
        if !review.waitForExistence(timeout: 10) { shot("t4-falha-revisar-xrpl", app) }
        XCTAssertTrue(review.exists)
        review.tap()
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Trocar ' AND label CONTAINS ' por '")).firstMatch
        let hijacked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Esta conta desativou a chave mestra'")).firstMatch
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !(title.exists || hijacked.exists) { usleep(500_000) }
        shot("t5-revisao-xrpl", app)
        XCTAssertFalse(app.staticTexts["O plano montado não confere com a troca pedida. Nada foi assinado."].exists)
        XCTAssertTrue(title.exists || hijacked.exists, "nem a revisao nem a recusa da conta tomada")
    }
}
