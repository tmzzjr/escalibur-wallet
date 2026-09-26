import EscaliburKeys
import SwiftUI

/// A4: o app trancado. O Face ID dispara sozinho quando a tela aparece.
struct LockView: View {
    @Environment(AppSession.self) private var session
    @State private var entry = PINEntry()
    @State private var working = false
    @State private var forgotPIN = false
    @State private var confirmErase = false
    @State private var throttleTask: Task<Void, Never>?

    var body: some View {
        PINScreen(
            title: "Digite o seu PIN",
            subtitle: nil,
            entry: entry,
            showsBadge: true,
            biometryIcon: session.biometryEnabled ? "faceid" : nil,
            onBiometry: { Task { await tryBiometry() } },
            working: working,
            onComplete: { Task { await submit() } }
        ) {
            TertiaryButton(title: "Esqueci o PIN") { forgotPIN = true }
        }
        .task {
            showThrottleIfNeeded()
            if session.biometryEnabled { await tryBiometry() }
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
        } catch RootKeyVault.Failure.biometryChanged {
            entry.fail("O Face ID deste iPhone mudou desde que foi ligado aqui. Entre com o PIN; depois você pode religar.")
        } catch {
            // Cancelado: o teclado continua ali.
        }
    }

    private func handle(_ failure: RootKeyVault.Failure) {
        switch failure {
        case .wrongPIN(let remaining):
            let failures = KeyServices.root.failureCount()
            if let remaining, remaining <= 3 {
                entry.fail("PIN incorreto. Depois de mais \(remaining), as carteiras deste iPhone são apagadas.")
            } else if failures >= 2 {
                let next = PINPolicy.delay(afterFailures: failures + 1)
                entry.fail("PIN incorreto. Mais um erro e o app pede uma espera de \(Self.duration(next)).")
            } else {
                entry.fail("PIN incorreto.")
            }
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
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Não existe redefinir o PIN") { forgotPIN = false }
            Text("O PIN mora só neste iPhone. Para voltar a usar o app, apague as carteiras deste aparelho e importe de novo, com a senha de cada carteira ou com um envelope Escalibur.")
                .typeStyle(.body)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
            Spacer()
            DestructiveButton(title: "Apagar as carteiras deste iPhone") { confirmErase = true }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xs)
        }
        .presentationDetents([.medium])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
        .confirmationDialog("Apagar as carteiras deste iPhone?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Apagar", role: .destructive) {
                forgotPIN = false
                session.eraseEverything()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Sem a senha de cada carteira, o saldo delas fica inacessível para sempre.")
        }
    }
}
