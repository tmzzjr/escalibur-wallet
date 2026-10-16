import XCTest

/// Passeio de conferencia visual por idioma: as telas mais apertadas, fotografadas no
/// idioma de ESCALIBUR_IDIOMA (ex.: "de", "hi", "ar"). Sem a variavel, nao roda. As fotos
/// vao para ESCALIBUR_FOTOS, com o idioma no nome.
final class LanguageTourTests: XCTestCase {
    var language: String? { ProcessInfo.processInfo.environment["ESCALIBUR_IDIOMA"] }

    override func setUpWithError() throws {
        try XCTSkipIf(language == nil, "so com ESCALIBUR_IDIOMA")
    }

    func shot(_ name: String, _ app: XCUIApplication) {
        guard let shots = ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"], let language else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(language)-\(name).png"))
    }

    func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        let region = ["en": "en_US", "es": "es_ES", "fr": "fr_FR", "de": "de_DE", "hi": "hi_IN", "zh-Hans": "zh_CN",
                      "ja": "ja_JP", "ko": "ko_KR", "tr": "tr_TR", "id": "id_ID", "vi": "vi_VN", "ar": "ar_SA"][language ?? ""] ?? "en_US"
        app.launchArguments = extra + ["-AppleLanguages", "(\(language ?? "en"))", "-AppleLocale", region]
        app.launch()
        return app
    }

    func testTour() {
        var app = launch(["-reset"])
        sleep(3)
        shot("01-entrada", app)
        app.terminate()

        app = launch(["-reset", "-demo"])
        let receive = app.buttons["acao-receber"]
        XCTAssertTrue(receive.waitForExistence(timeout: 40))
        sleep(6)
        shot("02-carteira", app)
        receive.tap()
        sleep(2)
        shot("03-receber", app)
        let btc = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BTC,'")).firstMatch
        if btc.waitForExistence(timeout: 10) {
            btc.tap()
            sleep(1)
            shot("04-receber-btc", app)
        }
        app.terminate()

        app = launch(["-demo"])
        let tabs = app.tabBars.buttons
        XCTAssertTrue(tabs.element(boundBy: 0).waitForExistence(timeout: 40))
        for (index, name) in [(2, "05-trocar"), (1, "06-mercado"), (4, "07-ajustes")] {
            tabs.element(boundBy: index).tap()
            sleep(3)
            shot(name, app)
        }
        app.terminate()

        app = launch(["-demo", "-tela", "transacao", "-transacao", "troca"])
        sleep(8)
        shot("08-transacao", app)
        app.terminate()

        app = launch(["-demo", "-tela", "palavras"])
        let all = app.buttons["ver-todas-palavras"]
        if all.waitForExistence(timeout: 40) {
            shot("09-palavras", app)
            all.tap()
            sleep(1)
            shot("10-chapa", app)
            if app.buttons["copiar-palavras"].exists {
                app.buttons["copiar-palavras"].tap()
                sleep(1)
                shot("11-copiar", app)
            }
        }
        app.terminate()

        app = launch(["-demo", "-tela", "camera", "-camera-negada"])
        sleep(8)
        shot("12-camera", app)
        app.terminate()

        // O tour: as moedas em orbita e a assinatura.
        app = launch(["-demo", "-tela", "promessa"])
        let next = app.buttons["tour-continuar"]
        if next.waitForExistence(timeout: 40) {
            sleep(4)
            shot("14-tour-moedas", app)
            next.tap()
            sleep(5)
            shot("15-tour-assina", app)
        }
        app.terminate()

        // A conferencia do aparelho, inteira, com o slider.
        app = launch(["-demo", "-tela", "checagem"])
        if app.descendants(matching: .any)["deslizar-digitar"].waitForExistence(timeout: 40) {
            sleep(8)
            shot("16-checagem", app)
        }
        app.terminate()

        // O Como funciona do envelope: o cifrado e a senha que revela as palavras.
        for (page, name) in [("1", "17-envelope-ruido"), ("2", "18-envelope-senha")] {
            app = launch(["-demo", "-tela", "envelope-como", page])
            sleep(9)
            shot(name, app)
            app.terminate()
        }
    }
}
