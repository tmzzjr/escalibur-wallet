#if DEBUG
import EscaliburCore
import EscaliburKeys
import SwiftUI

/// Conferencia visual no simulador, so em compilacao de depuracao.
///
/// `-demo` cadastra um PIN de teste e importa a carteira publica de teste do BIP-39
/// ("abandon ... about", que qualquer pessoa conhece e que ninguem deve usar), pelos
/// mesmos caminhos do app. `-tela <nome>` abre uma tela direto. verificar.sh confere
/// que nada disto existe num build de distribuicao.
enum DebugDemo {
    static let pin = "111111"
    static let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var enabled: Bool { arguments.contains("-demo") }

    static var screen: String? {
        guard let index = arguments.firstIndex(of: "-tela"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `-envelope <caminho>`: arquivo que `-tela abrir` ja carrega.
    static var envelopeURL: URL? {
        guard let index = arguments.firstIndex(of: "-envelope"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func securePIN() -> SecureBytes {
        let bytes = SecureBytes(capacity: 6)
        bytes.replaceAll(with: Array(pin.utf8))
        return bytes
    }

    @MainActor
    static func prepare(session: AppSession, router: Router) async {
        guard enabled else { return }
        do {
            if session.phase == .onboarding {
                try await session.setUpPIN(securePIN())
            } else if session.phase == .locked {
                try await session.unlock(pin: securePIN())
            }
            if session.metadata.wallets.isEmpty {
                // `-vazia`: uma carteira nova, sorteada agora, sem saldo nenhum.
                let secret = arguments.contains("-vazia")
                    ? try WalletSecret.from(phrase: BIP39.generate(wordCount: 12), language: .english)
                    : try WalletSecret.from(phrase: BIP39.canonical(phrase), language: .english)
                // `-sem-copia`: carteira criada aqui e ainda sem copia, para as telas que
                // pedem gravar a senha antes de receber.
                let withoutBackup = arguments.contains("-sem-copia")
                _ = try await session.addWallet(
                    secret: secret, name: "Carteira principal", origin: withoutBackup ? .created : .importedPhrase, wordCount: 12,
                    backupConfirmed: !withoutBackup, credential: .pin(securePIN())
                )
            }
            switch screen {
            case "mercado": router.tab = .market
            case "trocar": router.tab = .trade
            case "atividade": router.tab = .activity
            case "ajustes": router.tab = .settings
            case "enviar": router.present(.send(nil))
            case "enviar-eth", "envio-incerto": router.present(.send(.native(.ethereum)))
            default: break
            }
        } catch {
            assertionFailure("demo: \(error)")
        }
    }
}

/// `-tela lacrar` e `-tela abrir` abrem as telas de envelope por cima da carteira.
/// `-tela adicionar`, `-tela criar`, `-tela seguranca` e `-tela observar` abrem as
/// telas de carteira nova.
struct DemoEnvelopes: ViewModifier {
    @Environment(AppSession.self) private var session
    @State private var sealing: WalletMeta?
    @State private var opening = false
    @State private var newWallet: DemoNewWallet?
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $sealing) { wallet in SealEnvelopeFlow(wallet: wallet) { sealing = nil } }
            .fullScreenCover(isPresented: $opening) { OpenEnvelopeFlow(initialURL: DebugDemo.envelopeURL) { opening = false } }
            .fullScreenCover(item: $newWallet) { screen in
                switch screen {
                case .criar: NewWalletFlow(isFirstWallet: false) { newWallet = nil }
                case .seguranca: NavigationStack { ResponsibilityView(continueTitle: "Digitar as palavras") {} }
                case .observar: NavigationStack { WatchAddressView { newWallet = nil } }
                case .adicionar: AddWalletView(isFirst: false) { newWallet = nil }
                }
            }
            .task(id: session.metadata.wallets.first?.id) {
                guard !shown, let first = session.metadata.wallets.first else { return }
                shown = true
                if DebugDemo.screen == "lacrar" { sealing = first }
                if DebugDemo.screen == "abrir" { opening = true }
                newWallet = DebugDemo.screen.flatMap(DemoNewWallet.init(rawValue:))
            }
    }
}

/// As telas de carteira nova que `-tela` abre direto.
enum DemoNewWallet: String, Identifiable {
    case adicionar, criar, seguranca, observar
    var id: String { rawValue }
}
#endif
