import XCTest

/// O nome da biometria vem do aparelho: iPhone SE mostra Touch ID, os outros Face ID.
final class BiometryNameTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func testSecurityShowsThisDevicesBiometry() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "ajustes"]
        app.launch()
        let security = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Segurança'")).firstMatch
        XCTAssertTrue(security.waitForExistence(timeout: 30))
        security.tap()
        let names = ["Face ID", "Touch ID", "Optic ID"].filter { app.staticTexts[$0].waitForExistence(timeout: 3) }
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/b1-seguranca.png")) }
        XCTAssertEqual(names.count, 1, "nomes de biometria na tela: \(names)")
    }
}
