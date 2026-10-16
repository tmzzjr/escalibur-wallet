import XCTest

/// A tela do valor do envio (pedido do dono, 16/10/2026): tocar fora fecha o teclado
/// numerico, e o Max nunca mostra 0 enquanto o motor calcula quanto da para gastar.
final class SendAmountTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUp() {
        continueAfterFailure = false
    }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testTapOutsideClosesKeyboardAndMaxIsNotZero() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "envio-valor"]
        app.launch()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "o teclado numerico nao abriu")
        // Um toque no meio da tela, fora do campo e dos botoes.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, "tocar fora nao fechou o teclado")

        app.buttons["Máx"].tap()
        sleep(1)
        shot("v6-max", app)
        let value = field.value as? String ?? ""
        XCTAssertFalse(value.isEmpty || value == "0", "o Max mostrou \(value)")
    }
}
