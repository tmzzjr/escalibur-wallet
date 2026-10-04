import XCTest

/// Pagina da moeda no Mercado: alem do grafico, faixa de 24 horas, maxima historica,
/// oferta e "Sobre", carregados quando a pagina abre.
final class MarketCoinFactsTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testCoinFacts() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "mercado"]
        app.launch()
        let bitcoin = app.staticTexts["BTC"].firstMatch
        XCTAssertTrue(bitcoin.waitForExistence(timeout: 30), "o mercado deveria carregar")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Dados de mercado: '")).firstMatch.exists
            || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Dados de mercado: '")).firstMatch.waitForExistence(timeout: 5),
            "a lista deveria dizer a fonte e a hora")
        bitcoin.tap()
        XCTAssertTrue(app.staticTexts["Sobre o mercado"].waitForExistence(timeout: 10))
        let range = app.staticTexts["Faixa de 24 horas"]
        XCTAssertTrue(range.waitForExistence(timeout: 20), "a faixa de 24 horas deveria aparecer")
        // Meia tela para cima: o grafico sai e os numeros do mercado ficam no alto.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(
            forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)),
            withVelocity: .slow, thenHoldForDuration: 0.5
        )
        sleep(2)
        shot("f1-moeda-mercado", app)
        XCTAssertTrue(app.staticTexts["Máxima histórica"].exists)
        XCTAssertTrue(app.staticTexts["Oferta"].exists)
        XCTAssertTrue(app.staticTexts["Oferta máxima"].exists || app.staticTexts["Em circulação"].exists)
        app.swipeUp()
        sleep(1)
        XCTAssertTrue(app.staticTexts["Sobre o projeto"].waitForExistence(timeout: 5))
        shot("f2-moeda-sobre", app)
    }
}
