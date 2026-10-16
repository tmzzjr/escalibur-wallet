import EscaliburChains
import EscaliburCore
import SwiftUI

/// Depois do primeiro PIN e antes da primeira carteira: o que a Escalibur e, em dois
/// passos com uma cena cada (pedido do dono, 15/10/2026). A espada ja abriu o app, antes
/// do PIN, e nao se repete aqui.
///
/// 1. As moedas: o selo da carteira no centro e as moedas em duas orbitas.
/// 2. A assinatura: uma moeda de Bitcoin em 3D gira esperando, e o Face ID confirma.
///
/// Cada cena roda quando o passo aparece. Com Reduzir Movimento, ela ja aparece pronta.
struct WelcomeTour: View {
    let onFinish: () -> Void
    @State private var page = 0

    private static let pages = 2

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
                    title: String(localized: "Uma chave para todas as suas moedas"),
                    text: String(localized: "Bitcoin, Ethereum, Solana e as maiores moedas do mundo, com a chave criada e guardada neste iPhone. Envie, receba e troque entre redes, com a taxa à vista antes de assinar.")
                ) { NetworksScene(active: page == 0) }
                .tag(0)
                TourPage(
                    title: String(localized: "Só você assina"),
                    text: String(localized: "Antes de cada envio, você vê o que sai e para onde, e confirma com o seu \(KeyServices.biometryName) ou PIN. O código é publicado para auditoria: qualquer pessoa pode conferir.")
                ) { SignScene(active: page == 1) }
                .tag(1)
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
    }
}

/// Um passo: a cena solta no fundo, sem painel (pedido do dono, 15/10/2026), o titulo e o
/// texto embaixo. O texto tem altura reservada, para a cena ter o mesmo tamanho nos tres
/// passos.
private struct TourPage<Scene: View>: View {
    let title: String
    let text: String
    @ViewBuilder var scene: Scene

    var body: some View {
        VStack(spacing: 0) {
            scene.frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// O selo da carteira no centro e as moedas em duas orbitas, a de dentro num sentido e a
/// de fora no outro. Elas entram uma a uma; as de fora sao menores, mais longe. E a cena
/// das redes do tour antigo, de volta no lugar das orbitas 3D (pedido do dono, 15/10/2026).
private struct NetworksScene: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    private static let inner = ["bitcoin", "ethereum", "solana", "tether", "ripple", "usd-coin"]
    private static let outer = ["binancecoin", "the-open-network", "tron", "cardano", "polkadot", "avalanche-2",
                                "dogecoin", "sui", "stellar", "near"]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let innerRadius = side * 0.25
            let outerRadius = side * 0.42
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !active || reduceMotion)) { timeline in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle().stroke(Palette.edgeStrong, lineWidth: 1)
                        .frame(width: innerRadius * 2, height: innerRadius * 2).position(center)
                    Circle().stroke(Palette.edge, style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
                        .frame(width: outerRadius * 2, height: outerRadius * 2).position(center)
                    ForEach(Array(Self.inner.enumerated()), id: \.offset) { index, id in
                        let angle = Double(index) / Double(Self.inner.count) * 2 * .pi + time * 0.16
                        coin(id, size: side * 0.14, visible: shown > index)
                            .position(x: center.x + innerRadius * cos(angle), y: center.y + innerRadius * sin(angle))
                    }
                    ForEach(Array(Self.outer.enumerated()), id: \.offset) { index, id in
                        let angle = Double(index) / Double(Self.outer.count) * 2 * .pi + 0.3 - time * 0.1
                        coin(id, size: side * 0.105, visible: shown > Self.inner.count + index)
                            .position(x: center.x + outerRadius * cos(angle), y: center.y + outerRadius * sin(angle))
                    }
                    WalletBadge(size: side * 0.2)
                        .position(center)
                        .scaleEffect(shown > 0 ? 1 : 0.8)
                }
            }
        }
        .modifier(SceneRunner(active: active, reset: { shown = 0 }, finish: { shown = Self.inner.count + Self.outer.count }, run: run))
        .accessibilityHidden(true)
    }

    private func coin(_ id: String, size: CGFloat, visible: Bool) -> some View {
        CoinLogo(coingeckoID: id, size: size, ringColor: Palette.void)
            .scaleEffect(visible ? 1 : 0.2)
            .opacity(visible ? 1 : 0)
            .animation(.spring(response: 0.42, dampingFraction: 0.62), value: visible)
    }

    private func run() async {
        guard await pause(200) else { return }
        for _ in 0..<(Self.inner.count + Self.outer.count) {
            shown += 1
            guard await pause(70) else { return }
        }
    }
}

// MARK: - 3. A assinatura

/// Uma moeda de Bitcoin em 3D de verdade (`BitcoinCoin3D`, SceneKit). Ela gira devagar,
/// esperando; o Face ID procura o rosto e confirma; a moeda da um giro rapido e para de
/// frente. E o dono gira com o dedo (pedido do dono, 15/10/2026): arrastando ela acompanha,
/// ao soltar segue no embalo e para de frente, e um toque da uma volta inteira.
private struct SignScene: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var confirmedAt: Double?
    @State private var scanning = false
    @State private var spin = false
    @State private var confirmed = false
    /// O giro do dedo: o que esta sendo arrastado agora e o embalo depois de soltar.
    @State private var dragTurn: Double = 0
    @State private var release: CoinMotion.Release?

    static let slowTurn = 3.4
    static let finale = 1.1

    var body: some View {
        VStack(spacing: Space.lg) {
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !active || reduceMotion)) { timeline in
                let t = reduceMotion ? 10 : start.map { timeline.date.timeIntervalSince($0) } ?? 0
                let angle = Self.angle(t: t, confirmedAt: reduceMotion ? 0 : confirmedAt) + CoinMotion.handTurn(release, at: timeline.date) + dragTurn
                let enter = 1 - pow(1 - Self.clamp(t / 0.6), 3)
                let bob = 4 * sin(t * 1.6)
                ZStack {
                    // A sombra no chao, que encolhe quando a moeda sobe e quando ela esta de lado.
                    Canvas { context, size in CoinMotion.drawShadow(&context, size: size, angle: angle, bob: bob, enter: enter) }
                    BitcoinCoin3D(angle: angle)
                        .opacity(enter)
                        .scaleEffect(0.8 + 0.2 * enter)
                        .offset(y: bob - 8)
                }
            }
            .frame(height: 200)
            .contentShape(Rectangle())
            .onTapGesture { release = CoinMotion.release(from: CoinMotion.handTurn(release, at: Date()), extra: 2 * .pi) }
            .highPriorityGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { dragTurn = $0.translation.width / CoinMotion.pointsPerRadian }
                    .onEnded { value in
                        let momentum = (value.predictedEndTranslation.width - value.translation.width) / CoinMotion.pointsPerRadian
                        let from = CoinMotion.handTurn(release, at: Date()) + dragTurn
                        dragTurn = 0
                        release = CoinMotion.release(from: from, extra: momentum)
                    }
            )
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
}
