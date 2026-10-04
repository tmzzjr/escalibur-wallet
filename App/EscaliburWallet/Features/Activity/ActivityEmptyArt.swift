import EscaliburChains
import SwiftUI

/// Atividade vazia: tres cartoes de atividade entram um a um (receber, enviar, trocar,
/// cada um com a sua rede), com o status girando como pendente ate virar o visto lima
/// de confirmado. E o que a tela vai mostrar quando houver movimento. Ciclo de 6 s; com
/// Reduzir Movimento, os tres aparecem confirmados e parados.
struct ActivityEmptyArt: View {
    var height: CGFloat = 250
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Item {
        let icon: String
        let chain: Chain
        let width: CGFloat
    }

    private static let items = [
        Item(icon: "arrow.down", chain: .bitcoin, width: 0.62),
        Item(icon: "arrow.up", chain: .ethereum, width: 0.48),
        Item(icon: "arrow.left.arrow.right", chain: .solana, width: 0.7),
    ]
    private static let cycle = 6.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let t = reduceMotion ? 4.5 : now.truncatingRemainder(dividingBy: Self.cycle)
            let fade = reduceMotion ? 1 : 1 - Self.clamp((t - 5.3) / 0.6)
            VStack(spacing: Space.xs) {
                ForEach(Array(Self.items.enumerated()), id: \.offset) { index, item in
                    card(item, index: index, t: t, now: now, fade: fade)
                }
            }
            .frame(width: 290)
            .frame(maxWidth: .infinity)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func card(_ item: Item, index: Int, t: Double, now: Double, fade: Double) -> some View {
        let appear = Self.clamp((t - (0.3 + Double(index) * 0.45)) / 0.4) * fade
        let confirmed = Self.clamp((t - (2.0 + Double(index) * 0.55)) / 0.3)
        return HStack(spacing: Space.sm) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Palette.control))
                NetworkBadge(chain: item.chain, size: 16, ring: Palette.body)
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(Palette.edgeStrong).frame(width: 150 * item.width, height: 9)
                Capsule().fill(Palette.control).frame(width: 90 * item.width, height: 7)
            }
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Palette.inkMuted, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(reduceMotion ? 0 : now * 360))
                    .opacity(1 - confirmed)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.onLime)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.lime))
                    .scaleEffect(BackupFirstArt.easeOutBack(confirmed))
            }
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
        .opacity(appear)
        .offset(y: (1 - appear) * 16)
    }

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
