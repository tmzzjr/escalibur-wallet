import XCTest

/// Cada teste e uma cena do site: abre a Escalibur Wallet no modo demo (carteira publica
/// de teste do BIP-39, PIN de teste), espera a tela assentar e faz o gesto que o site
/// mostra. `gravar.sh` grava a tela do simulador enquanto o teste roda e corta o video
/// entre as marcas `inicio` e `fim` que o teste escreve. A marca `capa`, quando existe,
/// e o quadro que melhor resume a cena: o video comeca nele (o laco gira) e ele vira a
/// imagem que aparece antes de o video tocar.
///
/// Regra: nenhuma cena passa pela tela das palavras da carteira.
final class Cenas: XCTestCase {
    private var marcas: String? { ProcessInfo.processInfo.environment["GRAVACAO_MARCAS"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Apoio

    private func abrir(_ tela: String?) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "app.escalibur.wallet")
        app.launchArguments = ["-demo"] + (tela.map { ["-tela", $0] } ?? [])
        app.launch()
        return app
    }

    private func marcar(_ nome: String) {
        guard let marcas else { return }
        let linha = "\(nome) \(Date().timeIntervalSince1970)\n"
        if let arquivo = FileHandle(forWritingAtPath: marcas) {
            arquivo.seekToEndOfFile()
            arquivo.write(Data(linha.utf8))
            try? arquivo.close()
        } else {
            try? linha.write(toFile: marcas, atomically: true, encoding: .utf8)
        }
    }

    private func pausa(_ segundos: Double) {
        Thread.sleep(forTimeInterval: segundos)
    }

