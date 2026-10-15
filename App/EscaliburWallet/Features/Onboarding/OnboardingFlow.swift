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
    @State private var legalDocument: LegalDocument?

    enum Step { case welcome, choosePIN, repeatPIN }

    var body: some View {
        ZStack {
            Palette.void.ignoresSafeArea()
            switch step {
            case .welcome: welcome.transition(.opacity)
            case .choosePIN, .repeatPIN:
                // Uma tela so para escolher e repetir: so o titulo e o texto trocam. Duas
                // telas com fade piscavam, e o teclado mudava de altura com o texto.
                let chooseText = String(localized: "Seis dígitos para destravar o app e confirmar envios quando o \(KeyServices.biometryName) falhar.")
                PINScreen(
                    title: step == .choosePIN ? String(localized: "Escolha um PIN") : String(localized: "Repita o PIN"),
                    subtitle: step == .choosePIN ? chooseText : String(localized: "Os mesmos seis dígitos."),
                    subtitleSpace: chooseText,
                    entry: entry, working: working,
                    onComplete: { if step == .choosePIN { choose() } else { Task { await confirm() } } }
                ) { pinFooter }
                .overlay(alignment: .topLeading) { backButton }
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: step)
        .sheet(item: $legalDocument) { LegalDocumentView(document: $0) }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            SwordInStone()
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                .padding(.top, Space.xs)
            VStack(spacing: Space.sm) {
                Text("Só você tira a espada da pedra")
                    .typeStyle(.hero)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("As chaves ficam só neste iPhone, fora do backup do iCloud. Sem conta e sem e\u{2011}mail: a Escalibur não tem como ver, mover nem recuperar o seu saldo.")
                    .typeStyle(.body)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.top, Space.lg)
            if DeviceIntegrity.suspicious {
                Banner(kind: .caution, title: String(localized: "Este iPhone parece ter jailbreak"),
                       message: String(localized: "Apps de fora da App Store podem ler o que este app guarda."))
                    .padding(.top, Space.md)
            }
            if !KeyServices.deviceIsEligible {
                Banner(kind: .failure, title: String(localized: "Este iPhone não tem código"),
                       message: String(localized: "Configure um código em Ajustes do iPhone. Sem ele, o iOS não protege as chaves da carteira."))
                    .padding(.top, Space.md)
            }
            PrimaryButton(title: String(localized: "Começar"), enabled: KeyServices.deviceIsEligible) {
                step = .choosePIN
            }
            .padding(.top, Space.lg)
            Text("Ao continuar, você aceita os [Termos de uso](escalibur-doc:termos) e a [Política de privacidade](escalibur-doc:privacidade).")
                .typeStyle(.note)
                .foregroundStyle(Palette.inkMuted)
                .tint(Palette.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.sm)
                .environment(\.openURL, OpenURLAction { url in
                    legalDocument = LegalDocument(rawValue: url.absoluteString.replacingOccurrences(of: "escalibur-doc:", with: ""))
                    return .handled
                })
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.xs)
    }

    /// Escolher volta para a abertura; repetir volta para escolher, e o primeiro PIN e
    /// apagado.
    private var backButton: some View {
        Button {
            if step == .repeatPIN {
                firstPIN?.wipe()
                firstPIN = nil
                entry.reset()
                step = .choosePIN
            } else {
                entry.reset()
                step = .welcome
            }
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .padding(.leading, Space.xs)
        .disabled(working)
        .accessibilityLabel("Voltar")
        .accessibilityIdentifier("pin-voltar")
    }

    private var pinFooter: some View {
        Text("O PIN não recupera a carteira. Se você esquecer o PIN, a senha da carteira traz tudo de volta.")
            .typeStyle(.note)
            .foregroundStyle(Palette.inkMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.xl)
    }

    private func choose() {
        firstPIN = entry.take()
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
            entry.fail(String(localized: "Os dois não conferem. Escolha de novo."))
            step = .choosePIN
            return
        }
        working = true
        defer { working = false }
        do {
            firstPIN = nil
            try await session.setUpPIN(first)
        } catch {
            entry.fail(String(localized: "Não foi possível guardar o PIN neste iPhone."))
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
            PINScreen(title: String(localized: "Confirme com o PIN"), subtitle: String(localized: "Para ligar o \(KeyServices.biometryName) nesta carteira."), entry: entry, working: working,
                      onComplete: { Task { await enable() } }) {
                TertiaryButton(title: String(localized: "Voltar")) {
                    entry = PINEntry()
                    askPIN = false
                }
                .accessibilityIdentifier("biometria-voltar")
            }
        } else {
            VStack(spacing: 0) {
                Spacer()
                Image(systemName: KeyServices.biometryIcon)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(Palette.rail))
                Text("Destravar com o \(KeyServices.biometryName)")
                    .typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.lg)
                Text("Destrava o app e confirma envios em 1 segundo. Se o \(KeyServices.biometryName) falhar, o PIN vale.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                PrimaryButton(title: String(localized: "Usar o \(KeyServices.biometryName)")) { askPIN = true }
                SecondaryButton(title: String(localized: "Agora não")) { onDone() }.padding(.top, Space.sm)
            }
            .multilineTextAlignment(.center)
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
            entry.fail(String(localized: "PIN incorreto."))
        } catch RootKeyVault.Failure.throttled(let seconds) {
            entry.fail(String(localized: "Tentativas demais. Tente de novo em \(LockView.duration(seconds))."))
        } catch RootKeyVault.Failure.cancelled {
            entry.fail(String(localized: "O \(KeyServices.biometryName) não confirmou. Ele continua desligado; você pode ligar depois nos Ajustes."))
        } catch {
            entry.fail(String(localized: "Não foi possível ligar o \(KeyServices.biometryName) agora."))
        }
    }
}
