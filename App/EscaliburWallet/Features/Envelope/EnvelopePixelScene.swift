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
    /// No "Guardar num envelope" (pedido do dono, 16/10/2026): aberto, o envelope desenhado
    /// como papel; ao fechar, sem fresta nas bordas, ele vira pixels. No "Como funciona", todo
    /// em pixels desde o comeco.
    var pixelOnClose = false
    /// Lacrando um envelope de verdade (`SealEnvelopeFlow`): sem laco, a historia anda com o
    /// lacre. Enquanto o app faz a conta da senha, as palavras cifram no alto; gravando, elas
    /// caem no envelope; lacrado, a aba fecha, o envelope vira pixels, o cadeado se monta e o
    /// anel acende, e a cena para assim. Nil: o laco das telas de explicar.
    var stage: Stage? = nil

    enum Stage: Equatable { case working, writing, sealed }

    /// Onde a historia estava quando a etapa mudou, e quando: a cena segue dali.
    @State private var anchor: (t: Double, at: Date) = (0, Date())
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
        static let flapFrom = 2.45
        static let flapTime = 0.45
        static let sealFrom = 2.95
        static let ringFrom = 3.15
        /// Com `pixelOnClose`: o envelope fechado vira pixels, e o cadeado vem depois.
        static let pixelFrom = 2.9
        static let pixelTime = 0.45
        static let pixelDelay = 0.3
        static let ringTime = 0.45
        static let fadeFrom = 6.0
    }

    /// Quanto o envelope fechado sobe: do pe da cena ate o centro dela.
    static let liftHeight: CGFloat = 54

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? T.fadeFrom - 0.3 : storyTime(at: timeline.date)
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
        .onAppear {
            start = Date()
            anchor = (0, Date())
        }
        .onChange(of: stage) { _, _ in
            let now = Date()
            anchor = (storyTime(at: now), now)
        }
        .accessibilityHidden(true)
    }

    /// O tempo da historia: em laco nas telas de explicar; no lacre, andando de onde parou
    /// ate o teto da etapa (no lacrado, o fim, sem esmaecer).
    private func storyTime(at now: Date) -> Double {
        guard let stage else { return now.timeIntervalSince(start).truncatingRemainder(dividingBy: T.period) }
        let cap: Double
        switch stage {
        case .working: cap = T.breakFrom - 0.1
        case .writing: cap = T.flapFrom - 0.05
        case .sealed: cap = T.fadeFrom - 0.05
        }
        return min(cap, anchor.t + now.timeIntervalSince(anchor.at))
    }

    private func draw(_ context: inout GraphicsContext, t: Double, clock: Double) {
        // Tudo some junto no fim do laco e nasce de novo no comeco.
        context.opacity = min(Self.smooth(t / 0.35), 1 - Self.smooth((t - T.fadeFrom) / (T.period - T.fadeFrom)))
        // No lacre, fechado, o envelope sobe ate o centro da cena: sem as palavras e sem a aba
        // aberta, o alto ficava vazio (pedido do dono, 16/10/2026). Nas telas de explicar ele
        // fica parado depois de fechar (pedido do dono, no mesmo dia).
        if stage != nil {
            let lift = CGFloat(Self.easeInOut((t - T.flapFrom - T.flapTime - 0.05) / 0.55)) * Self.liftHeight
            context.translateBy(x: 0, y: -lift)
        }
        if pixelOnClose {
            // Fechado, uma linha varre o envelope da esquerda para a direita, e por onde ela
            // passa o papel vira pixel: antes os dois desenhos se sobrepunham, esmaecendo
            // juntos (pedido do dono, 16/10/2026).
            let p = reduceMotion ? 1 : Self.easeInOut((t - T.pixelFrom) / T.pixelTime)
            let sweep = G.envelope.minX - 8 + (G.envelope.width + 16) * CGFloat(p)
            if p < 1 {
                var solid = context
                if p > 0 { solid.clip(to: Path(CGRect(x: sweep, y: 0, width: G.width, height: G.height))) }
                drawSolid(&solid, t: t, clock: clock)
                drawChips(&context, t: t, clock: clock)
            }
            if p > 0 { drawEnvelope(&context, closing: 1, clock: clock, wipe: p < 1 ? sweep : nil) }
            drawLock(&context, t: t - T.pixelDelay)
            drawRing(&context, t: t - T.pixelDelay)
            return
        }
        let closing = reduceMotion ? 1 : Self.easeInOut((t - T.flapFrom) / T.flapTime)
        drawEnvelope(&context, closing: closing, clock: clock)
        drawPixels(&context, t: t, clock: clock)
        drawChips(&context, t: t, clock: clock)
        drawLock(&context, t: t)
        drawRing(&context, t: t)
    }

    /// O envelope de papel: o fundo, a aba aberta atras das palavras que caem, o bolso da
    /// frente e a aba que fecha por cima.
    private func drawSolid(_ context: inout GraphicsContext, t: Double, clock: Double) {
        let flap = CGFloat(-1 + 2 * Self.easeInOut((t - T.flapFrom) / T.flapTime))
        let envelope = Path(roundedRect: G.envelope, cornerRadius: 14, style: .continuous)
        context.fill(envelope, with: .color(Palette.rail))
        context.stroke(envelope, with: .color(Palette.edgeStrong), lineWidth: 1)
        if flap < 0 { drawFlap(&context, scale: flap) }
        drawPixels(&context, t: t, clock: clock)
        let pocket = PocketShape().path(in: G.envelope)
        context.fill(pocket, with: .color(Palette.control))
        context.stroke(pocket, with: .color(Palette.edgeStrong), lineWidth: 1)
        if flap >= 0 { drawFlap(&context, scale: flap) }
    }

    /// A aba: -1 aberta para cima, 1 fechada sobre o envelope. Os cantos dela seguem os
    /// cantos arredondados do envelope: fechada, encaixa sem fresta; aberta, nao sobra quina
    /// para fora (pedido do dono, 16/10/2026).
    private func drawFlap(_ context: inout GraphicsContext, scale: CGFloat) {
        var layer = context
        layer.translateBy(x: 0, y: G.envelope.minY)
        layer.scaleBy(x: 1, y: max(abs(scale), 0.02) * (scale < 0 ? -1 : 1))
        let rect = CGRect(x: G.envelope.minX, y: 0, width: G.envelope.width, height: G.flapHeight)
        let r: CGFloat = 14
        var path = Path()
        if scale >= 0 {
            // Fechada: os cantos de cima sao os do envelope, e ela encaixa sem fresta.
            path.move(to: CGPoint(x: rect.minX + r, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: r), control: CGPoint(x: rect.maxX, y: 0))
            path.addQuadCurve(to: CGPoint(x: rect.midX + 14, y: rect.maxY - 6), control: CGPoint(x: rect.midX + 40, y: rect.maxY * 0.72))
            path.addQuadCurve(to: CGPoint(x: rect.midX - 14, y: rect.maxY - 6), control: CGPoint(x: rect.midX, y: rect.maxY + 4))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: r), control: CGPoint(x: rect.midX - 40, y: rect.maxY * 0.72))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: 0), control: CGPoint(x: rect.minX, y: 0))
        } else {
            // Aberta: a dobra e reta e vai so pelo trecho reto da borda de cima, sem quina
            // para fora nem dente entre a aba e o envelope. A troca de forma acontece com a aba
            // de lado, quando ela e uma linha.
            path.move(to: CGPoint(x: rect.minX + r, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
            path.addQuadCurve(to: CGPoint(x: rect.midX + 14, y: rect.maxY - 6), control: CGPoint(x: rect.midX + 36, y: rect.maxY * 0.72))
            path.addQuadCurve(to: CGPoint(x: rect.midX - 14, y: rect.maxY - 6), control: CGPoint(x: rect.midX, y: rect.maxY + 4))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: 0), control: CGPoint(x: rect.midX - 36, y: rect.maxY * 0.72))
        }
        path.closeSubpath()
        layer.fill(path, with: .linearGradient(Gradient(colors: [Palette.edgeStrong, Palette.control]),
                                               startPoint: CGPoint(x: rect.midX, y: 0), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        layer.stroke(path, with: .color(Palette.edgeStrong), lineWidth: 1)
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
    /// uma passada de luz que corre devagar. A aba dobra na borda de cima como papel: aberta
    /// para cima, achata na dobra e desce sobre o envelope (`closing`, de 0 a 1). Antes a aba
    /// aberta sumia linha por linha e a fechada nascia no lugar (visto pelo dono, 16/10/2026).
    private func drawEnvelope(_ context: inout GraphicsContext, closing: Double, clock: Double, wipe: CGFloat? = nil) {
        let columns = G.columns, rows = G.rows, flapRows = G.flapRows
        let fold = CGPoint(x: G.envelope.midX, y: G.envelope.minY + G.envelope.height * 0.5)
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
                let pocketFold = Self.distance(center, CGPoint(x: G.envelope.minX, y: G.envelope.minY), fold) < G.grid * 0.6
                    || Self.distance(center, CGPoint(x: G.envelope.maxX, y: G.envelope.minY), fold) < G.grid * 0.6
                let bit = Self.tone(id, clock: clock)
                var tone = 0.13 + 0.16 * bit
                if edge { tone = 0.4 + 0.14 * bit } else if pocketFold { tone = 0.3 + 0.1 * bit }
                tone += light(center)
                // Na varredura, so ate a linha; os pixels logo atras dela acendem mais.
                if let wipe {
                    guard center.x < wipe else { continue }
                    let near = Double(max(0, 1 - (wipe - center.x) / 18))
                    tone += 0.35 * near
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 1.1), with: .color(PixelFill.gray(tone)))
            }
        }
        // A aba: cada pixel na sua distancia da dobra, multiplicada pela abertura (-1 aberta
        // para cima, 0 achatada na dobra, 1 fechada), e achatado junto, como papel virando.
        let turn = CGFloat(-1 + 2 * closing)
        let squash = max(abs(turn), 0.08)
        for row in 0..<flapRows {
            let half = (1 - (CGFloat(row) + 0.5) / CGFloat(flapRows)) * G.envelope.width / 2 + G.grid * 0.5
            for column in 0..<columns {
                let home = cell(column, row)
                let offCenter = abs(home.midX - G.envelope.midX)
                guard offCenter <= half else { continue }
                let rect = CGRect(x: home.minX, y: G.envelope.minY + (home.midY - G.envelope.minY) * turn - home.height * squash / 2,
                                  width: home.width, height: home.height * squash)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let rim = offCenter > half - G.grid * 1.2
                let bit = Self.tone(7000 + column * 40 + row, clock: clock)
                var tone = (rim ? 0.4 + 0.14 * bit : 0.2 + 0.16 * bit) + light(center)
                if let wipe {
                    guard center.x < wipe else { continue }
                    tone += 0.35 * Double(max(0, 1 - (wipe - center.x) / 18))
                }
                context.fill(Path(roundedRect: rect, cornerRadius: min(1.1, rect.height / 2)), with: .color(PixelFill.gray(tone)))
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

struct PocketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.5))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