    private func texto(_ app: XCUIApplication, comecando prefixo: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefixo)).firstMatch
    }

    private func esperar(_ elemento: XCUIElement, _ segundos: Double = 60, _ mensagem: String = "") {
        XCTAssertTrue(elemento.waitForExistence(timeout: segundos), mensagem)
    }

    /// Arrasto lento, como dedo de gente: o XCUITest arrasta rapido demais para o olho.
    private func arrastar(_ app: XCUIApplication, de: CGVector, para: CGVector, segurar: Double = 0.05, velocidade: XCUIGestureVelocity = 600) {
        let janela = app.windows.firstMatch
        let inicio = janela.coordinate(withNormalizedOffset: de)
        let fim = janela.coordinate(withNormalizedOffset: para)
        inicio.press(forDuration: segurar, thenDragTo: fim, withVelocity: velocidade, thenHoldForDuration: 0.1)
    }

    /// O pedido de notificacao do iOS (o aviso de recebimento pede na primeira abertura)
    /// nao pode aparecer no video: aceito antes de comecar.
    private func aceitarAvisos() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for rotulo in ["Permitir", "Allow"] {
            let botao = springboard.buttons[rotulo]
            if botao.waitForExistence(timeout: 1.5) { botao.tap(); return }
        }
    }

    private func tocar(_ elemento: XCUIElement, _ segundos: Double = 20) {
        esperar(elemento, segundos, "nao achei \(elemento)")
        elemento.tap()
    }

    /// Digita como gente, uma tecla por vez.
    private func digitar(_ campo: XCUIElement, _ texto: String) {
        for letra in texto {
            campo.typeText(String(letra))
            pausa(0.28)
        }
    }

    // MARK: Cenas

    /// Carteira: esconder e mostrar os valores, e a pagina de um ativo.
    func testCarteira() throws {
        let app = abrir(nil)
        aceitarAvisos()
        let xrp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'XRP,'")).firstMatch
        // O "esconder valores" fica gravado entre aberturas: a cena comeca com eles a mostra.
        if app.buttons["Mostrar valores"].waitForExistence(timeout: 3) { app.buttons["Mostrar valores"].tap() }
        esperar(xrp, 90)
        pausa(8)
        marcar("inicio")
        pausa(1.8)
        tocar(app.buttons["Ocultar valores"]); pausa(1.6)
        tocar(app.buttons["Mostrar valores"]); pausa(1.6)
        xrp.tap()
        pausa(4.2)
        tocar(app.buttons["Voltar"].firstMatch, 5)
        pausa(2.2)
        marcar("fim")
    }

    /// Receber: da carteira ate o QR do bitcoin, e copiar o endereco.
    func testReceber() throws {
        let app = abrir(nil)
        aceitarAvisos()
        esperar(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'USDT,'")).firstMatch, 90)
        pausa(8)
        marcar("inicio")
        pausa(1.5)
        tocar(app.buttons["Receber"])
        pausa(1.8)
        tocar(app.buttons["BTC, Bitcoin"])
        esperar(texto(app, comecando: "Receber BTC"), 30)
        pausa(1.0)
        marcar("capa")
        pausa(1.2)
        tocar(app.buttons["Copiar endereço"])
        pausa(2.6)
        marcar("fim")
    }

    /// Trocar: XRP por RLUSD no livro do XRP Ledger, com a cotacao chegando.
    func testTrocar() throws {
        let app = abrir("trocar")
        aceitarAvisos()
        let rede = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rede:'")).firstMatch
        esperar(rede, 60)
        pausa(4)
        marcar("inicio")
        pausa(1.4)
        rede.tap()
        pausa(1.0)
        tocar(app.buttons["XRP Ledger"].firstMatch, 10)
        pausa(1.4)
        let campo = app.textFields.firstMatch
        tocar(campo)
        pausa(0.6)
        digitar(campo, "250")
        esperar(texto(app, comecando: "Nova cotação"), 40, "a cotacao nao chegou")
        pausa(1.6)
        tocar(app.buttons["Pronto"], 5)
        pausa(1.0)
        marcar("capa")
        pausa(1.8)
        marcar("fim")
    }

    /// Ordem limite: o preco acima do atual e o prazo.
    func testLimite() throws {
        let app = abrir("limite-xrp")
        aceitarAvisos()
        esperar(app.buttons["Revisar ordem"], 60)
        pausa(4)
        marcar("inicio")
        pausa(1.4)
        tocar(app.buttons["+5%"]); pausa(1.6)
        tocar(app.buttons["+10%"]); pausa(1.6)
        tocar(app.buttons["30 dias"]); pausa(1.6)
        tocar(app.buttons["Até cancelar"]); pausa(1.6)
        tocar(app.buttons["7 dias"]); pausa(1.0)
        tocar(app.buttons["Atual"]); pausa(1.8)
        marcar("fim")
    }

    /// Revisao: os enderecos e contratos na placa clara, conferidos antes de assinar.
    func testRevisao() throws {
        let app = abrir("revisao")
        aceitarAvisos()
        let enderecos = app.buttons["revisao-enderecos"]
        esperar(enderecos, 60)
        pausa(3)
        marcar("inicio")
        pausa(1.6)
        enderecos.tap()
        pausa(1.2)
        marcar("capa")
        pausa(3.8)
        marcar("fim")
    }

    /// Enviando: a moeda indo da carteira para o destino.
    func testEnviando() throws {
        let app = abrir("envio-enviando")
        aceitarAvisos()
        esperar(texto(app, comecando: "Enviando"), 60)
        pausa(2)
        marcar("inicio")
        pausa(6)
        marcar("fim")
    }

    /// Enviado: a moeda girando e a confirmacao da rede.
    func testEnviado() throws {
        let app = abrir("enviado")
        aceitarAvisos()
        esperar(texto(app, comecando: "Enviado"), 60)
        pausa(2)
        marcar("inicio")
        pausa(6)
        marcar("fim")
    }

    /// Pagina da moeda: o dedo correndo o grafico e os periodos.
    func testMoeda() throws {
        let app = abrir("moeda")
        aceitarAvisos()
        esperar(app.buttons["7 dias"], 60)
        pausa(6)
        marcar("inicio")
        pausa(1.4)
        let janela = app.windows.firstMatch
        let inicio = janela.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.36))
        let fim = janela.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.36))
        inicio.press(forDuration: 0.5, thenDragTo: fim, withVelocity: 110, thenHoldForDuration: 0.6)
        pausa(1.2)
        tocar(app.buttons["7 dias"]); pausa(2.2)
        tocar(app.buttons["30 dias"]); pausa(2.2)
        tocar(app.buttons["24h"]); pausa(2.0)
        marcar("fim")
    }

    /// Alertas de preco: ligar e ver o que o iPhone confere sozinho. O pedido de
    /// notificacao do iOS sai antes da gravacao: liga, aceita, desliga, e so entao marca.
    func testAlertas() throws {
        let app = abrir("alertas")
        aceitarAvisos()
        let chave = app.switches["alertas-ligar"]
        esperar(chave, 60)
        pausa(1.5)
        if (chave.value as? String) == "0" {
            chave.tap()
            aceitarAvisos()
            pausa(2)
        }
        chave.tap()
        pausa(3)
        marcar("inicio")
        pausa(1.6)
        chave.tap()
        pausa(1.4)
        marcar("capa")
        pausa(2.6)
        marcar("fim")
    }

    /// Antes de comecar: a cifra viva em volta do iPhone.
    func testPromessa() throws {
        let app = abrir("promessa")
        aceitarAvisos()
        esperar(texto(app, comecando: "Sua carteira"), 60)
        pausa(3)
        marcar("inicio")
        pausa(9)
        marcar("fim")
    }

    /// Envelope: o bloco entra, a aba fecha e o cadeado tranca, em ciclo.
    func testEnvelope() throws {
        let app = abrir("lacrar")
        aceitarAvisos()
        esperar(texto(app, comecando: "Guardar num envelope"), 60)
        pausa(3)
        marcar("inicio")
        pausa(12)
        marcar("fim")
    }

    /// Mercado: a lista por relevancia, rolada devagar.
    func testMercado() throws {
        let app = abrir("mercado")
        aceitarAvisos()
        esperar(app.buttons["Relevância"].firstMatch, 60)
        pausa(6)
        marcar("inicio")
        pausa(1.6)
        arrastar(app, de: CGVector(dx: 0.5, dy: 0.80), para: CGVector(dx: 0.5, dy: 0.40), velocidade: 240)
        pausa(1.8)
        arrastar(app, de: CGVector(dx: 0.5, dy: 0.36), para: CGVector(dx: 0.5, dy: 0.80), velocidade: 240)
        pausa(2.0)
        marcar("fim")
    }

    /// Ponte: USDC da Base para a Arbitrum pelo CCTP, rapida e padrao. A carteira de teste
    /// nao tem USDC na Base: a tela diz isso, como diria a qualquer um.
    func testPonte() throws {
        let app = abrir("ponte")
        aceitarAvisos()
        let padrao = app.buttons["Padrão"].firstMatch
        esperar(padrao, 60)
        pausa(5)
        marcar("inicio")
        pausa(1.8)
        padrao.tap(); pausa(2.4)
        tocar(app.buttons["Rápida"].firstMatch); pausa(2.2)
        marcar("fim")
    }

    // MARK: Conferencia do site no Safari do simulador (nao grava video)

    /// `SAFARI_URL` aberta no Safari e fotografada tela a tela em `SAFARI_FOTOS`, rolando
    /// de cima a baixo (`SAFARI_TELAS` capturas). Serve para olhar o site no celular de
    /// verdade, com os videos tocando, antes de publicar.
    func testSafari() throws {
        let ambiente = ProcessInfo.processInfo.environment
        guard let endereco = ambiente["SAFARI_URL"], let url = URL(string: endereco), let pasta = ambiente["SAFARI_FOTOS"] else {
            throw XCTSkip("sem SAFARI_URL e SAFARI_FOTOS")
        }
        let telas = Int(ambiente["SAFARI_TELAS"] ?? "12") ?? 12
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        XCUIDevice.shared.system.open(url)
        pausa(4)
        for rotulo in ["Close", "Fechar", "Not Now", "Agora Não", "Continue", "Continuar"] {
            let botao = safari.buttons[rotulo].firstMatch
            if botao.exists && botao.isHittable { botao.tap(); pausa(0.5) }
        }
        pausa(2)
        for indice in 0..<telas {
            let nome = String(format: "%@/%02d.png", pasta, indice)
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: nome))
            arrastar(safari, de: CGVector(dx: 0.5, dy: 0.78), para: CGVector(dx: 0.5, dy: 0.22), velocidade: 1200)
            pausa(2.2)
        }
    }

    // MARK: Exploracao (nao grava): a arvore de acessibilidade de uma tela

    func testExplorar() throws {
        let ambiente = ProcessInfo.processInfo.environment
        let app = abrir(ambiente["EXPLORAR_TELA"].flatMap { $0.isEmpty ? nil : $0 })
        pausa(Double(ambiente["EXPLORAR_ESPERA"] ?? "20") ?? 20)
        // `EXPLORAR_TOQUES`: rotulos de botao, separados por "|", tocados em ordem.
        for rotulo in (ambiente["EXPLORAR_TOQUES"] ?? "").split(separator: "|").map(String.init) where !rotulo.isEmpty {
            let botao = app.buttons[rotulo].firstMatch
            if botao.waitForExistence(timeout: 20) { botao.tap() }
            pausa(4)
        }
        if let saida = ambiente["EXPLORAR_SAIDA"] {
            try app.debugDescription.write(toFile: saida, atomically: true, encoding: .utf8)
        }
    }
}
