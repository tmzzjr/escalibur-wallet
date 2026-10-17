import CoreGraphics
import XCTest

/// A camada segura contra captura (docs/seguranca.md §7, pedido do dono, 16/10/2026): na
/// chapa das 12 palavras, a captura de tela nao pode ter as letras. A mesma medida, com a
/// camada desligada (`-sem-camada-segura`, so na depuracao), precisa ver as letras: sem
/// isso o teste nao estaria medindo nada.
///
/// A medida: no lugar de cada palavra, quanto da regiao e letra gravada (escura) e quanto e
/// metal (claro). Letra no metal tem as duas coisas; metal liso so tem claro; um retangulo
/// preto no lugar da camada so tem escuro. Nos dois ultimos casos a palavra nao esta la.
final class CaptureShieldTests: XCTestCase {
    var shots: String? { ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] }

    override func setUp() {
        continueAfterFailure = false
    }

    func testPlateWordsLeaveTheScreenshot() {
        let open = plateLetters(arguments: ["-sem-camada-segura"], name: "camada-desligada")
        XCTAssertGreaterThan(open.mean, 0.08, "sem a camada, a medida deveria ver as letras (\(open)): o teste nao esta medindo")
        let shielded = plateLetters(arguments: [], name: "camada-ligada")
        XCTAssertLessThan(shielded.max, 0.02,
                          "com a camada, a captura ainda mostra letras (\(shielded)). Se no aparelho ela sai vazia, o simulador e que nao respeita a marca de captura")
    }

    /// Abre a chapa com as 12 palavras e mede as letras no lugar de cada uma: a media e a
    /// maior das 12.
    private func plateLetters(arguments: [String], name: String) -> (mean: Double, max: Double) {
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-demo", "-tela", "palavras"] + arguments
        app.launch()
        defer { app.terminate() }
        let all = app.buttons["ver-todas-palavras"]
        XCTAssertTrue(all.waitForExistence(timeout: 30), "a tela das palavras nao abriu")
        all.tap()
        XCTAssertTrue(app.buttons["copiar-palavras"].waitForExistence(timeout: 5), "a chapa nao abriu")
        // A chapa entra com uma mola: espera assentar.
        sleep(1)
        var frames: [CGRect] = []
        for index in 1...12 {
            let word = app.staticTexts["palavra-\(index)"].firstMatch
            XCTAssertTrue(word.waitForExistence(timeout: 5), "a palavra \(index) sumiu da acessibilidade")
            // A camada tira a palavra da captura, nao do VoiceOver.
            XCTAssertFalse(word.label.isEmpty, "o VoiceOver deveria ler a palavra \(index)")
            frames.append(word.frame)
        }
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots { try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png")) }
        guard let image = shot.image.cgImage else {
            XCTFail("a captura nao tem imagem")
            return (0, 0)
        }
        let scale = shot.image.scale
        let values = frames.map { Self.letters(in: image, at: $0, scale: scale) }
        return (values.reduce(0, +) / Double(values.count), values.max() ?? 0)
    }

    /// Na regiao (em pontos), a menor das duas fracoes: pixels escuros (letra gravada, ou um
    /// retangulo preto) e pixels claros (metal). Perto de zero, nao tem letra.
    static func letters(in image: CGImage, at frame: CGRect, scale: CGFloat) -> Double {
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 2, pixels.height >= 2, let crop = image.cropping(to: pixels) else { return 0 }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var dark = 0, light = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let luminance = (0.2126 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1]) + 0.0722 * Double(bytes[offset + 2])) / 255
            if luminance < 0.45 { dark += 1 } else if luminance > 0.55 { light += 1 }
        }
        let total = Double(width * height)
        return min(Double(dark) / total, Double(light) / total)
    }
}
