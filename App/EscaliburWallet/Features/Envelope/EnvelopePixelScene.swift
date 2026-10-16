import SwiftUI

/// "A senha da carteira entra no envelope", em pixels (pedido do dono, 16/10/2026, no lugar
/// da corrente de blocos): tres palavras ja cifradas se desfazem em pixels cinza que
/// cifram, como os do `SlideToConfirm`, e caem pela boca do envelope. O envelope inteiro e de
/// pixels que cifram ao vivo, para nao parecer papel que qualquer um abre (pedido do dono,
/// 16/10/2026): a aba fecha descendo linha por linha, sem fresta nas bordas, um cadeado de
/// pixels se monta no meio, e um anel de pixels acende em verde em volta dele, em ordem,
/// como o da checagem do aparelho. Em laco.
/// Nenhuma palavra de verdade: os glifos sao os do `EnvelopeCipherCard`. Com Reduzir
/// Movimento, o envelope trancado, parado.
struct EnvelopePixelScene: View {
    var height: CGFloat = 236
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    /// O desenho num quadro fixo, escalado para caber.
    private enum G {
        static let width: CGFloat = 300
        static let height: CGFloat = 236
        static let envelope = CGRect(x: 60, y: 120, width: 180, height: 104)
        static let flapHeight: CGFloat = 104 * 0.58
        static let mouth = CGPoint(x: 150, y: 166)
        static let seal = CGPoint(x: 150, y: 178)
        static let chipSize = CGSize(width: 82, height: 30)
        static let chips: [CGFloat] = [21, 109, 197]
        static let chipY: CGFloat = 16
        static let cell: CGFloat = 5
        static let pitch: CGFloat = 6.6
        static let ring = 28
        /// A grade do envelope: um pixel a cada 6 pontos.
        static let grid: CGFloat = 6
        static let gridCell: CGFloat = 4.6
        static var columns: Int { Int(envelope.width / grid) }
        static var rows: Int { Int(envelope.height / grid) }
        /// Quantas linhas a aba tem, da borda de cima ate a ponta.
        static var flapRows: Int { Int((flapHeight / grid).rounded()) }
        /// O cadeado em pixels: arco em cima, corpo embaixo, o buraco da chave no meio.
        static let lock = ["..#####..", ".##...##.", ".#.....#.", ".#.....#.", "#########",
                           "#########", "####.####", "####.####", "#########", "#########"]
    }

    /// A historia, em segundos dentro do laco.
    private enum T {
        static let period = 6.6
        static let breakFrom = 0.7
        static let breakStep = 0.32
        static let flight = 0.75
        static let flapFrom = 2.75
        static let flapTime = 0.45
        static let sealFrom = 3.25
        static let ringFrom = 3.45
        static let ringTime = 0.45
        static let fadeFrom = 6.0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? T.fadeFrom - 0.3 : timeline.date.timeIntervalSince(start).truncatingRemainder(dividingBy: T.period)
            let clock = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let scale = min(size.width / G.width, size.height / G.height)
                context.translateBy(x: (size.width - G.width * scale) / 2, y: (size.height - G.height * scale) / 2)
                context.scaleBy(x: scale, y: scale)
                draw(&context, t: t, clock: clock)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, t: Double, clock: Double) {
        // Tudo some junto no fim do laco e nasce de novo no comeco.
        context.opacity = min(Self.smooth(t / 0.35), 1 - Self.smooth((t - T.fadeFrom) / (T.period - T.fadeFrom)))
        let closing = reduceMotion ? 1 : Self.easeInOut((t - T.flapFrom) / T.flapTime)
        drawEnvelope(&context, closing: closing, clock: clock)
        drawPixels(&context, t: t, clock: clock)
        drawChips(&context, t: t, clock: clock)
        drawLock(&context, t: t)
        drawRing(&context, t: t)
    }

    /// Um pixel da grade do envelope, na coluna e na linha dadas (linha negativa: acima da
    /// borda de cima, onde fica a aba aberta).
    private func cell(_ column: Int, _ row: Int) -> CGRect {
        let inset = (G.grid - G.gridCell) / 2
        return CGRect(x: G.envelope.minX + CGFloat(column) * G.grid + inset, y: G.envelope.minY + CGFloat(row) * G.grid + inset,
                      width: G.gridCell, height: G.gridCell)
    }

