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
        // A carteira de teste e publica e os saldos mudam: abre o primeiro ativo da lista.
        let manage = app.buttons["gerenciar-ativos"]
        XCTAssertTrue(manage.waitForExistence(timeout: 30))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'USDT' OR label CONTAINS 'XRP' OR label CONTAINS 'NEAR' OR label CONTAINS 'SOL'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "a carteira de teste deveria listar algum ativo")
        row.tap()
        XCTAssertTrue(app.staticTexts["Atividade"].firstMatch.waitForExistence(timeout: 10))
        app.swipeUp()
        // A secao termina de ler: movimentos do ativo, ou o aviso de que ainda nao ha.
        // Nunca fica lendo para sempre nem mostra falha.
        let movement = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Enviado · ' OR label BEGINSWITH 'Recebido · ' OR label BEGINSWITH 'Troca · '")).firstMatch
        let none = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nenhum movimento de'")).firstMatch
        let deadline = Date().addingTimeInterval(45)
        while !movement.exists && !none.exists && Date() < deadline { sleep(1) }
        XCTAssertTrue(movement.exists || none.exists, "a secao Atividade deveria terminar de ler")
        XCTAssertFalse(app.staticTexts["Não foi possível ler os movimentos agora."].exists)
        shot("h1-ativo-atividade", app)
        if movement.exists {
            movement.tap()
            XCTAssertTrue(app.staticTexts["Identificador"].waitForExistence(timeout: 10), "a linha deveria abrir o detalhe")
        }
    }
}
