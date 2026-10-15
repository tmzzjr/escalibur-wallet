import XCTest

/// A conferencia do aparelho (pedido do dono, 15/10/2026): o horario exato no fim; quem
/// sai dela e entra de novo ve "Conferindo de novo", com o horario da anterior; voltar da
/// tela de digitar nao refaz.
final class DeviceCheckTests: XCTestCase {
    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots = ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
    }

    func testRecheckIsExplicitAndBackFromTypingKeepsIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "adicionar"]
        app.launch()
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Importar com a senha da carteira'")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 30))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: option)], timeout: 5)
        sleep(1)
        option.tap()
        let accept = app.buttons["aceite-responsabilidade"]
        if !accept.waitForExistence(timeout: 8) { option.tap() }
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        accept.tap()
        app.buttons["Conferir o aparelho"].tap()

        // Primeira conferencia: termina com o horario.
        let stamp = app.staticTexts["checagem-horario"]
        XCTAssertTrue(stamp.waitForExistence(timeout: 20))
        XCTAssertTrue(stamp.label.hasPrefix("Conferido às"))
        shot("checagem-1", app)

        // Volta para a tela anterior e entra de novo: conferencia nova, dita como nova.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Conferir o aparelho"].waitForExistence(timeout: 5))
        app.buttons["Conferir o aparelho"].tap()
        XCTAssertTrue(app.staticTexts["Conferindo de novo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'A anterior foi às'")).firstMatch.exists)
        shot("checagem-2-de-novo", app)
        XCTAssertTrue(stamp.waitForExistence(timeout: 20))
        XCTAssertTrue(stamp.label.hasPrefix("Conferido de novo às"))
        let second = stamp.label

        // Desliza, chega na tela de digitar, volta: a conferencia continua a mesma.
        app.passDeviceCheck()
        XCTAssertTrue(app.otherElements["palavra-1"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(stamp.waitForExistence(timeout: 5))
        XCTAssertEqual(stamp.label, second, "voltar da tela de digitar nao deve refazer a conferencia")
        shot("checagem-3-voltou", app)
    }
}
