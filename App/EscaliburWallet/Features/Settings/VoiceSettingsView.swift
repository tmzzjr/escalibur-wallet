import EscaliburCore
import SwiftUI

/// S4: confirmacao por voz, como camada depois do Face ID ou do PIN.
struct VoiceSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @StateObject private var listener = SpeechListener()
    /// Mudar qualquer coisa aqui pede o PIN: desligar tira uma camada, e ligar com
    /// uma frase do ladrao trancaria o dono fora das proprias palavras.
    @State private var authorized = false
    @State private var step = 0
    @State private var first = ""
    @State private var message: String?

    private var settings: VoiceSettings { session.metadata.settings.voice }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Confirmação por voz").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Uma segunda confirmação, depois do Face ID ou do PIN, nas operações que você escolher. Você escolhe uma frase que só você sabe e fala quando o app pedir.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                Banner(kind: .neutral, title: "O iPhone reconhece a frase, não a sua voz",
                       message: "Quem ouvir você falar pode repetir a frase. Ela protege contra quem viu o seu PIN, não contra quem está perto. A voz é processada neste iPhone e não sai dele.")
                    .padding(.top, Space.md)

                if !authorized {
                    EmptyView()
                } else if !VoiceGate.isSupported {
                    Text("Este iPhone não reconhece fala em português sem internet, então a confirmação por voz não está disponível.")
                        .typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.md)
                        .fixedSize(horizontal: false, vertical: true)
                } else if settings.enabled {
                    enabledOptions
                } else {
                    enrollment
                }
            }
            .padding(Space.gutter)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !authorized else { return }
            let ok = (try? await auth.perform(session, reason: "Mudar a confirmação por voz", requirePIN: true, { _ in true })) == true
            if ok { authorized = true } else { dismiss() }
        }
    }

    private func save() {
        do {
            try session.persist()
            message = nil
        } catch {
            message = "Não foi possível salvar. Tente de novo."
        }
    }

    private var enrollment: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step == 0 ? "Fale a sua frase, com 3 palavras ou mais." : "Fale a mesma frase de novo.")
                .typeStyle(.row).foregroundStyle(Palette.ink).padding(.top, Space.lg)
            if !listener.transcript.isEmpty {
                Text("Ouvi: \(listener.transcript)").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
            }
            if let message {
                Text(message).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PrimaryButton(title: listener.listening ? "Ouvindo" : "Gravar a minha frase", enabled: !listener.listening) {
                Task { await record() }
            }
            .padding(.top, Space.lg)
        }
    }

    private var enabledOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                toggle("Pedir para ver a senha da carteira", \.onReveal)
                toggle("Pedir para lacrar envelope", \.onEnvelope)
                Toggle(isOn: Binding(get: { settings.onSendAboveFiat != nil }, set: { on in
                    session.metadata.settings.voice.onSendAboveFiat = on ? 5000 : nil
                    save()
                })) {
                    Text("Pedir em envios acima de \(Fmt.fiat(5000, session.currency))").typeStyle(.body).foregroundStyle(Palette.ink)
                }
                .tint(Palette.up).padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
            }
            .padding(.top, Space.lg)
            if let message {
                Text(message).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.xs)
            }
            DestructiveButton(title: "Desligar a confirmação por voz") {
                session.metadata.settings.voice.enabled = false
                session.metadata.voicePhraseHash = nil
                session.metadata.voicePhraseSalt = nil
                save()
            }
            .padding(.top, Space.lg)
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<VoiceSettings, Bool>) -> some View {
        Toggle(isOn: Binding(get: { settings[keyPath: key] }, set: { value in
            session.metadata.settings.voice[keyPath: key] = value
            save()
        })) {
            Text(title).typeStyle(.body).foregroundStyle(Palette.ink)
        }
        .tint(Palette.up).padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
    }

    private func record() async {
        message = nil
        guard await SpeechListener.requestPermissions() else {
            message = "Para usar a voz, o app precisa do microfone e do reconhecimento de fala."
            return
        }
        let heard = VoiceGate.normalize(await listener.listen())
        guard heard.split(separator: " ").count >= 3 else {
            message = "Não reconheci 3 palavras. Fale de novo, perto do iPhone."
            return
        }
        if step == 0 {
            first = heard
            step = 1
            return
        }
        guard heard == first else {
            message = "As duas não conferem. Vamos começar de novo."
            step = 0
            first = ""
            return
        }
        let salt = Hex.encode((try? SecureBytes.random(count: 16).withUnsafeBytes { Array($0) }) ?? [])
        session.metadata.voicePhraseSalt = salt
        session.metadata.voicePhraseHash = VoiceGate.digest(heard, salt: salt)
        session.metadata.settings.voice.enabled = true
        session.metadata.settings.voice.failedChallenges = nil
        session.metadata.settings.voice.lockedUntil = nil
        save()
        first = ""
        step = 0
    }
}
