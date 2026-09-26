import EscaliburCore
import EscaliburKeys
import SwiftUI
import UIKit

/// Pede presenca do dono para uma operacao: Face ID quando ligado, PIN quando nao,
/// ou quando o Face ID falhar. Uma folha de PIN so, hospedada na raiz do app.
@MainActor
@Observable
final class AuthCoordinator {
    struct PINRequest: Identifiable {
        let id = UUID()
        let reason: String
        let continuation: CheckedContinuation<Credential?, Never>
    }

    var pinRequest: PINRequest?

    /// A credencial para uma operacao. `reason` aparece no Face ID e na folha do PIN
    /// ("Enviar 50 XRP"). Nil quando o dono cancela.
    func credential(reason: String, forcePIN: Bool = false) async -> Credential? {
        if !forcePIN, KeyServices.root.isBiometryEnabled {
            return .biometry(reason: reason)
        }
        return await withCheckedContinuation { continuation in
            let request = PINRequest(reason: reason, continuation: continuation)
            pinRequest = request
            OverlayWindow.shared.show(PINRequestSheet(request: request, coordinator: self))
        }
    }

    /// Executa uma operacao com a chave raiz, caindo para o PIN se o Face ID for
    /// cancelado ou tiver mudado. Devolve nil se o dono desistir.
    ///
    /// `requirePIN` para o que entrega ou destroi a carteira inteira (ver as palavras,
    /// exportar envelope, remover): o rosto pode ser apresentado a forca ou com o dono
    /// dormindo; o PIN precisa ser dito.
    func perform<T: Sendable>(
        _ session: AppSession, reason: String, requirePIN: Bool = false, _ body: @escaping @Sendable (SecureBytes) throws -> T
    ) async throws -> T? {
        guard let first = await credential(reason: reason, forcePIN: requirePIN) else { return nil }
        do {
            return try await session.withRootKey(first, body)
        } catch RootKeyVault.Failure.cancelled, RootKeyVault.Failure.biometryChanged {
            guard let pin = await credential(reason: reason, forcePIN: true) else { return nil }
            return try await session.withRootKey(pin, body)
        }
    }

    fileprivate func finish(_ request: PINRequest, with credential: Credential?) {
        pinRequest = nil
        OverlayWindow.shared.hide()
        request.continuation.resume(returning: credential)
    }
}

/// A folha do PIN para confirmar uma operacao.
struct PINRequestSheet: View {
    let request: AuthCoordinator.PINRequest
    let coordinator: AuthCoordinator
    @State private var entry = PINEntry()

    var body: some View {
        PINScreen(title: "Confirme com o PIN", subtitle: request.reason, entry: entry, onComplete: {
            coordinator.finish(request, with: .pin(entry.take()))
        }) {
            TertiaryButton(title: "Cancelar") { coordinator.finish(request, with: nil) }
        }
        .interactiveDismissDisabled()
        .presentationBackground(Palette.void)
    }
}

/// Uma janela propria, acima de tudo, para pedir o PIN ou a voz no meio de qualquer
/// fluxo. Folha do SwiftUI nao abre por baixo de uma tela cheia ja apresentada, e o
/// pedido de presenca precisa aparecer de onde quer que a operacao tenha comecado.
@MainActor
final class OverlayWindow {
    static let shared = OverlayWindow()
    private var window: UIWindow?

    func show<Content: View>(_ content: Content) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let host = UIHostingController(rootView: content.preferredColorScheme(.dark))
        host.view.backgroundColor = UIColor(Palette.void)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}
