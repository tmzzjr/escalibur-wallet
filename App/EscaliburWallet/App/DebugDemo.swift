#if DEBUG
import AVFoundation
import EscaliburCore
import EscaliburKeys
import SwiftUI

/// Conferencia visual no simulador, so em compilacao de depuracao.
///
/// `-demo` cadastra um PIN de teste e importa a carteira publica de teste do BIP-39
/// ("abandon ... about", que qualquer pessoa conhece e que ninguem deve usar), pelos
/// mesmos caminhos do app. `-tela <nome>` abre uma tela direto. verificar.sh confere
/// que nada disto existe num build de distribuicao.
enum DebugDemo {
    static let pin = "111111"
    static let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var enabled: Bool { arguments.contains("-demo") }

    static var screen: String? {
        guard let index = arguments.firstIndex(of: "-tela"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `-envelope <caminho>`: arquivo que `-tela abrir` ja carrega.
    static var envelopeURL: URL? {
        guard let index = arguments.firstIndex(of: "-envelope"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    // MARK: Voz

    /// `-voz-frase <texto>`: a confirmacao por voz ja ligada com esta frase de teste.
    @MainActor
    static func enrollVoice(_ session: AppSession) throws {
        guard let index = arguments.firstIndex(of: "-voz-frase"), arguments.indices.contains(index + 1) else { return }
        let salt = Hex.encode(Array("sal-de-teste-voz".utf8))
        session.metadata.voicePhraseSalt = salt
        session.metadata.voicePhraseHash = VoiceGate.digest(arguments[index + 1], salt: salt)
        session.metadata.settings.voice.enabled = true
        session.metadata.settings.voice.clearLock()
        try session.persist()
    }

    /// `-voz-audio a.m4a,b.m4a`: cada escuta toca o proximo arquivo no lugar do
    /// microfone, em tempo real, e depois silencio ate a escuta parar. O simulador nao
    /// tem quem fale; assim o caminho inteiro do reconhecedor roda nele.
    @MainActor private static var voiceAudioIndex = 0

    @MainActor
    static func nextVoiceAudio() -> URL? {
        guard let index = arguments.firstIndex(of: "-voz-audio"), arguments.indices.contains(index + 1) else { return nil }
        let files = arguments[index + 1].split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        guard !files.isEmpty else { return nil }
        defer { voiceAudioIndex += 1 }
        return files[voiceAudioIndex % files.count]
    }

    final class VoiceFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isStopped: Bool { lock.withLock { stopped } }
        func stop() { lock.withLock { stopped = true } }
    }

    /// O arquivo e o bloco do microfone, para a thread que toca.
    private final class VoiceSource: @unchecked Sendable {
        let file: AVAudioFile
        let tap: AVAudioNodeTapBlock
        init(file: AVAudioFile, tap: @escaping AVAudioNodeTapBlock) { self.file = file; self.tap = tap }
    }

    nonisolated static func feedVoice(_ url: URL, tap: @escaping AVAudioNodeTapBlock) -> VoiceFeed? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let feed = VoiceFeed()
        Thread.detachNewThread(feedBlock(VoiceSource(file: file, tap: tap), feed))
        return feed
    }

    /// Roda numa thread propria, como o microfone: 300 ms de silencio, o arquivo, e
    /// silencio de novo, em pedacos de 100 ms.
    nonisolated private static func feedBlock(_ source: VoiceSource, _ feed: VoiceFeed) -> @Sendable () -> Void {
        {
            let format = source.file.processingFormat
            let chunk = AVAudioFrameCount(format.sampleRate / 10)
            var sent: AVAudioFramePosition = 0
            let lead = AVAudioFramePosition(format.sampleRate * 0.3)
            while !feed.isStopped {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
                let playing = sent >= lead && source.file.framePosition < source.file.length
                if !playing || (try? source.file.read(into: buffer, frameCount: chunk)) == nil || buffer.frameLength == 0 {
                    buffer.frameLength = chunk
                    for channel in 0..<Int(format.channelCount) {
                        buffer.floatChannelData?[channel].update(repeating: 0, count: Int(chunk))
                    }
                }
                source.tap(buffer, AVAudioTime(sampleTime: sent, atRate: format.sampleRate))
                sent += AVAudioFramePosition(buffer.frameLength)
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / format.sampleRate)
            }
        }
    }

    static func securePIN() -> SecureBytes {
        let bytes = SecureBytes(capacity: 6)
        bytes.replaceAll(with: Array(pin.utf8))
        return bytes
    }

    @MainActor
    static func prepare(session: AppSession, router: Router) async {
        guard enabled else { return }
        do {
            if session.phase == .onboarding {
                try await session.setUpPIN(securePIN())
            } else if session.phase == .locked {
                try await session.unlock(pin: securePIN())
            }
            if session.metadata.wallets.isEmpty {
                // `-vazia`: uma carteira nova, sorteada agora, sem saldo nenhum.
                let secret = arguments.contains("-vazia")
                    ? try WalletSecret.from(phrase: BIP39.generate(wordCount: 12), language: .english)
                    : try WalletSecret.from(phrase: BIP39.canonical(phrase), language: .english)
                // `-sem-copia`: carteira criada aqui e ainda sem copia, para as telas que
                // pedem gravar a senha antes de receber.
                let withoutBackup = arguments.contains("-sem-copia")
                _ = try await session.addWallet(
                    secret: secret, name: "Carteira principal", origin: withoutBackup ? .created : .importedPhrase, wordCount: 12,
                    backupConfirmed: !withoutBackup, credential: .pin(securePIN())
                )
            }
            try enrollVoice(session)
            switch screen {
            // `-tela voz-conferir` (com `-voz-frase`): a folha de voz, como antes de
            // ver a senha da carteira.
            case "voz-conferir": Task { _ = await VoiceGate.shared.confirm(.reveal, session: session) }
            case "mercado": router.tab = .market
            case "trocar": router.tab = .trade
            case "atividade": router.tab = .activity
            case "ajustes": router.tab = .settings
            case "enviar": router.present(.send(nil))
            case "enviar-eth", "envio-incerto": router.present(.send(.native(.ethereum)))
            default: break
            }
        } catch {
            assertionFailure("demo: \(error)")
        }
    }
}

/// `-tela lacrar` e `-tela abrir` abrem as telas de envelope por cima da carteira.
/// `-tela adicionar`, `-tela criar`, `-tela seguranca` e `-tela observar` abrem as
/// telas de carteira nova.
struct DemoEnvelopes: ViewModifier {
    @Environment(AppSession.self) private var session
    @State private var sealing: WalletMeta?
    @State private var opening = false
    @State private var newWallet: DemoNewWallet?
    @State private var voice = false
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            // `-tela voz`: Ajustes, Seguranca, Confirmacao por voz.
            .fullScreenCover(isPresented: $voice) { NavigationStack { VoiceSettingsView() } }
            .fullScreenCover(item: $sealing) { wallet in SealEnvelopeFlow(wallet: wallet) { sealing = nil } }
            .fullScreenCover(isPresented: $opening) { OpenEnvelopeFlow(initialURL: DebugDemo.envelopeURL) { opening = false } }
            .fullScreenCover(item: $newWallet) { screen in
                switch screen {
                case .criar: NewWalletFlow(isFirstWallet: false) { newWallet = nil }
                case .seguranca: NavigationStack { ResponsibilityView(continueTitle: "Digitar as palavras") {} }
                case .observar: NavigationStack { WatchAddressView { newWallet = nil } }
                case .adicionar: AddWalletView(isFirst: false) { newWallet = nil }
                }
            }
            .task(id: session.metadata.wallets.first?.id) {
                guard !shown, let first = session.metadata.wallets.first else { return }
                shown = true
                if DebugDemo.screen == "lacrar" { sealing = first }
                if DebugDemo.screen == "abrir" { opening = true }
                if DebugDemo.screen == "voz" { voice = true }
                newWallet = DebugDemo.screen.flatMap(DemoNewWallet.init(rawValue:))
            }
    }
}

/// As telas de carteira nova que `-tela` abre direto.
enum DemoNewWallet: String, Identifiable {
    case adicionar, criar, seguranca, observar
    var id: String { rawValue }
}
#endif
