import AVFoundation
import CryptoKit
import EscaliburCore
import EscaliburKeys
import Speech
import SwiftUI

/// Confirmacao por voz: uma camada **a mais** junto do Face ID ou do PIN, nunca no
/// lugar deles, nas acoes que o dono escolher. A frase vem primeiro, e o Face ID ou o
/// PIN logo depois, antes de qualquer chave abrir.
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

    /// `send(fiat:)` com nil quando nao ha cotacao: sem saber o valor, a voz e pedida.
    enum Action { case reveal, envelope, send(fiat: Double?) }

    struct Challenge: Identifiable {
        let id = UUID()
        let continuation: CheckedContinuation<Bool, Never>
        let expected: String
        let salt: String
        let session: AppSession
        /// Preenchido quando as acoes com voz estao em espera: a folha so avisa.
        let lockedUntil: Date?
    }

    /// Tres desafios falhos em seguida pausam as acoes com voz por 15 minutos.
    static let challengesBeforeLock = 3
    static let lockSeconds: TimeInterval = 15 * 60

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
        case .send(let fiat):
            guard let limit = settings.onSendAboveFiat else { return true }
            if let fiat, fiat < limit { return true }
        }
        let remaining = lockRemaining(session)
        let locked = remaining > 0 ? Date.now.addingTimeInterval(remaining) : nil
        return await withCheckedContinuation { continuation in
            let challenge = Challenge(continuation: continuation, expected: hash, salt: salt, session: session, lockedUntil: locked)
            self.challenge = challenge
            OverlayWindow.shared.show(VoiceChallengeSheet(challenge: challenge))
        }
    }

    /// `exhausted`: o dono errou as tres tentativas deste desafio (fechar a folha nao
    /// conta como falha).
    func finish(_ challenge: Challenge, passed: Bool, exhausted: Bool = false) {
        self.challenge = nil
        OverlayWindow.shared.hide()
        let session = challenge.session
        if passed {
            session.metadata.settings.voice.clearLock()
            try? session.persist()
        } else if exhausted {
            let failures = (session.metadata.settings.voice.failedChallenges ?? 0) + 1
            if failures >= Self.challengesBeforeLock {
                session.metadata.settings.voice.failedChallenges = nil
                session.metadata.settings.voice.startLock(seconds: Self.lockSeconds)
            } else {
                session.metadata.settings.voice.failedChallenges = failures
            }
            try? session.persist()
        }
        challenge.continuation.resume(returning: passed)
    }

    /// Quanto falta da pausa, no relogio monotono. De outro boot o relogio recomecou
    /// do zero: a pausa recomeca cheia, como a espera do PIN (falha para o lado de
    /// esperar mais). Sem identidade de boot, sobra o relogio de parede.
    private func lockRemaining(_ session: AppSession) -> TimeInterval {
        var voice = session.metadata.settings.voice
        if voice.lockUptimeDeadline == nil {
            // Pausa gravada antes do prazo monotono existir: vira monotona, cheia.
            guard let until = voice.lockedUntil, until > .now else { return 0 }
            voice.startLock(seconds: Self.lockSeconds)
            session.metadata.settings.voice = voice
            try? session.persist()
            return Self.lockSeconds
        }
        let boot = PINPolicy.bootSession
        if boot == PINPolicy.unknownBoot {
            return max(0, (voice.lockedUntil ?? .distantPast).timeIntervalSinceNow)
        }
        if !PINPolicy.isSameBoot(voice.lockBoot.flatMap(Hex.decode) ?? [], boot) {
            voice.startLock(seconds: Self.lockSeconds)
            session.metadata.settings.voice = voice
            try? session.persist()
            return Self.lockSeconds
        }
        let left = min(Self.lockSeconds, (voice.lockUptimeDeadline ?? 0) - PINPolicy.uptime)
        if left <= 0 {
            voice.clearLock()
            session.metadata.settings.voice = voice
            try? session.persist()
            return 0
        }
        return left
    }

    /// A frase dita confere com a gravada? HMAC comparado em tempo constante.
    static func matches(_ heard: String, expected: String, salt: String) -> Bool {
        Hash.constantTimeEqual(Array(digest(heard, salt: salt).utf8), Array(expected.utf8))
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

    /// O iOS responde as permissoes numa fila de fundo. Um bloco escrito dentro desta
    /// classe herdaria o ator principal, e o Swift 6 derruba o app quando ele roda fora
    /// dela (visto no iPhone: o app fechava ao permitir o reconhecimento de voz). Por
    /// isso os tres blocos que o sistema chama de outra fila nascem fora do ator.
    nonisolated static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization(Self.authorizationHandler(continuation))
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    nonisolated private static func authorizationHandler(_ continuation: CheckedContinuation<Bool, Never>)
        -> (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { status in continuation.resume(returning: status == .authorized) }
    }

    /// Roda na thread de audio: entrega o pedaco ao reconhecedor e o pico ao medidor.
    nonisolated private static func tapBlock(_ request: SFSpeechAudioBufferRecognitionRequest,
                                             level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            var peak: Float = 0
            if let samples = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
            }
            level(peak)
        }
    }

    /// Roda na fila do reconhecedor: so o texto atravessa para o ator principal.
    nonisolated private static func resultHandler(_ transcript: @escaping @Sendable (String) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            transcript(text)
        }
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(request) { @Sendable [weak self] peak in
            Task { @MainActor in self?.level = peak }
        })
        engine.prepare()
        try? engine.start()
        listening = true

        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { @Sendable [weak self] text in
            Task { @MainActor in self?.transcript = text }
        })
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
            if let until = challenge.lockedUntil {
                Text("Muitas tentativas de voz seguidas. As operações que pedem voz voltam às \(until.formatted(date: .omitted, time: .shortened)).")
                    .typeStyle(.body).foregroundStyle(Palette.down).padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("A frase que só você sabe. Depois dela vem o \(KeyServices.biometryName) ou o PIN. O iPhone reconhece a frase, não a sua voz.")
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
            PrimaryButton(title: listener.listening ? "Ouvindo" : "Falar agora", enabled: !listener.listening && challenge.lockedUntil == nil) {
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
        if VoiceGate.matches(heard, expected: challenge.expected, salt: challenge.salt) {
            VoiceGate.shared.finish(challenge, passed: true)
            return
        }
        attempts += 1
        if attempts >= 3 {
            VoiceGate.shared.finish(challenge, passed: false, exhausted: true)
        } else {
            message = "Não reconheci. Fale de novo, perto do iPhone."
        }
    }
}
