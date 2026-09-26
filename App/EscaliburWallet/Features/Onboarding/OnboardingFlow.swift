import EscaliburCore
import EscaliburKeys
import SwiftUI

/// A1 e A2: boas-vindas e o primeiro PIN. O PIN vem antes de a frase existir.
struct OnboardingFlow: View {
    @Environment(AppSession.self) private var session
    @State private var step: Step = .welcome
    @State private var entry = PINEntry()
    @State private var firstPIN: SecureBytes?
    @State private var working = false

    enum Step { case welcome, choosePIN, repeatPIN }

    var body: some View {
        ZStack {
            Palette.void.ignoresSafeArea()
            switch step {
            case .welcome: welcome.transition(.opacity)
            case .choosePIN:
                PINScreen(
                    title: "Escolha um PIN",
                    subtitle: "Seis dígitos para destravar o app e confirmar envios quando o Face ID falhar.",
                    entry: entry, onComplete: choose
                ) { pinFooter }
                .transition(.opacity)
            case .repeatPIN:
                PINScreen(
                    title: "Repita o PIN",
                    subtitle: "Os mesmos seis dígitos.",
                    entry: entry, working: working, onComplete: { Task { await confirm() } }
                ) { pinFooter }
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: step)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            WalletBadge(size: 40).padding(.top, Space.md)
            Spacer()
            Text("Uma carteira que só você abre")
                .typeStyle(.hero)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("As chaves ficam neste iPhone. Sem conta e sem e\u{2011}mail: a Escalibur não tem como ver, mover nem recuperar o seu saldo.")
                .typeStyle(.body)
                .foregroundStyle(Palette.inkSoft)
                .padding(.top, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
            if DeviceIntegrity.suspicious {
                Banner(kind: .caution, title: "Este iPhone parece ter jailbreak",
                       message: "Apps de fora da App Store podem ler o que este app guarda.")
                    .padding(.top, Space.lg)
            }
            if !KeyServices.deviceIsEligible {
                Banner(kind: .failure, title: "Este iPhone não tem código",
                       message: "Configure um código em Ajustes do iPhone. Sem ele, o iOS não protege as chaves da carteira.")
                    .padding(.top, Space.lg)
            }
            PrimaryButton(title: "Começar", enabled: KeyServices.deviceIsEligible) {
                step = .choosePIN
            }
            .padding(.top, Space.xl)
            Text("Ao continuar, você aceita os Termos de uso e a Política de privacidade.")
                .typeStyle(.note)
                .foregroundStyle(Palette.inkMuted)
                .padding(.top, Space.sm)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.xs)
    }

    private var pinFooter: some View {
        Text("O PIN não recupera a carteira. Se você esquecer o PIN, a senha da carteira traz tudo de volta.")
            .typeStyle(.note)
            .foregroundStyle(Palette.inkMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.xl)
    }

    private func choose() {
        let pin = entry.take()
        if RootKeyVault.isBlocked(pin) {
            pin.wipe()
            entry.fail("Este PIN é fácil de adivinhar. Escolha outro.")
            return
        }
        firstPIN = pin
        step = .repeatPIN
    }

    private func confirm() async {
        let second = entry.take()
        guard let first = firstPIN else { return }
        let same = Hash.constantTimeEqual(first, second)
        second.wipe()
        guard same else {
            first.wipe()
            firstPIN = nil
            entry.fail("Os dois não conferem. Escolha de novo.")
            step = .choosePIN
            return
        }
        working = true
        defer { working = false }
        do {
            firstPIN = nil
            try await session.setUpPIN(first)
        } catch {
            entry.fail("Não foi possível guardar o PIN neste iPhone.")
            step = .choosePIN
        }
    }
}

/// A3: oferecer o Face ID, depois do PIN e antes da primeira carteira.
struct BiometryOfferView: View {
    @Environment(AppSession.self) private var session
    let onDone: () -> Void
    @State private var askPIN = false
    @State private var entry = PINEntry()
    @State private var working = false

    var body: some View {
        if askPIN {
            PINScreen(title: "Confirme com o PIN", subtitle: "Para ligar o Face ID nesta carteira.", entry: entry, working: working,
                      onComplete: { Task { await enable() } }) { EmptyView() }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                Image(systemName: "faceid")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Palette.ink)
                Text("Destravar com o Face ID")
                    .typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.lg)
                Text("Destrava o app e confirma envios em 1 segundo. Se o Face ID falhar, o PIN vale.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                PrimaryButton(title: "Usar o Face ID") { askPIN = true }
                SecondaryButton(title: "Agora não") { onDone() }.padding(.top, Space.sm)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xs)
            .background(Palette.void.ignoresSafeArea())
        }
    }

    private func enable() async {
        working = true
        defer { working = false }
        do {
            try await session.enableBiometry(pin: entry.take())
            onDone()
        } catch RootKeyVault.Failure.wrongPIN {
            entry.fail("PIN incorreto.")
        } catch RootKeyVault.Failure.cancelled {
            entry.fail("O Face ID não confirmou. Ele continua desligado; você pode ligar depois nos Ajustes.")
        } catch {
            entry.fail("Não foi possível ligar o Face ID agora.")
        }
    }
}
