import EscaliburKeys
import SwiftUI

/// A4: o app trancado. O Face ID dispara sozinho quando o app esta na frente.
struct LockView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    /// O Face ID automatico ja foi tentado nesta vinda para a frente.
    @State private var triedBiometry = false
    @State private var entry = PINEntry()
    @State private var working = false
    @State private var forgotPIN = false
    @State private var confirmErase = false
    @State private var throttleTask: Task<Void, Never>?

    /// Depois de reiniciar (ou de a bateria acabar), o Face ID so vale depois do PIN.
    private var restartNeedsPIN: Bool { session.biometryEnabled && !KeyServices.root.pinEnteredThisBoot }

    var body: some View {
        PINScreen(
            title: "Digite o seu PIN",
            subtitle: restartNeedsPIN
                ? "O iPhone reiniciou. Depois de reiniciar ou de a bateria acabar, o PIN é necessário uma vez antes do \(KeyServices.biometryName) voltar a valer."
                : nil,
            entry: entry,
            showsBadge: true,
            biometryIcon: session.biometryEnabled && !restartNeedsPIN ? KeyServices.biometryIcon : nil,
            onBiometry: { Task { await tryBiometry() } },
            working: working,
            onComplete: { Task { await submit() } }
        ) {
            TertiaryButton(title: "Esqueci o PIN") { forgotPIN = true }
        }
        // O alerta de preco abre o app em segundo plano, as vezes com o iPhone
        // bloqueado: ai nao ha rosto para ler e o chaveiro nao responde. O Face ID
        // automatico espera o app vir para a frente, uma vez a cada vinda.
        .task(id: scenePhase) {
            guard scenePhase == .active, !triedBiometry else { return }
            triedBiometry = true
            showThrottleIfNeeded()
            if session.biometryEnabled, !restartNeedsPIN { await tryBiometry() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { triedBiometry = false }
        }
        .sheet(isPresented: $forgotPIN) { forgotSheet }
    }

    private func submit() async {
        working = true
        defer { working = false }
        let pin = entry.take()
        do {
            try await session.unlock(pin: pin)
        } catch let failure as RootKeyVault.Failure {
            handle(failure)
        } catch {
            entry.fail("Não foi possível destravar. Tente de novo.")
        }
    }

    private func tryBiometry() async {
        guard session.biometryEnabled, KeyServices.root.throttleRemaining() <= 0 else { return }
        do {
            try await session.unlockWithBiometry()
        } catch RootKeyVault.Failure.pinRequiredAfterRestart {
            entry.fail("O iPhone reiniciou. Digite o PIN uma vez para o \(KeyServices.biometryName) voltar a valer.")
        } catch RootKeyVault.Failure.biometryChanged {
            entry.fail("O \(KeyServices.biometryName) deste iPhone mudou desde que foi ligado aqui. Entre com o PIN; depois você pode religar.")
        } catch {
            // Cancelado: o teclado continua ali.
        }
    }

    private func handle(_ failure: RootKeyVault.Failure) {
        switch failure {
        case .wrongPIN(let remaining):
            entry.fail(AuthCoordinator.wrongPINMessage(remaining))
            showThrottleIfNeeded()
        case .throttled(let seconds):
            entry.fail("Tentativas demais. Tente de novo em \(Self.duration(seconds)).")
            showThrottleIfNeeded()
        case .wiped:
            session.eraseEverything()
        default:
            entry.fail("Não foi possível destravar. Tente de novo.")
        }
    }

    private func showThrottleIfNeeded() {
        guard KeyServices.root.throttleRemaining() > 0 else { return }
        throttleTask?.cancel()
        throttleTask = Task { @MainActor in
            while !Task.isCancelled {
                let left = KeyServices.root.throttleRemaining()
                if left <= 0 {
                    entry.error = nil
                    return
                }
                entry.error = "Tentativas demais. Tente de novo em \(Self.duration(left))."
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return s == 1 ? "1 segundo" : "\(s) segundos" }
        let m = Int((Double(s) / 60).rounded(.up))
        if m < 60 { return m == 1 ? "1 minuto" : "\(m) minutos" }
        let h = Int((Double(m) / 60).rounded(.up))
        return h == 1 ? "1 hora" : "\(h) horas"
    }

    private var forgotSheet: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "") { forgotPIN = false }
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "lock.iphone")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Palette.control))
                    Text("Não existe redefinir o PIN")
                        .typeStyle(.title).foregroundStyle(Palette.ink)
                        .padding(.top, Space.md)
                    Text("O PIN mora só neste iPhone, e ninguém tem cópia dele, nem a Escalibur. Para voltar a usar o app, comece de novo:")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.xs)
                    VStack(alignment: .leading, spacing: Space.md) {
                        ForgotStep(number: 1, text: "Tenha em mãos a senha de cada carteira (as 12 ou 24 palavras) ou o envelope Escalibur.")
                        ForgotStep(number: 2, text: "Apague as carteiras deste iPhone.")
                        ForgotStep(number: 3, text: "Crie um PIN novo e importe cada carteira de novo.")
                    }
                    .padding(Space.base)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
                    .padding(.top, Space.lg)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xs)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: Space.sm) {
                DestructiveButton(title: "Apagar as carteiras deste iPhone") { confirmErase = true }
                SecondaryButton(title: "Voltar e tentar o PIN") { forgotPIN = false }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xs)
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
        // O alerta do proprio iPhone, no centro da tela: apagar e para sempre.
        .alert("Apagar as carteiras deste iPhone?", isPresented: $confirmErase) {
            Button("Apagar permanentemente", role: .destructive) {
                forgotPIN = false
                session.eraseEverything()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Sem a senha de cada carteira ou um envelope, o saldo delas fica inacessível para sempre.")
        }
    }
}

/// Um passo numerado de como voltar a usar o app sem o PIN.
private struct ForgotStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.control))
            Text(text).typeStyle(.body).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
    }
}
