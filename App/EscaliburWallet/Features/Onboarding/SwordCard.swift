import CoreMotion
import SwiftUI

/// A carta da espada (pedido do dono, 15/10/2026): o painel do "So voce e digno" vira uma
/// carta que inclina com o iPhone e com o dedo, com um holografico que muda de cor
/// conforme o angulo, e que vira com um toque ou arrastando para o lado. No verso, a lenda
/// da espada na pedra e o que ela tem a ver com uma carteira sem custodia.
///
/// Na primeira vez, a carta da uma espiada (gira um pouco e volta) para dizer que vira.
/// Com Reduzir Movimento: sem inclinar, sem espiada, e virar e um esmaecer.
struct SwordCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Giro em graus no eixo vertical: 0 e a frente, 180 o verso.
    @State private var angle: Double = 0
    @State private var drag: CGSize = .zero
    @State private var tilt = TiltReader()
    @State private var peeked = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let yaw = angle + Double(drag.width / max(size.width, 1)) * 180 + (reduceMotion ? 0 : tilt.roll * 14)
            let pitch = reduceMotion ? 0 : -Double(drag.height / max(size.height, 1)) * 30 + tilt.pitch * 10
            let back = Self.facesBack(yaw)
            ZStack {
                front(size, yaw: yaw, pitch: pitch)
                    .opacity(back ? 0 : 1)
                // Girando, o verso ja vem de costas; sem girar (Reduzir Movimento), de frente.
                SwordCardBack(yaw: yaw, pitch: pitch)
                    .rotation3DEffect(.degrees(reduceMotion ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                    .opacity(back ? 1 : 0)
            }
            .rotation3DEffect(.degrees(reduceMotion ? 0 : yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
            .shadow(color: .black.opacity(0.45), radius: 18, y: 12)
            .contentShape(Rectangle())
            .onTapGesture { flip(by: 1) }
            .highPriorityGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        let turn = Double(value.predictedEndTranslation.width / max(size.width, 1)) * 180
                        settle(flip: abs(turn) > 95 ? (turn > 0 ? 1 : -1) : 0)
                    }
            )
        }
        .sensoryFeedback(.impact(weight: .light), trigger: Self.facesBack(angle))
        .onAppear {
            if !reduceMotion { tilt.start() }
            guard !reduceMotion, !peeked else { return }
            peeked = true
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                withAnimation(.easeInOut(duration: 0.45)) { angle -= 28 }
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { angle += 28 }
            }
        }
        .onDisappear { tilt.stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.facesBack(angle) ? SwordCardBack.spoken : String(localized: "Carta da espada na pedra"))
        .accessibilityHint(String(localized: "Toque duas vezes para virar a carta."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { flip(by: 1) }
        .accessibilityIdentifier("carta-espada")
    }

    private func front(_ size: CGSize, yaw: Double, pitch: Double) -> some View {
        ZStack {
            // A espada anda um tico contra a inclinacao, como se estivesse atras do vidro.
            SwordInStone()
                .offset(x: CGFloat(-sin(yaw * .pi / 180)) * 10, y: CGFloat(sin(pitch * .pi / 180)) * 10)
                .scaleEffect(1.04)
            Hologram(yaw: yaw, pitch: pitch)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
    }

    /// O verso aparece entre 90 e 270 graus.
    static func facesBack(_ yaw: Double) -> Bool {
        let turn = (yaw.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return turn > 90 && turn < 270
    }

    private func flip(by direction: Double) {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) { angle += 180 * direction }
        } else {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) { angle += 180 * direction }
        }
    }

    /// Solta o dedo: vira se passou da metade (ou foi jogada), senao volta.
    private func settle(flip direction: Double) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
            angle = (angle / 180).rounded() * 180 + 180 * direction
            drag = .zero
        }
    }
}

/// O holografico: uma faixa estreita de arco-iris que corre a carta conforme o angulo,
/// como a luz batendo numa carta holografica, um veu de cor bem leve na carta inteira, o
/// fio fino da folha metalica e o reflexo de luz. Quanto mais a carta inclina, mais ele
/// aparece; de frente, quase some. So desenho: nao pega toque.
private struct Hologram: View {
    let yaw: Double
    let pitch: Double

    static let spectrum: [Color] = [Color(hex: 0x00E5FF), Color(hex: 0x7B61FF), Color(hex: 0xFF4FD8), Color(hex: 0xFFE14D),
                                    Color(hex: 0x5CFF9D), Color(hex: 0x00E5FF)]

