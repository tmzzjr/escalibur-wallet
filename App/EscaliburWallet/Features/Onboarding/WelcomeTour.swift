import EscaliburChains
import EscaliburCore
import SwiftUI

/// Depois do primeiro PIN e antes da primeira carteira: o que a Escalibur e, em tres
/// passos com uma cena cada (pedido do dono, 15/10/2026). Substitui a lista de cinco
/// promessas que vinha antes de criar e de importar.
///
/// 1. A espada na pedra, a mesma da abertura: so sai pelas maos certas.
/// 2. As moedas: o icone do app no centro e as moedas em orbitas em perspectiva.
/// 3. A assinatura: uma moeda de Bitcoin em 3D gira esperando, e o Face ID confirma.
///
/// Cada cena roda quando o passo aparece. Com Reduzir Movimento, ela ja aparece pronta.
struct WelcomeTour: View {
    let onFinish: () -> Void
    @State private var page = 0

    private static let pages = 3

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { onFinish() } label: {
                    Text("Pular").typeStyle(.row).foregroundStyle(Palette.inkSoft)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .opacity(page < Self.pages - 1 ? 1 : 0)
                .disabled(page == Self.pages - 1)
                .accessibilityIdentifier("tour-pular")
            }
            .padding(.horizontal, Space.gutter)

            TabView(selection: $page) {
                TourPage(
                    title: String(localized: "Só você é digno"),
                    text: String(localized: "Na lenda, só as mãos certas tiram a Escalibur da pedra. Nesta carteira, as mãos certas são as suas."),
                    framed: false
                ) { SwordCard() }
                .tag(0)
                TourPage(
                    title: String(localized: "Uma chave para todas as suas moedas"),
                    text: String(localized: "Bitcoin, Ethereum, Solana e as maiores moedas do mundo, com a chave criada e guardada neste iPhone. Envie, receba e troque entre redes, com a taxa à vista antes de assinar.")
                ) { OrbitScene(active: page == 1) }
                .tag(1)
                TourPage(
                    title: String(localized: "Só você assina"),
                    text: String(localized: "Antes de cada envio, você vê o que sai e para onde, e confirma com o seu \(KeyServices.biometryName) ou PIN. O código é aberto: qualquer pessoa pode conferir.")
                ) { SignScene(active: page == 2) }
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            PageMarks(count: Self.pages, current: page)
                .padding(.vertical, Space.md)
            PrimaryButton(title: page < Self.pages - 1 ? String(localized: "Continuar") : String(localized: "Começar")) {
                if page < Self.pages - 1 {
                    withAnimation(.snappy) { page += 1 }
                } else {
                    onFinish()
                }
            }
            .accessibilityIdentifier("tour-continuar")
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xs)
        }
        .background(Palette.void.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: page)
        // Enquanto a espada cai, os logos da cena seguinte ja ficam decodificados.
        .task { await TourLogos.prepare() }
    }
}

/// Um passo: a cena no painel grafite, o titulo e o texto embaixo. O texto tem altura
/// reservada, para o painel ter o mesmo tamanho nos tres passos.
private struct TourPage<Scene: View>: View {
    let title: String
    let text: String
    /// A carta da espada traz a propria moldura e gira para fora dela: sem o painel.
    var framed = true
    @ViewBuilder var scene: Scene

    var body: some View {
        VStack(spacing: 0) {
            if framed {
                scene
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [Palette.rail, Palette.body], startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1))
            } else {
                scene.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: Space.sm) {
                Text(title).typeStyle(.hero).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text).typeStyle(.body).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 196, alignment: .top)
            .padding(.top, Space.lg)
        }
        .padding(.horizontal, Space.gutter)
    }
}

/// Onde o dono esta: o passo atual mais largo, no rosa da selecao.
private struct PageMarks: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Palette.accent : Palette.edgeStrong)
                    .frame(width: index == current ? 22 : 8, height: 8)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Passo \(current + 1) de \(count)"))
    }
}

/// Roda uma sequencia quando a cena fica ativa e para quando ela sai. Com Reduzir
/// Movimento, so o estado final.
private struct SceneRunner: ViewModifier {
    let active: Bool
    let reset: () -> Void
    let finish: () -> Void
    let run: () async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) {
                task?.cancel()
                guard active else { return }
                if reduceMotion {
                    finish()
                    return
                }
                reset()
                task = Task { await run() }
            }
            .onDisappear { task?.cancel() }
    }
}

private func pause(_ milliseconds: Int) async -> Bool {
    try? await Task.sleep(for: .milliseconds(milliseconds))
    return !Task.isCancelled
}

// MARK: - 2. As moedas

