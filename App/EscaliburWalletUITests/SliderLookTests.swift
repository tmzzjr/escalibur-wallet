import XCTest

/// So para gravar o slider da conferencia em video (ESCALIBUR_VIDEO): espera a
/// conferencia, arrasta devagar ate a metade e segura, depois solta.
final class SliderLookTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ESCALIBUR_VIDEO"] == nil, "so com ESCALIBUR_VIDEO")
    }

    func testDragHalfway() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "checagem"]
        app.launch()
        let slider = app.descendants(matching: .any)["deslizar-digitar"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 30))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Deslize para digitar as palavras'"), object: slider)], timeout: 30)
        sleep(4)
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let middle = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: middle, withVelocity: .slow, thenHoldForDuration: 2)
        sleep(2)
    }

    /// Ate o fim, devagar: a onda que acende o resto e a grade fechando.
    func testDragToEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "checagem"]
        app.launch()
        let slider = app.descendants(matching: .any)["deslizar-digitar"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 30))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Deslize para digitar as palavras'"), object: slider)], timeout: 30)
        sleep(4)
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: 140, thenHoldForDuration: 0.2)
        sleep(3)
    }
}
