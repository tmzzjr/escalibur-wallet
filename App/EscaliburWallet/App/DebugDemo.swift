#if DEBUG
import AVFoundation
import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import EscaliburNetwork
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
    static func prepare(session: AppSession, router: Router, portfolio: Portfolio? = nil) async {
        // `-experimento-se`: o experimento da chave do Secure Enclave com senha de
        // aplicativo, sem demo, sem PIN e sem tocar o cofre. O resultado vai para
        // Documents/experimento-se.txt, que se le pelo devicectl.
        if ProcessInfo.processInfo.arguments.contains("-experimento-se") {
            let lines = await Task.detached { EnclaveSpike.run() }.value
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("experimento-se.txt")
            try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
            return
        }
        // `-estado-pin`: o formato do slot do PIN, so lido (sem PIN, sem demo, sem gastar
        // tentativa), para conferir a migracao no aparelho e no teste de atualizacao.
        defer {
            if ProcessInfo.processInfo.arguments.contains("-estado-pin") {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("estado-pin.txt")
                try? "\(KeyServices.root.pinSlotFormat.map(String.init) ?? "nenhum")\n".data(using: .utf8)?.write(to: url, options: .atomic)
            }
        }
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
            // `-tela moeda`: a pagina do bitcoin, pelo mesmo caminho do toque num alerta.
            case "moeda":
                router.tab = .market
                router.pendingCoinID = "bitcoin"
            case "trocar", "trocar-grande": router.tab = .trade
            case "limite":
                router.tab = .trade
                router.tradeMode = .limit
            // `-tela refazer`: a pergunta de refazer uma ordem limite vencida (ETH por
            // USDC na Base, 40% ja tinha saido), sem rede.
            case "refazer":
                router.tab = .trade
                router.tradeMode = .limit
                if let wallet = session.selectedWallet, let usdc = TokenRegistry.tokens.first(where: { $0.chainID == "base" && $0.symbol == "USDC" }) {
                    let record = LimitRenewal(
                        orderID: "0x00", walletID: wallet.id, chainID: "base", sellAssetID: Asset.native(.base).id, buyAssetID: usdc.id,
                        amountIn: BigUInt(1) * BigUInt.power(of: 10, 18), minimumOut: BigUInt(2_000) * BigUInt.power(of: 10, 6),
                        validFor: 604_800, expiresAt: Date()
                    )
                    LimitRenewalCenter.shared.preview(DueRenewal(
                        record: record, chain: .base, sell: .native(.base), buy: usdc,
                        amountIn: BigUInt(6) * BigUInt.power(of: 10, 17), minimumOut: BigUInt(1_200) * BigUInt.power(of: 10, 6), filledFraction: 0.4
                    ))
                }
            // `-tela ponte`: a ponte em Trocar, com 250 USDC da Base para a Arbitrum cotados
            // ao vivo e uma ponte ja chegada na lista (sem rede).
            case "ponte":
                router.tab = .trade
                router.tradeMode = .bridge
                if let wallet = session.selectedWallet, let account = wallet.account(.base), let owner = try? EVMAddress(account.address),
                   let intent = try? BridgeIntent(owner: owner, asset: .usdc, from: .optimism, to: .base, amount: BigUInt(1_200_000_000)),
                   let quote = try? BridgeValidator.cctp(intent, route: .cctpStandard, fees: CCTPFees(
                       fast: nil, standard: .init(protocolBps: TradeDecimal("0")!, forwardFee: BigUInt(54_000))), fastAllowance: nil) {
                    var record = BridgeRecord(quote: quote, walletID: wallet.id, depositTxHash: "0x" + String(repeating: "ab", count: 32),
                                              now: Date().addingTimeInterval(-3_600))
                    record.state = .arrived
                    record.receivedAmount = quote.minimumReceived.decimalString
                    record.settledTxHash = "0x" + String(repeating: "cd", count: 32)
                    session.metadata.bridges = [record]
                }
            // `-tela token-grafico`: a pagina do BNB Frog Inu (fora da lista, com aviso do
            // CoinGecko), com o preco e o grafico pelo contrato, ao vivo.
            case "token-grafico":
                let frog = Asset(chainID: "bnb", kind: .token(contract: "0x64da67a12a46f1ddf337393e2da12ed0a507ad3d"), symbol: "BNBFROG",
                                 name: "BNB Frog Inu", decimals: 9, coingeckoID: nil, isStablecoin: false, origin: .discovered)
                Task { @MainActor in
                    router.walletPath.append(UnlistedHolding(asset: frog, amount: BigUInt(decimal: "125000000000000000000")!, reasons: []))
                    // Depois que a carteira abriu (ela recarrega os precos guardados), com
                    // novas tentativas se o CoinGecko limitar.
                    for _ in 0..<8 {
                        try? await Task.sleep(for: .seconds(6))
                        if let quote = await MarketService.shared.tokenQuotes([frog], currency: session.metadata.settings.currency)[frog.id] {
                            portfolio?.debugSetTokenQuote(quote, for: frog.id)
                            break
                        }
                    }
                }
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
    @State private var alerts = false
    @State private var progress = false
    @State private var reviewPreview = false
    @State private var animationPreview = false
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            // `-tela voz`: Ajustes, Seguranca, Confirmacao por voz.
            .fullScreenCover(isPresented: $voice) { NavigationStack { VoiceSettingsView() } }
            // `-tela alertas`: Ajustes, Alertas de preco.
            .fullScreenCover(isPresented: $alerts) { NavigationStack { PriceAlertsView() } }
            // `-tela andamento`: o anel de uma troca pela CoW em 45%, e o anel das
            // ordens abertas nos estados de ponta.
            .fullScreenCover(isPresented: $progress) { DemoOrderProgress() }
            // `-tela revisao`: a revisao de uma ordem limite de exemplo, sem rede.
            .fullScreenCover(isPresented: $reviewPreview) { DemoReviewPreview() }
            // `-tela animacao`: a animacao da troca e a do cancelamento.
            .fullScreenCover(isPresented: $animationPreview) {
                VStack(spacing: Space.xl) {
                    Spacer()
                    SwapProcessingIndicator(sell: .native(.base), buy: TokenRegistry.tokens.first { $0.chainID == "base" && $0.symbol == "USDC" })
                    Text("Enviando a troca").typeStyle(.title).foregroundStyle(Palette.ink)
                    SwapProcessingIndicator(sell: .native(.base), buy: TokenRegistry.tokens.first { $0.chainID == "base" && $0.symbol == "USDC" },
                                            cancelling: true)
                    Text("Enviando o cancelamento").typeStyle(.title).foregroundStyle(Palette.ink)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Palette.void.ignoresSafeArea())
            }
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
                if DebugDemo.screen == "alertas" { alerts = true }
                if DebugDemo.screen == "andamento" { progress = true }
                if DebugDemo.screen == "revisao" { reviewPreview = true }
                if DebugDemo.screen == "animacao" { animationPreview = true }
                newWallet = DebugDemo.screen.flatMap(DemoNewWallet.init(rawValue:))
            }
    }
}

