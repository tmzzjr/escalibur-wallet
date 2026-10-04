import XCTest

/// Redes sem historico publico sem cadastro: a Atividade explica e leva ao explorador.
final class ActivityExplorerTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testExplorerLinkForChainWithoutHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "atividade"]
        app.launch()
        let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ver o histórico no'")).firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !link.exists && Date() < deadline { app.swipeUp(); sleep(1) }
        guard link.exists else { throw XCTSkip("a carteira de teste nao tem saldo agora nas redes sem historico") }
        shot("a5-explorador", app)
    }
}
