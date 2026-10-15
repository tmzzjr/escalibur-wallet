import XCTest

/// A checagem do aparelho antes de digitar a frase, ao importar (14/10/2026). A antiga
/// "Sua carteira, so sua" virou o tour depois do primeiro PIN (15/10/2026).
extension XCUIApplication {
    /// A checagem do aparelho: espera terminar e segue. Com aviso (simulador: jailbreak so
    /// vale no iPhone), marca o "Entendo o risco" quando ele aparece.
    func passDeviceCheck() {
        let slider = descendants(matching: .any)["deslizar-digitar"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 15), "a checagem do aparelho nao apareceu")
        let risk = switches["Entendo o risco e quero seguir mesmo assim"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: slider)
        if XCTWaiter.wait(for: [done], timeout: 15) != .completed, risk.waitForExistence(timeout: 3) {
            risk.tap()
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: slider)], timeout: 5)
        slideToConfirm(slider)
    }

    /// Arrasta o cadeado do slider ate o fim.
    func slideToConfirm(_ slider: XCUIElement) {
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }
}
