import XCTest

/// Carteira nova: a escolha 12 | 24 palavras, a tela de seguranca antes das palavras
/// (criar e importar), a placa que se arrasta, voltar e confirmar depois, e observar
/// um endereco.
final class NewWalletFlowTests: XCTestCase {
    let pin = "111111"
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUp() {
        continueAfterFailure = false
    }

    func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
        }
    }

    func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", screen]
        app.launch()
        return app
    }

    func type(pin: String, in app: XCUIApplication) {
        for digit in pin {
            let key = app.buttons.matching(identifier: "tecla-\(digit)").firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 10), "tecla \(digit)")
            key.tap()
        }
    }

    func text(_ prefix: String, in app: XCUIApplication, timeout: TimeInterval = 3) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch.waitForExistence(timeout: timeout)
    }

    /// Da tela de seguranca ate as palavras: a caixa desmarcada segura o botao.
    func acceptAndShowWords(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Só você tem a chave"].waitForExistence(timeout: 5))
        app.buttons["Marque o aceite para continuar"].tap()
        XCTAssertFalse(app.staticTexts["Confirme com o PIN"].waitForExistence(timeout: 1), "continuou sem o aceite")
        app.buttons["aceite-responsabilidade"].tap()
        app.buttons["Mostrar as palavras"].tap()
        XCTAssertTrue(app.staticTexts["Confirme com o PIN"].waitForExistence(timeout: 10))
        type(pin: pin, in: app)
    }

    /// O destaque roxo esta embaixo deste botao? Le o pixel da tela entre a borda e o
    /// texto, depois de a animacao assentar.
    func highlighted(_ button: XCUIElement, in app: XCUIApplication) -> Bool {
        usleep(600_000)
        let image = app.screenshot().image
        guard let cg = image.cgImage else { return false }
        let scale = CGFloat(cg.width) / app.windows.firstMatch.frame.width
        let point = CGPoint(x: (button.frame.minX + 10) * scale, y: button.frame.midY * scale)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -point.x, y: point.y - CGFloat(cg.height) + 1, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        // Trilho e quase preto; o segmento e cor de marca, bem mais claro.
        return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) > 200
    }

    /// O bug do 12 | 24: tocar num lado tem de escolher esse lado, no destaque, no
    /// texto e na frase gerada. Confere tambem o estado de selecao que o VoiceOver le.
    func testWordCountFollowsTheTap() {
        let app = launch("criar")
        let twelve = app.buttons["12 palavras"]
        let twentyFour = app.buttons["24 palavras"]
        XCTAssertTrue(twentyFour.waitForExistence(timeout: 20))
        XCTAssertTrue(twelve.isSelected)
        XCTAssertFalse(twentyFour.isSelected)
        XCTAssertTrue(text("A senha da carteira são 12 palavras", in: app))

        XCTAssertTrue(highlighted(twelve, in: app) && !highlighted(twentyFour, in: app), "destaque fora do 12 ao abrir")

        twentyFour.tap()
        XCTAssertTrue(twentyFour.isSelected, "tocou 24, a selecao ficou no 12")
        XCTAssertFalse(twelve.isSelected)
        XCTAssertTrue(text("A senha da carteira são 24 palavras", in: app), "tocou 24, o texto ficou em 12")
        XCTAssertTrue(highlighted(twentyFour, in: app) && !highlighted(twelve, in: app), "tocou 24, o destaque ficou no 12")

        // Toque na ponta de dentro de cada lado, onde os dois encostam, e toques em
        // seguida, sem esperar a animacao.
        twelve.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(twelve.isSelected, "tocou a ponta do 12, foi para o 24")
        XCTAssertTrue(highlighted(twelve, in: app) && !highlighted(twentyFour, in: app), "tocou a ponta do 12, o destaque foi para o 24")
        twentyFour.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        XCTAssertTrue(twentyFour.isSelected, "tocou a ponta do 24, foi para o 12")
        twelve.tap()
        twentyFour.tap()
        XCTAssertTrue(twentyFour.isSelected)
        XCTAssertTrue(highlighted(twentyFour, in: app) && !highlighted(twelve, in: app), "toques seguidos, o destaque ficou no lado errado")

        app.buttons["Continuar"].tap()
        acceptAndShowWords(app)
        XCTAssertTrue(text("Palavras 1 a 3 de 24", in: app, timeout: 15), "escolheu 24, a frase nasceu com outro tamanho")
    }

    /// A placa se arrasta; da conferencia da para voltar; e da para sair e confirmar
    /// depois, com aviso, ficando o lembrete na Carteira.
    func testSwipeBackAndConfirmLater() {
        let app = launch("criar")
        XCTAssertTrue(app.buttons["Continuar"].waitForExistence(timeout: 20))
        app.buttons["Continuar"].tap()
        shot("seguranca-criar", app)
        acceptAndShowWords(app)

        XCTAssertTrue(text("Palavras 1 a 3 de 12", in: app, timeout: 15))
        let plate = app.staticTexts["palavra-2"]
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Esconde em'")).firstMatch.exists)
        plate.swipeLeft()
        XCTAssertTrue(text("Palavras 4 a 6 de 12", in: app), "arrastar para a esquerda nao avancou")
        shot("placa-arrastavel", app)
        app.staticTexts["palavra-5"].swipeRight()
        XCTAssertTrue(text("Palavras 1 a 3 de 12", in: app), "arrastar para a direita nao voltou")

        for _ in 0..<3 { app.buttons["Próximas"].tap() }
        XCTAssertTrue(text("Palavras 10 a 12 de 12", in: app))
        app.buttons["Já anotei as 12"].tap()

        XCTAssertTrue(app.staticTexts["Confirme a senha da carteira"].waitForExistence(timeout: 5))
        app.buttons["Voltar"].tap()
        XCTAssertTrue(text("Palavras 1 a 3 de 12", in: app, timeout: 5), "voltar nao levou as palavras")
        for _ in 0..<3 { app.buttons["Próximas"].tap() }
        app.buttons["Já anotei as 12"].tap()

        XCTAssertTrue(app.buttons["Anotar e confirmar depois"].waitForExistence(timeout: 5))
        shot("confirmar-depois", app)
        app.buttons["Anotar e confirmar depois"].tap()
        XCTAssertTrue(app.alerts["Confirmar depois?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Confirmar depois"].tap()

        XCTAssertTrue(app.staticTexts["Esta carteira ainda não tem cópia"].waitForExistence(timeout: 10))
    }

    /// Importar passa pela tela de seguranca; o link abre os Termos.
    func testImportShowsResponsibilityFirst() {
        let app = launch("adicionar")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Importar com a senha da carteira'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        // O demo ainda monta a Carteira por baixo nos primeiros segundos; empurrar uma
        // tela antes disso a perde quando a cobertura e refeita.
        sleep(4)
        row.tap()

        XCTAssertTrue(app.staticTexts["Só você tem a chave"].waitForExistence(timeout: 5))
        shot("seguranca-importar", app)
        app.buttons["Marque o aceite para continuar"].tap()
        sleep(1)
        XCTAssertTrue(app.staticTexts["Só você tem a chave"].exists, "continuou sem o aceite")

        app.descendants(matching: .any)["link-termos"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["A sua responsabilidade"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Só você guarda a senha da carteira'")).firstMatch.exists
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Só você guarda a senha da carteira'")).firstMatch.exists)
        app.buttons["Fechar"].tap()

        app.buttons["aceite-responsabilidade"].tap()
        XCTAssertTrue(app.buttons["aceite-responsabilidade"].isSelected)
        app.buttons["Digitar as palavras"].tap()
        XCTAssertTrue(app.staticTexts["Importar com a senha da carteira"].waitForExistence(timeout: 5))
    }

    /// Revelar a senha: o titulo diz "suas palavras" e a lista continua "Estou ciente que:".
    func testRevealWarningReadsAsOneSentence() {
        let app = launch("revelar")
        XCTAssertTrue(app.staticTexts["Ninguém da Escalibur vai pedir suas palavras"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Estou ciente que:"].exists)
        XCTAssertTrue(app.buttons["quem tem as palavras tem o saldo"].exists || app.staticTexts["quem tem as palavras tem o saldo"].exists)
        shot("revelar-ciente", app)
    }

    /// Observar: colar ou digitar, a rede aparece com o logo, o botao libera.
    func testWatchAddress() {
        let app = launch("observar")
        XCTAssertTrue(app.staticTexts["Observar um endereço"].waitForExistence(timeout: 20))
        shot("observar-vazio", app)
        let input = app.descendants(matching: .any).matching(identifier: "campo-endereco").firstMatch
        XCTAssertTrue(input.exists)
        input.tap()
        input.typeText("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
        XCTAssertTrue(app.staticTexts["Endereço EVM"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(app.buttons["Observar"].isEnabled)
        shot("observar-evm", app)
    }
}
