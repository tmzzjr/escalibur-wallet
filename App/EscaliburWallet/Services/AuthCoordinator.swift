import EscaliburCore
import EscaliburKeys
import SwiftUI

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
            pinRequest = PINRequest(reason: reason, continuation: continuation)
        }
    }

    /// Executa uma operacao com a chave raiz, caindo para o PIN se o Face ID for
    /// cancelado ou tiver mudado. Devolve nil se o dono desistir.
    func perform<T: Sendable>(
        _ session: AppSession, reason: String, _ body: @escaping @Sendable (SecureBytes) throws -> T
    ) async throws -> T? {
        guard let first = await credential(reason: reason) else { return nil }
        do {
            return try await session.withRootKey(first, body)
        } catch RootKeyVault.Failure.cancelled, RootKeyVault.Failure.biometryChanged {
            guard let pin = await credential(reason: reason, forcePIN: true) else { return nil }
            return try await session.withRootKey(pin, body)
        }
    }

    fileprivate func finish(_ request: PINRequest, with credential: Credential?) {
        pinRequest = nil
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