    var body: some View {
        let x = sin(yaw * .pi / 180)
        let y = sin(pitch * .pi / 180)
        let strength = min(0.12 + abs(x) * 2.2 + abs(y) * 2.2, 1)
        ZStack {
            LinearGradient(colors: Self.spectrum, startPoint: UnitPoint(x: 0.5 - x, y: 0), endPoint: UnitPoint(x: 0.5 + x + 0.6, y: 1))
                .blendMode(.softLight)
                .opacity(0.25 * strength)
            // A faixa: um retangulo de arco-iris inclinado que atravessa a carta e sai pelo
            // outro lado conforme a inclinacao (nunca espreme na borda).
            GeometryReader { geo in
                let width = geo.size.width, height = geo.size.height
                let diagonal = (width * width + height * height).squareRoot()
                LinearGradient(stops: [.init(color: .clear, location: 0)]
                                + Self.spectrum.enumerated().map { .init(color: $1, location: 0.15 + Double($0) * 0.14) }
                                + [.init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: diagonal * 0.42, height: diagonal * 1.6)
                    .rotationEffect(.degrees(35))
                    .position(x: width / 2 + CGFloat(-x * 1.7 - y * 0.7) * width, y: height / 2)
            }
            .blendMode(.colorDodge)
            .opacity(0.42 * strength)
            Canvas { context, size in
                // O fio da folha holografica: riscos finos na diagonal.
                var lines = Path()
                var start: CGFloat = -size.height
                while start < size.width {
                    lines.move(to: CGPoint(x: start, y: size.height))
                    lines.addLine(to: CGPoint(x: start + size.height, y: 0))
                    start += 5
                }
                context.stroke(lines, with: .color(.white.opacity(0.1)), lineWidth: 1)
            }
            .blendMode(.overlay)
            .opacity(strength)
            RadialGradient(colors: [.white.opacity(0.4), .white.opacity(0)], center: UnitPoint(x: 0.5 - x * 1.2, y: 0.35 - y * 1.2),
                           startRadius: 0, endRadius: 260)
                .blendMode(.softLight)
        }
        .allowsHitTesting(false)
    }
}

/// O verso: a lenda, e a mesma regra numa carteira sem custodia.
private struct SwordCardBack: View {
    let yaw: Double
    let pitch: Double

    static var legend: String {
        String(localized: "Na lenda do rei Arthur, a espada ficou cravada na pedra com uma promessa: quem a tirasse seria rei. Cavaleiros e reis tentaram e falharam. Arthur tirou.")
    }

    static var rule: String {
        String(localized: "Numa carteira sem custódia vale a mesma regra. Suas moedas ficam na rede e só se movem com a assinatura da sua chave, que nasce e fica neste iPhone. Nem a Escalibur, nem banco, nem ninguém tira por você.")
    }

    static var spoken: String {
        [String(localized: "A espada na pedra"), legend, String(localized: "Na sua carteira"), rule].joined(separator: ". ")
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1F1F24), Palette.body, Color(hex: 0x0E0E11)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Hologram(yaw: yaw + 180, pitch: pitch).opacity(0.6)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("A lenda").typeStyle(.note).foregroundStyle(Palette.accent)
                Text("A espada na pedra").typeStyle(.title).foregroundStyle(Palette.ink)
                Text(Self.legend).typeStyle(.body).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Na sua carteira").typeStyle(.note).foregroundStyle(Palette.accent).padding(.top, Space.xs)
                Text(Self.rule).typeStyle(.body).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Label("Toque para virar", systemImage: "arrow.uturn.backward").typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
            .minimumScaleFactor(0.75)
            .padding(Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
    }
}

/// A inclinacao do iPhone, para a carta acompanhar a mao. Le a gravidade do Core Motion
/// (nao pede permissao: e o mesmo sensor da rotacao de tela), 30 vezes por segundo, so
/// enquanto a carta esta na tela, e mede a partir de como o iPhone estava quando ela
/// apareceu. Fica entre -1 e 1.
@Observable
final class TiltReader {
    private(set) var roll: Double = 0
    private(set) var pitch: Double = 0
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var base: (x: Double, y: Double)?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        base = nil
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            let reference = self.base ?? (gravity.x, gravity.y)
            self.base = reference
            let clamp = { (value: Double) in min(max(value / 0.35, -1), 1) }
            // Suaviza: um tremor da mao nao faz a carta tremer.
            self.roll += (clamp(gravity.x - reference.x) - self.roll) * 0.2
            self.pitch += (clamp(gravity.y - reference.y) - self.pitch) * 0.2
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        roll = 0
        pitch = 0
    }
}
