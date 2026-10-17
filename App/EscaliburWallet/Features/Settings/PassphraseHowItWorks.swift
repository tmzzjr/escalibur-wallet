import EscaliburChains
import SwiftUI

/// "Como funciona" da carteira com passphrase (pedido do dono, 16/10/2026): quatro passos com
/// animacao, no formato do "Como funciona" do envelope. A passphrase como um cofre escondido
/// nas mesmas palavras; quem acha so as palavras ve a carteira de sempre; o cofre tem os
/// proprios enderecos de deposito; e a passphrase nao se recupera. Nada aqui e de verdade:
/// palavras sao glifos e os enderecos sao de exemplo.
struct PassphraseHowItWorks: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    struct Page {
        let title: String
        let text: String
    }

    static let pages = [
        Page(title: String(localized: "Um cofre escondido nas mesmas palavras"),
             text: String(localized: "A passphrase é uma senha extra que você escolhe. Junto com as palavras da carteira, ela abre outra carteira, separada da de sempre.")),
        Page(title: String(localized: "Quem só tem as palavras não abre o cofre"),
             text: String(localized: "Se alguém achar as suas palavras, vê só a carteira de sempre. O saldo da carteira com passphrase continua fora do alcance: falta a passphrase.")),
        Page(title: String(localized: "Endereços próprios para receber"),
             text: String(localized: "A carteira com passphrase tem outros endereços de depósito, em todas as redes. Para guardar no cofre, receba nos endereços dela.")),
        Page(title: String(localized: "Anote longe das palavras, e não esqueça"),
             text: String(localized: "Guarde a passphrase num lugar diferente das palavras. Esquecer a passphrase é perder a carteira com passphrase: ninguém recupera, nem a Escalibur.")),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "Como funciona")) { dismiss() }
            TabView(selection: $page) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    VStack(spacing: 0) {
                        // So a tela visivel anima.
                        Group {
                            if page == index { illustration(index) } else { Color.clear }
                        }
                        .frame(height: 236)
                        .padding(.top, Space.lg)
                        Text(Self.pages[index].title).typeStyle(.title).foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.xl)
                        Text(Self.pages[index].text).typeStyle(.body).foregroundStyle(Palette.inkSoft)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.sm)
                        Spacer(minLength: Space.xl)
                    }
                    .padding(.horizontal, Space.gutter)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            PrimaryButton(title: page < Self.pages.count - 1 ? String(localized: "Próximo") : String(localized: "Entendi")) {
                if page < Self.pages.count - 1 { withAnimation(Motion.fade) { page += 1 } } else { dismiss() }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xs)
            .padding(.top, Space.sm)
        }
        .background(Palette.void.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationBackground(Palette.void)
        .presentationCornerRadius(Radius.sheet)
    }

    @ViewBuilder
    private func illustration(_ index: Int) -> some View {
        switch index {
        case 0: VaultFromWordsScene()
        case 1: WordsOnlyScene()
        case 2: OwnAddressesScene()
        default: KeepApartScene()
        }
    }
}

// MARK: Pecas

/// As palavras da carteira, cifradas: um cartao com seis pastilhas de glifos trocando.
private struct WordsCard: View {
    var tick: UInt64
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Palavras").typeStyle(.label).foregroundStyle(Palette.inkSoft)
            LazyVGrid(columns: [GridItem(.fixed(44), spacing: 4), GridItem(.fixed(44), spacing: 4)], spacing: 4) {
                ForEach(0..<6, id: \.self) { index in
                    Text(verbatim: EnvelopeCipherCard.glyphs(index, tick: tick))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.inkSoft)
                        .frame(width: 44, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.void)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 1)))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
        .fixedSize()
    }
}

/// A passphrase: uma pastilha com a chave e a cifra dela.
private struct PassphrasePill: View {
    var tick: UInt64
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.horizontal.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.void)
                .frame(width: 24, height: 24).background(Circle().fill(Palette.ink))
            Text(verbatim: EnvelopeCipherCard.glyphs(41, tick: tick) + EnvelopeCipherCard.glyphs(42, tick: tick))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.inkSoft)
        }
        .padding(.leading, 5).padding(.trailing, 10)
        .frame(height: 34)
        .background(Capsule().fill(Palette.body).overlay(Capsule().stroke(Palette.edge, lineWidth: 1)))
    }
}

/// Pontos de pixel descendo de uma peca para a outra.
private struct PixelFlow: View {
    var progress: Double
    var height: CGFloat = 26
    var body: some View {
        Canvas { context, size in
            for step in 0..<5 {
                let y = CGFloat(step) / 4 * (size.height - 4) + 2
                let lit = progress * 5 - Double(step)
                let tone = 0.2 + 0.6 * max(0, min(1, lit)) * (1 - max(0, min(1, lit - 1)))
                context.fill(Path(roundedRect: CGRect(x: size.width / 2 - 2, y: y - 2, width: 4, height: 4), cornerRadius: 1),
                             with: .color(PixelFill.gray(tone)))
            }
        }
        .frame(width: 8, height: height)
    }
}

