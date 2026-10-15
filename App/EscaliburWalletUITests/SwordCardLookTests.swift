import XCTest

/// So para gravar a carta da espada em video (ESCALIBUR_VIDEO): a espiada, um arrasto ate
/// a metade e de volta, um arrasto que vira a carta, o verso, e um toque que desvira.
final class SwordCardLookTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ESCALIBUR_VIDEO"] == nil, "so com ESCALIBUR_VIDEO")
    }

    func testFlipAndTilt() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo-onboarding"]
        app.launch()
        let card = app.descendants(matching: .any)["carta-espada"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        sleep(3)
        let middle = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let left = card.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.4))
        middle.press(forDuration: 0.1, thenDragTo: left, withVelocity: 60, thenHoldForDuration: 1.5)
        sleep(2)
        let right = card.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: right, withVelocity: 900, thenHoldForDuration: 0)
        sleep(4)
        card.tap()
        sleep(3)
    }
}
