import SwiftUI

/// A abertura: a espada cravada na pedra. Escalibur e a Excalibur da lenda, a espada que
/// so o dono de direito tira da pedra, que e o que a tela promete: uma carteira que so
/// voce abre. O painel e o roxo do icone, para o app abrir como continuacao dele.
///
/// Ao aparecer, a espada desce e crava; um anel lima marca o encaixe, uma vez so. Depois,
/// um brilho corre a lamina de tempos em tempos, como metal polido. Com Reduzir
/// Movimento, a espada ja esta cravada e nada se mexe.
struct SwordInStone: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false
    @State private var ringOut = false

    /// Onde a lamina entra na pedra, em fracao da altura do painel.
    static let entryY: CGFloat = 0.695

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let entry = CGPoint(x: size.width / 2, y: size.height * Self.entryY)
            ZStack(alignment: .topLeading) {
                // Luz de cima: o roxo do icone no alto, um tom abaixo junto da pedra.
                LinearGradient(colors: [Color(hex: 0x8B4DF5), Palette.brand, Color(hex: 0x6A2BD9)],
                               startPoint: .top, endPoint: .bottom)
                Canvas { context, size in Self.drawStone(context, size) }
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !landed)) { timeline in
                    Canvas { context, size in
                        Self.drawSword(context, size, glint: reduceMotion ? nil : Self.glintPhase(timeline.date))
                    }
                }
                .offset(y: landed ? 0 : -size.height)
                // A parte da lamina abaixo da entrada esta dentro da pedra.
                .mask(alignment: .top) { Rectangle().frame(height: entry.y) }
                Ellipse()
                    .stroke(Palette.lime, lineWidth: 2)
                    .frame(width: size.width * 0.16, height: size.height * 0.035)
                    .scaleEffect(ringOut ? 2.6 : 0.4)
                    .opacity(ringOut ? 0 : (landed && !reduceMotion ? 1 : 0))
                    .position(entry)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityHidden(true)
        .task {
            guard !landed else { return }
            if reduceMotion { landed = true; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { landed = true }
            try? await Task.sleep(nanoseconds: 420_000_000)
            withAnimation(.easeOut(duration: 0.9)) { ringOut = true }
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
        static let top = Color(hex: 0xA78BFA)
        static let left = Color(hex: 0x5B21B6)
        static let middle = Palette.purpleDeep
        static let middleCut = Color(hex: 0x431A88)
        static let edge = Color(hex: 0xC4B5FD)
        static let right = Color(hex: 0x3B0F80)
        static let slot = Color(hex: 0x2E1065)
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
        let slot = CGRect(x: size.width * 0.5 - size.height * 0.05, y: size.height * entryY - size.height * 0.011,
                          width: size.height * 0.10, height: size.height * 0.022)
        context.fill(Path(ellipseIn: slot), with: .color(Stone.slot))
    }

    // MARK: Espada

    private enum Steel {
        static let light = Color.white
        /// A lamina um tom abaixo do branco, para o brilho aparecer no lado claro tambem.
        static let blade = Color(hex: 0xECECEF)
        static let shade = Color(hex: 0xD4D4D8)
        static let fuller = Color(hex: 0xA1A1AA)
        static let grip = Palette.logoDisc
        static let wrap = Palette.purpleDeep
    }

    /// A espada do icone, de pe: pomo, punho com tres voltas, guarda reta e lamina com
    /// o lado esquerdo claro e o direito em sombra, como no icone.
    static func drawSword(_ context: GraphicsContext, _ size: CGSize, glint: CGFloat?) {
        let h = size.height
        let cx = size.width / 2
        let pommelRadius = h * 0.032
        let top = h * 0.09
        let gripWidth = h * 0.046
        let gripTop = top + pommelRadius * 1.6
        let gripBottom = gripTop + h * 0.12
        let guardHeight = h * 0.036
        let guardWidth = h * 0.27
        let bladeWidth = h * 0.078
        let bladeTop = gripBottom + guardHeight
        let tipStart = h * entryY + h * 0.06
        let tip = tipStart + bladeWidth * 0.9

        let pommel = Path(ellipseIn: CGRect(x: cx - pommelRadius, y: top, width: pommelRadius * 2, height: pommelRadius * 2))
        context.fill(pommel, with: .color(Steel.light))

        let grip = Path(roundedRect: CGRect(x: cx - gripWidth / 2, y: gripTop, width: gripWidth, height: gripBottom - gripTop),
                        cornerRadius: gripWidth * 0.2)
        context.fill(grip, with: .color(Steel.grip))
        for index in 1...3 {
            let y = gripTop + (gripBottom - gripTop) * CGFloat(index) / 4
            context.fill(Path(CGRect(x: cx - gripWidth / 2, y: y - 1.5, width: gripWidth, height: 3)), with: .color(Steel.wrap))
        }

        let guardBar = Path(roundedRect: CGRect(x: cx - guardWidth / 2, y: gripBottom, width: guardWidth, height: guardHeight),
                            cornerRadius: guardHeight / 2)
        context.fill(guardBar, with: .color(Steel.light))

        var blade = Path()
        blade.move(to: CGPoint(x: cx - bladeWidth / 2, y: bladeTop))
        blade.addLine(to: CGPoint(x: cx + bladeWidth / 2, y: bladeTop))
        blade.addLine(to: CGPoint(x: cx + bladeWidth / 2, y: tipStart))
        blade.addLine(to: CGPoint(x: cx, y: tip))
        blade.addLine(to: CGPoint(x: cx - bladeWidth / 2, y: tipStart))
        blade.closeSubpath()
        context.fill(blade, with: .color(Steel.blade))
        var shade = Path()
        shade.move(to: CGPoint(x: cx, y: bladeTop))
        shade.addLine(to: CGPoint(x: cx + bladeWidth / 2, y: bladeTop))
        shade.addLine(to: CGPoint(x: cx + bladeWidth / 2, y: tipStart))
        shade.addLine(to: CGPoint(x: cx, y: tip))
        shade.closeSubpath()
        context.fill(shade, with: .color(Steel.shade))
        var fuller = Path()
        fuller.move(to: CGPoint(x: cx, y: bladeTop + h * 0.02))
        fuller.addLine(to: CGPoint(x: cx, y: tipStart))
        context.stroke(fuller, with: .color(Steel.fuller), lineWidth: 1.5)

        // O brilho: uma faixa inclinada que desce pela lamina, presa ao contorno dela.
        if let glint {
            let span = tip - bladeTop
            let y = bladeTop - span * 0.25 + span * 1.5 * glint
            context.drawLayer { layer in
                layer.clip(to: blade)
                var band = Path()
                band.move(to: CGPoint(x: cx - bladeWidth, y: y + bladeWidth * 0.6))
                band.addLine(to: CGPoint(x: cx + bladeWidth, y: y - bladeWidth * 0.6))
                band.addLine(to: CGPoint(x: cx + bladeWidth, y: y - bladeWidth * 0.6 + h * 0.05))
                band.addLine(to: CGPoint(x: cx - bladeWidth, y: y + bladeWidth * 0.6 + h * 0.05))
                band.closeSubpath()
                layer.fill(band, with: .color(.white.opacity(0.85)))
            }
        }
    }
}