    /// Distancia, em pontos, do centro de um pixel ate a reta de a ate b.
    private static func distance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let u = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)))
        return hypot(point.x - (a.x + u * dx), point.y - (a.y + u * dy))
    }

    /// O envelope de pixels, cifrando ao vivo: o corpo, a borda e as dobras mais claras, e
    /// uma passada de luz que corre devagar. A aba aberta fica acima e some de cima para
    /// baixo enquanto a fechada desce, linha por linha, ate a ponta (`closing`, de 0 a 1).
    private func drawEnvelope(_ context: inout GraphicsContext, closing: Double, clock: Double) {
        let columns = G.columns, rows = G.rows, flapRows = G.flapRows
        let left = CGPoint(x: G.envelope.minX + G.grid / 2, y: G.envelope.minY + G.grid / 2)
        let right = CGPoint(x: G.envelope.maxX - G.grid / 2, y: G.envelope.minY + G.grid / 2)
        let fold = CGPoint(x: G.envelope.midX, y: G.envelope.minY + G.envelope.height * 0.5)
        let tip = CGPoint(x: G.envelope.midX, y: G.envelope.minY + CGFloat(flapRows) * G.grid)
        let shown = Int((closing * Double(flapRows)).rounded(.up))
        let sweep = CGFloat((clock / 2.2).truncatingRemainder(dividingBy: 1)) * (G.envelope.width + 80) + G.envelope.minX - 40
        func light(_ center: CGPoint) -> Double {
            let d = Double((center.x - sweep + (center.y - G.envelope.minY) * 0.5) / 18)
            return 0.14 * exp(-d * d)
        }
        for column in 0..<columns {
            for row in 0..<rows {
                let rect = cell(column, row)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let id = 5000 + column * rows + row
                let edge = column == 0 || column == columns - 1 || row == 0 || row == rows - 1
                // 1 na borda de cima, 0 na ponta: a aba cobre a largura inteira em cima, sem fresta.
                let depth = (tip.y - center.y) / (tip.y - G.envelope.minY)
                let inFlap = row < shown && depth >= -0.05 && abs(center.x - G.envelope.midX) <= depth * G.envelope.width / 2 + G.grid * 0.5
                let flapEdge = inFlap && (Self.distance(center, left, tip) < G.grid * 0.7 || Self.distance(center, right, tip) < G.grid * 0.7)
                let pocketFold = !inFlap && (Self.distance(center, CGPoint(x: G.envelope.minX, y: G.envelope.minY), fold) < G.grid * 0.6
                    || Self.distance(center, CGPoint(x: G.envelope.maxX, y: G.envelope.minY), fold) < G.grid * 0.6)
                let bit = Self.tone(id, clock: clock)
                var tone = (inFlap ? 0.2 : 0.13) + 0.16 * bit
                if edge || flapEdge { tone = 0.4 + 0.14 * bit } else if pocketFold { tone = 0.3 + 0.1 * bit }
                tone += light(center)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.1), with: .color(PixelFill.gray(tone)))
            }
        }
        // A aba aberta, acima da borda: some de cima para baixo enquanto a fechada desce.
        let hidden = Int((closing * Double(flapRows)).rounded(.down))
        let openTip = CGPoint(x: G.envelope.midX, y: G.envelope.minY - CGFloat(flapRows) * G.grid)
        for row in 1...flapRows where row > hidden {
            let y = G.envelope.minY - CGFloat(row) * G.grid + G.grid / 2
            let half = (y - openTip.y) / (G.envelope.minY - openTip.y) * (G.envelope.width / 2)
            for column in 0..<columns {
                let rect = cell(column, -row)
                guard abs(rect.midX - G.envelope.midX) <= half else { continue }
                let rim = abs(rect.midX - G.envelope.midX) > half - G.grid
                let bit = Self.tone(7000 + column * 40 + row, clock: clock)
                let tone = (rim ? 0.4 + 0.14 * bit : 0.18 + 0.14 * bit) + light(CGPoint(x: rect.midX, y: rect.midY))
                context.fill(Path(roundedRect: rect, cornerRadius: 1.1), with: .color(PixelFill.gray(tone)))
            }
        }
    }

    /// As tres palavras cifradas no alto, que somem quando viram pixels.
    private func drawChips(_ context: inout GraphicsContext, t: Double, clock: Double) {
        let tick = UInt64(max(clock * 12, 0))
        for (index, x) in G.chips.enumerated() {
            let breakAt = T.breakFrom + Double(index) * T.breakStep
            let alpha = 1 - Self.smooth((t - breakAt) / 0.22)
            guard alpha > 0.01 else { continue }
            var chip = context
            chip.opacity *= alpha
            let rect = CGRect(origin: CGPoint(x: x, y: G.chipY), size: G.chipSize)
            let shape = Path(roundedRect: rect, cornerRadius: 9, style: .continuous)
            chip.fill(shape, with: .color(Palette.void))
            chip.stroke(shape, with: .color(Palette.edgeStrong), lineWidth: 1)
            chip.draw(Text(verbatim: "\(index + 1)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundColor(Palette.inkMuted),
                      at: CGPoint(x: rect.minX + 12, y: rect.midY), anchor: .center)
            chip.draw(Text(verbatim: EnvelopeCipherCard.glyphs(index, tick: tick)).font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(Palette.inkSoft),
                      at: CGPoint(x: rect.minX + 24, y: rect.midY), anchor: .leading)
        }
    }

    /// Cada palavra vira uma grade de pixels que cifram e voam ate a boca do envelope.
    private func drawPixels(_ context: inout GraphicsContext, t: Double, clock: Double) {
        let columns = Int(G.chipSize.width / G.pitch), rows = Int(G.chipSize.height / G.pitch)
        for (index, x) in G.chips.enumerated() {
            let breakAt = T.breakFrom + Double(index) * T.breakStep
            guard t > breakAt - 0.05 else { continue }
            for column in 0..<columns {
                for row in 0..<rows {
                    let id = index * 100 + column * rows + row
                    let delay = PixelFill.noise(id, 7, 0x3C1) * 0.35
                    let p = Self.smooth((t - breakAt - delay) / T.flight)
                    guard p < 0.999 else { continue }
                    let from = CGPoint(x: x + 4 + CGFloat(column) * G.pitch, y: G.chipY + 2 + CGFloat(row) * G.pitch)
                    let spread = CGFloat(PixelFill.noise(id, 11, 0x5A) - 0.5) * 36
                    let to = CGPoint(x: G.mouth.x + spread, y: G.mouth.y)
                    // Uma curva: sobe um pouco, depois cai para dentro.
                    let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 10)
                    let u = CGFloat(p)
                    let point = CGPoint(x: (1 - u) * (1 - u) * from.x + 2 * (1 - u) * u * control.x + u * u * to.x,
                                        y: (1 - u) * (1 - u) * from.y + 2 * (1 - u) * u * control.y + u * u * to.y)
                    let side = G.cell * (1 - 0.35 * u)
                    let tone = 0.22 + 0.32 * Self.tone(id, clock: clock) + 0.2 * Double(1 - u)
                    context.fill(Path(roundedRect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), cornerRadius: 1.2),
                                 with: .color(PixelFill.gray(tone).opacity(p < 0.02 ? 0 : 1)))
                }
            }
        }
    }

    /// O cadeado de pixels, que se monta no meio depois que a aba fecha, sobre um disco escuro.
    private func drawLock(_ context: inout GraphicsContext, t: Double) {
        let p = Self.easeOut((t - T.sealFrom) / 0.25)
        guard p > 0 else { return }
        var lock = context
        lock.opacity *= p
        let radius: CGFloat = 23
        lock.fill(Path(ellipseIn: CGRect(x: G.seal.x - radius, y: G.seal.y - radius, width: radius * 2, height: radius * 2)),
                  with: .color(Palette.void))
        let pitch: CGFloat = 3.6, side: CGFloat = 3.0
        let rows = G.lock.count, columns = G.lock[0].count
        let origin = CGPoint(x: G.seal.x - CGFloat(columns) * pitch / 2, y: G.seal.y - CGFloat(rows) * pitch / 2)
        for (row, line) in G.lock.enumerated() {
            for (column, mark) in line.enumerated() where mark == "#" {
                // Cada pixel chega no seu instante: o cadeado se monta, nao aparece pronto.
                let arrive = T.sealFrom + PixelFill.noise(column, row, 0x10C) * 0.3
                guard t >= arrive || reduceMotion else { continue }
                let rect = CGRect(x: origin.x + CGFloat(column) * pitch, y: origin.y + CGFloat(row) * pitch, width: side, height: side)
                lock.fill(Path(roundedRect: rect, cornerRadius: 0.6), with: .color(Palette.ink))
            }
        }
    }

    /// O anel de pixels em volta do cadeado, acendendo em verde em ordem: trancado e conferido.
    private func drawRing(_ context: inout GraphicsContext, t: Double) {
        guard t > T.sealFrom else { return }
        for index in 0..<G.ring {
            let angle = Double(index) / Double(G.ring) * 2 * .pi - .pi / 2
            let point = CGPoint(x: G.seal.x + 34 * CGFloat(cos(angle)), y: G.seal.y + 34 * CGFloat(sin(angle)))
            let litAt = T.ringFrom + Double(index) / Double(G.ring) * T.ringTime
            let lit = t >= litAt
            let flash = lit ? exp(-max(t - litAt, 0) * 6) : 0
            let side: CGFloat = 4.6 + 1.6 * CGFloat(flash)
            let square = Path(roundedRect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), cornerRadius: 1.2)
            context.fill(square, with: .color(lit ? Palette.success : PixelFill.gray(0.2)))
            if flash > 0.02 { context.fill(square, with: .color(.white.opacity(0.5 * flash))) }
        }
    }

    /// O tom cifrado de um pixel agora, de 0 a 1, trocando no compasso dele.
    private static func tone(_ id: Int, clock: Double) -> Double {
        let phase = PixelFill.noise(id, 3, 0x77)
        let beat = clock * 7 * (0.6 + 0.8 * phase) + phase * 8
        let step = beat.rounded(.down)
        let blend = smooth(beat - step)
        let a = PixelFill.noise(id, 3, Int(step)), b = PixelFill.noise(id, 3, Int(step) + 1)
        return a + (b - a) * blend
    }

    private static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func easeOut(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return 1 - (1 - t) * (1 - t) * (1 - t)
    }

    private static func easeInOut(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
