import SwiftUI

/// A abertura: a espada cravada na pedra. Escalibur e a Excalibur da lenda, a espada que
/// so o dono de direito tira da pedra, que e o que a tela promete: uma carteira que so
/// voce abre. O painel e o rosa do icone e a espada e a dele, para o app abrir como
/// continuacao do icone. A pedra e grafite, como o resto do app.
///
/// Ao aparecer, a espada cai de ponta e crava: a pedra nao tem furo antes dela, o
/// painel treme de leve com o golpe e o iPhone da um toque firme. Depois, um brilho
/// corre a espada de tempos em tempos, como metal polido. Com Reduzir Movimento, a
/// espada ja esta cravada e nada se mexe.
struct SwordInStone: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false
    @State private var jolt: CGFloat = 0
    /// Depois do golpe: o encaixe e o contato aparecem so quando a espada chega.
    @State private var seated = false

    /// Onde a lamina entra na pedra, em fracao da altura do painel.
    nonisolated static let entryY: CGFloat = 0.695

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // Luz de cima: o rosa do icone no alto, um tom abaixo junto da pedra.
                LinearGradient(colors: [Color(hex: 0xFF2E92), Palette.brand, Color(hex: 0xDE006B)],
                               startPoint: .top, endPoint: .bottom)
                Canvas { context, size in Self.drawStone(context, size) }
                Canvas { context, size in
                    // O encaixe: um fio de sombra de cada lado da lamina, que cobre o meio.
                    context.fill(Path(ellipseIn: SwordGeometry(size).slot), with: .color(Stone.slot))
                }
                .opacity(seated ? 1 : 0)
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !landed)) { timeline in
                    Canvas { context, size in
                        Self.drawSword(context, size, glint: reduceMotion ? nil : Self.glintPhase(timeline.date))
                    }
                }
                .offset(y: landed ? 0 : -size.height)
                // A lamina some na borda da frente do encaixe: dali para baixo esta dentro
                // da pedra, e o furo nao aparece por baixo dela.
                .mask {
                    Canvas { context, size in
                        let slot = SwordGeometry(size).slot
                        var visible = Path(CGRect(x: 0, y: 0, width: size.width, height: slot.midY))
                        visible.addEllipse(in: slot)
                        context.fill(visible, with: .color(.black))
                    }
                }
                // A borda da pedra na frente da lamina pega a luz, e a lamina escurece
                // onde entra: o contato que diz que ela esta cravada, e nao apoiada.
                Canvas { context, size in Self.drawSeat(context, size) }
                    .opacity(seated ? 1 : 0)
            }
            .offset(y: jolt)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityHidden(true)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: seated) { _, new in new && !reduceMotion }
        // A espada nunca falta: se a tela sai no meio da queda, ou a queda e cortada, ela
        // volta ja cravada.
        .onDisappear {
            landed = true
            seated = true
        }
        .task {
            guard !landed else { return }
            if reduceMotion { landed = true; seated = true; return }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { landed = true; seated = true; return }
            // Cai acelerando e para seco na pedra; o painel desce um tico e volta.
            withAnimation(.easeIn(duration: 0.34)) { landed = true }
            do { try await Task.sleep(nanoseconds: 340_000_000) } catch { seated = true; return }
            seated = true
            jolt = 4
            withAnimation(.spring(response: 0.22, dampingFraction: 0.32)) { jolt = 0 }
        }
    }

    /// O brilho passa pela lamina em 1,1 s a cada 4,5 s; fora disso, nil.
    static func glintPhase(_ date: Date) -> CGFloat? {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.5)
        let pass = 1.1
        return cycle < pass ? CGFloat(cycle / pass) : nil
    }

    // MARK: Pedra

    private enum Stone {
        static let top = Color(hex: 0x3A3A40)
        static let left = Palette.control
        static let middle = Palette.rail
        static let middleCut = Color(hex: 0x19191C)
        static let edge = Color(hex: 0x5A5A62)
        static let right = Color(hex: 0x141417)
        static let slot = Palette.void
    }

    /// Pedra lapidada: face de cima clara (luz de cima) e tres faces da frente, que
    /// descem alem da borda do painel.
    static func drawStone(_ context: GraphicsContext, _ size: CGSize) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
        func poly(_ points: [CGPoint]) -> Path {
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            return path
        }
        let bottom: CGFloat = 1.05
        context.fill(poly([p(0.20, 0.705), p(0.42, 0.765), p(0.38, bottom), p(0.08, bottom)]), with: .color(Stone.left))
        context.fill(poly([p(0.42, 0.765), p(0.74, 0.752), p(0.80, bottom), p(0.38, bottom)]), with: .color(Stone.middle))
        // Um corte na face do meio, para a pedra parecer lapidada e nao um bloco.
        context.fill(poly([p(0.58, 0.759), p(0.74, 0.752), p(0.80, bottom), p(0.63, bottom)]), with: .color(Stone.middleCut))
        context.fill(poly([p(0.74, 0.752), p(0.83, 0.688), p(0.94, bottom), p(0.80, bottom)]), with: .color(Stone.right))
        context.fill(poly([p(0.20, 0.705), p(0.35, 0.645), p(0.63, 0.636), p(0.83, 0.688), p(0.74, 0.752), p(0.42, 0.765)]),
                     with: .color(Stone.top))
        // A aresta da frente da face de cima pega a luz.
        var edge = Path()
        edge.addLines([p(0.20, 0.705), p(0.42, 0.765), p(0.74, 0.752), p(0.83, 0.688)])
        context.stroke(edge, with: .color(Stone.edge), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    // MARK: Espada

    /// As medidas da espada e do encaixe, numa conta so para a pedra, a espada e o
    /// contato. Pomo, punho e guarda sao os retangulos do icone, nas proporcoes dele (o
    /// travessao tem 606 pontos no icone de 1024), so com acabamento de aco; a lamina
    /// ganha dois chanfros, nervura e canaleta, e afina ate a pedra.
    struct SwordGeometry {
        let size: CGSize
        let unit: CGFloat
        let cx: CGFloat
        let entry: CGPoint
        let pommelTop: CGFloat
        let gripTop: CGFloat
        let guardTop: CGFloat
        let bladeTop: CGFloat
        /// Largura da lamina junto da guarda (a do icone) e na entrada da pedra.
        let bladeTopWidth: CGFloat
        let bladeEntryWidth: CGFloat
        let slot: CGRect

        static let pommel = CGSize(width: 144, height: 63)
        static let grip = CGSize(width: 74, height: 147)
        static let crossguard = CGSize(width: 606, height: 51)

        init(_ size: CGSize) {
            self.size = size
            let h = size.height
            unit = h * 0.40 / 606
            cx = size.width / 2
            entry = CGPoint(x: cx, y: h * SwordInStone.entryY)
            // Mais funda que a do icone: o pomo comeca mais baixo, e mais lamina fica na pedra.
            pommelTop = h * 0.155
            gripTop = pommelTop + Self.pommel.height * unit
            guardTop = gripTop + Self.grip.height * unit
            bladeTop = guardTop + Self.crossguard.height * unit
            bladeTopWidth = 128 * unit
            bladeEntryWidth = 114 * unit
            // O encaixe tem a largura da lamina: so um fio de sombra de cada lado, para a
            // espada parecer presa na pedra, sem folga.
            let slotWidth = bladeEntryWidth + max(1.5, 3 * unit)
            let slotHeight = max(3, bladeEntryWidth * 0.2)
            slot = CGRect(x: cx - slotWidth / 2, y: entry.y - slotHeight / 2, width: slotWidth, height: slotHeight)
        }

        /// Largura da lamina numa altura, afinando ate a entrada.
        func bladeWidth(at y: CGFloat) -> CGFloat {
            let t = min(max((y - bladeTop) / max(entry.y - bladeTop, 1), 0), 1)
            return bladeTopWidth + (bladeEntryWidth - bladeTopWidth) * t
        }

        func rect(_ part: CGSize, top: CGFloat) -> CGRect {
            CGRect(x: cx - part.width * unit / 2, y: top, width: part.width * unit, height: part.height * unit)
        }
    }

    /// O metal da espada, da luz para a sombra. Aco um tom abaixo do branco: o brilho que
    /// corre por ele precisa de onde subir.
    struct Metal {
        let light: Color
        let lit: Color
        let mid: Color
        let shade: Color
        let deep: Color

        static let steel = Metal(light: Color(hex: 0xF1F1F3), lit: Color(hex: 0xD9D9DE), mid: Color(hex: 0xB0B0B8),
                                 shade: Color(hex: 0x83838C), deep: Color(hex: 0x62626B))
        static let gold = Metal(light: Color(hex: 0xFFF2BF), lit: Color(hex: 0xF3CF5E), mid: Color(hex: 0xD6A429),
                                shade: Color(hex: 0xA6761A), deep: Color(hex: 0x6B4A0D))
    }

    /// Ouro (escolha do dono, 15/10/2026). Em DEBUG, `-espada aco` mostra a de aco, para
    /// comparar.
    static let metal: Metal = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("aco") { return .steel }
        #endif
        return .gold
    }()

    static func drawSword(_ context: GraphicsContext, _ size: CGSize, glint: CGFloat?) {
        let g = SwordGeometry(size)
        let u = g.unit
        let cx = g.cx
        // A lamina segue reta abaixo da entrada e termina em ponta: e o que se ve na queda.
        // Cravada, a ponta fica dentro da pedra.
        let bottom = g.entry.y + 70 * u
        let tip = bottom + g.bladeEntryWidth * 0.9

        // Lamina: o chanfro da esquerda pega a luz, o da direita fica na sombra, e a
        // nervura no meio separa os dois.
        let leftBevel = Path { path in
            path.move(to: CGPoint(x: cx - g.bladeTopWidth / 2, y: g.bladeTop))
            path.addLine(to: CGPoint(x: cx, y: g.bladeTop))
            path.addLine(to: CGPoint(x: cx, y: tip))
            path.addLine(to: CGPoint(x: cx - g.bladeWidth(at: bottom) / 2, y: bottom))
            path.closeSubpath()
        }
        let rightBevel = Path { path in
            path.move(to: CGPoint(x: cx, y: g.bladeTop))
            path.addLine(to: CGPoint(x: cx + g.bladeTopWidth / 2, y: g.bladeTop))
            path.addLine(to: CGPoint(x: cx + g.bladeWidth(at: bottom) / 2, y: bottom))
            path.addLine(to: CGPoint(x: cx, y: tip))
            path.closeSubpath()
        }
        context.fill(leftBevel, with: .linearGradient(
            Gradient(colors: [metal.lit, metal.light]),
            startPoint: CGPoint(x: cx - g.bladeTopWidth / 2, y: 0), endPoint: CGPoint(x: cx, y: 0)))
        context.fill(rightBevel, with: .linearGradient(
            Gradient(colors: [metal.mid, metal.shade]),
            startPoint: CGPoint(x: cx, y: 0), endPoint: CGPoint(x: cx + g.bladeTopWidth / 2, y: 0)))
        // Canaleta (fuller) no primeiro terco, e a nervura dali para baixo.
        let fullerBottom = g.bladeTop + (g.entry.y - g.bladeTop) * 0.42
        let fuller = Path(roundedRect: CGRect(x: cx - 9 * u, y: g.bladeTop + 14 * u, width: 18 * u, height: fullerBottom - g.bladeTop - 14 * u),
                          cornerRadius: 9 * u)
        context.fill(fuller, with: .linearGradient(
            Gradient(colors: [metal.shade, metal.mid, metal.lit]),
            startPoint: CGPoint(x: cx - 9 * u, y: 0), endPoint: CGPoint(x: cx + 9 * u, y: 0)))
        var ridge = Path()
        ridge.move(to: CGPoint(x: cx, y: fullerBottom))
        ridge.addLine(to: CGPoint(x: cx, y: tip))
        context.stroke(ridge, with: .color(.white.opacity(0.75)), lineWidth: max(1, 2 * u))
        // Fio das bordas: a da esquerda brilha, a da direita escurece.
        var leftEdge = Path()
        leftEdge.move(to: CGPoint(x: cx - g.bladeTopWidth / 2, y: g.bladeTop))
        leftEdge.addLine(to: CGPoint(x: cx - g.bladeWidth(at: bottom) / 2, y: bottom))
        leftEdge.addLine(to: CGPoint(x: cx, y: tip))
        context.stroke(leftEdge, with: .color(.white), lineWidth: max(1, 2.5 * u))
        var rightEdge = Path()
        rightEdge.move(to: CGPoint(x: cx + g.bladeTopWidth / 2, y: g.bladeTop))
        rightEdge.addLine(to: CGPoint(x: cx + g.bladeWidth(at: bottom) / 2, y: bottom))
        rightEdge.addLine(to: CGPoint(x: cx, y: tip))
        context.stroke(rightEdge, with: .color(metal.deep), lineWidth: max(1, 2.5 * u))
        // A guarda faz sombra na lamina logo abaixo dela.
        let guardShadow = CGRect(x: cx - g.bladeTopWidth / 2, y: g.bladeTop, width: g.bladeTopWidth, height: 30 * u)
        context.fill(Path(guardShadow), with: .linearGradient(
            Gradient(colors: [.black.opacity(0.32), .black.opacity(0)]),
            startPoint: CGPoint(x: 0, y: guardShadow.minY), endPoint: CGPoint(x: 0, y: guardShadow.maxY)))

        // Pomo, punho e guarda: os retangulos do icone, em aco escovado. Luz de cima, a
        // aresta de cima acesa, a de baixo na sombra, e as pontas do travessao um tom
        // abaixo, como uma barra cilindrica.
        let pommel = g.rect(SwordGeometry.pommel, top: g.pommelTop)
        let grip = g.rect(SwordGeometry.grip, top: g.gripTop)
        let crossguard = g.rect(SwordGeometry.crossguard, top: g.guardTop)
        steelBar(context, grip, unit: u, tone: 0.92, rounded: true)
        // Ranhuras do punho, de leve: e onde a mao segura.
        context.drawLayer { layer in
            layer.clip(to: Path(grip))
            var y = grip.minY + 16 * u
            while y < grip.maxY - 8 * u {
                layer.fill(Path(CGRect(x: grip.minX, y: y, width: grip.width, height: 2.5 * u)), with: .color(.black.opacity(0.14)))
                layer.fill(Path(CGRect(x: grip.minX, y: y + 2.5 * u, width: grip.width, height: 1.5 * u)), with: .color(.white.opacity(0.35)))
                y += 18 * u
            }
        }
        steelBar(context, pommel, unit: u, tone: 1, rounded: false)
        steelBar(context, crossguard, unit: u, tone: 1, rounded: false)
        context.fill(Path(crossguard), with: .linearGradient(
            Gradient(stops: [.init(color: .black.opacity(0.18), location: 0), .init(color: .clear, location: 0.22),
                             .init(color: .clear, location: 0.78), .init(color: .black.opacity(0.22), location: 1)]),
            startPoint: CGPoint(x: crossguard.minX, y: 0), endPoint: CGPoint(x: crossguard.maxX, y: 0)))

        // O brilho: uma faixa suave, na diagonal, que corre da ponta do pomo ate a pedra
        // somando luz ao aco; quando passa pela guarda, um lampejo na ponta dela.
        if let glint {
            var sword = Path()
            sword.addRect(pommel)
            sword.addRect(grip)
            sword.addRect(crossguard)
            sword.addPath(leftBevel)
            sword.addPath(rightBevel)
            let top = g.pommelTop
            let span = g.entry.y - top
            let center = top - span * 0.2 + span * 1.4 * glint
            let slant = crossguard.width * 0.35
            let band = span * 0.09
            context.drawLayer { layer in
                layer.clip(to: sword)
                layer.blendMode = .plusLighter
                var sweep = Path()
                sweep.move(to: CGPoint(x: crossguard.minX - slant, y: center - band + slant * 0.6))
                sweep.addLine(to: CGPoint(x: crossguard.maxX + slant, y: center - band - slant * 0.6))
                sweep.addLine(to: CGPoint(x: crossguard.maxX + slant, y: center + band - slant * 0.6))
                sweep.addLine(to: CGPoint(x: crossguard.minX - slant, y: center + band + slant * 0.6))
                sweep.closeSubpath()
                layer.fill(sweep, with: .linearGradient(
                    Gradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.22), location: 0.3),
                                     .init(color: .white.opacity(0.85), location: 0.5), .init(color: .white.opacity(0.22), location: 0.7),
                                     .init(color: .clear, location: 1)]),
                    startPoint: CGPoint(x: cx, y: center - band), endPoint: CGPoint(x: cx, y: center + band)))
            }
            // O lampejo: uma estrela de quatro pontas na ponta direita da guarda.
            let tipY = crossguard.midY - 0 * u
            let distance = abs(center - tipY + slant * 0.6) / span
            if distance < 0.08 {
                let strength = 1 - distance / 0.08
                let tip = CGPoint(x: crossguard.maxX - 6 * u, y: crossguard.minY + 6 * u)
                let length = 46 * u * strength
                let thickness = 5 * u * strength
                var star = Path()
                star.move(to: CGPoint(x: tip.x - length, y: tip.y))
                star.addQuadCurve(to: CGPoint(x: tip.x, y: tip.y - length), control: CGPoint(x: tip.x - thickness, y: tip.y - thickness))
                star.addQuadCurve(to: CGPoint(x: tip.x + length, y: tip.y), control: CGPoint(x: tip.x + thickness, y: tip.y - thickness))
                star.addQuadCurve(to: CGPoint(x: tip.x, y: tip.y + length), control: CGPoint(x: tip.x + thickness, y: tip.y + thickness))
                star.addQuadCurve(to: CGPoint(x: tip.x - length, y: tip.y), control: CGPoint(x: tip.x - thickness, y: tip.y + thickness))
                star.closeSubpath()
                context.fill(star, with: .color(.white.opacity(0.95 * strength)))
            }
        }
    }

    /// Uma barra de aco: degrade de cima para baixo, aresta de cima acesa e a de baixo
    /// escura. `tone` escurece o punho um pouco, como o cinza do punho no icone.
    private static func steelBar(_ context: GraphicsContext, _ rect: CGRect, unit u: CGFloat, tone: Double, rounded: Bool) {
        let path = rounded ? Path(roundedRect: rect, cornerRadius: 3 * u) : Path(rect)
        context.fill(path, with: .linearGradient(
            Gradient(stops: [.init(color: metal.light, location: 0), .init(color: metal.lit, location: 0.4),
                             .init(color: metal.mid, location: 0.85), .init(color: metal.shade, location: 1)]),
            startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
        if tone < 1 { context.fill(path, with: .color(.black.opacity(1 - tone))) }
        context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, 3 * u))), with: .color(.white.opacity(0.9)))
        context.fill(Path(CGRect(x: rect.minX, y: rect.maxY - max(1, 3 * u), width: rect.width, height: max(1, 3 * u))),
                     with: .color(metal.deep.opacity(0.8)))
    }

    /// O contato da lamina com a pedra: a lamina escurece onde entra, e a borda da frente
    /// do encaixe, que fica na frente dela, pega a luz.
    static func drawSeat(_ context: GraphicsContext, _ size: CGSize) {
        let g = SwordGeometry(size)
        let u = g.unit

        // A sombra so dentro da lamina, ate a curva do encaixe.
        let top = g.slot.midY - 80 * u
        var blade = Path()
        blade.move(to: CGPoint(x: g.cx - g.bladeWidth(at: top) / 2, y: top))
        blade.addLine(to: CGPoint(x: g.cx + g.bladeWidth(at: top) / 2, y: top))
        blade.addLine(to: CGPoint(x: g.cx + g.bladeEntryWidth / 2, y: g.slot.midY))
        blade.addLine(to: CGPoint(x: g.cx - g.bladeEntryWidth / 2, y: g.slot.midY))
        blade.closeSubpath()
        blade.addEllipse(in: g.slot)
        context.drawLayer { layer in
            layer.clip(to: blade)
            layer.clip(to: Path(CGRect(x: g.slot.minX, y: top, width: g.slot.width, height: g.slot.maxY - top)))
            let rect = CGRect(x: g.slot.minX, y: top, width: g.slot.width, height: g.slot.maxY - top)
            layer.fill(Path(rect), with: .linearGradient(
                Gradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.1), location: 0.55),
                                 .init(color: .black.opacity(0.42), location: 1)]),
                startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
        }
        var lip = Path()
        lip.addArc(center: CGPoint(x: g.slot.midX, y: g.slot.midY), radius: 1, startAngle: .degrees(10), endAngle: .degrees(170), clockwise: false)
        let scaled = lip.applying(CGAffineTransform(translationX: -g.slot.midX, y: -g.slot.midY)
            .concatenating(CGAffineTransform(scaleX: g.slot.width / 2, y: g.slot.height / 2))
            .concatenating(CGAffineTransform(translationX: g.slot.midX, y: g.slot.midY)))
        context.stroke(scaled, with: .color(Stone.edge), style: StrokeStyle(lineWidth: max(1, 3 * u), lineCap: .round))
    }
}