/// O icone do app no centro e as moedas em tres orbitas em perspectiva, como aneis vistos
/// um pouco de cima. As de tras passam atras do icone, menores e mais apagadas; as da
/// frente, maiores, por cima. Os aneis se desenham, o icone entra com uma mola e as
/// moedas chegam de fora, uma a uma, em espiral, e encaixam na orbita. Sem brilho nem
/// halo (pedido do dono, 15/10/2026). Com Reduzir Movimento, tudo parado no lugar.
private struct OrbitScene: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?

    struct Orbit { let radius: Double; let speed: Double; let size: Double; let ids: [String] }
    static let orbits: [Orbit] = [
        Orbit(radius: 0.42, speed: 0.32, size: 36, ids: ["bitcoin", "ethereum", "solana", "tether", "usd-coin"]),
        Orbit(radius: 0.68, speed: -0.21, size: 31, ids: ["ripple", "binancecoin", "the-open-network", "tron", "cardano", "dogecoin", "sui"]),
        Orbit(radius: 0.94, speed: 0.14, size: 27, ids: ["polkadot", "avalanche-2", "stellar", "near", "litecoin", "polygon-ecosystem-token",
                                                          "chainlink", "aptos", "arbitrum"]),
    ]
    static let ids: [String] = orbits.flatMap(\.ids)
    /// A perspectiva: o circulo visto de cima vira elipse, levemente girada.
    static let flatten = 0.52
    static let tilt = -0.16
    static let iconSide: CGFloat = 78

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !active || reduceMotion)) { timeline in
            let elapsed = reduceMotion ? 4 : start.map { timeline.date.timeIntervalSince($0) } ?? 0
            Canvas { context, size in
                Self.draw(&context, size: size, t: elapsed, spinning: !reduceMotion)
            } symbols: {
                WalletBadge(size: Self.iconSide).tag(1000)
            }
        }
        .modifier(SceneRunner(active: active, reset: { start = nil }, finish: { start = .distantPast }, run: run))
        .accessibilityHidden(true)
    }

    private func run() async {
        await TourLogos.prepare()
        guard !Task.isCancelled else { return }
        start = Date()
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
    private static func easeOut(_ value: Double) -> Double { 1 - pow(1 - clamp(value), 3) }

    private static func draw(_ context: inout GraphicsContext, size: CGSize, t: Double, spinning: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rx = Double(size.width) * 0.47
        let cosTilt = cos(tilt), sinTilt = sin(tilt)
        func place(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: center.x + x * cosTilt - y * sinTilt, y: center.y + x * sinTilt + y * cosTilt)
        }

        // Os aneis, desenhados um apos o outro.
        for (index, orbit) in orbits.enumerated() {
            let reveal = easeOut((t - Double(index) * 0.12) / 0.9)
            guard reveal > 0 else { continue }
            let a = rx * orbit.radius, b = a * flatten
            var ring = Path(ellipseIn: CGRect(x: -a, y: -b, width: a * 2, height: b * 2))
            ring = ring.applying(CGAffineTransform(rotationAngle: tilt)).applying(CGAffineTransform(translationX: center.x, y: center.y))
            context.stroke(ring.trimmedPath(from: 0, to: reveal), with: .color(Color.white.opacity(0.1)), lineWidth: 1)
        }

        // Cada moeda: angulo na orbita, profundidade (a frente e a metade de baixo) e chegada.
        struct Coin { let id: String; let point: CGPoint; let depth: Double; let side: Double; let alpha: Double }
        var coins: [Coin] = []
        var order = 0
        for orbit in orbits {
            let a = rx * orbit.radius, b = a * flatten
            for (slot, id) in orbit.ids.enumerated() {
                let base = Double(slot) / Double(orbit.ids.count) * 2 * .pi
                let arrive = easeOut((t - 0.35 - Double(order) * 0.055) / 0.95)
                order += 1
                guard arrive > 0 else { continue }
                let angle = base + (spinning ? t * orbit.speed : 0) - (1 - arrive) * 1.3
                let spread = 1 + 0.85 * (1 - arrive)
                let depth = sin(angle)
                let point = place(a * spread * cos(angle), b * spread * depth)
                let scale = 0.76 + 0.34 * (depth + 1) / 2
                coins.append(Coin(id: id, point: point, depth: depth, side: orbit.size * scale,
                                  alpha: arrive * (0.5 + 0.5 * (depth + 1) / 2)))
            }
        }
        let back = coins.filter { $0.depth < 0 }.sorted { $0.depth < $1.depth }
        let front = coins.filter { $0.depth >= 0 }.sorted { $0.depth < $1.depth }
        for coin in back { drawCoin(&context, coin.id, at: coin.point, side: coin.side, alpha: coin.alpha) }

        // O icone, com uma mola.
        if let icon = context.resolveSymbol(id: 1000) {
            let k = max(t - 0.1, 0)
            let spring = 1 - exp(-6 * k) * cos(11 * k) * 0.45
            var layer = context
            layer.opacity = clamp(k / 0.15)
            layer.translateBy(x: center.x, y: center.y)
            layer.scaleBy(x: spring, y: spring)
            layer.draw(icon, at: .zero)
        }
        for coin in front { drawCoin(&context, coin.id, at: coin.point, side: coin.side, alpha: coin.alpha) }
    }

    /// Um logo como o `CoinLogo`: os sem circulo proprio (ETH, SOL) num disco, com o
    /// glifo menor; os escuros (XRP, XLM) com um disco claro atras.
    private static func drawCoin(_ context: inout GraphicsContext, _ id: String, at point: CGPoint, side: Double, alpha: Double) {
        guard let image = TourLogos.images[id] else { return }
        var layer = context
        layer.opacity = alpha
        let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let disc = Path(ellipseIn: rect)
        if CoinLogo.bareLogos.contains(id) {
            layer.fill(disc, with: .color(Palette.control))
            layer.draw(image, in: rect.insetBy(dx: side * 0.19, dy: side * 0.19))
            return
        }
        if CoinLogo.darkLogos.contains(id) { layer.fill(disc, with: .color(Palette.logoDisc)) }
        layer.clip(to: disc)
        layer.draw(image, in: rect)
    }
}

