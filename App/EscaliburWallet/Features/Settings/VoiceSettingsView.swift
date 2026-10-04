import EscaliburCore
import SwiftUI

/// S4: confirmacao por voz, como camada a mais junto do Face ID ou do PIN.
///
/// Gravar a frase tem tres passos: falar, conferir o texto (aqui pode corrigir
/// digitando) e falar de novo. A segunda fala confere que o iPhone escreve a frase
/// sempre do mesmo jeito, inclusive a versao corrigida: sem isso, uma correcao que o
/// reconhecedor nunca escreve trancaria o dono fora da propria frase. Na hora de
/// confirmar uma operacao nao tem teclado (VoiceChallengeSheet).
struct VoiceSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @StateObject private var listener = SpeechListener()
    /// Mudar qualquer coisa aqui pede o PIN: desligar tira uma camada, e ligar com
    /// uma frase do ladrao trancaria o dono fora das proprias palavras.
    @State private var authorized = false
    @State private var step = Step.speak
    /// A frase em cadastro: o que o iPhone ouviu, com a correcao que o dono digitar.
    /// Fica em String porque o reconhecedor e o TextField so falam String (o codigo
    /// anterior guardava em `first` do mesmo jeito); some logo depois de gravar o HMAC.
    @State private var draft = ""
    @State private var heardIn: VoiceLanguage?
    @State private var other: SpeechListener.Reading?
    @State private var misses = 0
    @State private var message: String?
    @State private var needsPermission = false
    /// Gravando uma frase nova com a voz ja ligada.
    @State private var replacing = false
    @State private var saved = false
    @State private var testing = false
    @State private var testPassed = false
    @State private var testResult: String?
    @FocusState private var editing: Bool

    private enum Step { case speak, review, confirm }

    private var settings: VoiceSettings { session.metadata.settings.voice }
    private var words: Int { VoiceGate.normalize(draft).split(separator: " ").count }

    var body: some View {
        ScrollViewReader { proxy in
            content
                // No iPhone pequeno o texto de cima ocupa a tela: cada passo novo e o
                // comeco da escuta levam o passo para o alto.
                .onChange(of: step) { scroll(proxy, to: "passo") }
                .onChange(of: listener.listening) { if listener.listening { scroll(proxy, to: testing ? "teste" : "passo") } }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String) {
        withAnimation(Motion.select) { proxy.scrollTo(id, anchor: .top) }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Confirmação por voz").typeStyle(.title).foregroundStyle(Palette.ink)
                    // Do passo 2 em diante a explicacao ja foi lida e sai, para o campo
                    // da frase ficar acima do teclado no iPhone pequeno.
                    if step == .speak {
                        intro
                    }
                }
                .padding(.horizontal, Space.gutter)

                if !authorized {
                    EmptyView()
                } else if !VoiceGate.isSupported {
                    Text("Este iPhone não reconhece fala sem internet, nem em português nem em inglês, então a confirmação por voz não está disponível.")
                        .typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.md).padding(.horizontal, Space.gutter)
                        .fixedSize(horizontal: false, vertical: true)
                } else if settings.enabled && !replacing {
                    enabledOptions
                } else {
                    enrollment.padding(.horizontal, Space.gutter)
                }
            }
            .padding(.vertical, Space.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { listener.stop() }
        .task {
            guard !authorized else { return }
            let ok = (try? await auth.perform(session, reason: "Mudar a confirmação por voz", requirePIN: true, { _ in true })) == true
            if ok { authorized = true } else { dismiss() }
        }
    }


    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Uma confirmação a mais nas operações que você escolher: você fala uma frase que só você sabe, e depois confirma com o \(KeyServices.biometryName) ou o PIN, como sempre.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
            Banner(kind: .neutral, title: "O iPhone reconhece a frase, não a sua voz",
                   message: "Quem ouvir você falar pode repetir a frase. Ela protege contra quem viu o seu PIN, não contra quem está perto. A voz é processada neste iPhone e não sai dele.")
                .padding(.top, Space.md)
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

    // MARK: Gravar a frase

    private var enrollment: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(stepLabel).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.lg).id("passo")
            Text(stepTitle).typeStyle(.heading).foregroundStyle(Palette.ink).padding(.top, Space.xxs)
            Text(stepHint).typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                .fixedSize(horizontal: false, vertical: true)
            switch step {
            case .speak: speakStep
            case .review: reviewStep
            case .confirm: confirmStep
            }
        }
    }

    private var stepLabel: String {
        switch step {
        case .speak: return "Passo 1 de 3"
        case .review: return "Passo 2 de 3"
        case .confirm: return "Passo 3 de 3"
        }
    }

    private var stepTitle: String {
        switch step {
        case .speak: return replacing ? "Diga a frase nova" : "Diga a sua frase"
        case .review: return "Confira o que eu ouvi"
        case .confirm: return "Fale a frase de novo"
        }
    }

    private var stepHint: String {
        switch step {
        case .speak: return "Escolha 3 palavras ou mais que só você saiba e fale em voz normal, perto do iPhone. Eu paro de ouvir sozinho quando você terminar."
        case .review: return "Se alguma palavra saiu errada, corrija digitando. Na hora de confirmar uma operação não tem teclado: só vale falar."
        case .confirm: return "Para conferir que o iPhone escreve a frase sempre do mesmo jeito."
        }
    }

    private var speakStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VoiceListeningPanel(listener: listener, idle: "Toque em Começar a falar.")
                .padding(.top, Space.md)
            feedback
            languageNote.padding(.top, Space.sm)
            PrimaryButton(title: listener.listening ? "Terminei de falar" : "Começar a falar",
                          loading: listener.busy && !listener.listening) {
                listenOrStop { await hearPhrase() }
            }
            .padding(.top, Space.md)
            if replacing {
                TertiaryButton(title: "Manter a frase atual") {
                    listener.stop()
                    replacing = false
                    message = nil
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $draft, prompt: Text("A sua frase").foregroundColor(Palette.inkMuted), axis: .vertical)
                .typeStyle(.heading).foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($editing)
                .submitLabel(.done)
                .onChange(of: draft) {
                    // A frase e uma linha so: o retorno do teclado fecha a edicao.
                    guard draft.contains("\n") else { return }
                    draft = draft.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                    editing = false
                }
                .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                .frame(minHeight: Height.field, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .stroke(editing ? Palette.edgeStrong : Palette.edge, lineWidth: 1))
                )
                .accessibilityLabel("A sua frase")
                .accessibilityIdentifier("voz-frase-campo")
                .padding(.top, Space.md)
            if let heardIn {
                Text("Ouvi em \(heardIn.name).").typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xs)
            }
            if let other {
                TertiaryButton(title: "Foi em \(other.language.name)? Usar “\(other.text)”") {
                    let current = heardIn.map { SpeechListener.Reading(language: $0, text: draft, confidence: 0) }
                    draft = other.text
                    heardIn = other.language
                    self.other = current
                }
            }
            if words < 3 {
                Text("Use 3 palavras ou mais.").typeStyle(.note).foregroundStyle(Palette.caution).padding(.top, Space.xs)
            }
            PrimaryButton(title: "Continuar", enabled: words >= 3) {
                editing = false
                misses = 0
                message = nil
                listener.reset()
                step = .confirm
            }
            .padding(.top, Space.md)
            SecondaryButton(title: "Falar de novo") {
                editing = false
                step = .speak
                Task { await hearPhrase() }
            }
            .padding(.top, Space.xs)
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft)
                .typeStyle(.heading).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
                .padding(.top, Space.md)
            VoiceListeningPanel(listener: listener, idle: "Toque em Falar a frase.")
                .padding(.top, Space.sm)
            feedback
            PrimaryButton(title: listener.listening ? "Terminei de falar" : "Falar a frase",
                          loading: listener.busy && !listener.listening) {
                listenOrStop { await confirmPhrase() }
            }
            .padding(.top, Space.md)
            TertiaryButton(title: "Mudar a frase") {
                listener.stop()
                message = nil
                step = .review
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var feedback: some View {
        if let message {
            Text(message).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voz-mensagem")
        }
        if needsPermission {
            TertiaryButton(title: "Abrir os Ajustes do iPhone") { VoicePermission.openSettings() }
        }
    }

    private var languageNote: some View {
        let missing = VoiceLanguage.allCases.filter { !listener.languages.contains($0) }.map(\.name)
        return VStack(alignment: .leading, spacing: Space.xxs) {
            Text(VoiceGate.languageNote(listener.languages))
            if !missing.isEmpty && !listener.languages.isEmpty {
                Text("Costuma ficar disponível quando você adiciona um teclado em \(missing.joined(separator: " e ")) nos Ajustes do iPhone.")
            }
        }
        .typeStyle(.note).foregroundStyle(Palette.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// O botao principal comeca a ouvir ou, se ja estiver ouvindo, para.
    private func listenOrStop(_ action: @escaping @MainActor () async -> Void) {
        if listener.listening { listener.stop() } else { Task { await action() } }
    }

    private func permitted() async -> Bool {
        guard await SpeechListener.requestPermissions() else {
            message = VoicePermission.deniedMessage
            needsPermission = true
            return false
        }
        needsPermission = false
        return true
    }

    /// Passo 1: ouve e leva para a conferencia do texto, mesmo com menos de 3
    /// palavras (la da para completar digitando ou falar de novo).
    private func hearPhrase() async {
        message = nil
        guard await permitted() else { return }
        let heard = await listener.listen()
        if let failure = heard.failure {
            message = VoicePermission.message(for: failure)
            return
        }
        guard let best = heard.best else { return }
        draft = best.text
        heardIn = best.language
        other = heard.readings.dropFirst().first { VoiceGate.normalize($0.text) != VoiceGate.normalize(best.text) }
        step = .review
    }

    /// Passo 3: a segunda fala tem de dar o mesmo texto, em qualquer das leituras.
    private func confirmPhrase() async {
        message = nil
        guard await permitted() else { return }
        let heard = await listener.listen()
        if let failure = heard.failure {
            message = VoicePermission.message(for: failure)
            return
        }
        let target = VoiceGate.normalize(draft)
        guard heard.alternatives.contains(where: { VoiceGate.normalize($0) == target }) else {
            misses += 1
            message = misses < 2
                ? "Não conferiu com a frase acima. Fale de novo, do mesmo jeito."
                : "Ainda não conferiu. Se o iPhone escreve uma palavra de outro jeito, toque em Mudar a frase e deixe como ele escreveu."
            return
        }
        let salt = Hex.encode((try? SecureBytes.random(count: 16).withUnsafeBytes { Array($0) }) ?? [])
        session.metadata.voicePhraseSalt = salt
        session.metadata.voicePhraseHash = VoiceGate.digest(draft, salt: salt)
        session.metadata.settings.voice.enabled = true
        session.metadata.settings.voice.clearLock()
        save()
        saved = message == nil
        draft = ""
        heardIn = nil
        other = nil
        step = .speak
        replacing = false
        testing = false
        testResult = nil
        listener.reset()
    }

    // MARK: Voz ligada

    private var enabledOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if saved {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ink)
                    Text("Frase gravada. As operações marcadas abaixo pedem a frase antes do \(KeyServices.biometryName) ou do PIN.")
                        .foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
                .typeStyle(.body)
                .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("voz-gravada")
            }
            SettingsGroup {
                toggle("Pedir para ver a senha da carteira", \.onReveal)
                toggle("Pedir para lacrar envelope", \.onEnvelope)
                Toggle(isOn: Binding(get: { settings.onSendAboveFiat != nil }, set: { on in
                    session.metadata.settings.voice.onSendAboveFiat = on ? 5000 : nil
                    save()
                })) {
                    Text("Pedir em envios acima de \(Fmt.fiat(5000, session.currency))").typeStyle(.body).foregroundStyle(Palette.ink)
                }
                .tint(Palette.lime).padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
            }
            .padding(.top, Space.lg)

            VStack(alignment: .leading, spacing: 0) {
                feedback
                if testing {
                    Text("Teste a frase").typeStyle(.heading).foregroundStyle(Palette.ink).padding(.top, Space.lg).id("teste")
                    Text("Aqui errar não conta como tentativa.").typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
                    VoiceListeningPanel(listener: listener, idle: "Toque em Falar a frase.", outcome: testPassed ? .passed : nil)
                        .padding(.top, Space.sm)
                    if let testResult {
                        Text(testResult).typeStyle(.note).foregroundStyle(testPassed ? Palette.inkSoft : Palette.down).padding(.top, Space.sm)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("voz-teste")
                    }
                    PrimaryButton(title: listener.listening ? "Terminei de falar" : "Falar a frase",
                                  loading: listener.busy && !listener.listening) {
                        listenOrStop { await test() }
                    }
                    .padding(.top, Space.md)
                } else {
                    SecondaryButton(title: "Testar a minha frase") {
                        testing = true
                        Task { await test() }
                    }
                    .padding(.top, Space.lg)
                }
                SecondaryButton(title: "Gravar outra frase") {
                    listener.stop()
                    listener.reset()
                    replacing = true
                    saved = false
                    testing = false
                    testResult = nil
                    message = nil
                    step = .speak
                }
                .padding(.top, Space.xs)
                DestructiveButton(title: "Desligar a confirmação por voz") {
                    listener.stop()
                    session.metadata.settings.voice.enabled = false
                    session.metadata.voicePhraseHash = nil
                    session.metadata.voicePhraseSalt = nil
                    saved = false
                    testing = false
                    save()
                }
                .padding(.top, Space.lg)
            }
            .padding(.horizontal, Space.gutter)
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<VoiceSettings, Bool>) -> some View {
        Toggle(isOn: Binding(get: { settings[keyPath: key] }, set: { value in
            session.metadata.settings.voice[keyPath: key] = value
            save()
        })) {
            Text(title).typeStyle(.body).foregroundStyle(Palette.ink)
        }
        .tint(Palette.lime).padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
    }

    /// Ensaio da conferencia, sem contar tentativa nem pausar a voz.
    private func test() async {
        testResult = nil
        testPassed = false
        message = nil
        guard let hash = session.metadata.voicePhraseHash, let salt = session.metadata.voicePhraseSalt else { return }
        guard await permitted() else { return }
        let heard = await listener.listen()
        if let failure = heard.failure {
            testResult = VoicePermission.message(for: failure)
            return
        }
        testPassed = VoiceGate.matches(any: heard.alternatives, expected: hash, salt: salt)
        testResult = testPassed
            ? "Conferiu. É assim que a frase vai ser pedida."
            : "Não conferiu. Numa operação, isto contaria como uma tentativa errada."
    }
}
