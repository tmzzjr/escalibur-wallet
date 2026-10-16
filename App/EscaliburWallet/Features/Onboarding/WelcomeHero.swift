import AVFoundation
import SwiftUI

/// A abertura das boas-vindas (pedido do dono, 16/10/2026): a espada cravada no pico ao
/// amanhecer, com as moedas vindo dos dois lados e sumindo no horizonte atras dela, em loop
/// e sem som, com a camera parada. O video tem 7,5 s em HEVC, sem faixa de audio (uns 480
/// KB); a emenda do loop cai num trecho sem moedas na tela.
///
/// O primeiro quadro fica embaixo do video, para nao piscar preto enquanto ele carrega.
/// Com Reduzir Movimento, so ele, parado.
struct WelcomeHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image("AberturaEspada").resizable()
            if !reduceMotion, let url = Bundle.main.url(forResource: "abertura-espada", withExtension: "mp4") {
                LoopingVideo(url: url)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Um video mudo em loop, preenchendo o espaco. Pausa ao sair da tela e volta a tocar
/// quando o app volta ao primeiro plano (o iOS pausa o video no segundo plano).
private struct LoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        PlayerView(url: url)
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var resume: NSObjectProtocol?

        init(url: URL) {
            super.init(frame: .zero)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            if let layer = layer as? AVPlayerLayer {
                layer.player = player
                layer.videoGravity = .resizeAspectFill
            }
            resume = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.player.play() }
            }
            player.play()
        }

        required init?(coder: NSCoder) { nil }

        func stop() {
            player.pause()
            looper?.disableLooping()
            if let resume { NotificationCenter.default.removeObserver(resume) }
            resume = nil
        }
    }
}
