import XCTest

/// A tela de anotar as palavras redesenhada em 16/10/2026: a troca dos cartoes sem o veu
/// preto, a chapa de metal inclinada sem os cantos cortados e a cena da copia.
final class RecordWordsLookTests: XCTestCase {
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

    func testCardsPlateAndCopy() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "palavras"]
        app.launch()
        let next = app.buttons["Próximas"]
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        sleep(1)
        shot("w1-cartoes", app)
        next.tap()
        usleep(220_000)
        shot("w2-troca", app)
        sleep(1)
        app.buttons["ver-todas-palavras"].tap()
        XCTAssertTrue(app.buttons["copiar-palavras"].waitForExistence(timeout: 5))
        sleep(1)
        shot("w3-chapa", app)
        // Arrasta a chapa para o lado e fotografa antes de soltar.
        let plate = app.staticTexts["palavra-1"]
        let from = plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 90, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.6)
        shot("w4-chapa-solta", app)
        app.buttons["copiar-palavras"].tap()
        XCTAssertTrue(app.staticTexts["Copiar a senha da carteira?"].waitForExistence(timeout: 5))
        sleep(2)
        shot("w5-copiar", app)
        sleep(2)
        shot("w6-copiar-contando", app)
    }
}
