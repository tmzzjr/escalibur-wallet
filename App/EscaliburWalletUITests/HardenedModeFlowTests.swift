import XCTest

/// O modo reforcado de ponta a ponta: ligar o Face ID, ligar o modo (com a frase inteira da
/// carteira da demo, a publica "abandon ... about") na politica padrao, sem aceite, reabrir e
/// destravar com PIN e rosto, e desligar. E escolher "Bloquear as carteiras" (a animacao, o
/// aceite, as palavras, o PIN e dois rostos) e voltar para "Continuar normal".
///
/// So roda com `ESCALIBUR_FACE_ID=1`: o rosto do simulador precisa de um rosto cadastrado e
/// de alguem aprovando cada pedido (`notifyutil -p com.apple.BiometricKit_Sim.pearl.match`
/// em laco, fora do teste).
final class HardenedModeFlowTests: XCTestCase {
    let pin = "111111"
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ESCALIBUR_FACE_ID"] == "1", "so com o rosto do simulador aprovado em laco")
    }

    func type(pin: String, in app: XCUIApplication) {
        for digit in pin {
            let key = app.buttons.matching(identifier: "tecla-\(digit)").firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 15), "tecla \(digit)")
            key.tap()
        }
    }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
    }

    /// O primeiro uso do Face ID pelo app pede a permissao do iOS.
    func allowFaceID() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["OK", "Permitir", "Allow"] {
            let button = springboard.buttons[title]
            if button.waitForExistence(timeout: 4) { button.tap(); return }
        }
    }

    /// A frase inteira da carteira da demo, pela tela da importacao em modo de conferencia, no
    /// teclado proprio: a conferencia do modo reforcado nunca usa o do iPhone.
    func typeDemoPhrase(_ app: XCUIApplication) {
        let first = app.otherElements["palavra-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        XCTAssertEqual(app.keyboards.count, 0, "a conferencia abriu o teclado do iPhone")
        for _ in 1...11 { app.typeOnOwnKeyboard("abandon") }
        app.typeOnOwnKeyboard("about")
        app.tapWhenEnabled(app.buttons["conferir-copia"])
    }

    func waitSelected(_ element: XCUIElement, timeout: TimeInterval = 60) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)], timeout: timeout) == .completed
    }

    /// Da abertura limpa ate o modo reforcado ligado na politica padrao: o Face ID primeiro (o
    /// modo nasce dele), a frase, e o PIN e dois rostos, sem aceite nenhum.
    func enableDefault(_ app: XCUIApplication, prefix: String) {
        let security = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Segurança'")).firstMatch
        XCTAssertTrue(security.waitForExistence(timeout: 30))
        security.tap()

        let faceID = app.switches.matching(NSPredicate(format: "label CONTAINS 'Face ID'")).firstMatch
        XCTAssertTrue(faceID.waitForExistence(timeout: 10))
        // O interruptor fica na ponta direita da linha.
        shot("\(prefix)00-seguranca", app)
        faceID.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        sleep(1)
        shot("\(prefix)01-pin", app)
        type(pin: pin, in: app)
        allowFaceID()
        shot("\(prefix)0-face-id", app)
        // O rosto da conferencia e aprovado de fora; a folha fecha e o interruptor liga.
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: faceID)
        XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 45), .completed, "o Face ID deveria ligar")

        let row = app.buttons["ajustes-reforcado"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        app.tapWhenEnabled(row)
        let enable = app.buttons["reforcado-ligar"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        // O preco saiu da tela principal: so aparece na tela do bloqueio.
        XCTAssertFalse(app.staticTexts["O preço"].exists)
        XCTAssertTrue(app.buttons["reforcado-politica"].exists)
        shot("\(prefix)1-reforcado", app)
        app.tapWhenEnabled(enable)

        typeDemoPhrase(app)
        // O ultimo passo: a politica padrao escolhida, e nenhum aceite.
        let confirm = app.buttons["reforcado-confirmar"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reforcado-politica-continuar"].isSelected)
        XCTAssertFalse(app.buttons["reforcado-aceite"].exists)
        shot("\(prefix)2-antes-de-ligar", app)
        app.tapWhenEnabled(confirm)
        type(pin: pin, in: app)
        // Dois rostos, aprovados de fora; o toast e a tela dizem ligado.
        XCTAssertTrue(app.staticTexts["Ligado neste iPhone"].waitForExistence(timeout: 60))
        shot("\(prefix)3-ligado", app)
    }

    func testEnableUnlockDisable() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "ajustes"]
        app.launch()
        enableDefault(app, prefix: "h")

        // Reabrir: o PIN, e o rosto depois dele.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Super Security'")).firstMatch.waitForExistence(timeout: 20))
        shot("h4-bloqueio", app)
        type(pin: pin, in: app)
        XCTAssertTrue(app.staticTexts["Saldo total"].waitForExistence(timeout: 60))
        // Fora do modo demo, a carteira oferece o aviso de recebimento na primeira abertura.
        if app.buttons["recebimento-oferta-ligar"].waitForExistence(timeout: 30) { app.buttons["Agora não"].tap() }
        // E depois os alertas de preco pedem a permissao de notificar.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Permitir", "Allow"] where springboard.buttons[title].waitForExistence(timeout: 5) {
            springboard.buttons[title].tap()
            break
        }

        // Desligar: PIN e rosto, e o Face ID volta.
        let tab = app.tabBars.buttons["Ajustes"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        let securityAgain = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Segurança'")).firstMatch
        // O toque na aba as vezes cai durante a folha que fecha: tenta de novo.
        for _ in 0..<4 where !securityAgain.exists {
            tab.tap()
            _ = securityAgain.waitForExistence(timeout: 5)
        }
        if !securityAgain.exists { shot("h4b-ajustes", app) }
        app.tapWhenEnabled(securityAgain)
        app.tapWhenEnabled(app.buttons["ajustes-reforcado"])
        let disable = app.buttons["reforcado-desligar"]
        XCTAssertTrue(disable.waitForExistence(timeout: 10))
        disable.tap()
        type(pin: pin, in: app)
        let off = app.buttons["reforcado-ligar"].waitForExistence(timeout: 60)
        if !off { shot("h5-falhou", app) }
        XCTAssertTrue(off)
        shot("h5-desligado", app)
    }

    /// Ligado no padrao, escolher "Bloquear as carteiras": a tela com a animacao e o aceite, a
    /// frase inteira, o PIN e dois rostos. E voltar para "Continuar normal", com o PIN e dois
    /// rostos, sem palavras.
    func testChooseLockAndBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "ajustes"]
        app.launch()
        enableDefault(app, prefix: "b")

        app.tapWhenEnabled(app.buttons["reforcado-politica"])
        let lock = app.buttons["reforcado-politica-bloquear"]
        let normal = app.buttons["reforcado-politica-continuar"]
        XCTAssertTrue(lock.waitForExistence(timeout: 10))
        XCTAssertTrue(normal.isSelected)
        shot("b4-politicas", app)
        lock.tap()

        // A tela do bloqueio: a animacao, o que vale e o aceite. Sem aceite, nao segue.
        let consent = app.buttons["reforcado-bloquear-aceite"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        let confirm = app.buttons["reforcado-bloquear-confirmar"]
        XCTAssertFalse(confirm.isEnabled)
        sleep(3)
        shot("b5-bloquear", app)
        consent.tap()
        app.tapWhenEnabled(confirm)
        typeDemoPhrase(app)
        type(pin: pin, in: app)
        // Dois rostos, aprovados de fora; a lista volta com a trava escolhida.
        XCTAssertTrue(waitSelected(lock), "a trava deveria valer")
        shot("b6-bloqueado", app)

        // De volta: PIN e rosto pela kand.bio, e o rosto de novo para conferir.
        normal.tap()
        type(pin: pin, in: app)
        XCTAssertTrue(waitSelected(normal), "continuar normal deveria valer")
        XCTAssertFalse(lock.isSelected)
        shot("b7-normal", app)
    }
}
