import XCTest

/// Busca do Mercado: tocar fora do campo fecha o teclado; dentro, nao; a moeda tocada
/// continua abrindo.
final class MarketSearchKeyboardTests: XCTestCase {
    func testTapOutsideClosesKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "mercado"]
        app.launch()
        let search = app.textFields.firstMatch
        XCTAssertTrue(app.staticTexts["XRP"].firstMatch.waitForExistence(timeout: 30))
        search.tap()
        search.typeText("bit")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        // Dentro do campo: o teclado fica.
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "tocar no proprio campo nao pode fechar o teclado")

        // Fora (o titulo da aba): fecha.
        app.staticTexts["Mercado"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "tocar fora do campo deveria fechar o teclado")

        // De novo com o teclado aberto, tocar numa moeda fecha e abre a moeda.
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let bitcoin = app.staticTexts["Bitcoin"].firstMatch
        XCTAssertTrue(bitcoin.waitForExistence(timeout: 5))
        bitcoin.tap()
        XCTAssertTrue(app.buttons["Avisar sobre o preço desta moeda"].waitForExistence(timeout: 10), "a moeda tocada deveria abrir")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
}
