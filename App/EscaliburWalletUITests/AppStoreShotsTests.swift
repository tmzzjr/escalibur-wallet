import XCTest

/// As capturas da pagina da App Store, em ingles (a loja e en-US). So roda com
/// `ESCALIBUR_LOJA=1`: abre cada tela da carteira de demonstracao, espera os dados e fotografa.
final class AppStoreShotsTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ESCALIBUR_LOJA"] == "1", "so para as capturas da loja")
    }

    func open(_ screen: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + (screen.map { ["-tela", $0] } ?? [])
        app.launch()
        return app
    }

    func save(_ name: String, _ app: XCUIApplication) {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? image.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testStoreScreenshots() {
        var app = open(nil)
        XCTAssertTrue(app.buttons["acao-receber"].waitForExistence(timeout: 40))
        sleep(14)
        save("1-carteira", app)
        app.terminate()

        app = open("receber-btc")
        sleep(16)
        save("2-receber", app)
        app.terminate()

        app = open("trocar-grande")
        sleep(18)
        save("3-trocar", app)
        app.terminate()

        app = open("mercado")
        sleep(16)
        save("4-mercado", app)
        app.terminate()

        app = open("moeda")
        sleep(16)
        save("5-moeda", app)
        app.terminate()

        app = open("lacrar")
        sleep(12)
        save("6-envelope", app)
        app.terminate()
    }
}
