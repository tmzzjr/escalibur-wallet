import XCTest

/// A checagem do aparelho antes de digitar a frase, ao importar (14/10/2026). A antiga
/// "Sua carteira, so sua" virou o tour depois do primeiro PIN (15/10/2026).
extension XCUIApplication {
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
