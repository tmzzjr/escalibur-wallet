import XCTest

/// Envenenamento de endereco: um destino com as pontas do endereco da propria carteira
/// e o meio trocado pede os 6 caracteres do meio, nunca os do fim.
final class SendLookalikeTests: XCTestCase {
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

    func testMiddleSegmentChallenge() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "enviar-eth"]
        app.launch()
        // A carteira de teste na Ethereum e 0x9858EfFD...EcaEda94. O destino abaixo tem
        // as mesmas pontas e zeros no meio; em minusculas, sem checksum a conferir.
        XCTAssertTrue(app.staticTexts["Para"].waitForExistence(timeout: 30))
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        shot("s0-destino", app)
        field.tap()
        field.typeText("0x98580000000000000000000000000000ecaeda94")
        let check = app.textFields["conferir-trecho-endereco"]
        if !check.waitForExistence(timeout: 10) { shot("falha-parecido", app) }
        XCTAssertTrue(check.exists)
        shot("s1-parecido", app)
        let next = app.buttons["Continuar"]
        app.swipeUp()
        check.tap()
        // O fim e o que o atacante copiou: digita-lo nao pode liberar o envio.
        check.typeText("aeda94")
        next.tap()
        sleep(1)
        XCTAssertTrue(check.exists, "o fim copiado pelo atacante nao pode liberar")
        check.clearAndType("000000")
        shot("s2-conferido", app)
    }
}

extension XCUIElement {
    func clearAndType(_ text: String) {
        guard let current = value as? String else { return }
        tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        typeText(text)
    }
}

/// Transmissao sem resposta certa: a tela so oferece enviar os mesmos bytes de novo.
final class SendUnsureTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func testUnsureScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "envio-incerto"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Não deu para confirmar o envio"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Transmitir de novo"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/s3-incerto.png")) }
    }
}

/// Tag opcional: quando a rede tem e o destino nao exige, o campo abre a pedido.
final class SendOptionalTagTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    func testOptionalTagField() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "enviar"]
        app.launch()
        let xrp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'XRP,'")).firstMatch
        XCTAssertTrue(xrp.waitForExistence(timeout: 40))
        xrp.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh")
        let addTag = app.buttons["Adicionar tag de destino"]
        XCTAssertTrue(addTag.waitForExistence(timeout: 10))
        addTag.tap()
        let tag = app.textFields["tag-opcional"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        tag.tap()
        tag.typeText("0123")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/s4-tag-opcional.png")) }
    }
}
