import XCTest

/// Detalhe de moeda: favorito fixa no topo do Mercado, e trocar abre a aba com a moeda.
final class CoinDetailTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testFavoriteAndTrade() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "mercado"]
        app.launch()
        let solana = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'SOL'")).firstMatch
        XCTAssertTrue(solana.waitForExistence(timeout: 30))
        solana.tap()
        let heart = app.buttons["Fixar no topo do Mercado"]
        XCTAssertTrue(heart.waitForExistence(timeout: 10))
        sleep(3)
        shot("m1-detalhe", app)
        heart.tap()
        XCTAssertTrue(app.buttons["Tirar dos favoritos"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Favoritas"].waitForExistence(timeout: 5))
        shot("m2-favoritas", app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'SOL'")).firstMatch.tap()
        let trade = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trocar por'")).firstMatch
        XCTAssertTrue(trade.waitForExistence(timeout: 10))
        trade.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rede:'")).firstMatch.waitForExistence(timeout: 10))
        shot("m3-trocar", app)
    }
}
