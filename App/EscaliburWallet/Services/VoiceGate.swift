import AVFoundation
import CryptoKit
import EscaliburCore
import Speech
import SwiftUI

/// Confirmacao por voz: uma camada **depois** do Face ID ou do PIN, nunca no lugar
/// deles, nas acoes que o dono escolher.
///
/// O que ela e, dito na tela e aqui: o iPhone reconhece **a frase**, nao a voz. O
/// iOS nao tem verificacao de locutor, e voz clonada ou gravada passaria por
/// qualquer "verificacao" feita no processo. A frase e uma segunda senha falada:
/// protege contra quem viu o PIN mas nao conhece a frase. Nao protege contra quem
/// ouve o dono falar nem contra malware no aparelho. O agente de seguranca
/// recomendou nao oferecer voz; o dono escolheu oferecer como camada extra, e o texto
/// da tela nao promete mais que isto (docs/seguranca.md §3).
///
/// Reconhecimento so no aparelho (`requiresOnDeviceRecognition`). Se o aparelho nao
/// reconhece localmente, o recurso nao liga: nunca cai para o servidor da Apple. O
/// audio nao e gravado e a transcricao nao e registrada.
@MainActor
@Observable
final class VoiceGate {
    static let shared = VoiceGate()

    enum Action { case reveal, envelope, send(fiat: Double) }

    struct Challenge: Identifiable {
        let id = UUID()
        let continuation: CheckedContinuation<Bool, Never>
        let expected: String
        let salt: String
    }

    var challenge: Challenge?

    static var locale: Locale { Locale(identifier: "pt-BR") }

    static var isSupported: Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }

    /// Precisa de voz para esta acao? Se sim, pede; se nao, deixa passar.
    func confirm(_ action: Action, session: AppSession) async -> Bool {
        let settings = session.metadata.settings.voice
        guard settings.enabled, let hash = session.metadata.voicePhraseHash, let salt = session.metadata.voicePhraseSalt else { return true }
        switch action {
        case .reveal: guard settings.onReveal else { return true }
        case .envelope: guard settings.onEnvelope else { return true }
        case .send(let fiat): guard let limit = settings.onSendAboveFiat, fiat >= limit else { return true }
        }
        return await withCheckedContinuation { continuation in
            let challenge = Challenge(continuation: continuation, expected: hash, salt: salt)
            self.challenge = challenge
            OverlayWindow.shared.show(VoiceChallengeSheet(challenge: challenge))
        }
    }

    func finish(_ challenge: Challenge, passed: Bool) {
        self.challenge = nil
        OverlayWindow.shared.hide()
        challenge.continuation.resume(returning: passed)
    }

    // MARK: Frase

    /// Forma canonica do que foi dito: minusculas, sem acento, sem pontuacao, um
    /// espaco entre palavras.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func digest(_ phrase: String, salt: String) -> String {
        Hex.encode(Hash.hmacSHA256(key: Array(salt.utf8), data: Array(normalize(phrase).utf8)))
    }
}

extension Metadata {
    /// HMAC da frase de voz normalizada. Cifrado junto com o resto dos metadados.
    var voicePhraseHash: String? {
        get { settings.voicePhraseHash }
        set { settings.voicePhraseHash = newValue }
    }

    var voicePhraseSalt: String? {
        get { settings.voicePhraseSalt }
        set { settings.voicePhraseSalt = newValue }
    }
}

/// Ouve ate 6 segundos e devolve o que reconheceu, so no aparelho.
@MainActor
final class SpeechListener: ObservableObject {
    @Published var transcript = ""
    @Published var level: Float = 0
    @Published var listening = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func listen() async -> String {
        guard let recognizer = SFSpeechRecognizer(locale: VoiceGate.locale), recognizer.supportsOnDeviceRecognition else { return "" }
        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        self.request = request

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let samples = buffer.floatChannelData?[0]
            var peak: Float = 0
            if let samples { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) } }
            Task { @MainActor in self?.level = peak }
        }
        engine.prepare()
        try? engine.start()
        listening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            Task { @MainActor in self?.transcript = result.bestTranscription.formattedString }
        }
        try? await Task.sleep(for: .seconds(6))
        stop()
        return transcript
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        listening = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

/// S4b: "Diga a sua frase de voz".
struct VoiceChallengeSheet: View {
    let challenge: VoiceGate.Challenge
    @StateObject private var listener = SpeechListener()
    @State private var attempts = 0
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Diga a sua frase de voz") { VoiceGate.shared.finish(challenge, passed: false) }
            Text("Depois do Face ID ou do PIN, a frase que só você sabe. O iPhone reconhece a frase, não a sua voz.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(0..<24, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Float(index) / 24 < listener.level * 3 ? Palette.ink : Palette.rail)
                        .frame(width: 6, height: 28)
                }
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
            if let message {
                Text(message).typeStyle(.note).foregroundStyle(Palette.down).padding(.horizontal, Space.gutter).padding(.top, Space.sm)
            }
            Spacer()
            PrimaryButton(title: listener.listening ? "Ouvindo" : "Falar agora", enabled: !listener.listening) {
                Task { await listen() }
            }
            .padding(.horizontal, Space.gutter).padding(.bottom, Space.xs)
        }
        .presentationDetents([.medium])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
        .interactiveDismissDisabled()
    }

    private func listen() async {
        guard await SpeechListener.requestPermissions() else {
            message = "Para usar a voz, o app precisa do microfone e do reconhecimento de fala."
            return
        }
        let heard = await listener.listen()
        if VoiceGate.digest(heard, salt: challenge.salt) == challenge.expected {
            VoiceGate.shared.finish(challenge, passed: true)
            return
        }
        attempts += 1
        if attempts >= 3 {
            VoiceGate.shared.finish(challenge, passed: false)
        } else {
            message = "Não reconheci. Fale de novo, perto do iPhone."
        }
    }
}