/// Os logos do tour, decodificados uma vez (`byPreparingForDisplay`) e guardados como
/// `Image` pronta para o Canvas: decodificar no primeiro quadro travava a cena.
@MainActor
private enum TourLogos {
    static var images: [String: Image] = [:]

    static func prepare() async {
        for id in OrbitScene.ids where images[id] == nil {
            guard let raw = UIImage(named: "logo-\(id)") else { continue }
            let ready = await raw.byPreparingForDisplay() ?? raw
            images[id] = Image(uiImage: ready)
        }
    }
}

// MARK: - 3. A assinatura

/// Uma moeda de Bitcoin em 3D de verdade (`BitcoinCoin3D`, SceneKit). Ela gira devagar,
/// esperando; o Face ID procura o rosto e confirma; a moeda da um giro rapido e para de
/// frente.
private struct SignScene: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var confirmedAt: Double?
    @State private var scanning = false
    @State private var spin = false
    @State private var confirmed = false

    static let slowTurn = 3.4
    static let finale = 1.1

    var body: some View {
        VStack(spacing: Space.lg) {
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !active || reduceMotion)) { timeline in
                let t = reduceMotion ? 10 : start.map { timeline.date.timeIntervalSince($0) } ?? 0
                let angle = Self.angle(t: t, confirmedAt: reduceMotion ? 0 : confirmedAt)
                let enter = 1 - pow(1 - Self.clamp(t / 0.6), 3)
                let bob = 4 * sin(t * 1.6)
                ZStack {
                    // A sombra no chao, que encolhe quando a moeda sobe e quando ela esta de lado.
                    Canvas { context, size in Self.drawShadow(&context, size: size, angle: angle, bob: bob, enter: enter) }
                    BitcoinCoin3D(angle: angle)
                        .opacity(enter)
                        .scaleEffect(0.8 + 0.2 * enter)
                        .offset(y: bob - 8)
                }
            }
            .frame(height: 200)
            biometry
                .opacity(scanning || confirmed ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .modifier(SceneRunner(active: active, reset: reset, finish: finish, run: run))
        .sensoryFeedback(.success, trigger: confirmed)
        .accessibilityHidden(true)
    }

    private var biometry: some View {
        VStack(spacing: Space.sm) {
            ZStack {
                Circle().stroke(confirmed ? Palette.accent : Palette.edgeStrong, lineWidth: 2)
                Circle().trim(from: 0, to: 0.22)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .opacity(scanning && !confirmed ? 1 : 0)
                Image(systemName: confirmed ? "checkmark" : KeyServices.biometryIcon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 68, height: 68)
            Text(confirmed ? String(localized: "Assinado neste iPhone") : String(localized: "Confirme com o \(KeyServices.biometryName)"))
                .typeStyle(.note).foregroundStyle(confirmed ? Palette.ink : Palette.inkSoft)
                .contentTransition(.opacity)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: confirmed)
    }

    private func reset() {
        start = nil
        confirmedAt = nil
        scanning = false
        spin = false
        confirmed = false
    }

    private func finish() {
        start = .distantPast
        confirmedAt = 0
        confirmed = true
    }

    private func run() async {
        let began = Date()
        start = began
        guard await pause(1300) else { return }
        withAnimation(.easeOut(duration: 0.25)) { scanning = true }
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        guard await pause(1500) else { return }
        confirmedAt = Date().timeIntervalSince(began)
        confirmed = true
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    /// O angulo da moeda: giro lento ate a confirmacao; depois, um giro rapido que para de
    /// frente numa volta inteira.
    static func angle(t: Double, confirmedAt: Double?) -> Double {
        let slow = { (time: Double) in time / slowTurn * 2 * .pi }
        guard let confirmedAt else { return slow(t) }
        if confirmedAt == 0 { return 0 }
        let from = slow(confirmedAt)
        let to = (floor(from / (2 * .pi)) + 2) * 2 * .pi
        let p = clamp((t - confirmedAt) / finale)
        return from + (to - from) * (1 - pow(1 - p, 3))
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
