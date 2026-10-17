import XCTest

/// A checagem do aparelho antes de digitar a frase, ao importar (14/10/2026). A antiga
/// "Sua carteira, so sua" virou o tour depois do primeiro PIN (15/10/2026).
extension XCUIApplication {
    /// A checagem do aparelho: espera terminar e segue. Com aviso (simulador: jailbreak so
    /// vale no iPhone), marca o "Estou ciente" quando ele aparece.
    func passDeviceCheck() {
        // O deslizar so aparece quando a conferencia termina (16/10/2026).
        let slider = descendants(matching: .any)["deslizar-digitar"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 45), "a checagem do aparelho nao terminou")
        let risk = buttons["checagem-ciente"]
        // A conferencia termina quando o slider passa a dizer o que faz.
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Deslize para'"), object: slider)], timeout: 20)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: slider)
        if XCTWaiter.wait(for: [done], timeout: 15) != .completed, risk.waitForExistence(timeout: 3) {
            risk.tap()
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: slider)], timeout: 5)
        slideToConfirm(slider)
    }

    /// Digita uma palavra no teclado proprio do app, tecla por tecla, e fecha com o Seguinte.
    func typeOnOwnKeyboard(_ word: String) {
        for letter in word {
            let key = buttons["teclado-\(letter)"]
            XCTAssertTrue(key.waitForExistence(timeout: 10), "tecla \(letter)")
            key.tap()
        }
        buttons["teclado-seguinte"].tap()
    }

    /// Toca quando o botao habilita: depois de um aceite, ele habilita um instante depois.
    func tapWhenEnabled(_ button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND hittable == true"), object: button)], timeout: 5)
        button.tap()
    }

    /// Arrasta o cadeado do slider ate o fim.
    func slideToConfirm(_ slider: XCUIElement) {
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }
}
