import SwiftUI

/// Um cofre de pixels (pedido do dono, 16/10/2026, para a carteira com passphrase): a caixa
/// e a porta redonda em pixels cinza que cifram, como os do `PixelFill`; o volante gira um
/// terco de volta e os quatro pinos da tranca saem da porta, trancando; depois volta, e
/// tranca de novo. Diz "outra carteira, trancada por algo que so voce sabe" sem texto. Com
/// Reduzir Movimento, o cofre trancado, parado.
struct PixelVault: View {
    var size: CGFloat = 112
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period = 4.2
    private static let pitch: CGFloat = 4.6
    private static let cell: CGFloat = 3.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let now = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let t = reduceMotion ? 1.2 : now.truncatingRemainder(dividingBy: Self.period)
            // Trancando: o volante gira e os pinos saem; no fim do laco, destranca devagar.
            let locking = Self.ease(t / 0.9)
            let unlocking = Self.ease((t - (Self.period - 0.8)) / 0.8)
            let locked = locking * (1 - unlocking)
            Canvas { context, canvas in
                let scale = min(canvas.width, canvas.height) / 112
                context.scaleBy(x: scale, y: scale)
                draw(&context, locked: locked, clock: now)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, locked: Double, clock: Double) {
        let center = CGPoint(x: 56, y: 56)
        func pixel(_ point: CGPoint, tone: Double, side: CGFloat = Self.cell) {
            context.fill(Path(roundedRect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), cornerRadius: 0.8),
                         with: .color(PixelFill.gray(tone)))
        }
        // A caixa: um quadrado de pixels, com a borda mais clara.
        let half: CGFloat = 50
        var index = 0
        var y = center.y - half
        while y <= center.y + half + 0.1 {
            var x = center.x - half
            while x <= center.x + half + 0.1 {
                let point = CGPoint(x: x, y: y)
                let distance = hypot(x - center.x, y - center.y)
                let edge = abs(x - center.x) > half - Self.pitch || abs(y - center.y) > half - Self.pitch
                // O espaco da porta fica de fora: ela e desenhada por cima.
                if distance > 38 {
                    let bit = Self.tone(index, 1, clock)
                    pixel(point, tone: edge ? 0.4 + 0.12 * bit : 0.15 + 0.12 * bit)
                }
                index += 1
                x += Self.pitch
            }
            y += Self.pitch
        }
        // A porta: dois aneis, o de fora mais claro.
        for (ring, radius, count, base) in [(0, 35.0, 44, 0.46), (1, 29.0, 36, 0.24)] as [(Int, CGFloat, Int, Double)] {
            for step in 0..<count {
                let angle = Double(step) / Double(count) * 2 * .pi
                let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
                pixel(point, tone: base + 0.12 * Self.tone(step, 10 + ring, clock))
            }
        }
        // Os pinos da tranca: saem da porta para dentro da caixa quando tranca.
        for side in 0..<4 {
            let angle = Double(side) * .pi / 2
            for depth in 0..<3 {
                let radius = 39 + CGFloat(depth) * Self.pitch * CGFloat(locked)
                let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
                pixel(point, tone: 0.55 + 0.3 * locked)
            }
        }
        // O volante: tres raios que giram um terco de volta ao trancar, e o cubo no meio.
        let turn = locked * 2 * .pi / 3
        for spoke in 0..<3 {
            let angle = Double(spoke) / 3 * 2 * .pi + turn - .pi / 2
            for step in 1...5 {
                let radius = CGFloat(step) * Self.pitch
                let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
                pixel(point, tone: 0.72 + 0.2 * Self.tone(spoke * 8 + step, 20, clock))
            }
            // A pega na ponta de cada raio.
            let tip = CGPoint(x: center.x + 26 * CGFloat(cos(angle)), y: center.y + 26 * CGFloat(sin(angle)))
            pixel(tip, tone: 0.92, side: 4.6)
        }
        pixel(center, tone: 0.95, side: 6)
    }

    /// O tom cifrado de um pixel agora, de 0 a 1, no compasso dele.
    private static func tone(_ index: Int, _ layer: Int, _ clock: Double) -> Double {
        let phase = PixelFill.noise(index, layer, 0x7A1)
        let beat = clock * 5 * (0.6 + 0.8 * phase) + phase * 8
        let step = beat.rounded(.down)
        let t = beat - step
        let blend = t * t * (3 - 2 * t)
        let a = PixelFill.noise(index, layer, Int(step)), b = PixelFill.noise(index, layer, Int(step) + 1)
        return a + (b - a) * blend
    }

    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