private func ease(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

// MARK: Cenas

/// Passo 1: as palavras, mais a passphrase, abrem o cofre.
private struct VaultFromWordsScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 4 : timeline.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 6)
            let tick = UInt64(max(timeline.date.timeIntervalSinceReferenceDate * 10, 0))
            VStack(spacing: 6) {
                HStack(spacing: Space.sm) {
                    WordsCard(tick: tick)
                        .opacity(ease(t / 0.5))
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.inkMuted)
                        .opacity(ease((t - 0.6) / 0.4))
                    PassphrasePill(tick: tick)
                        .opacity(ease((t - 0.9) / 0.4))
                        .offset(x: CGFloat(1 - ease((t - 0.9) / 0.5)) * 30)
                }
                PixelFlow(progress: (t - 1.6) / 0.8)
                PixelVault(size: 96)
                    .opacity(0.35 + 0.65 * ease((t - 2.2) / 0.4))
            }
            .opacity(1 - ease((t - 5.5) / 0.5))
        }
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }
}

/// Passo 2: so com as palavras, abre a carteira de sempre; o cofre continua fechado e
/// treme quando tentam.
private struct WordsOnlyScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 3 : timeline.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 5.5)
            let tick = UInt64(max(timeline.date.timeIntervalSinceReferenceDate * 10, 0))
            let shake = reduceMotion ? 0 : (t > 2.4 && t < 3.0 ? sin((t - 2.4) * 40) * 5 * (1 - (t - 2.4) / 0.6) : 0)
            VStack(spacing: 6) {
                WordsCard(tick: tick).opacity(ease(t / 0.5))
                PixelFlow(progress: (t - 0.7) / 0.8)
                HStack(alignment: .top, spacing: Space.xl) {
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottomTrailing) {
                            WalletGlyph(id: UUID(), size: 64, selected: t > 1.5)
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.void)
                                .frame(width: 22, height: 22).background(Circle().fill(Palette.success))
                                .offset(x: 6, y: 6)
                                .scaleEffect(ease((t - 1.5) / 0.3))
                        }
                        Text("De sempre").typeStyle(.label).foregroundStyle(Palette.inkSoft)
                    }
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottomTrailing) {
                            PixelVault(size: 64)
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white)
                                .frame(width: 22, height: 22).background(Circle().fill(Palette.down))
                                .offset(x: 6, y: 6)
                                .scaleEffect(ease((t - 2.4) / 0.3))
                        }
                        .offset(x: shake)
                        Text("Com passphrase").typeStyle(.label).foregroundStyle(Palette.inkSoft)
                    }
                }
            }
            .opacity(1 - ease((t - 5.0) / 0.5))
        }
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }
}

/// Passo 3: a mesma rede, dois enderecos: o de sempre e o do cofre, trocando de rede.
private struct OwnAddressesScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    /// Enderecos de exemplo, so desenho.
    private static let samples: [(Chain, String, String)] = [
        (.bitcoin, "bc1q8f4…3k2v", "bc1qz7m…9wd0"),
        (.ethereum, "0x4B1c…7e09", "0xA93f…12cD"),
        (.solana, "7xKp…Qm4T", "GhR2…d8Lw"),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
            let index = Int(t / 2.2) % Self.samples.count
            let local = t.truncatingRemainder(dividingBy: 2.2)
            let sample = Self.samples[index]
            VStack(spacing: Space.sm) {
                row(chain: sample.0, title: String(localized: "De sempre"), address: sample.1, vault: false, appear: ease(local / 0.35))
                row(chain: sample.0, title: String(localized: "Com passphrase"), address: sample.2, vault: true, appear: ease((local - 0.25) / 0.35))
            }
            .frame(maxWidth: 320)
        }
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }

    private func row(chain: Chain, title: String, address: String, vault: Bool, appear: Double) -> some View {
        HStack(spacing: Space.sm) {
            NetworkBadge(chain: chain, size: 34, ring: Palette.body)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if vault { Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.inkSoft) }
                    Text(title).typeStyle(.label).foregroundStyle(Palette.inkSoft)
                }
                Text(verbatim: address).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink)
                    .opacity(appear)
                    .offset(y: CGFloat(1 - appear) * 6)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.down.circle").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.inkMuted)
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(vault ? Palette.edgeStrong : Palette.edge, lineWidth: 1)))
    }
}

/// Passo 4: as palavras e a passphrase em papeis separados, que se afastam; sem a
/// passphrase, o cofre nao abre mais.
private struct KeepApartScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 3 : timeline.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 5)
            let tick = UInt64(max(timeline.date.timeIntervalSinceReferenceDate * 10, 0))
            let apart = CGFloat(ease((t - 0.5) / 0.9))
            VStack(spacing: Space.md) {
                HStack(spacing: 14 + 60 * apart) {
                    paper(icon: "doc.text", title: String(localized: "Palavras")) { WordsCard(tick: tick).scaleEffect(0.62).frame(width: 74, height: 62) }
                    paper(icon: "key.horizontal", title: String(localized: "Passphrase")) {
                        Text(verbatim: EnvelopeCipherCard.glyphs(41, tick: tick)).font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.inkSoft).frame(width: 74, height: 62)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.caution)
                    Text("Sem a passphrase, ninguém recupera").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                .opacity(ease((t - 1.6) / 0.5))
            }
            .opacity(1 - ease((t - 4.5) / 0.5))
        }
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }

    private func paper<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            content()
            Label(title, systemImage: icon).typeStyle(.label).foregroundStyle(Palette.ink)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
    }
}
