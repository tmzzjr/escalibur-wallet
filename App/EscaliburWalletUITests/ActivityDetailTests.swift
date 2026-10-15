import XCTest

/// O detalhe de uma transacao: logo da moeda e da rede, valor, situacao e o
/// identificador (pedido do dono, 15/10/2026). Transacoes inventadas pela tela de teste.
final class ActivityDetailTests: XCTestCase {
    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots = ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
    }

    func testDetailVariants() {
        for (variant, kind, network) in [("recebida", "Recebido", "Solana"), ("enviada", "Enviado", "Arbitrum"), ("troca", "Troca", "Base")] {
            let app = XCUIApplication()
            app.launchArguments = ["-reset", "-demo", "-tela", "transacao", "-transacao", variant]
            app.launch()
            XCTAssertTrue(app.staticTexts[kind].waitForExistence(timeout: 30), variant)
            XCTAssertTrue(app.staticTexts[network].exists, "\(variant): a rede")
            XCTAssertTrue(app.staticTexts["Identificador"].exists)
            sleep(1)
            shot("transacao-\(variant)", app)
            app.terminate()
        }
    }
}
