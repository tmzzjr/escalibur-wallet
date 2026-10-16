import SwiftUI

/// "Como funciona" do envelope (pedido do dono, 14/10/2026; tres telas desde 15/10/2026):
/// a senha da carteira virando um arquivo criptografado que so abre com a senha que a
/// pessoa escolhe. Nenhuma palavra de verdade aparece: o cifrado e desenho, e as palavras
/// que a senha revela sao de exemplo, que nao formam uma frase valida.
struct EnvelopeHowItWorks: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    #if DEBUG
    @MainActor private static var debugPageUsed = false
    #endif

    struct Page {
        let title: String
        let text: String
    }

    static let pages = [
        Page(title: String(localized: "As palavras viram um arquivo cifrado"),
             text: String(localized: "O app cifra uma cópia da senha da sua carteira com outra senha, que só você escolhe. Tudo acontece aqui no iPhone, e o envelope fica salvo só aqui, até você decidir onde guardar uma cópia.")),
        Page(title: String(localized: "Sem a senha, o arquivo é ruído"),
             text: String(localized: "Tudo dentro dele é criptografado aqui no iPhone. Sem a senha, ele não mostra quantas palavras guarda nem o que tem dentro, e uma senha errada só devolve ruído.")),
        Page(title: String(localized: "Só a sua senha abre"),
             text: String(localized: "Com a senha certa, as palavras voltam. Sem ela, ninguém abre, nem a Escalibur, e senha esquecida não se recupera. Cada tentativa exige uma conta pesada, de propósito: adivinhar uma senha forte fica lento demais.")),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "Como funciona")) { dismiss() }
            TabView(selection: $page) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    VStack(spacing: 0) {
                        // So a tela visivel anima: as vizinhas que o TabView prepara ficam paradas.
                        Group {
                            if page == index { illustration(index) } else { Color.clear }
                        }
                        .frame(height: 236)
                        // As duas do cartao cifrado descem um pouco, com o texto, para o
                        // conjunto ficar no centro (pedido do dono, 16/10/2026).
                        .padding(.top, index == 0 ? Space.lg : Space.lg + 32)
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
        #if DEBUG
        // A pagina vem logo depois do nome da tela: o passeio por idioma poe mais
        // argumentos no fim.
        // So na primeira abertura: depois, o "Como funciona" abre na primeira pagina, como no
        // app de verdade (antes reabria sempre na pagina do argumento).
        .onAppear {
            guard !Self.debugPageUsed, DebugDemo.screen == "envelope-como", let index = DebugDemo.arguments.firstIndex(of: "envelope-como"),
                  DebugDemo.arguments.indices.contains(index + 1) else { return }
            Self.debugPageUsed = true
            page = Int(DebugDemo.arguments[index + 1]) ?? 0
        }
        #endif
    }

    @ViewBuilder
    private func illustration(_ index: Int) -> some View {
        switch index {
        case 0: EnvelopePixelScene()
        // As duas seguintes sao o mesmo arquivo: primeiro uma senha errada que nao abre;
        // depois a senha certa abre o envelope e revela as palavras.
        case 1: EnvelopeCipherCard(mode: .denied)
        default: EnvelopeCipherCard(mode: .reveal)
        }
    }
}
