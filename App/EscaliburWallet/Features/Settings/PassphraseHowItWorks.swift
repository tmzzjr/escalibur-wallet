import SwiftUI

/// "Como funciona" da carteira com passphrase (pedido do dono, 16/10/2026): quatro passos com
/// animacao, no formato do "Como funciona" do envelope, em cenas de pixels
/// (`PassphrasePixelScene`, refeitas em 17/10/2026): a porta escondida nas mesmas palavras;
/// quem so tem as palavras nao acha a porta; cada porta com o proprio codigo de deposito; e a
/// chave esquecida vira ruido.
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
        case 0: PassphrasePixelScene(scene: .hiddenDoor)
        case 1: PassphrasePixelScene(scene: .wordsOnly)
        case 2: PassphrasePixelScene(scene: .ownCodes)
        default: PassphrasePixelScene(scene: .forgotten)
        }
    }
}
