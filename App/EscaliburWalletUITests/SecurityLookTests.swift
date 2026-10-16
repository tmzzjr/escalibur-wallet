import XCTest

/// Seguranca, o modo reforcado e o teclado proprio: as telas abrem, o Face ID aparece
/// para ligar dentro do modo reforcado, e o teclado proprio liga e fica ligado.
final class SecurityLookTests: XCTestCase {
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

    func testHardenedAndKeyboardScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "ajustes"]
        app.launch()
        let security = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Segurança'")).firstMatch
        XCTAssertTrue(security.waitForExistence(timeout: 30))
        security.tap()

        app.tapWhenEnabled(app.buttons["ajustes-reforcado"])
        XCTAssertTrue(app.buttons["reforcado-ligar"].waitForExistence(timeout: 10))
        // O Face ID se liga daqui mesmo.
        XCTAssertTrue(app.switches["reforcado-face-id"].waitForExistence(timeout: 5))
        sleep(2)
        shot("s1-reforcado", app)
        app.swipeUp()
        shot("s2-reforcado-fim", app)
        app.navigationBars.buttons.firstMatch.tap()

        app.tapWhenEnabled(app.buttons["ajustes-teclado"])
        let toggle = app.switches["teclado-proprio"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "0", "o teclado proprio nasce desligado")
        sleep(3)
        shot("s3-teclado", app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 5), .completed)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'ajustes-teclado' AND label CONTAINS 'Ligado'")).firstMatch.waitForExistence(timeout: 5))
    }
}
