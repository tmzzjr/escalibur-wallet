import SwiftUI

/// "Ainda não há ativos para enviar": o disco de enviar no centro, com a seta subindo
/// e voltando sem levar nada; em volta, onde estariam as moedas, so lugares vazios
/// tracejados, girando devagar. Par da ilustracao de "Grave a senha antes de receber".
/// Com Reduzir Movimento, parado.
struct EmptySendArt: View {
    var height: CGFloat = 280
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let slots = 8
    private static let launch = 2.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let now = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let radius = min(geometry.size.width, geometry.size.height) / 2 - 18
                ZStack {
                    Circle().stroke(Palette.edge, lineWidth: 1)
                        .frame(width: radius * 2, height: radius * 2).position(center)
                    ForEach(0..<Self.slots, id: \.self) { index in
                        let theta = now / 70 * 2 * .pi + Double(index) / Double(Self.slots) * 2 * .pi
                        // Cada lugar vazio respira em defasagem: nada chega a ocupar.
                        let breath = reduceMotion ? 0.5 : (sin(now * 1.6 + Double(index)) + 1) / 2
                        Circle()
                            .strokeBorder(Palette.edgeStrong, style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                            .frame(width: 30, height: 30)
                            .opacity(0.45 + 0.4 * breath)
                            .position(x: center.x + radius * CGFloat(cos(theta)), y: center.y + radius * CGFloat(sin(theta)))
                    }
                    disc(now: now).position(center)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// A seta sobe e sai pelo alto do disco; volta por baixo. Sobe vazia: nao ha o que
    /// levar.
    private func disc(now: Double) -> some View {
        let phase = reduceMotion ? 0.0 : now.truncatingRemainder(dividingBy: Self.launch) / Self.launch
        // 0 a 0,45: sobe e sai; 0,45 a 0,7: volta de baixo; resto: parada no centro.
        let offset: CGFloat
        let opacity: Double
        switch phase {
        case ..<0.45:
            let x = phase / 0.45
            offset = -CGFloat(x * x) * 70
            opacity = 1 - x
        case ..<0.7:
            let x = (phase - 0.45) / 0.25
            offset = CGFloat(1 - x) * 40
            opacity = x
        default:
            offset = 0
            opacity = 1
        }
        return ZStack {
            Circle().fill(Palette.rail)
            Circle().strokeBorder(Palette.edge, lineWidth: 1)
            Image(systemName: "arrow.up")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .offset(y: offset)
                .opacity(opacity)
        }
        .frame(width: 104, height: 104)
        .clipShape(Circle())
    }
}
