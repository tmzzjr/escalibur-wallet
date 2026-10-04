import SwiftUI

/// A ilustracao das telas de envelope: uma corrente de blocos e o envelope.
///
/// Ao lacrar, os blocos correm na corrente e o da vez cai dentro do envelope aberto,
/// deixando na corrente a marca vazia do elo. Ao abrir, eles saem do envelope e
/// ocupam as marcas. O bloco da vez fica roxo, e o seguinte embaralha os bits como
/// quem calcula o hash. No fim, a corrente desacelera ate parar: lacrado, a aba fecha
/// com o selo e so ficam as marcas; aberto, a corrente fica inteira e um bloco fica
/// de fora do envelope. Desenho chapado, sem brilho; com Reduzir Movimento, um quadro
/// parado.
struct EnvelopeChain: View {
    enum Mode: Equatable { case idle, working, sealed, opened }
    enum Direction { case inward, outward }

    let mode: Mode
    var direction: Direction = .inward
    var height: CGFloat = 236

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock: Clock
    /// Depois da transicao final nada mais se move: a linha do tempo para.
    @State private var settled = false

    init(mode: Mode, direction: Direction = .inward, height: CGFloat = 236) {
        self.mode = mode
        self.direction = direction
        self.height = height
        var clock = Clock(period: Self.period(for: mode))
        if Self.isFinal(mode) { clock.settle = Clock.Settle(from: 0, to: 0, start: .distantPast, duration: 0.25) }
        _clock = State(initialValue: clock)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || settled)) { timeline in
            Canvas { context, size in
                let scale = min(size.width / G.width, size.height / G.height)
                context.translateBy(x: (size.width - G.width * scale) / 2, y: (size.height - G.height * scale) / 2)
                context.scaleBy(x: scale, y: scale)
                draw(context, frame(at: timeline.date))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .onChange(of: mode) { _, new in
            let now = Date()
            let current = clock.phase(at: now)
            if Self.isFinal(new) {
                // Desacelera ate o proximo bloco inteiro, com a mesma velocidade de
                // partida que a corrente tinha.
                let target = current.rounded(.up)
                let duration = min(max(2 * (target - current) * clock.period, 0.25), 1.1)
                clock.settle = Clock.Settle(from: current, to: target, start: now, duration: duration)
            } else {
                clock.settle = nil
                clock.anchorPhase = current
                clock.anchorTime = now
                clock.period = Self.period(for: new)
            }
            clock.changedAt = now
        }
        .task(id: mode) {
            settled = false
            guard Self.isFinal(mode) else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { settled = true }
        }
        .accessibilityHidden(true)
    }

    private static func isFinal(_ mode: Mode) -> Bool { mode == .sealed || mode == .opened }

    private static func period(for mode: Mode) -> Double {
        switch mode {
        case .working: return 0.95
        // Parado, o ciclo conta a historia inteira: entra um bloco, a aba fecha, o
        // cadeado tranca, destranca e a aba abre para o proximo.
        case .idle: return 5.2
        default: return 2.4
        }
    }

    /// Fracao do ciclo parado em que a corrente anda e o bloco cai; o resto e do
    /// envelope fechando e trancando.
    private static let idleTravel = 0.46

    // MARK: Tempo

    struct Clock {
        struct Settle {
            var from: Double
            var to: Double
            var start: Date
            var duration: Double
        }

        var anchorPhase = 0.0
        var anchorTime = Date()
        var period: Double
        var changedAt = Date()
        var settle: Settle?

        func phase(at date: Date) -> Double {
            if let settle {
                let t = min(max(date.timeIntervalSince(settle.start) / settle.duration, 0), 1)
                return settle.from + (settle.to - settle.from) * (1 - (1 - t) * (1 - t))
            }
            return anchorPhase + date.timeIntervalSince(anchorTime) / period
        }
    }

    /// Um quadro: `p` e a fracao do ciclo (0 = bloco da vez no centro da corrente),
    /// `loop` numera os ciclos para cada bloco manter os proprios bits.
    struct Frame {
        var p: Double
        var loop: Int
        var time: Double
        var since: Double
    }

    private func frame(at date: Date) -> Frame {
        if reduceMotion { return Frame(p: 0.3, loop: 0, time: 0, since: 10) }
        let phase = clock.phase(at: date)
        let loop = Int(phase.rounded(.down))
        let fraction = phase - Double(loop)
        let since = settled ? 10 : date.timeIntervalSince(clock.changedAt)
        let time = date.timeIntervalSinceReferenceDate
        switch direction {
        case .inward: return Frame(p: fraction, loop: loop, time: time, since: since)
        case .outward: return Frame(p: 1 - fraction, loop: -loop, time: time, since: since)
        }
    }

    // MARK: Geometria

    /// Tudo desenhado num quadro de 280 por 196 e escalado para caber.
    private enum G {
        static let width: CGFloat = 280
        static let height: CGFloat = 196
        static let cx: CGFloat = 140
        static let chainY: CGFloat = 16
        static let block: CGFloat = 22
        static let spacing: CGFloat = 44
        static let left: CGFloat = 66
        static let right: CGFloat = 214
        static let top: CGFloat = 92
        static let bottom: CGFloat = 190
        static let radius: CGFloat = 8
        static let flapOpen: CGFloat = 46
        static let flapClosed: CGFloat = 58
        static let pocketApex: CGFloat = top + 50
        static let dropTarget: CGFloat = pocketApex + 26
        /// Fracao do ciclo que o bloco leva para cair (ou subir).
        static let fall: Double = 0.55
        static let line = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
    }

    // MARK: Desenho

    private func draw(_ context: GraphicsContext, _ whole: Frame) {
        let story = mode == .idle && !reduceMotion
        // Na historia do modo parado, a corrente e a queda usam so o comeco do ciclo.
        var f = whole
        if story { f.p = min(whole.p / Self.idleTravel, 1) }
        let sealing = mode == .sealed ? smooth(f.since / 0.4) : 0
        let opening = mode == .opened ? smooth(f.since / 0.5) : 0
        var flap = mode == .sealed ? -1 + 2 * smooth((f.since - 0.2) / 0.45) : -1
        let sealPop = mode == .sealed ? backOut((f.since - 0.62) / 0.4) : 0
        let rise = mode == .opened ? easeOut((f.since - 0.15) / 0.65) : 0
        let travelling = (1 - sealing) * (1 - opening)
        // Parado: fecha, tranca, segura, destranca e abre.
        var lockPop = sealPop
        var shackle = mode == .sealed ? smooth((f.since - 0.9) / 0.18) : 0
        var lockFade = 1.0
        if story {
            let t = whole.p
            flap = -1 + 2 * smooth((t - 0.5) / 0.08) - 2 * smooth((t - 0.9) / 0.07)
            lockPop = backOut((t - 0.58) / 0.07)
            shackle = smooth((t - 0.67) / 0.035)
            lockFade = 1 - smooth((t - 0.84) / 0.05)
        }

        drawChain(context, f, sealing: sealing, opening: opening)

        // O envelope da um leve assentar quando um bloco termina de entrar (ou sai).
        let kickT = (f.p - G.fall) / 0.2
        let kick = travelling > 0.5 && kickT > 0 && kickT < 1 ? sin(.pi * kickT) : 0
        var envelope = context
        if kick > 0 {
            envelope.translateBy(x: G.cx, y: G.bottom)
            envelope.scaleBy(x: 1 + 0.012 * kick, y: 1 - 0.03 * kick)
            envelope.translateBy(x: -G.cx, y: -G.bottom)
        }

        let outline = Path(roundedRect: CGRect(x: G.left, y: G.top, width: G.right - G.left, height: G.bottom - G.top),
                           cornerRadius: G.radius, style: .continuous)

        if flap < 0 {
            let path = flapPath(flap)
            envelope.fill(path, with: .color(Palette.rail))
            envelope.stroke(path, with: .color(Palette.ink), style: G.line)
        }
        envelope.fill(outline, with: .color(Palette.body))
        // A borda de cima do fundo fica atras do bloco que passa pela boca.
        envelope.stroke(outline, with: .color(Palette.ink), style: G.line)

        // O bloco da vez, entre o fundo e o bolso da frente.
        if travelling > 0.01, f.p < G.fall {
            var falling = envelope
            falling.opacity = travelling
            let q = f.p / G.fall
            drawBlock(falling, at: CGPoint(x: G.cx, y: fallY(q)), scale: 1 - 0.2 * q, bits: bits(f.loop), accent: 1)
        }
        if rise > 0 {
            let y = G.dropTarget + (G.top - 10 - G.dropTarget) * rise
            drawBlock(envelope, at: CGPoint(x: G.cx, y: y), scale: 0.8 + 0.45 * rise, bits: bits(f.loop), accent: 1)
        }

        var pocket = envelope
        pocket.clip(to: outline)
        var front = Path()
        front.move(to: CGPoint(x: G.left - 2, y: G.top))
        front.addLine(to: CGPoint(x: G.cx, y: G.pocketApex))
        front.addLine(to: CGPoint(x: G.right + 2, y: G.top))
        front.addLine(to: CGPoint(x: G.right + 2, y: G.bottom + 2))
        front.addLine(to: CGPoint(x: G.left - 2, y: G.bottom + 2))
        front.closeSubpath()
        pocket.fill(front, with: .color(Palette.control))
        var folds = Path()
        folds.move(to: CGPoint(x: G.left, y: G.bottom))
        folds.addLine(to: CGPoint(x: G.cx, y: G.pocketApex + 20))
        folds.addLine(to: CGPoint(x: G.right, y: G.bottom))
        pocket.stroke(folds, with: .color(Palette.edgeStrong), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        pocket.stroke(vee(depth: G.pocketApex - G.top), with: .color(Palette.ink), style: G.line)
        // O bolso cobre a metade de dentro da borda: ela volta por cima, menos na boca.
        var rim = envelope
        rim.clip(to: front)
        rim.stroke(outline, with: .color(Palette.ink), style: G.line)

        if flap > 0 {
            // Fechada, a aba tem a base na borda de cima: so as duas diagonais tem
            // traco, para nao dobrar a linha da borda.
            var closed = envelope
            closed.clip(to: outline)
            let depth = G.flapClosed * flap
            var cover = vee(depth: depth)
            cover.closeSubpath()
            closed.fill(cover, with: .color(Palette.control))
            closed.stroke(vee(depth: depth), with: .color(Palette.ink), style: G.line)
            envelope.stroke(outline, with: .color(Palette.ink), style: G.line)
        }

        if lockPop > 0.01, lockFade > 0.01, flap > 0.5 {
            var lock = envelope
            lock.opacity = lockFade
            lock.translateBy(x: G.cx, y: G.top + G.flapClosed)
            // O estalo: o corpo cresce um pouco no instante em que a alca encaixa.
            let click = 1 + 0.1 * sin(.pi * clamp((shackle - 0.6) / 0.4))
            lock.scaleBy(x: lockPop * click, y: lockPop * click)
            drawPadlock(lock, shackle: shackle)
        }
    }

    /// Cadeado com buraco de fechadura, centrado na origem: corpo branco, alca que
    /// desce e encaixa (`shackle` de 0, aberta, a 1, trancada).
    private func drawPadlock(_ context: GraphicsContext, shackle: Double) {
        let body = CGRect(x: -13, y: -6, width: 26, height: 21)
        // A alca: um arco com as duas pernas; aberta, sobe e a perna direita sai do corpo.
        let lift = CGFloat(1 - shackle) * 7
        var arch = Path()
        arch.move(to: CGPoint(x: -7.5, y: -4 - lift * 0.4))
        arch.addLine(to: CGPoint(x: -7.5, y: -11 - lift))
        arch.addArc(center: CGPoint(x: 0, y: -11 - lift), radius: 7.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        arch.addLine(to: CGPoint(x: 7.5, y: -4 - lift))
        context.stroke(arch, with: .color(Palette.ink), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
        context.fill(Path(roundedRect: body, cornerRadius: 5, style: .continuous), with: .color(Palette.ink))
        var keyhole = Path(ellipseIn: CGRect(x: -3, y: 0, width: 6, height: 6))
        keyhole.move(to: CGPoint(x: -1.6, y: 4.5))
        keyhole.addLine(to: CGPoint(x: 1.6, y: 4.5))
        keyhole.addLine(to: CGPoint(x: 2.3, y: 11))
        keyhole.addLine(to: CGPoint(x: -2.3, y: 11))
        keyhole.closeSubpath()
        context.fill(keyhole, with: .color(Palette.void))
    }

    private func fallY(_ q: Double) -> CGFloat {
        G.chainY + (G.dropTarget - G.chainY) * q * q
    }

    /// As duas diagonais que partem dos cantos de cima e se encontram no centro.
    private func vee(depth: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: G.left - 2, y: G.top - 2 * depth / (G.cx - G.left)))
        path.addLine(to: CGPoint(x: G.cx, y: G.top + depth))
        path.addLine(to: CGPoint(x: G.right + 2, y: G.top - 2 * depth / (G.right - G.cx)))
        return path
    }

    /// A aba aberta, apontando para cima; `f` vai de -1 (toda aberta) a 0.
    private func flapPath(_ f: Double) -> Path {
        // A base nasce no meio do arco do canto, para a aba nao sobrar alem dele.
        let inset = G.radius * 0.29
        var path = Path()
        path.move(to: CGPoint(x: G.left + inset, y: G.top + inset))
        path.addLine(to: CGPoint(x: G.cx, y: G.top + G.flapOpen * f))
        path.addLine(to: CGPoint(x: G.right - inset, y: G.top + inset))
        path.closeSubpath()
        return path
    }

    /// A corrente. Cada posicao tem uma marca vazia (o elo que ficou) e um bloco
    /// cheio; a mistura das duas conta a historia: a esquerda do centro, marcas de
    /// quem ja entrou; a direita, a fila. Lacrado, a fila vira marca; aberto, as
    /// marcas viram bloco.
    private func drawChain(_ context: GraphicsContext, _ f: Frame, sealing: Double, opening: Double) {
        let half = G.block / 2
        let imprint = f.p < G.fall ? clamp(f.p / G.fall * 3) : 1
        let slots: [(x: CGFloat, ghost: Double, real: Double, i: Int)] = (-4...5).map { i in
            let x = G.cx + (CGFloat(i) - f.p) * G.spacing
            var ghost: Double = i < 0 ? 1 : (i == 0 ? imprint : 0)
            var real: Double = i > 0 ? 1 : 0
            if i >= 0 { ghost = max(ghost, sealing) }
            real *= 1 - sealing
            if i <= 0 {
                ghost *= 1 - opening
                real = max(real, opening)
            }
            return (x, ghost, real, i)
        }

        var rail = Path()
        rail.move(to: CGPoint(x: 6, y: G.chainY))
        rail.addLine(to: CGPoint(x: G.width - 6, y: G.chainY))
        context.stroke(rail, with: .linearGradient(
            Gradient(stops: [
                .init(color: Palette.edgeStrong.opacity(0), location: 0),
                .init(color: Palette.edgeStrong, location: 0.3),
                .init(color: Palette.edgeStrong, location: 0.7),
                .init(color: Palette.edgeStrong.opacity(0), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: G.chainY), endPoint: CGPoint(x: G.width, y: G.chainY)
        ), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 5]))

        for (a, b) in zip(slots, slots.dropFirst()) {
            var link = Path()
            link.move(to: CGPoint(x: a.x + half + 3, y: G.chainY))
            link.addLine(to: CGPoint(x: b.x - half - 3, y: G.chainY))
            let fade = min(edgeFade(a.x), edgeFade(b.x))
            let solid = min(a.real, b.real)
            let hollow = max(min(a.ghost + a.real, b.ghost + b.real) - solid, 0)
            var ink = context
            ink.opacity = fade * solid
            ink.stroke(link, with: .color(Palette.inkMuted), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            var dim = context
            dim.opacity = fade * hollow
            dim.stroke(link, with: .color(Palette.edgeStrong), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }

        // O elo com o bloco que cai estica e some; ao abrir, ele se refaz.
        let travelling = (1 - sealing) * (1 - opening)
        if travelling > 0.01, f.p < G.fall {
            let q = f.p / G.fall
            var link = Path()
            link.move(to: CGPoint(x: slots[5].x - half - 3, y: G.chainY))
            link.addLine(to: CGPoint(x: G.cx + half * (1 - 0.2 * q), y: fallY(q)))
            var stretched = context
            stretched.opacity = travelling * (1 - clamp(q * 2.2))
            stretched.stroke(link, with: .color(Palette.inkMuted), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }

        for slot in slots {
            let fade = edgeFade(slot.x)
            if slot.ghost > 0.01 {
                var ghost = context
                ghost.opacity = fade * slot.ghost * (1 - slot.real)
                let rect = CGRect(x: slot.x - half, y: G.chainY - half, width: G.block, height: G.block)
                ghost.stroke(Path(roundedRect: rect, cornerRadius: 6, style: .continuous), with: .color(Palette.edgeStrong),
                             style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            if slot.real > 0.01 {
                // O proximo da fila vai ficando roxo ao chegar no centro; antes
                // disso, embaralha os bits.
                let accent = slot.i == 1 ? smooth((f.p - 0.55) / 0.45) * (1 - opening) : 0
                let id = f.loop + slot.i
                let scrambling = slot.i == 1 && accent == 0 && travelling > 0.5
                let rate = mode == .working ? 16.0 : 3.0
                let value = scrambling ? bits(id, salt: Int((f.time * rate).rounded(.down))) : bits(id)
                var block = context
                block.opacity = fade * slot.real
                drawBlock(block, at: CGPoint(x: slot.x, y: G.chainY), scale: 1, bits: value, accent: accent)
            }
        }
    }

    private func drawBlock(_ context: GraphicsContext, at center: CGPoint, scale k: CGFloat, bits: UInt16, accent a: Double) {
        guard context.opacity > 0.01 else { return }
        let side = G.block * k
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let shape = Path(roundedRect: rect, cornerRadius: 6 * k, style: .continuous)
        context.fill(shape, with: .color(Palette.body))
        if a > 0 { context.fill(shape, with: .color(Palette.purple.opacity(a))) }
        if a < 1 { context.stroke(shape, with: .color(Palette.inkSoft.opacity(1 - a)), lineWidth: 1.5) }
        if a > 0 { context.stroke(shape, with: .color(Palette.purple.opacity(a)), lineWidth: 1.5) }

        let cell = 4 * k
        let gap = 2 * k
        let span = cell * 3 + gap * 2
        for row in 0..<3 {
            for column in 0..<3 {
                let on = bits & (1 << (row * 3 + column)) != 0
                let square = CGRect(x: center.x - span / 2 + CGFloat(column) * (cell + gap),
                                    y: center.y - span / 2 + CGFloat(row) * (cell + gap), width: cell, height: cell)
                let path = Path(roundedRect: square, cornerRadius: 1.2 * k)
                if on {
                    context.fill(path, with: .color(Palette.ink))
                } else {
                    if a < 1 { context.fill(path, with: .color(Palette.edgeStrong.opacity(1 - a))) }
                    if a > 0 { context.fill(path, with: .color(Palette.purpleDeep.opacity(a))) }
                }
            }
        }
    }

    // MARK: Apoio

    /// Nove bits por bloco, estaveis pelo numero do bloco; `salt` embaralha.
    private func bits(_ id: Int, salt: Int = 0) -> UInt16 {
        var x = UInt64(bitPattern: Int64(id &* 0x9E37_79B1 &+ salt &* 0x85EB_CA6B))
        x ^= x >> 33
        x &*= 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 33
        x &*= 0xC4CE_B9FE_1A85_EC53
        x ^= x >> 33
        let value = UInt16(truncatingIfNeeded: x) & 0x1FF
        // Nunca um bloco vazio nem cheio: os dois parecem erro de desenho.
        return value == 0 || value == 0x1FF ? 0x0AA : value
    }

    private func edgeFade(_ x: CGFloat) -> Double {
        1 - smooth((abs(x - G.cx) - 92) / 40)
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    private func smooth(_ x: Double) -> Double {
        let t = clamp(x)
        return t * t * (3 - 2 * t)
    }

    private func easeOut(_ x: Double) -> Double {
        let t = clamp(x)
        return 1 - (1 - t) * (1 - t) * (1 - t)
    }

    /// Passa um pouco do tamanho final e volta: o selo "carimbado".
    private func backOut(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        let t = clamp(x) - 1
        let c1 = 1.70158
        return 1 + (c1 + 1) * t * t * t + c1 * t * t
    }
}