/// As telas de carteira nova que `-tela` abre direto.
enum DemoNewWallet: String, Identifiable {
    case adicionar, criar, seguranca, observar
    var id: String { rawValue }
}
/// O andamento de uma ordem sem rede, para conferir o desenho.
struct DemoOrderProgress: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let usdc = TokenRegistry.tokens.first { $0.chainID == "ethereum" && $0.symbol == "USDC" }
        let progress = OrderProgress(
            id: "0x00", state: .open, totalSell: BigUInt(8_000) * BigUInt.power(of: 10, 18),
            soldSell: BigUInt(3_600) * BigUInt.power(of: 10, 18), receivedBuy: BigUInt(8_971_000) * BigUInt.power(of: 10, 6),
            minimumBuy: BigUInt(19_927_226) * BigUInt.power(of: 10, 6), expiresAt: Date().addingTimeInterval(2_400)
        )
        VStack(spacing: 0) {
            Spacer()
            if let account = session.selectedWallet?.account(.ethereum) {
                OrderProgressPanel(kind: .swap, chain: .ethereum, orderID: "0x00", account: account, sell: .native(.ethereum), buy: usdc,
                                   preview: progress)
            }
            Spacer()
            HStack(spacing: Space.lg) {
                ForEach([0, 0.004, 0.45, 1], id: \.self) { fraction in FillRing(fraction: fraction, size: 44) }
            }
            .padding(.bottom, Space.xl)
        }
        .padding(.horizontal, Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.void.ignoresSafeArea())
    }
}
/// A revisao de uma ordem limite de exemplo: as moedas com a seta, o titulo, o cartao
/// dos enderecos fechado e o botao curto.
struct DemoReviewPreview: View {
    var body: some View {
        let usdc = TokenRegistry.tokens.first { $0.chainID == "base" && $0.symbol == "USDC" }
        let review = PlanReview(
            kind: .limitOrder, title: "Ordem limite: vender 1 ETH por USDC",
            lines: [
                .init("Rede", "Base"), .init("Vende", "1 ETH"), .init("Recebe, no mínimo", "2.600 USDC"),
                .init("Destinatário", "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F", verbatim: true),
                .init("Contrato da CoW", "0x9008D19f58AAbD9eD0D60971565AA8510560ab41", verbatim: true),
                .init("Autorizado a gastar", "0xC92E8bdf79f0507f65a392b0ab4667716BFE0110", verbatim: true),
                .init("Taxa da Escalibur", "Sem taxa da Escalibur"),
            ],
            transactionCount: 2
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TradeDirectionHeader(sell: .native(.base), buy: usdc, sellAmount: BigUInt.power(of: 10, 18),
                                     buyMinimum: BigUInt(2_600) * BigUInt.power(of: 10, 6))
                    .padding(.bottom, Space.lg)
                Text(review.title).typeStyle(.title).foregroundStyle(Palette.ink)
                PlanVerbatimPlate(review: review, collapsible: true).padding(.top, Space.lg)
                PlanDetailLines(review: review).padding(.top, Space.lg)
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.xl)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Criar ordem limite") {}.padding(.horizontal, Space.gutter).padding(.bottom, Space.xs)
        }
        .background(Palette.void.ignoresSafeArea())
    }
}
#endif
