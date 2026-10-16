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

    /// O que uma operacao pede ao dono.
    enum Presence {
        /// Face ID quando ligado, PIN quando nao: envios, trocas, ordens.
        case either
        /// O PIN sempre: o que muda as barreiras (tempo de bloqueio, apagar apos erros, voz).
        case pin
        /// O PIN e, com o Face ID ligado, o rosto tambem (A1): o que entrega ou destroi a
        /// carteira inteira (ver as palavras, lacrar o envelope, remover) e desligar o Face
        /// ID. O rosto pode ser apresentado a forca ou com o dono dormindo; o PIN pode ter
        /// sido visto. Os dois juntos, nao.
        case pinAndBiometry
    }

    /// A credencial para uma operacao. `reason` aparece no Face ID e na folha do PIN
    /// ("Enviar 50 XRP"). Nil quando o dono cancela.
    func credential(reason: String, forcePIN: Bool = false, notice: String? = nil, error: String? = nil) async -> Credential? {
        // Modo reforcado: toda operacao e o PIN e depois o rosto, pela criptografia.
        if KeyServices.root.securityMode == .hardened {
            let pin: Credential? = await withCheckedContinuation { continuation in
                let request = PINRequest(reason: reason, notice: notice ?? Self.hardenedNotice, error: error, continuation: continuation)
                pinRequest = request
                OverlayWindow.shared.show(PINRequestSheet(request: request, coordinator: self))
            }
            guard case .pin(let digits)? = pin else { return nil }
            return .hardened(digits, reason: reason)
        }
        let afterRestart = KeyServices.root.isBiometryEnabled && !KeyServices.root.pinEnteredThisBoot
        if !forcePIN, KeyServices.root.isBiometryEnabled, !afterRestart {
            return .biometry(reason: reason)
        }
        let notice = notice ?? (afterRestart && !forcePIN
            ? String(localized: "O iPhone reiniciou: o PIN é necessário uma vez antes do \(KeyServices.biometryName) voltar a valer.")
            : nil)
        return await withCheckedContinuation { continuation in
            let request = PINRequest(reason: reason, notice: notice, error: error, continuation: continuation)
            pinRequest = request
            OverlayWindow.shared.show(PINRequestSheet(request: request, coordinator: self))
        }
    }

    /// Executa uma operacao com a chave raiz, caindo para o PIN se o Face ID for
    /// cancelado ou tiver mudado. Devolve nil se o dono desistir.
    func perform<T: Sendable>(
        _ session: AppSession, reason: String, presence: Presence = .either, _ body: @escaping @Sendable (SecureBytes) throws -> T
    ) async throws -> T? {
        try await retrying(reason: reason, presence: presence) { try await session.withRootKey($0, body) }
    }

    /// O laco de `perform` para operacoes que recebem a credencial pronta (guardar uma
    /// carteira): Face ID cancelado, mudado ou pedindo o PIN depois de reiniciar cai
    /// para o PIN; PIN errado ou espera volta ao teclado com o aviso. Antes, guardar uma
    /// carteira com o Face ID ligado nao tinha esse laco, e qualquer falha do rosto
    /// virava "Nao foi possivel importar" (visto no iPhone). Devolve nil se o dono
    /// desistir; o apagamento (`wiped`) e qualquer erro da propria operacao sobem.
    func retrying<T>(reason: String, presence: Presence = .either, _ operation: (Credential) async throws -> T) async throws -> T? {
        // A espera do A1, e o Face ID perdido e nao religado, recusam antes do teclado:
        // digitar o PIN para ouvir "espere" nao ajuda ninguem. O cofre confere de novo.
        if presence == .pinAndBiometry { try Self.checkPINAndBiometry() }
        let both = presence == .pinAndBiometry
        guard var attempt = await credential(reason: reason, forcePIN: presence != .either, notice: both ? Self.bothNotice : nil) else { return nil }
        while true {
            if both, case .pin(let pin) = attempt { attempt = .pinAndBiometry(pin, reason: reason) }
            var notice: String?
            var error: String?
            do {
                return try await operation(attempt)
            } catch RootKeyVault.Failure.cancelled {
                notice = both ? Self.bothCancelledNotice : nil
            } catch RootKeyVault.Failure.biometryChanged {
                // Nas operacoes que pedem os dois, o Face ID que caiu agora so volta religado:
                // nada de seguir so com o PIN.
                if both { throw RootKeyVault.Failure.biometryRequired }
                notice = String(localized: "O \(KeyServices.biometryName) deste iPhone mudou desde que foi ligado aqui. Confirme com o PIN; depois você pode religar.")
            } catch RootKeyVault.Failure.pinRequiredAfterRestart {
                notice = String(localized: "O iPhone reiniciou: o PIN é necessário uma vez antes do \(KeyServices.biometryName) voltar a valer.")
            } catch RootKeyVault.Failure.wrongPIN(let remaining) {
                error = Self.wrongPINMessage(remaining)
            } catch RootKeyVault.Failure.throttled(let seconds) {
                error = String(localized: "Tentativas demais. Tente de novo em \(LockView.duration(seconds)).")
            } catch RootKeyVault.Failure.biometryNotConfirmed(let remaining) {
                error = Self.faceNotConfirmedMessage(remaining)
            }
            guard let next = await credential(reason: reason, forcePIN: true, notice: notice ?? (both ? Self.bothNotice : nil), error: error) else { return nil }
            attempt = next
        }
    }

    /// Modo reforcado: o aviso acima do teclado de toda operacao.
    private static var hardenedNotice: String {
        String(localized: "Modo reforçado: depois do PIN, o \(KeyServices.biometryName) confirma que é você.")
    }

    /// O rosto que nao confirmou no modo reforcado conta como tentativa, como um PIN errado.
    static func faceNotConfirmedMessage(_ remaining: UInt32?) -> String {
        let base: String
        if let remaining, remaining <= 3 {
            base = String(localized: "O \(KeyServices.biometryName) não confirmou, e isso conta como tentativa. Depois de mais \(remaining), as carteiras deste iPhone são apagadas.")
        } else {
            base = String(localized: "O \(KeyServices.biometryName) não confirmou, e isso conta como tentativa.")
        }
        // O cadastro de rostos parece outro (o hash mudou e a chave continua la): o dono fica
        // sabendo do caminho de volta, sem o app declarar o cofre perdido por um hash.
        guard KeyServices.root.hardenedEnrollmentChanged else { return base }
        return base + " " + String(localized: "Se o cadastro de rostos deste iPhone mudou, só as palavras de cada carteira trazem as carteiras de volta.")
    }

    /// Com o Face ID ligado, o aviso acima do teclado de uma operacao que pede os dois.
    private static var bothNotice: String? {
        KeyServices.root.isBiometryEnabled ? String(localized: "Depois do PIN, o \(KeyServices.biometryName) confirma que é você.") : nil
    }

    private static var bothCancelledNotice: String {
        String(localized: "O \(KeyServices.biometryName) não confirmou. Com ele ligado, isto pede o PIN e o rosto.")
    }

    /// O que pede PIN e rosto pode comecar agora? Para as telas perguntarem antes do PIN e
    /// da frase de voz (`VoiceGate`).
    static func checkPINAndBiometry() throws {
        try KeyServices.root.checkPINAndBiometryAllowed()
    }

    /// O texto de uma recusa que a tela mostra no lugar do erro generico. Nil quando nao e
    /// uma recusa conhecida.
    static func refusalMessage(_ error: Error) -> String? {
        switch error as? RootKeyVault.Failure {
        case .biometryHold(let seconds):
            return String(localized: "O \(KeyServices.biometryName) deste iPhone mudou há pouco. Por segurança, isto volta a funcionar em \(LockView.duration(seconds)).")
        case .biometryRequired:
            return String(localized: "O \(KeyServices.biometryName) deste iPhone mudou desde que foi ligado aqui. Para isto, ligue o \(KeyServices.biometryName) de novo em Ajustes, Segurança; por segurança, volta a funcionar 24 horas depois.")
        case .biometryUnavailable:
            return String(localized: "O \(KeyServices.biometryName) não está disponível agora. Confira se ele está ligado para a Escalibur em Ajustes do iPhone e tente de novo. Pelo Espelhamento do iPhone, isto não funciona.")
        case .biometryLockedOut:
            return String(localized: "O iPhone bloqueou o \(KeyServices.biometryName) depois de tentativas demais. Bloqueie e desbloqueie o iPhone com o código, e tente de novo.")
        case .hardenedSlotLost:
            return String(localized: "O \(KeyServices.biometryName) deste iPhone mudou desde que o modo reforçado foi ligado. As carteiras não abrem mais aqui: só as palavras de cada carteira trazem de volta.")
        default:
            return nil
        }
    }

    /// O aviso de PIN errado, o mesmo na tela de bloqueio e dentro das operacoes.
    static func wrongPINMessage(_ remaining: UInt32?) -> String {
        let failures = KeyServices.root.failureCount()
        if let remaining, remaining <= 3 {
            return String(localized: "PIN incorreto. Depois de mais \(remaining), as carteiras deste iPhone são apagadas.")
        }
        if failures >= 2 {
            return String(localized: "PIN incorreto. Mais um erro e o app pede uma espera de \(LockView.duration(PINPolicy.delay(afterFailures: failures + 1))).")
        }
        return String(localized: "PIN incorreto.")
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
        PINScreen(title: String(localized: "Confirme com o PIN"), subtitle: request.notice.map { "\(request.reason)\n\n\($0)" } ?? request.reason, entry: entry, onComplete: {
            coordinator.finish(request, with: .pin(entry.take()))
        }) {
            TertiaryButton(title: String(localized: "Cancelar")) { coordinator.finish(request, with: nil) }
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
