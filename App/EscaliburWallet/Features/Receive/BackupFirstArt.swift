import EscaliburChains
import SwiftUI

/// "Grave a senha antes de receber": o papel da senha sendo escrito, posicao por
/// posicao, ate o selo lima de conferido; em volta, as redes esperando em orbita, como
/// na abertura de "Sua primeira carteira". O ciclo recomeca a cada 7 segundos. Com
/// Reduzir Movimento, o papel aparece escrito e conferido, parado.
struct BackupFirstArt: View {
    var height: CGFloat = 300
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cycle = 7.0
    private static let chains: [Chain] = Array(Chain.all.prefix(8))
    /// Larguras do traco de cada palavra, em fracao da linha: parece letra de mao.
    private static let strokes: [CGFloat] = [0.72, 0.55, 0.86, 0.64, 0.5, 0.78, 0.6, 0.9, 0.58, 0.7, 0.82, 0.52]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let t = reduceMotion ? 5.0 : now.truncatingRemainder(dividingBy: Self.cycle)
            let fade = reduceMotion ? 1 : 1 - Self.clamp((t - 6.4) / 0.6)
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let radius = min(geometry.size.width, geometry.size.height) / 2 - 18
                ZStack {
                    Circle().stroke(Palette.edge, lineWidth: 1)
                        .frame(width: radius * 2, height: radius * 2).position(center)
                    ForEach(Array(Self.chains.enumerated()), id: \.element.id) { index, chain in
                        let theta = (reduceMotion ? 0 : now / 50 * 2 * .pi) + Double(index) / Double(Self.chains.count) * 2 * .pi
                        NetworkBadge(chain: chain, size: 30, ring: Palette.body)
                            .position(x: center.x + radius * CGFloat(cos(theta)), y: center.y + radius * CGFloat(sin(theta)))
                    }
                    paper(t: t, fade: fade).position(center)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func paper(t: Double, fade: Double) -> some View {
        let checkScale = Self.easeOutBack(Self.clamp((t - 4.3) / 0.35))
        return ZStack(alignment: .topTrailing) {
            VStack(spacing: 7) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 12) {
                        slot(row * 2, t: t, fade: fade)
                        slot(row * 2 + 1, t: t, fade: fade)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(width: 186)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.live))
            .rotationEffect(.degrees(-3))
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Palette.onLime)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Palette.lime))
                .overlay(Circle().stroke(Palette.body, lineWidth: 3))
                .scaleEffect(checkScale * fade)
                .opacity(checkScale > 0 ? fade : 0)
                .offset(x: 14, y: -14)
        }
    }

    private func slot(_ index: Int, t: Double, fade: Double) -> some View {
        let progress = Self.clamp((t - (0.4 + Double(index) * 0.32)) / 0.28) * fade
        return HStack(spacing: 5) {
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.plateMuted)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 14, alignment: .trailing)
            GeometryReader { line in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.plateRule).frame(height: 2).offset(y: 3)
                    Capsule().fill(Palette.plateInk)
                        .frame(width: line.size.width * Self.strokes[index] * progress, height: 4)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
        }
    }

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    /// Passa um pouco do tamanho e volta: o selo carimba.
    static func easeOutBack(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}
