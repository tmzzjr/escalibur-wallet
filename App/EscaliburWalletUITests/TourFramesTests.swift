import XCTest

/// Quadros das cenas do tour, para conferir a animacao (pedido do dono, 15/10/2026).
/// So com ESCALIBUR_FOTOS: tira uma foto em cada instante da cena.
final class TourFramesTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUpWithError() throws {
        try XCTSkipIf(shots == nil, "so com ESCALIBUR_FOTOS")
    }

    /// Com ESCALIBUR_VIDEO, so espera: a foto do XCUITest congela a tela do simulador por
    /// um instante, e quem grava o video ve a cena pular.
    var videoOnly: Bool { ProcessInfo.processInfo.environment["ESCALIBUR_VIDEO"] != nil }

    func frames(_ name: String, at marks: [Double]) {
        guard let shots else { return }
        let start = Date()
        if videoOnly {
            usleep(UInt32((marks.last ?? 1) * 1_000_000))
            return
        }
        for (index, mark) in marks.enumerated() {
            let wait = mark - Date().timeIntervalSince(start)
            if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/tour-\(name)-\(index).png"))
        }
    }

    func testTourScenes() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "promessa"]
        app.launch()
        let next = app.buttons["tour-continuar"]
        XCTAssertTrue(next.waitForExistence(timeout: 40))
        frames("2-moedas", at: [0.4, 1.0, 1.8, 3.0, 5.0])
        next.tap()
        frames("3-assinatura", at: [0.6, 1.6, 2.6, 3.4, 4.2, 5.5])
        guard videoOnly else { return }
        // A moeda com o dedo: um arrasto que gira e solta no embalo, e um toque.
        let coin = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let side = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.3))
        coin.press(forDuration: 0.05, thenDragTo: side, withVelocity: 700, thenHoldForDuration: 0)
        sleep(3)
        coin.tap()
        sleep(3)
    }
}
