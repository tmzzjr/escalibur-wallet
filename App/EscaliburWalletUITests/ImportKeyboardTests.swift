import UIKit
import XCTest

/// A tela de importar com o teclado proprio e com o Colar em vidro: o iOS so cola pelo
/// PasteButton se ele estiver visivel e legivel, e a capsula dele agora e transparente,
/// com o vidro por tras. Aqui o toque tem de colar de verdade.
final class ImportKeyboardTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testPasteButtonFills() {
        // A frase publica de teste do BIP-39, nunca uma carteira de verdade.
        UIPasteboard.general.string = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "frase", "-frase-topo"]
        app.launch()
        let paste = app.buttons.matching(NSPredicate(format: "label == 'Colar' OR label == 'Paste'")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 30))
        shot("k0-colar", app)
        paste.tap()
        let first = app.otherElements["palavra-1"]
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Palavra 1, preenchida'"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 10), .completed, "o Colar em vidro nao colou")
        XCTAssertEqual(app.otherElements["palavra-12"].label, "Palavra 12, preenchida")
    }

    func testOwnKeyboardTypesOnlyListWords() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "frase", "-frase-topo", "-teclado-proprio"]
        app.launch()
        let first = app.otherElements["palavra-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        first.tap()
        let a = app.buttons["teclado-a"]
        XCTAssertTrue(a.waitForExistence(timeout: 10), "o teclado proprio nao subiu")
        // O teclado do iPhone nao sobe.
        XCTAssertEqual(app.keyboards.count, 0, "o teclado do iPhone subiu junto")
        for letter in "aban" { app.buttons["teclado-\(letter)"].tap() }
        // Depois de "aban", nenhuma palavra da lista segue com "x".
        XCTAssertFalse(app.buttons["teclado-x"].isEnabled, "uma letra fora da lista ficou acesa")
        shot("k1-teclado", app)
        app.buttons["teclado-seguinte"].tap()
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Palavra 1, preenchida'"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed, "o Seguinte nao fechou a palavra")
        // O globo devolve o teclado do iPhone, para as frases que este nao escreve, depois
        // de perguntar.
        app.buttons["teclado-sistema"].tap()
        let confirm = app.alerts.buttons["Usar o do iPhone"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "o globo nao perguntou")
        confirm.tap()
        app.otherElements["palavra-2"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "o globo nao trouxe o teclado do iPhone")
    }

    /// Tocar numa posicao ja preenchida abre a palavra para corrigir (visto no app de verdade,
    /// 16/10/2026). Aberta, a posicao diz "editando".
    func testTapPreviousSlotToEdit() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "frase", "-frase-topo", "-teclado-proprio"]
        app.launch()
        let first = app.otherElements["palavra-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        first.tap()
        XCTAssertTrue(app.buttons["teclado-a"].waitForExistence(timeout: 10))
        for letter in "aban" { app.buttons["teclado-\(letter)"].tap() }
        app.buttons["teclado-seguinte"].tap()
        for letter in "abil" { app.buttons["teclado-\(letter)"].tap() }
        app.buttons["teclado-seguinte"].tap()
        let second = app.otherElements["palavra-2"]
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Palavra 2, preenchida'"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 5), .completed)
        first.tap()
        let editing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'editando'"), object: first)
        let opened = XCTWaiter.wait(for: [editing], timeout: 5)
        shot("k4-corrigir", app)
        XCTAssertEqual(opened, .completed, "tocar na posicao anterior nao abriu a palavra para corrigir")
    }

    func testWordCountPickerAndKeyboardInfo() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "frase", "-frase-topo", "-teclado-proprio"]
        app.launch()
        // 12 e 24 a vista; o "+" abre os outros, e escolhido um, voltam dois.
        XCTAssertTrue(app.buttons["12 palavras"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["24 palavras"].exists)
        XCTAssertFalse(app.buttons["18"].exists)
        shot("k2-tamanhos", app)
        app.buttons["palavras-mais"].tap()
        XCTAssertTrue(app.buttons["18"].waitForExistence(timeout: 3))
        app.buttons["18"].tap()
        XCTAssertTrue(app.buttons["18 palavras"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["24 palavras"].exists)
        XCTAssertFalse(app.buttons["12 palavras"].exists)
        XCTAssertTrue(app.otherElements["palavra-18"].exists)

        // O nome do teclado abre a explicacao, e dela se desliga o teclado proprio.
        app.otherElements["palavra-1"].tap()
        let about = app.buttons["teclado-sobre"]
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        about.tap()
        let disable = app.buttons["teclado-desativar"]
        XCTAssertTrue(disable.waitForExistence(timeout: 5))
        sleep(2)
        shot("k3-sobre-teclado", app)
    }

    /// A palavra fechada continua na posicao dela (cifrada) quando a seguinte comeca: o dono
    /// relatou que ela sumia (16/10/2026).
    func testPreviousWordStaysWhileTypingNext() {
        for own in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-reset", "-demo", "-tela", "frase", "-frase-topo"] + (own ? ["-teclado-proprio"] : [])
            app.launch()
            let first = app.otherElements["palavra-1"]
            XCTAssertTrue(first.waitForExistence(timeout: 30))
            first.tap()
            if own {
                app.typeOnOwnKeyboard("abandon")
                for letter in "abi" { app.buttons["teclado-\(letter)"].tap() }
            } else {
                app.typeText("abandon ")
                app.typeText("abi")
            }
            sleep(1)
            shot(own ? "k4-proxima-proprio" : "k4-proxima-iphone", app)
            XCTAssertEqual(first.label, "Palavra 1, preenchida", "a palavra 1 sumiu ao digitar a 2")
            app.terminate()
        }
    }
}
