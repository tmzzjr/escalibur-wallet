import SwiftUI

/// O selo das telas onde se digita um segredo: o cadeado no meio de dois aneis de pixels
/// cinza que cifram, o mesmo desenho do preenchimento do `SlideToConfirm` (`PixelFill`).
/// Cada pixel troca de tom no seu compasso, e uma passada mais clara gira devagar pelos
/// aneis. Pequeno e calmo de proposito: diz "isto aqui esta cifrado" sem chamar mais
/// atencao que o campo (pedido do dono, 16/10/2026).
struct CipherEmblem: View {
    var size: CGFloat = 88
    var symbol = "lock.fill"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rings: [(count: Int, inset: CGFloat)] = [(40, 5), (30, 14)]
    private static let cell: CGFloat = 4.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { timeline in
            let clock = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvas in
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                let pass = (clock / 2.6).truncatingRemainder(dividingBy: 1) * 2 * .pi
                for (ring, shape) in Self.rings.enumerated() {
                    let radius = min(canvas.width, canvas.height) / 2 - shape.inset
                    for index in 0..<shape.count {
                        let angle = Double(index) / Double(shape.count) * 2 * .pi - .pi / 2
                        let phase = PixelFill.noise(index, ring, 0x51ED)
                        let beat = clock * 5 * (0.6 + 0.8 * phase) + phase * 8
                        let step = beat.rounded(.down)
                        let t = beat - step
                        let blend = t * t * (3 - 2 * t)
                        let a = PixelFill.noise(index, ring, Int(step)), b = PixelFill.noise(index, ring, Int(step) + 1)
                        let bit = a + (b - a) * blend
                        var distance = abs(angle + .pi / 2 - pass)
                        distance = min(distance, 2 * .pi - distance)
                        let glow = exp(-(distance / 0.55) * (distance / 0.55))
                        let tone = 0.2 + 0.28 * bit + 0.38 * glow * (ring == 0 ? 1 : 0.7)
                        let x = center.x + radius * CGFloat(cos(angle)), y = center.y + radius * CGFloat(sin(angle))
                        let square = CGRect(x: x - Self.cell / 2, y: y - Self.cell / 2, width: Self.cell, height: Self.cell)
                        context.fill(Path(roundedRect: square, cornerRadius: 1.2), with: .color(PixelFill.gray(tone)))
                    }
                }
            }
        }
        .overlay {
            Circle().fill(Palette.control).frame(width: size * 0.5, height: size * 0.5)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.2, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A tela de espera com o selo: o cofre abrindo depois do PIN. Cobre o que estava por
/// baixo (a checagem do aparelho, com o deslizar ja usado) ate a tela seguinte chegar
/// (pedido do dono, 16/10/2026), como em "Abrindo as palavras".
struct CipherWorking: View {
    let title: String

    var body: some View {
        VStack(spacing: Space.md) {
            Spacer()
            CipherEmblem()
            Text(title).typeStyle(.heading).foregroundStyle(Palette.ink)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.void.ignoresSafeArea())
        .transition(.opacity)
    }
}
