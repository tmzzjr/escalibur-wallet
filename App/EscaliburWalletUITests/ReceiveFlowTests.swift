import XCTest

/// Receber: moeda, depois rede, depois endereco.
final class ReceiveFlowTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    func testCoinThenNetworkThenAddress() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        let receive = app.buttons["Receber"].firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        receive.tap()
        let usdt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'USDT'")).firstMatch
        XCTAssertTrue(usdt.waitForExistence(timeout: 10))
        shot("r1-moedas", app)
        usdt.tap()
        let tron = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tron'")).firstMatch
        XCTAssertTrue(tron.waitForExistence(timeout: 10))
        shot("r2-redes", app)
        tron.tap()
        let title = app.staticTexts["Receber USDT"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // O contrato do token no topo direito, acima do titulo (pedido do dono, 17/10/2026).
        let contract = app.buttons["receber-copiar-contrato"]
        XCTAssertTrue(contract.waitForExistence(timeout: 5), "sem o botao do contrato")
        XCTAssertGreaterThan(contract.frame.midX, app.frame.width * 0.6, "o contrato deveria ficar a direita")
        XCTAssertLessThan(contract.frame.maxY, title.frame.minY, "o contrato deveria ficar acima do titulo")
        shot("r3-endereco", app)

        // Copiar mostra que copiou: no botao e no aviso, por cima da folha de Receber.
        // O da folha, nao o "Copiar endereço" do topo da Carteira, que fica por baixo.
        app.buttons.matching(NSPredicate(format: "label == 'Copiar endereço' AND identifier != 'copiar-endereco-carteira'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Endereço copiado"].waitForExistence(timeout: 3), "o botao deveria dizer que copiou")
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Endereço copiado.'")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "o aviso de copiado deveria aparecer por cima da folha")
        shot("r4-copiado", app)
    }

    /// Token emitido (RLUSD no XRP Ledger): a tela avisa da linha de confianca.
    func testIssuedTokenTrustLineNote() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        let receive = app.buttons["Receber"].firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 30))
        receive.tap()
        let rlusd = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'RLUSD'")).firstMatch
        // A lista tem as nativas e depois dezenas de tokens: rola ate o RLUSD aparecer.
        for _ in 0..<6 where !rlusd.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(rlusd.waitForExistence(timeout: 10))
        rlusd.tap()
        let xrpl = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'XRP Ledger'")).firstMatch
        if xrpl.waitForExistence(timeout: 5) { xrpl.tap() }
        XCTAssertTrue(app.staticTexts["Receber RLUSD"].waitForExistence(timeout: 10))
        app.swipeUp()
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Para receber RLUSD, esta conta precisa antes de uma linha de confiança'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        shot("r4-rlusd-linha", app)
    }

    /// Ao lado do olho, na Carteira: copiar o endereco numa tela com cada rede e o icone dela.
    func testCopyAddressFromWalletHeader() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo"]
        app.launch()
        let copy = app.buttons["copiar-endereco-carteira"]
        XCTAssertTrue(copy.waitForExistence(timeout: 30))
        copy.tap()
        XCTAssertTrue(app.staticTexts["Copiar endereço"].waitForExistence(timeout: 5), "a tela de copiar nao abriu")
        let evm = app.buttons["copiar-ethereum"]
        XCTAssertTrue(evm.waitForExistence(timeout: 5), "sem a linha das redes EVM")
        let bitcoin = app.buttons["copiar-bitcoin"]
        XCTAssertTrue(bitcoin.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "w1-copiar-tela"
        attachment.lifetime = .keepAlways
        add(attachment)
        bitcoin.tap()
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Endereço Bitcoin copiado'")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "sem o aviso de copiado")
        XCTAssertFalse(app.staticTexts["Copiar endereço"].exists, "a tela nao fechou depois de copiar")
    }
}
