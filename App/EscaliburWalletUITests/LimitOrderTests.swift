import XCTest

/// Ordem limite: o prazo "Até cancelar" e a folha de ordens abertas, lida da rede.
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

    func testUntilCancelledAndOpenOrders() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "trocar"]
        app.launch()
        let limit = app.buttons["Limite"]
        XCTAssertTrue(limit.waitForExistence(timeout: 30))
        limit.tap()
        app.swipeUp()
        let untilCancelled = app.buttons["Até cancelar"]
        XCTAssertTrue(untilCancelled.waitForExistence(timeout: 10))
        untilCancelled.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Na CoW toda ordem tem prazo'")).firstMatch.waitForExistence(timeout: 5))
        shot("l1-ate-cancelar", app)
        let orders = app.buttons["Ordens abertas"]
        XCTAssertTrue(orders.exists)
        orders.tap()
        let empty = app.staticTexts["Nenhuma ordem aberta nesta carteira."]
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
}
