import XCTest

/// Sem a camera: a tela explica e "Abrir Ajustes" leva a pagina do app nos Ajustes
/// (pedido do dono, 15/10/2026).
final class CameraAccessTests: XCTestCase {
    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots = ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
    }

    func testDeniedOpensAppSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "camera", "-camera-negada"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Libere a câmera para ler o QR"].waitForExistence(timeout: 30))
        sleep(3)
        shot("camera-negada", app)
        app.buttons["abrir-ajustes-camera"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10), "os Ajustes deveriam abrir")
        // No iOS 17 o link cai na pagina do app; no iOS 26, na raiz (a tela diz o caminho).
        if #unavailable(iOS 18) {
            XCTAssertTrue(settings.navigationBars["Escalibur Wallet"].waitForExistence(timeout: 10), "deveria abrir a pagina do app")
        }
    }
}
