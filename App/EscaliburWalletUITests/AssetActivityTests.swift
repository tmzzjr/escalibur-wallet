import XCTest

/// Pagina do ativo: a secao Atividade com os movimentos daquela moeda.
final class AssetActivityTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testAssetPageShowsItsActivity() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        // TRX: a carteira de teste tem movimento frequente na Tron.
        let trx = app.buttons.matching(NSPredicate(format: "label CONTAINS 'TRX'")).firstMatch
        XCTAssertTrue(trx.waitForExistence(timeout: 30))
        trx.tap()
        XCTAssertTrue(app.staticTexts["Atividade"].firstMatch.waitForExistence(timeout: 10))
        app.swipeUp()
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Enviado · TRX' OR label BEGINSWITH 'Recebido · TRX'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "a pagina do TRX deveria listar os movimentos de TRX")
        shot("h1-ativo-atividade", app)
        row.tap()
        XCTAssertTrue(app.staticTexts["Identificador"].waitForExistence(timeout: 10), "a linha deveria abrir o detalhe")
    }
}
