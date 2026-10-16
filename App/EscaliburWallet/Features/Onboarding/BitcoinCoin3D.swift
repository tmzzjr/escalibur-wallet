import SceneKit
import SwiftUI

/// A moeda de Bitcoin do "So voce assina" em 3D de verdade (pedido do dono, 15/10/2026):
/// um cilindro de 128 lados no SceneKit, com a foto da moeda na frente, no verso e na
/// borda serrilhada, em material metalico que reflete a luz conforme gira. As texturas
/// vem de "Bit Coin", de marcio3d (Sketchfab, CC BY 4.0), recortadas e travadas no
/// modelos.lock; o credito esta em Ajustes, Sobre.
///
/// `angle` e o giro em radianos em volta do eixo vertical: 0 e a frente.
struct BitcoinCoin3D: UIViewRepresentable {
    let angle: Double

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = Self.scene()
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
        material.diffuse.contents = Bundle.main.url(forResource: name, withExtension: "jpg").flatMap { UIImage(contentsOfFile: $0.path) }
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
