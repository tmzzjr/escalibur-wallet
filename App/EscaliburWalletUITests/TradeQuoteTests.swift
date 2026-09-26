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

    /// Ate a revisao do plano, sem assinar: o plano da Solana tem de conferir com o
    /// pedido (ativo, valor, minimo e dono) para a revisao aparecer (auditoria 2, M1).
    func testSolanaPlanReview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "trocar"]
        app.launch()
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rede:'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        let solana = app.buttons["Solana"].firstMatch
        XCTAssertTrue(solana.waitForExistence(timeout: 5))
        solana.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("0,01")
        let next = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nova cotação'")).firstMatch
        if !next.waitForExistence(timeout: 40) {
            app.buttons["Pronto"].tap()
            shot("t3-falha-cotacao", app)
            XCTFail("a cotacao nao chegou: " + app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | "))
            return
        }
        app.buttons["Pronto"].tap()
        let review = app.buttons["Revisar troca"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Trocar'")).firstMatch
        let refused = app.staticTexts["O plano montado não confere com a troca pedida. Nada foi assinado."]
        let arrived = title.waitForExistence(timeout: 60)
        shot("t3-revisao-solana", app)
        XCTAssertFalse(refused.exists, "o plano nao conferiu com o pedido")
        XCTAssertTrue(arrived, "a revisao nao chegou")
    }
}
