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
        /// Aviso acima do teclado (reinicio, Face ID mudou).
        var notice: String? = nil
        /// O erro da tentativa anterior (PIN errado, espera), em vermelho no teclado.
        var error: String? = nil
        let continuation: CheckedContinuation<Credential?, Never>
    }

    var pinRequest: PINRequest?

    /// A credencial para uma operacao. `reason` aparece no Face ID e na folha do PIN
    /// ("Enviar 50 XRP"). Nil quando o dono cancela.
    func credential(reason: String, forcePIN: Bool = false, notice: String? = nil, error: String? = nil) async -> Credential? {
        let afterRestart = KeyServices.root.isBiometryEnabled && !KeyServices.root.pinEnteredThisBoot
        if !forcePIN, KeyServices.root.isBiometryEnabled, !afterRestart {
            return .biometry(reason: reason)
        }
        let notice = notice ?? (afterRestart && !forcePIN
            ? "O iPhone reiniciou: o PIN é necessário uma vez antes do \(KeyServices.biometryName) voltar a valer."
            : nil)
        return await withCheckedContinuation { continuation in
            let request = PINRequest(reason: reason, notice: notice, error: error, continuation: continuation)
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
        guard var attempt = await credential(reason: reason, forcePIN: requirePIN) else { return nil }
        // PIN errado ou espera dentro de um envio ou troca volta para o teclado com o
        // mesmo aviso da tela de bloqueio, e nao como falha de rede (auditoria 2, M4).
        // O apagamento (`wiped`) e qualquer erro da propria operacao sobem.
        while true {
            var notice: String?
            var error: String?
            do {
                return try await session.withRootKey(attempt, body)
            } catch RootKeyVault.Failure.cancelled {
                notice = nil
            } catch RootKeyVault.Failure.biometryChanged {
                notice = "O \(KeyServices.biometryName) deste iPhone mudou desde que foi ligado aqui. Confirme com o PIN; depois você pode religar."
            } catch RootKeyVault.Failure.pinRequiredAfterRestart {
                notice = "O iPhone reiniciou: o PIN é necessário uma vez antes do \(KeyServices.biometryName) voltar a valer."
            } catch RootKeyVault.Failure.wrongPIN(let remaining) {
                error = Self.wrongPINMessage(remaining)
            } catch RootKeyVault.Failure.throttled(let seconds) {
                error = "Tentativas demais. Tente de novo em \(LockView.duration(seconds))."
            }
            guard let next = await credential(reason: reason, forcePIN: true, notice: notice, error: error) else { return nil }
            attempt = next
        }
    }

    /// O aviso de PIN errado, o mesmo na tela de bloqueio e dentro das operacoes.
    static func wrongPINMessage(_ remaining: UInt32?) -> String {
        let failures = KeyServices.root.failureCount()
        if let remaining, remaining <= 3 {
            return "PIN incorreto. Depois de mais \(remaining), as carteiras deste iPhone são apagadas."
        }
        if failures >= 2 {
            return "PIN incorreto. Mais um erro e o app pede uma espera de \(LockView.duration(PINPolicy.delay(afterFailures: failures + 1)))."
        }
        return "PIN incorreto."
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
        PINScreen(title: "Confirme com o PIN", subtitle: request.notice.map { "\(request.reason)\n\n\($0)" } ?? request.reason, entry: entry, onComplete: {
            coordinator.finish(request, with: .pin(entry.take()))
        }) {
            TertiaryButton(title: "Cancelar") { coordinator.finish(request, with: nil) }
        }
        .onAppear { if let error = request.error { entry.fail(error) } }
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
