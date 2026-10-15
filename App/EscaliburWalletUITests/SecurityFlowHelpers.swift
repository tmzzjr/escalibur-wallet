import XCTest

/// As telas de seguranca que vem antes das palavras (14/10/2026): "Sua carteira, so sua",
/// com os pontos aparecendo um a um e o Continuar ligando no fim, e, ao importar, a
/// checagem do aparelho antes de digitar.
extension XCUIApplication {
    /// Passa por "Sua carteira, so sua", se ela aparecer.
    func passSecurityPromise() {
        guard staticTexts["Sua carteira, só sua"].waitForExistence(timeout: 8) else { return }
        let next = buttons["Continuar"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: next)
        _ = XCTWaiter.wait(for: [enabled], timeout: 15)
        next.tap()
    }

    /// A checagem do aparelho: espera terminar e segue. Com aviso (simulador: jailbreak so
    /// vale no iPhone), marca o "Entendo o risco" quando ele aparece.
    func passDeviceCheck() {
        let next = buttons["Digitar as palavras"]
        XCTAssertTrue(next.waitForExistence(timeout: 15), "a checagem do aparelho nao apareceu")
        let risk = switches["Entendo o risco e quero seguir mesmo assim"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: next)
        if XCTWaiter.wait(for: [done], timeout: 12) != .completed, risk.waitForExistence(timeout: 3) {
            risk.tap()
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: next)], timeout: 5)
        next.tap()
    }
}
