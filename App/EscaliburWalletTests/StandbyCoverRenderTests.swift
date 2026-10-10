import SwiftUI
import Testing
@testable import EscaliburWallet

/// So com ESCALIBUR_FOTOS: desenha a capa do seletor de apps num PNG, para conferir.
@MainActor
struct StandbyCoverRenderTests {
    @Test func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["ESCALIBUR_FOTOS"] else { return }
        let renderer = ImageRenderer(content: StandbyCover().frame(width: 402, height: 874))
        renderer.scale = 2
        let data = try #require(renderer.uiImage?.pngData())
        try data.write(to: URL(fileURLWithPath: "\(dir)/capa.png"))
    }
}
