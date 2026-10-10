import SwiftUI
import UIKit

/// As defesas que nao sao criptografia, herdadas do Escalibur.
///
/// Uma carteira com a melhor derivacao de chave do mundo e uma frase parada num PNG
/// do seletor de tarefas nao e uma carteira segura. Nenhuma destas e opcional.
final class PlatformGuards: NSObject, UIApplicationDelegate {
    private static let coverTag = 0xE5C1

    /// Instala os observadores de ciclo de vida. Chamado uma vez, na abertura.
    @MainActor
    static func install() {
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { cover() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { uncover() }
        }
    }

    /// Bloqueia teclados de terceiros no app inteiro. Um teclado de terceiro e o
    /// jeito mais barato de registrar uma frase de recuperacao enquanto ela e digitada.
    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier identifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        identifier != .keyboard
    }

    /// Cobre todas as janelas antes da foto do seletor de tarefas. A foto e tirada
    /// entre `willResignActive` e `didEnterBackground` e vai para o disco fora da
    /// criptografia do app; cobrir so em `didEnterBackground` seria tarde. Cobertura
    /// opaca, nao desfoque: desfoque baixo deixa palavra em mono legivel.
    @MainActor
    private static func cover() {
        for window in allWindows where window.viewWithTag(coverTag) == nil {
            // A tela inteira no rosa da marca, com o icone do app no centro (`StandbyCover`).
            let host = UIHostingController(rootView: StandbyCover())
            let cover = host.view!
            cover.frame = window.bounds
            cover.backgroundColor = UIColor(Palette.brand)
            cover.tag = coverTag
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(cover)
        }
    }

    @MainActor
    private static func uncover() {
        for window in allWindows { window.viewWithTag(coverTag)?.removeFromSuperview() }
    }

    @MainActor
    private static var allWindows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }
}

/// A capa do seletor de apps: o rosa da marca e o icone do app no centro, com a borda
/// e a sombra do icone. So a espada, solta no rosa, terminava num corte seco onde o
/// icone acaba (relatado no iPhone); com o contorno do icone, o corte e a borda dele.
struct StandbyCover: View {
    var body: some View {
        ZStack {
            Palette.brand.ignoresSafeArea()
            WalletBadge(size: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 120 * 0.2237, style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                )
                .shadow(color: Color(hex: 0x5C0030).opacity(0.45), radius: 28, y: 12)
        }
        .accessibilityHidden(true)
    }
}

/// Esconde o conteudo sensivel durante gravacao ou espelhamento de tela, e avisa
/// depois de uma captura. Nao e blindagem: a captura so notifica depois do fato. A
/// defesa real e a tela da frase comecar oculta e mostrar poucas palavras por vez.
struct CaptureGuard: ViewModifier {
    @State private var captured = false
    @State private var screenshotWarning = false

    /// Tela inteira gravada ou espelhada (`isCaptured`), ou a propria cena sendo
    /// capturada (`sceneCaptureState`, iOS 17: captura de uma janela so, que
    /// `isCaptured` nao ve).
    private static var anyScreenCaptured: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { scene in
            scene.screen.isCaptured || scene.traitCollection.sceneCaptureState == .active
        }
    }

    func body(content: Content) -> some View {
        ZStack {
            content.opacity(captured ? 0 : 1)
            if captured {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("A tela está sendo gravada ou espelhada")
                        .typeStyle(.row).foregroundStyle(Palette.ink)
                    Text("As palavras voltam quando isso parar.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Palette.void)
            }
        }
        .onAppear { captured = Self.anyScreenCaptured }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = Self.anyScreenCaptured
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            captured = Self.anyScreenCaptured
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            screenshotWarning = true
        }
        .alert("Você fez uma captura de tela", isPresented: $screenshotWarning) {
            Button("Entendi", role: .cancel) {}
        } message: {
            Text("A captura está na Fototeca e pode já ter subido para o iCloud. Se ela mostra as palavras da carteira, apague agora.")
        }
    }
}

extension View {
    /// Aplicar em toda tela que possa mostrar palavras da frase ou segredo.
    func guardedAgainstCapture() -> some View { modifier(CaptureGuard()) }
}
