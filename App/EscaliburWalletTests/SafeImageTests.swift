import Foundation
import Testing
import UIKit
@testable import EscaliburWallet

/// A logo baixada so abre se for PNG ou JPEG de verdade, de tamanho razoavel.
@MainActor
struct SafeImageTests {
    func image(_ width: Int, _ height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func pngAndJpegOpenReduced() throws {
        let png = try #require(image(1024, 1024).pngData())
        let opened = try #require(SafeImage.decode(png))
        #expect(max(opened.size.width, opened.size.height) <= 256)
        let jpeg = try #require(image(64, 64).jpegData(compressionQuality: 0.8))
        #expect(SafeImage.decode(jpeg) != nil)
    }

    @Test func otherFormatsAndGiantsRefused() throws {
        let gif = try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        #expect(SafeImage.decode(gif) == nil)
        let giant = try #require(image(3000, 8).pngData())
        #expect(SafeImage.decode(giant) == nil)
        #expect(SafeImage.decode(Data("nao e imagem".utf8)) == nil)
        // Cabecalho de PNG com lixo atras: os bytes magicos passam, o ImageIO nao.
        #expect(SafeImage.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x41, count: 64)) == nil)
    }
}
