import EscaliburChains
import SwiftUI

/// A abertura de "Sua primeira carteira": o selo do app no centro e as redes em duas
/// orbitas, girando devagar em sentidos opostos. Uma carteira, todas as redes. Com
/// Reduzir Movimento, parado.
struct WalletOrbit: View {
    var height: CGFloat = 280
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let inner: [Chain] = [.bitcoin, .ethereum, .solana, .xrpl, .tron, .ton]
    private static var outer: [Chain] {
        Chain.all.filter { chain in !inner.contains(where: { $0.id == chain.id }) }.prefix(12).map { $0 }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let outerRadius = min(geometry.size.width, geometry.size.height) / 2 - 20
                let innerRadius = outerRadius * 0.66
                ZStack {
                    Circle().stroke(Palette.edge, lineWidth: 1).frame(width: outerRadius * 2, height: outerRadius * 2).position(center)
                    Circle().stroke(Palette.edge, lineWidth: 1).frame(width: innerRadius * 2, height: innerRadius * 2).position(center)
                    ring(Self.outer, radius: outerRadius, size: 30, angle: -t / 60 * 2 * .pi, center: center)
                    ring(Self.inner, radius: innerRadius, size: 34, angle: t / 40 * 2 * .pi, center: center)
                    WalletBadge(size: 72)
                        .scaleEffect(appeared ? 1 : 0.7)
                        .position(center)
                }
                .opacity(appeared ? 1 : 0)
            }
        }
        .frame(height: height)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.72)) { appeared = true } }
        .accessibilityHidden(true)
    }

    private func ring(_ chains: [Chain], radius: CGFloat, size: CGFloat, angle: Double, center: CGPoint) -> some View {
        ForEach(Array(chains.enumerated()), id: \.element.id) { index, chain in
            let theta = angle + Double(index) / Double(chains.count) * 2 * .pi
            NetworkBadge(chain: chain, size: size, ring: Palette.void)
                .position(x: center.x + radius * CGFloat(cos(theta)), y: center.y + radius * CGFloat(sin(theta)))
        }
    }
}
