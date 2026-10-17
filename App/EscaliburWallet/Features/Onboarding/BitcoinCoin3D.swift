import SceneKit
import SwiftUI

/// A moeda de Bitcoin do "So voce assina" em 3D de verdade (pedido do dono, 15/10/2026):
/// um cilindro de 128 lados no SceneKit, com a foto da moeda na frente, no verso e na
/// borda serrilhada, em material metalico que reflete a luz conforme gira. As texturas
/// vem de "Bit Coin", de marcio3d (Sketchfab, CC BY 4.0), recortadas e travadas no
/// modelos.lock; o credito esta no fim dos Termos de uso.
///
/// `angle` e o giro em radianos em volta do eixo vertical: 0 e a frente.
struct BitcoinCoin3D: UIViewRepresentable {
    let angle: Double

    /// As tres fotos da moeda, decodificadas uma vez so: decodificar na hora em que a
    /// tela do "So voce assina" aparecia travava a passagem do tour (visto no app de
    /// verdade, 16/10/2026).
    nonisolated private static let textures: [String: UIImage] = {
        var out: [String: UIImage] = [:]
        for name in ["bitcoin-borda", "bitcoin-frente", "bitcoin-verso"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"), let image = UIImage(contentsOfFile: url.path) else { continue }
            out[name] = image.preparingForDisplay() ?? image
        }
        return out
    }()

    /// Adianta o trabalho da moeda, fora da tela principal: chamado pela tela de antes.
    static func preload() {
        Task.detached(priority: .userInitiated) { _ = textures }
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = Self.scene()
        // Sobe as texturas e os shaders para a GPU antes do primeiro quadro.
        if let scene = view.scene { view.prepare([scene], completionHandler: nil) }
        view.pointOfView = view.scene?.rootNode.childNode(withName: "camera", recursively: false)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.isUserInteractionEnabled = false
        view.rendersContinuously = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.scene?.rootNode.childNode(withName: "giro", recursively: false)?.eulerAngles.y = Float(angle)
    }

    private static func scene() -> SCNScene {
        let scene = SCNScene()
        let coin = SCNCylinder(radius: 1, height: 0.14)
        coin.radialSegmentCount = 128
        coin.materials = [material("bitcoin-borda", repeats: 6), material("bitcoin-frente"), material("bitcoin-verso")]
        let body = SCNNode(geometry: coin)
        // O cilindro nasce de pe; deitado, a frente olha para a camera.
        body.eulerAngles.x = .pi / 2
        let turn = SCNNode()
        turn.name = "giro"
        turn.addChildNode(body)
        scene.rootNode.addChildNode(turn)

        // O metal precisa de algo para refletir: claro em cima, escuro embaixo, como o ceu
        // e o chao. E uma luz de cima, da esquerda.
        scene.lightingEnvironment.contents = environment()
        scene.lightingEnvironment.intensity = 1.8
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 1150
        light.eulerAngles = SCNVector3(-0.6, -0.5, 0)
        scene.rootNode.addChildNode(light)

        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.position = SCNVector3(0, 0, 4.6)
        scene.rootNode.addChildNode(camera)
        return scene
    }

    private static func material(_ name: String, repeats: Int = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = textures[name]
        if repeats > 1 {
            material.diffuse.wrapS = .repeat
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(Float(repeats), 1, 1)
        }
        material.metalness.contents = 0.85
        material.roughness.contents = 0.32
        return material
    }

    private static func environment() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 256, height: 128)).image { context in
            let colors = [UIColor(white: 1, alpha: 1).cgColor, UIColor(white: 0.45, alpha: 1).cgColor, UIColor(white: 0.06, alpha: 1).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 128), options: [])
        }
    }
}

/// O giro da moeda pelo dedo e a sombra no chao, iguais no tour e no aviso de recebimento.
enum CoinMotion {
    /// O embalo depois de soltar: de onde a moeda estava ate a volta inteira em que para.
    struct Release {
        let from: Double
        let to: Double
        let at: Date
    }

    /// Quanto o dedo precisa andar, em pontos, para a moeda girar um radiano.
    static let pointsPerRadian = 55.0

    /// O giro do dedo num instante: o embalo desacelera e para numa volta inteira.
    static func handTurn(_ release: Release?, at date: Date) -> Double {
        guard let release else { return 0 }
        let p = min(max(date.timeIntervalSince(release.at) / 1.2, 0), 1)
        return release.from + (release.to - release.from) * (1 - pow(1 - p, 3))
    }

    /// Solta a moeda em `from` com `extra` de embalo: ela para de frente, na volta inteira
    /// mais perto de onde o embalo a levaria.
    static func release(from: Double, extra: Double) -> Release {
        let full = 2 * Double.pi
        return Release(from: from, to: ((from + extra) / full).rounded() * full, at: Date())
    }

    /// A sombra no chao, embaixo da moeda.
    static func drawShadow(_ context: inout GraphicsContext, size: CGSize, angle: Double, bob: Double, enter: Double) {
        let diameter = Double(size.height) * 0.7
        let floorY = size.height / 2 + diameter * 0.56
        let width = diameter * (0.7 - bob * 0.01) * max(abs(cos(angle)), 0.35)
        let center = size.width / 2
        context.fill(Path(ellipseIn: CGRect(x: center - width / 2, y: floorY - 6, width: width, height: 12)),
                     with: .radialGradient(Gradient(colors: [.black.opacity(0.45 * enter), .clear]),
                                           center: CGPoint(x: center, y: floorY), startRadius: 0, endRadius: width / 2))
    }
}

/// A moeda girando devagar no ar, que o dedo gira: arrastando ela acompanha, ao soltar
/// segue no embalo e para de frente, e um toque da uma volta inteira. `onSpin` avisa a cada
/// giro do dono (o aviso de recebimento faz chegar mais uma moeda).
struct SpinningCoin: View {
    var slowTurn = 6.0
    var onSpin: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var dragTurn: Double = 0
    @State private var release: CoinMotion.Release?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
            let idle = reduceMotion ? 0 : t / slowTurn * 2 * .pi
            let angle = idle + CoinMotion.handTurn(release, at: timeline.date) + dragTurn
            let enter = reduceMotion ? 1 : 1 - pow(1 - min(max(t / 0.6, 0), 1), 3)
            let bob = reduceMotion ? 0 : 4 * sin(t * 1.6)
            ZStack {
                Canvas { context, size in CoinMotion.drawShadow(&context, size: size, angle: angle, bob: bob, enter: enter) }
                BitcoinCoin3D(angle: angle)
                    .opacity(enter)
                    .scaleEffect(0.8 + 0.2 * enter)
                    .offset(y: bob - 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            release = CoinMotion.release(from: CoinMotion.handTurn(release, at: Date()), extra: 2 * .pi)
            onSpin()
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { dragTurn = $0.translation.width / CoinMotion.pointsPerRadian }
                .onEnded { value in
                    let momentum = (value.predictedEndTranslation.width - value.translation.width) / CoinMotion.pointsPerRadian
                    let from = CoinMotion.handTurn(release, at: Date()) + dragTurn
                    dragTurn = 0
                    release = CoinMotion.release(from: from, extra: momentum)
                    if abs(momentum) + abs(from) > 0.5 { onSpin() }
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: release?.at)
        .accessibilityHidden(true)
    }
}
