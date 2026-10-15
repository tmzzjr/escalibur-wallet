import SwiftUI

/// O1: de onde vem a carteira. As tres importacoes sao linhas; criar e o primario,
/// porque quem abre pela primeira vez quase sempre cria.
struct AddWalletView: View {
    @Environment(AppSession.self) private var session
    let isFirst: Bool
    let onFinished: () -> Void

    @State private var path: [Route] = []
    @State private var creating = false
    @State private var openingEnvelope = false

    /// Importar passa antes pela tela de seguranca e responsabilidade.
    enum Route: Hashable { case responsibility, deviceCheck, importPhrase, watch }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                WalletOrbit(height: 260).padding(.top, Space.xs)
                // Centrado sob o selo em orbita: titulo e frase de apoio no mesmo eixo dele.
                VStack(spacing: Space.xxs) {
                    Text(isFirst ? "Sua primeira carteira" : "Adicionar carteira")
                        .typeStyle(.title).foregroundStyle(Palette.ink)
                    Text("Uma frase, um endereço em cada rede. As chaves ficam só neste iPhone.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.sm)
                VStack(spacing: 0) {
                    row(String(localized: "Importar com a senha da carteira"), String(localized: "Você já tem 12 ou 24 palavras de outra carteira."), "text.word.spacing") {
                        path.append(.responsibility)
                    }
                    row(String(localized: "Importar de um envelope Escalibur"), String(localized: "O arquivo .esclbr e a senha do envelope."), "envelope") {
                        openingEnvelope = true
                    }
                    row(String(localized: "Só observar um endereço"), String(localized: "Acompanhe um saldo sem poder enviar."), "eye") {
                        path.append(.watch)
                    }
                }
                .padding(.top, Space.md)
                Spacer(minLength: 0)
                ActionFooter {
                    PrimaryButton(title: String(localized: "Criar carteira nova")) { creating = true }
                }
            }
            .background(Palette.void.ignoresSafeArea())
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .responsibility:
                    ResponsibilityView(continueTitle: String(localized: "Conferir o aparelho")) { path.append(.deviceCheck) }
                case .deviceCheck:
                    DeviceCheckView { path.append(.importPhrase) }
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

    private func row(_ title: String, _ subtitle: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Palette.control))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                    Text(subtitle).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, Space.gutter)
            .frame(height: 72)
        }
        .buttonStyle(RowStyle())
    }
}
