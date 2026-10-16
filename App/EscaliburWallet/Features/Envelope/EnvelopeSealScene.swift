import SwiftUI

/// O lacre do envelope (pedido do dono, 15/10/2026: redesenho completo). O cartao do
/// arquivo, com as palavras ja em cifra trocando, fica sobre o envelope aberto enquanto o
/// app deixa a senha dificil de adivinhar; cifrando, a cifra acelera; gravando, o cartao
/// desce para dentro; lacrado, a aba fecha em 3D sobre a dobra e o selo de prata com a
/// espada carimba. Nenhuma palavra de verdade: os glifos sao os do `EnvelopeCipherCard`.
/// Com Reduzir Movimento, cada etapa aparece pronta.
struct EnvelopeSealScene: View {
    enum Stage: Int, Comparable {
        case hardening, encrypting, writing, sealed
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    let stage: Stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 236
    private static let envelopeTop: CGFloat = 96
    private static let envelopeHeight: CGFloat = 132

    var body: some View {
        let inside = stage >= .writing
        let closed = stage == .sealed
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || closed)) { timeline in
            let tick = UInt64(max(timeline.date.timeIntervalSinceReferenceDate * (stage == .encrypting ? 24 : 12), 0))
            ZStack(alignment: .top) {
                // O fundo do envelope e a aba aberta, atras do cartao.
                back
                flap
                    .rotation3DEffect(.degrees(closed ? 0 : 180), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.45)
                    .offset(y: Self.envelopeTop)
                    .opacity(closed ? 0 : 1)
                card(tick: tick)
                    .offset(y: inside ? Self.envelopeTop + 8 : 6)
                    .scaleEffect(inside ? 0.92 : 1)
                // O bolso da frente cobre o cartao quando ele entra.
                pocket.offset(y: Self.envelopeTop)
                // Fechada, a aba vem para a frente.
                flap
                    .rotation3DEffect(.degrees(closed ? 0 : 180), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.45)
                    .offset(y: Self.envelopeTop)
                    .opacity(closed ? 1 : 0)
                seal
                    .offset(y: Self.envelopeTop + 50)
                    .scaleEffect(closed ? 1 : 1.6)
                    .opacity(closed ? 1 : 0)
            }
            .frame(width: Self.width, height: Self.envelopeTop + Self.envelopeHeight + 4, alignment: .top)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.78), value: stage)
        .sensoryFeedback(.impact(weight: .medium), trigger: closed) { _, new in new }
        .accessibilityHidden(true)
    }

    private var back: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Palette.rail)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 1))
            .frame(width: Self.width, height: Self.envelopeHeight)
            .offset(y: Self.envelopeTop)
    }

    /// A aba: o triangulo que desce da borda de cima ate o meio do envelope.
    private var flap: some View {
        FlapShape()
            .fill(LinearGradient(colors: [Palette.edgeStrong, Palette.control], startPoint: .top, endPoint: .bottom))
            .overlay(FlapShape().stroke(Palette.edgeStrong, lineWidth: 1))
            .frame(width: Self.width, height: Self.envelopeHeight * 0.58)
    }

    /// O bolso da frente: o envelope sem a ponta de cima, onde o cartao some.
    private var pocket: some View {
        PocketShape()
            .fill(Palette.control)
            .overlay(PocketShape().stroke(Palette.edgeStrong, lineWidth: 1))
            .frame(width: Self.width, height: Self.envelopeHeight)
    }

    private func card(tick: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.inkSoft)
                Capsule().fill(Palette.edgeStrong).frame(width: 64, height: 5)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                ForEach(0..<9, id: \.self) { index in
                    Text(verbatim: EnvelopeCipherCard.glyphs(index, tick: tick))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.void)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 0.8)))
                }
            }
        }
        .padding(10)
        .frame(width: 176)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.body)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 1)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    /// O selo de prata com a espada do icone, carimbado na ponta da aba.
    private var seal: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: 0xF4F5F8), Color(hex: 0xB9BCC3), Color(hex: 0x8D9098)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().inset(by: 4).stroke(Color(hex: 0x6F737C).opacity(0.6), lineWidth: 1)
            SwordEmblem()
                .fill(Color(hex: 0x3A3C42))
                .frame(width: 18, height: 24)
        }
        .frame(width: 46, height: 46)
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
    }
}

private struct FlapShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 6, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 6, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.midX + 14, y: rect.maxY - 6), control: CGPoint(x: rect.midX + 40, y: rect.maxY * 0.7))
        path.addQuadCurve(to: CGPoint(x: rect.midX - 14, y: rect.maxY - 6), control: CGPoint(x: rect.midX, y: rect.maxY + 4))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 6, y: rect.minY), control: CGPoint(x: rect.midX - 40, y: rect.maxY * 0.7))
        path.closeSubpath()
        return path
    }
}

private struct PocketShape: Shape {
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
