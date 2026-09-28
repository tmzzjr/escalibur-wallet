import SwiftUI

/// O1: de onde vem a carteira. As tres importacoes sao linhas; criar e o primario,
/// porque quem abre pela primeira vez quase sempre cria.
struct AddWalletView: View {
    @Environment(AppSession.self) private var session
    let isFirst: Bool
    let onFinished: () -> Void

    @State private var route: Route?
    @State private var creating = false
    @State private var openingEnvelope = false
    @State private var appeared = false

    enum Route: Hashable { case importPhrase, watch }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                WalletOrbit(height: 260).padding(.top, Space.xs)
                Text(isFirst ? "Sua primeira carteira" : "Adicionar carteira")
                    .typeStyle(.title).foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.sm)
                Text("Uma frase, um endereço em cada rede. As chaves ficam só neste iPhone.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.gutter).padding(.top, Space.xxs)
                VStack(spacing: 0) {
                    row("Importar com a senha da carteira", "Você já tem 12 ou 24 palavras de outra carteira.", "text.word.spacing", order: 0) {
                        route = .importPhrase
                    }
                    row("Importar de um envelope Escalibur", "O arquivo .esclbr e a senha do envelope.", "envelope", order: 1) {
                        openingEnvelope = true
                    }
                    row("Só observar um endereço", "Acompanhe um saldo sem poder enviar.", "eye", order: 2) {
                        route = .watch
                    }
                }
                .padding(.top, Space.md)
                Spacer(minLength: 0)
                ActionFooter {
                    PrimaryButton(title: "Criar carteira nova") { creating = true }
                }
            }
            .background(Palette.void.ignoresSafeArea())
            .navigationDestination(item: $route) { route in
                switch route {
                case .importPhrase: ImportPhraseView(onFinished: onFinished)
                case .watch: WatchAddressView(onFinished: onFinished)
                }
            }
            .toolbar {
                if !isFirst {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { onFinished() } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                        }
                        .accessibilityLabel("Fechar")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $creating) {
            NewWalletFlow(isFirstWallet: isFirst) { creating = false; if !session.metadata.wallets.isEmpty { onFinished() } }
        }
        .fullScreenCover(isPresented: $openingEnvelope) {
            OpenEnvelopeFlow(initialURL: nil) {
                openingEnvelope = false
                if !session.metadata.wallets.isEmpty { onFinished() }
            }
        }
    }

    /// Cada opcao sobe um pouco depois da anterior, na primeira aparicao.
    private func row(_ title: String, _ subtitle: String, _ icon: String, order: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Palette.purple))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                    Text(subtitle).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, Space.gutter)
            .frame(height: 72)
        }
        .buttonStyle(RowStyle())
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.25 + 0.08 * Double(order)), value: appeared)
        .onAppear { appeared = true }
    }
}
