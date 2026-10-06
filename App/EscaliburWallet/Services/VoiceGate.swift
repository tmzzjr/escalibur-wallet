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
    /// Frases erradas por desafio. Nao ouvir nada nao conta.
    static let attemptsPerChallenge = 3
    static let lockSeconds: TimeInterval = 15 * 60

    var challenge: Challenge?
    /// O ultimo envio pedido passou pela frase? Decide se a transmissao conta na
    /// sequencia de envios sem voz.
    private var lastSendUsedVoice = true

    /// Um envio ou troca foi transmitido (ou pode ter sido): sem a frase, conta na
    /// sequencia; com ela, a sequencia ja zerou na conferencia.
    func noteSendTransmitted(session: AppSession) {
        guard session.metadata.settings.voice.enabled, !lastSendUsedVoice else { return }
        session.metadata.settings.voice.sendsWithoutVoice = (session.metadata.settings.voice.sendsWithoutVoice ?? 0) + 1
        try? session.persist()
    }

    /// So para dobrar acentos e caixa na forma canonica; a frase pode ser em qualquer
    /// lingua de `VoiceLanguage`.
    static var locale: Locale { Locale(identifier: "pt-BR") }

    /// As linguas que este iPhone reconhece sem internet agora.
    static var languages: [VoiceLanguage] { VoiceLanguage.allCases.filter(\.onDevice) }

    static var isSupported: Bool { !languages.isEmpty }

    /// Uma linha para a tela: em que linguas o iPhone ouve a frase.
    static func languageNote(_ languages: [VoiceLanguage]) -> String {
        let missing = VoiceLanguage.allCases.filter { !languages.contains($0) }
        if languages.isEmpty { return "Este iPhone não reconhece fala sem internet agora." }
        if missing.isEmpty { return "Entendo a frase em português ou em inglês." }
        let on = languages.map(\.name).joined(separator: " e ")
        let off = missing.map(\.name).joined(separator: " e ")
        return "Entendo só em \(on): o \(off) não está disponível sem internet neste iPhone."
    }

    /// Uma linha para a tela: a lingua escolhida, e o que fazer quando o iPhone nao a
    /// reconhece sem internet.
    static func languageLine(_ language: VoiceLanguage) -> String {
        language.onDevice
            ? "Ouço em \(language.name). A língua se troca em Ajustes, Confirmação por voz."
            : "O \(language.name) sem internet não está disponível neste iPhone agora. Costuma ficar disponível quando você adiciona um teclado em \(language.name) nos Ajustes do iPhone."
    }

    /// O envio pede a frase? Com o pedido em envios desligado, nunca. Sem cotacao, o
    /// valor e desconhecido e pede (falha fechada). Abaixo do valor, so quando a
    /// sequencia de envios sem a frase chegou ao limite.
    static func sendNeedsVoice(fiat: Double?, settings: VoiceSettings) -> Bool {
        guard let limit = settings.onSendAboveFiat else { return false }
        guard let fiat else { return true }
        let streakFull = settings.maxSendsWithoutVoice.map { (settings.sendsWithoutVoice ?? 0) >= $0 } ?? false
        return fiat >= limit || streakFull
    }

    /// Precisa de voz para esta acao? Se sim, pede; se nao, deixa passar.
    func confirm(_ action: Action, session: AppSession) async -> Bool {
        let settings = session.metadata.settings.voice
        guard settings.enabled, let hash = session.metadata.voicePhraseHash, let salt = session.metadata.voicePhraseSalt else { return true }
        switch action {
        case .reveal: guard settings.onReveal else { return true }
        case .envelope: guard settings.onEnvelope else { return true }
        case .send(let fiat):
            lastSendUsedVoice = Self.sendNeedsVoice(fiat: fiat, settings: settings)
            guard lastSendUsedVoice else { return true }
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
        // Uma resposta por desafio: fechar a folha enquanto ela ainda confere a fala
        // nao pode retomar a continuacao duas vezes (o Swift derrubaria o app).
        guard self.challenge?.id == challenge.id else { return }
        self.challenge = nil
        OverlayWindow.shared.hide()
        let session = challenge.session
        if passed {
            session.metadata.settings.voice.clearLock()
            session.metadata.settings.voice.sendsWithoutVoice = nil
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

    /// Alguma das leituras confere? Cada lingua devolve a melhor leitura e as
    /// alternativas; vale qualquer uma. Confere todas, sem parar na primeira.
    static func matches(any heard: [String], expected: String, salt: String) -> Bool {
        var found = false
        for text in heard where !normalize(text).isEmpty {
            found = matches(text, expected: expected, salt: salt) || found
        }
        return found
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

/// As linguas em que a frase pode ser dita. Cada uma so entra se o iPhone a reconhece
/// sem internet; a que nao tiver modelo no aparelho fica de fora, e a tela diz.
enum VoiceLanguage: String, CaseIterable, Sendable, Codable {
    case portuguese = "pt-BR"
    case english = "en-US"

    var locale: Locale { Locale(identifier: rawValue) }
    var name: String { self == .portuguese ? "português" : "inglês" }
    var title: String { self == .portuguese ? "Português" : "Inglês" }
    /// O iPhone reconhece esta lingua sem internet? Criar um reconhecedor so para
    /// perguntar e lento, e a tela pergunta a cada redesenho (o teclado do PIN perdia
    /// toques): o "sim" vale 30 s. O "nao" e conferido de novo a cada vez, porque o iOS
    /// pode dizer "nao" logo ao criar o reconhecedor e "sim" instantes depois.
    var onDevice: Bool {
        if VoiceLanguageAvailability.cached(self) == true { return true }
        let available = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
        if available { VoiceLanguageAvailability.store(true, for: self) }
        return available
    }
}

/// A disponibilidade de cada lingua, guardada por pouco tempo.
private enum VoiceLanguageAvailability {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [VoiceLanguage: (available: Bool, at: Date)] = [:]
    static let lifetime: TimeInterval = 30

    static func cached(_ language: VoiceLanguage) -> Bool? {
        lock.withLock {
            guard let entry = answers[language], Date.now.timeIntervalSince(entry.at) < lifetime else { return nil }
            return entry.available
        }
    }

    static func store(_ available: Bool, for language: VoiceLanguage) {
        lock.withLock { answers[language] = (available, .now) }
    }
}

/// Ouve uma frase curta e devolve o que reconheceu, so no aparelho.
///
/// Os mesmos pedacos do microfone vao para um reconhecedor por lingua (portugues e
/// ingles, as que o iPhone tiver sem internet), e vale o que qualquer um ouvir.
/// Para sozinho pouco depois da ultima palavra; desiste se ninguem falar.
@MainActor
final class SpeechListener: ObservableObject {
    /// O que uma escuta devolve.
    struct Heard: Sendable {
        enum Failure: Sendable { case unavailable, microphone, nothing }
        var failure: Failure?
        /// A melhor leitura de cada lingua, da mais confiante para a menos.
        var readings: [Reading] = []
        /// Todas as leituras, com as alternativas de cada reconhecedor, para conferir.
        var alternatives: [String] = []

        var best: Reading? { readings.first }
    }

    struct Reading: Sendable, Equatable {
        let language: VoiceLanguage
        let text: String
        let confidence: Float
    }

    /// O que o reconhecedor de uma lingua entrega, da fila dele para o ator principal.
    struct Update: Sendable {
        let language: VoiceLanguage
        let text: String?
        let alternatives: [String]
        let confidence: Float
        let isFinal: Bool
    }

    /// Para 1,2 s depois da ultima palavra; desiste em 6 s se nao ouvir nada; nunca
    /// passa de 10 s com o microfone aberto.
    static let quietAfterSpeech: Duration = .milliseconds(1200)
    static let waitForSpeech: Duration = .seconds(6)
    static let maxListen: Duration = .seconds(10)
    /// Nivel (0 a 1) acima do qual o pedaco conta como som de fala.
    static let speechLevel: Float = 0.35
    static let historyCount = 12

    /// A melhor leitura ate agora, ao vivo.
    @Published private(set) var transcript = ""
    /// O que a outra lingua ouviu, quando difere da melhor.
    @Published private(set) var alternate: Reading?
    @Published private(set) var level: Float = 0
    /// Os ultimos niveis, do mais antigo ao mais novo, para a onda.
    @Published private(set) var levels = [Float](repeating: 0, count: SpeechListener.historyCount)
    /// Microfone aberto.
    @Published private(set) var listening = false
    /// Do toque em falar ate a leitura final (inclui o meio segundo de conferencia).
    @Published private(set) var busy = false
    /// As linguas desta escuta.
    @Published private(set) var languages = VoiceGate.languages

    private struct Live {
        var text = ""
        var alternatives: [String] = []
        var confidence: Float = 0
        var done = false
        var failed = false
    }

    private let engine = AVAudioEngine()
    private var tasks: [SFSpeechRecognitionTask] = []
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var live: [VoiceLanguage: Live] = [:]
    /// Cada escuta tem um numero; o que chegar de uma escuta antiga e ignorado.
    private var session = 0
    private var stopRequested = false
    private var lastWord = ContinuousClock.now
    private var lastLoud = ContinuousClock.now
    private var lastHistory = ContinuousClock.now
    private var interruption: NSObjectProtocol?
    #if DEBUG
    private var debugFeed: DebugDemo.VoiceFeed?
    #endif

    /// O iOS responde as permissoes numa fila de fundo. Um bloco escrito dentro desta
    /// classe herdaria o ator principal, e o Swift 6 derruba o app quando ele roda fora
    /// dela (visto no iPhone: o app fechava ao permitir o reconhecimento de voz). Por
    /// isso todo bloco que o sistema chama de outra fila (permissao, pedaco de audio,
    /// resultado do reconhecedor, aviso de interrupcao do audio) nasce numa funcao
    /// `nonisolated static`, e so atravessa para o ator principal por `Task`.
    /// Nunca escreva um desses blocos direto num metodo desta classe.
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

    /// Roda na thread de audio: entrega o mesmo pedaco a cada reconhecedor e o nivel
    /// ao medidor.
    nonisolated static func tapBlock(_ requests: [SFSpeechAudioBufferRecognitionRequest],
                                     level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            for request in requests { request.append(buffer) }
            level(meter(buffer))
        }
    }

    /// Nivel de 0 a 1 do pedaco: a media quadratica em decibeis, de -55 dB (sala em
    /// silencio) a -15 dB (fala perto do iPhone).
    nonisolated static func meter(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let decibels = 20 * log10(max((sum / Float(count)).squareRoot(), 1e-7))
        return min(1, max(0, (decibels + 55) / 40))
    }

    /// Roda na fila do reconhecedor: so texto e numero atravessam para o ator principal.
    nonisolated private static func resultHandler(_ language: VoiceLanguage, _ deliver: @escaping @Sendable (Update) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let result {
                let best = result.bestTranscription
                let confidence = best.segments.isEmpty ? 0 : best.segments.reduce(0) { $0 + $1.confidence } / Float(best.segments.count)
                deliver(Update(language: language, text: best.formattedString,
                               alternatives: result.transcriptions.map(\.formattedString),
                               confidence: confidence, isFinal: result.isFinal))
            } else if error != nil {
                deliver(Update(language: language, text: nil, alternatives: [], confidence: 0, isFinal: true))
            }
        }
    }

    /// Roda na fila de quem avisa (central de notificacoes): uma ligacao ou a Siri
    /// tomou o audio, e a escuta para.
    nonisolated private static func interruptionBlock(_ stop: @escaping @Sendable () -> Void) -> @Sendable (Notification) -> Void {
        { _ in stop() }
    }

    /// Os tres recados para o ator principal tambem nascem aqui, fora dele.
    nonisolated private static func forwardLevel(to listener: SpeechListener, session: Int) -> @Sendable (Float) -> Void {
        { [weak listener] value in Task { @MainActor in listener?.receive(level: value, session: session) } }
    }

    nonisolated private static func forwardUpdate(to listener: SpeechListener, session: Int) -> @Sendable (Update) -> Void {
        { [weak listener] update in Task { @MainActor in listener?.receive(update, session: session) } }
    }

    nonisolated private static func forwardStop(to listener: SpeechListener, session: Int) -> @Sendable () -> Void {
        { [weak listener] in Task { @MainActor in if listener?.session == session { listener?.stop() } } }
    }

    /// Ouve uma vez. Volta quando a pessoa para de falar, quando toca em parar, ou
    /// no limite de tempo.
    /// So na lingua escolhida pelo dono: dois reconhecedores ao mesmo tempo faziam o
    /// ingles "ganhar" com uma leitura errada de frase em portugues (relatado no iPhone).
    func listen(in language: VoiceLanguage) async -> Heard {
        let languages = language.onDevice ? [language] : []
        self.languages = languages
        reset()
        guard !languages.isEmpty else { return Heard(failure: .unavailable) }
        session += 1
        let id = session
        busy = true
        defer { busy = false }
        stopRequested = false

        let recognizers = languages.compactMap { language in
            SFSpeechRecognizer(locale: language.locale).map { (language, $0) }
        }
        requests = recognizers.map { _ in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = false
            return request
        }
        let tap = Self.tapBlock(requests, level: Self.forwardLevel(to: self, session: id))
        guard startAudio(tap, session: id) else {
            finishAudio()
            requests = []
            return Heard(failure: .microphone)
        }
        listening = true
        for ((language, recognizer), request) in zip(recognizers, requests) {
            tasks.append(recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(language, Self.forwardUpdate(to: self, session: id))))
        }

        let start = ContinuousClock.now
        lastWord = start
        lastLoud = start
        while !stopRequested && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let now = ContinuousClock.now
            let spoke = live.values.contains { !$0.text.isEmpty }
            if now - start > Self.maxListen { break }
            if !spoke && now - start > Self.waitForSpeech { break }
            if spoke && now - lastWord > Self.quietAfterSpeech && now - lastLoud > .milliseconds(500) { break }
            if languages.allSatisfy({ live[$0]?.failed == true }) { break }
        }

        finishAudio()
        for request in requests { request.endAudio() }
        // Depois do fim do audio cada reconhecedor entrega a leitura final, que costuma
        // ser melhor que a parcial. Espera por ela no maximo 1,5 s.
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while ContinuousClock.now < deadline, !languages.allSatisfy({ live[$0]?.done == true }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for task in tasks { task.cancel() }
        tasks = []
        requests = []
        let failedEarly = languages.allSatisfy { live[$0]?.failed == true }
        let heard = result()
        session += 1
        live = [:]
        if heard.readings.isEmpty { return Heard(failure: failedEarly ? .unavailable : .nothing) }
        return heard
    }

    /// Para de ouvir agora e confere o que ja ouviu.
    func stop() {
        stopRequested = true
    }

    /// Limpa a transcricao da tela.
    func reset() {
        transcript = ""
        alternate = nil
        level = 0
        levels = [Float](repeating: 0, count: Self.historyCount)
    }

    private func receive(level value: Float, session id: Int) {
        guard id == session, listening else { return }
        level = value
        let now = ContinuousClock.now
        if value > Self.speechLevel { lastLoud = now }
        // A onda anda no maximo a cada 60 ms, para nao correr mais rapido num iPhone
        // que entrega pedacos menores.
        if now - lastHistory >= .milliseconds(60) {
            lastHistory = now
            levels.removeFirst()
            levels.append(value)
        }
    }

    private func receive(_ update: Update, session id: Int) {
        guard id == session else { return }
        var entry = live[update.language] ?? Live()
        if let text = update.text {
            if text != entry.text { lastWord = .now }
            entry.text = text
            entry.alternatives = update.alternatives
            entry.confidence = update.confidence
        } else if listening {
            // Erro com o microfone ainda aberto: essa lingua nao vai ouvir nada.
            entry.failed = true
        }
        if update.isFinal { entry.done = true }
        live[update.language] = entry
        let readings = result().readings
        transcript = readings.first?.text ?? ""
        alternate = readings.dropFirst().first { VoiceGate.normalize($0.text) != VoiceGate.normalize(transcript) }
    }

    /// As leituras de agora: a mais confiante primeiro; empate fica na ordem das linguas.
    private func result() -> Heard {
        let order = VoiceLanguage.allCases
        let readings = live.compactMap { language, entry in
            entry.text.isEmpty ? nil : Reading(language: language, text: entry.text, confidence: entry.confidence)
        }
        .sorted { a, b in
            a.confidence != b.confidence ? a.confidence > b.confidence
                : order.firstIndex(of: a.language)! < order.firstIndex(of: b.language)!
        }
        let alternatives = live.values.flatMap { [$0.text] + $0.alternatives }.filter { !$0.isEmpty }
        return Heard(readings: readings, alternatives: alternatives)
    }

    private func startAudio(_ tap: @escaping AVAudioNodeTapBlock, session id: Int) -> Bool {
        #if DEBUG
        if let file = DebugDemo.nextVoiceAudio() {
            debugFeed = DebugDemo.feedVoice(file, tap: tap)
            return debugFeed != nil
        }
        #endif
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return false
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Sem entrada de audio o formato vem zerado, e o installTap derrubaria o app
        // com uma excecao de Objective-C. Confere antes.
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audio, queue: nil,
            using: Self.interruptionBlock(Self.forwardStop(to: self, session: id))
        )
        return true
    }

    /// Fecha o microfone. O reconhecedor continua com o que ja recebeu.
    private func finishAudio() {
        listening = false
        level = 0
        #if DEBUG
        if let debugFeed {
            debugFeed.stop()
            self.debugFeed = nil
            return
        }
        #endif
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// S4b: "Diga a sua frase de voz". Mostra ao vivo o que o iPhone ouve, mas aqui nao
/// tem campo para digitar: na hora de confirmar so a voz vale, senao a camada nao
/// conferiria nada que o PIN ja nao confira.
struct VoiceChallengeSheet: View {
    let challenge: VoiceGate.Challenge
    @StateObject private var listener = SpeechListener()
    @State private var attempts = 0
    @State private var message: String?
    @State private var needsPermission = false
    @State private var passed = false
    @State private var closed = false

    private var locked: Bool { challenge.lockedUntil != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Diga a sua frase de voz") { close() }
            if let until = challenge.lockedUntil {
                Text("Muitas tentativas de voz seguidas. As operações que pedem voz voltam às \(until.formatted(date: .omitted, time: .shortened)).")
                    .typeStyle(.body).foregroundStyle(Palette.down).padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Fale a frase que você gravou. Depois dela vem o \(KeyServices.biometryName) ou o PIN. O iPhone reconhece a frase, não a sua voz.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
            VoiceListeningPanel(listener: listener, idle: locked ? "Em espera" : "Toque em Falar agora e diga a frase.",
                                outcome: passed ? .passed : nil)
                .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
            if let message {
                Text(message).typeStyle(.note).foregroundStyle(Palette.down).padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voz-mensagem")
            }
            if needsPermission {
                TertiaryButton(title: "Abrir os Ajustes do iPhone") { VoicePermission.openSettings() }
                    .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
            }
            Spacer(minLength: Space.md)
            Text(VoiceGate.languageLine(challenge.session.metadata.settings.voice.phraseLanguage))
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.horizontal, Space.gutter).padding(.bottom, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: listener.listening ? "Terminei de falar" : "Falar agora",
                          enabled: !locked && !passed, loading: listener.busy && !listener.listening) {
                if listener.listening { listener.stop() } else { Task { await listen() } }
            }
            .padding(.horizontal, Space.gutter).padding(.bottom, Space.xs)
        }
        .background(Palette.void.ignoresSafeArea())
        .onDisappear { listener.stop() }
    }

    private func close() {
        closed = true
        listener.stop()
        VoiceGate.shared.finish(challenge, passed: false)
    }

    private func listen() async {
        message = nil
        guard await SpeechListener.requestPermissions() else {
            message = VoicePermission.deniedMessage
            needsPermission = true
            return
        }
        needsPermission = false
        let heard = await listener.listen(in: challenge.session.metadata.settings.voice.phraseLanguage)
        guard !closed else { return }
        if let failure = heard.failure {
            // Nao ouvir nada nao gasta tentativa: so conta a frase errada.
            message = VoicePermission.message(for: failure)
            return
        }
        if VoiceGate.matches(any: heard.alternatives, expected: challenge.expected, salt: challenge.salt) {
            passed = true
            try? await Task.sleep(for: .milliseconds(800))
            VoiceGate.shared.finish(challenge, passed: true)
            return
        }
        attempts += 1
        let left = VoiceGate.attemptsPerChallenge - attempts
        if left <= 0 {
            VoiceGate.shared.finish(challenge, passed: false, exhausted: true)
        } else {
            message = left == 1 ? "Não conferiu. Você tem mais 1 tentativa." : "Não conferiu. Você tem mais \(left) tentativas."
        }
    }
}

/// Textos e atalhos de permissao e de falha, iguais no cadastro e na conferencia.
enum VoicePermission {
    static let deniedMessage = "Para usar a voz, permita o microfone e o reconhecimento de fala para este app nos Ajustes do iPhone."

    static func message(for failure: SpeechListener.Heard.Failure) -> String {
        switch failure {
        case .nothing: return "Não ouvi nada. Toque em falar e diga a frase perto do iPhone."
        case .microphone: return "O microfone não abriu. Se outro app estiver usando o microfone, feche e tente de novo."
        case .unavailable: return "O reconhecimento de fala sem internet não respondeu. Tente de novo em instantes."
        }
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
