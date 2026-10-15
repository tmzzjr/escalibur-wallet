import EscaliburChains
import EscaliburCore
import SwiftUI

/// Depois do primeiro PIN e antes da primeira carteira: o que a Escalibur e, em quatro
/// passos com uma cena cada (pedido do dono, 15/10/2026). Substitui a lista de cinco
/// promessas que vinha antes de criar e de importar.
///
/// 1. A espada na pedra, a mesma da abertura: so sai pelas maos certas.
/// 2. A chave: as moedas e as redes giram, se juntam no centro e viram o icone do app.
/// 3. As redes: as moedas de verdade entram uma a uma e giram em volta do selo.
/// 4. A assinatura: o BTC espera, o Face ID confirma, e so entao ele vai ate o USDC.
///
/// Cada cena roda quando o passo aparece. Com Reduzir Movimento, ela ja aparece pronta.
struct WelcomeTour: View {
    let onFinish: () -> Void
    @State private var page = 0

    private static let pages = 4

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
                    title: String(localized: "Uma carteira que só você abre"),
                    text: String(localized: "Na lenda, a Escalibur só sai da pedra pelas mãos certas. Aqui, essas mãos são as suas.")
                ) { SwordInStone() }
                .tag(0)
                TourPage(
                    title: String(localized: "A chave de tudo é sua"),
                    text: String(localized: "Todas as suas moedas num lugar só, com a chave criada e guardada neste iPhone. Sem servidor, sem conta e sem e-mail.")
                ) { ConvergeScene(active: page == 1) }
                .tag(1)
                TourPage(
                    title: String(localized: "\(Chain.all.count) redes, um app só"),
                    text: String(localized: "Bitcoin, Ethereum, Solana e as maiores moedas do mundo. Envie, receba, troque e leve entre redes, com a taxa à vista antes de assinar.")
                ) { NetworksScene(active: page == 2) }
                .tag(2)
                TourPage(
                    title: String(localized: "Só você assina"),
                    text: String(localized: "Antes de cada envio, você vê o que sai e para onde, e confirma com o seu \(KeyServices.biometryName) ou PIN. O código é aberto: qualquer pessoa pode conferir.")
                ) { SignScene(active: page == 3) }
                .tag(3)
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
        .task { await ConvergeLogos.prepare() }
    }
}

/// Um passo: a cena no painel grafite, o titulo e o texto embaixo. O texto tem altura
/// reservada, para o painel ter o mesmo tamanho nos tres passos.
private struct TourPage<Scene: View>: View {
    let title: String
    let text: String
    @ViewBuilder var scene: Scene

    var body: some View {
        VStack(spacing: 0) {
            scene
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [Palette.rail, Palette.body], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1))
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

// MARK: - 2. A chave

/// As moedas e as redes espalhadas em tres planos (as do fundo menores e desfocadas),
/// girando devagar. Depois elas sao puxadas para o centro num redemoinho que acelera,
/// com rastro, e somem num clarao de onde sai o icone do app, com uma onda e um toque
/// firme. Fica o icone, com um brilho que passa de tempos em tempos.
///
/// Tudo e funcao do tempo desde o comeco (`start`): a cena e a mesma toda vez, e o
/// Canvas desenha os logos como simbolos, sem uma view por quadro.
private struct ConvergeScene: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var merged = false

    static let ids = ["bitcoin", "ethereum", "solana", "tether", "ripple", "usd-coin", "binancecoin", "the-open-network",
                              "tron", "cardano", "polkadot", "avalanche-2", "dogecoin", "sui", "stellar", "near", "litecoin",
                              "polygon-ecosystem-token", "chainlink", "aptos", "arbitrum", "optimism"]

    /// Onde cada logo comeca: angulo de ouro (espalha sem grade), raio, plano e atraso.
    private struct Seat { let angle: Double; let radius: Double; let depth: Double; let delay: Double }
    private static let seats: [Seat] = ids.indices.map { index in
        Seat(angle: Double(index) * 2.399963, radius: 0.5 + 0.5 * Double((index * 37) % 11) / 10,
             depth: [1.0, 0.78, 0.58][index % 3], delay: Double(index) * 0.035)
    }

    /// Quando comecam a ser puxados, e quando viram o icone (segundos).
    static let gather = 1.4
    static let merge = 2.65
    static let logoSide: CGFloat = 64
    static let iconSide: CGFloat = 112

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !active || reduceMotion)) { timeline in
            let elapsed = reduceMotion ? 60 : start.map { timeline.date.timeIntervalSince($0) } ?? 0
            Canvas { context, size in
                Self.draw(&context, size: size, t: elapsed)
            } symbols: {
                WalletBadge(size: Self.iconSide).tag(1000)
            }
        }
        .modifier(SceneRunner(active: active, reset: { start = nil; merged = false }, finish: { start = .distantPast }, run: run))
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: merged) { _, new in new }
        .accessibilityHidden(true)
    }

    private func run() async {
        // O relogio so comeca com os logos prontos: decodificar no primeiro quadro
        // travava a cena por mais de um segundo e ela pulava o comeco (gravacao do
        // simulador, 15/10/2026).
        await ConvergeLogos.prepare()
        guard !Task.isCancelled else { return }
        start = Date()
        guard await pause(Int(Self.merge * 1000)) else { return }
        merged = true
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
    private static func smooth(_ value: Double) -> Double { let x = clamp(value); return x * x * (3 - 2 * x) }

    /// Posicao, escala e opacidade de um logo no instante `t`.
    private static func pose(_ index: Int, t: Double, center: CGPoint, reach: Double) -> (point: CGPoint, scale: Double, alpha: Double) {
        let seat = seats[index]
        let appear = smooth((t - 0.1 - seat.delay) / 0.45)
        let fade = 1 - smooth((t - (merge - 0.22)) / 0.22)
        let pull = pow(clamp((t - gather) / (merge - gather)), 3)
        let angle = seat.angle + t * 0.14 * seat.depth + pull * 2.6
        let breathe = 0.97 + 0.03 * sin(t * 1.4 + Double(index))
        let radius = reach * seat.radius * (1 - pull) * breathe
        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle) * 0.86)
        let scale = (0.38 + 0.4 * seat.depth) * (1 - 0.5 * pull) * (0.7 + 0.3 * appear)
        return (point, scale, appear * fade * (0.5 + 0.5 * seat.depth))
    }

    /// Um logo como o `CoinLogo`: os sem circulo proprio (ETH, SOL) num disco, com o
    /// glifo menor; os escuros (XRP, XLM) com um disco claro atras.
    private static func drawLogo(_ context: inout GraphicsContext, image: Image, id: String) {
        let side = Double(logoSide)
        let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        let disc = Path(ellipseIn: rect)
        if CoinLogo.bareLogos.contains(id) {
            context.fill(disc, with: .color(Palette.control))
            context.draw(image, in: rect.insetBy(dx: side * 0.19, dy: side * 0.19))
            return
        }
        if CoinLogo.darkLogos.contains(id) { context.fill(disc, with: .color(Palette.logoDisc)) }
        var round = context
        round.clip(to: disc)
        round.draw(image, in: rect)
    }

    private static func draw(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = Double(min(size.width, size.height)) * 0.5
        let pull = pow(clamp((t - gather) / (merge - gather)), 3)

        // A luz que cresce no centro enquanto eles chegam, e o clarao do encontro.
        let flash = exp(-pow((t - merge) / 0.14, 2))
        let core = max(0.28 * pull, 0.85 * flash)
        if core > 0.01 {
            let glow = CGRect(x: center.x - reach * 0.7, y: center.y - reach * 0.7, width: reach * 1.4, height: reach * 1.4)
            context.fill(Path(ellipseIn: glow), with: .radialGradient(
                Gradient(colors: [Color.white.opacity(core), Palette.accent.opacity(core * 0.45), .clear]),
                center: center, startRadius: 0, endRadius: reach * 0.7))
        }

        // Os logos, do fundo para a frente, com rastro enquanto sao puxados.
        let order = seats.indices.sorted { seats[$0].depth < seats[$1].depth }
        for index in order {
            guard let image = ConvergeLogos.images[ids[index]] else { continue }
            let ghosts = pull > 0.04 ? 3 : 0
            for ghost in stride(from: ghosts, through: 0, by: -1) {
                let pose = pose(index, t: t - Double(ghost) * 0.035, center: center, reach: reach)
                let alpha = pose.alpha * (ghost == 0 ? 1 : 0.28 / Double(ghost))
                guard alpha > 0.01 else { continue }
                var layer = context
                layer.opacity = alpha
                if seats[index].depth < 0.7 { layer.addFilter(.blur(radius: 1.6 * (1 - pull))) }
                layer.translateBy(x: pose.point.x, y: pose.point.y)
                layer.scaleBy(x: pose.scale, y: pose.scale)
                drawLogo(&layer, image: image, id: ids[index])
            }
        }

        guard t >= merge - 0.04 else { return }
        let since = t - merge

        // A onda que sai do encontro.
        let wave = clamp(since / 0.85)
        if wave < 1 {
            let radius = Double(iconSide) * 0.55 + reach * 1.05 * (1 - pow(1 - wave, 3))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(Color.white.opacity(0.55 * (1 - wave))), lineWidth: 2)
        }

        // O halo rosa atras do icone, respirando.
        let halo = clamp(since / 0.4) * (0.32 + 0.06 * sin(t * 2.2))
        let haloRect = CGRect(x: center.x - Double(iconSide), y: center.y - Double(iconSide), width: Double(iconSide) * 2, height: Double(iconSide) * 2)
        context.fill(Path(ellipseIn: haloRect), with: .radialGradient(
            Gradient(colors: [Palette.accent.opacity(halo), .clear]), center: center, startRadius: 0, endRadius: Double(iconSide)))

        // O icone, com uma mola que passa um pouco do tamanho e volta.
        guard let icon = context.resolveSymbol(id: 1000) else { return }
        let spring = 1 - exp(-7 * max(since, 0)) * cos(13 * max(since, 0)) * 0.5
        var layer = context
        layer.opacity = clamp((since + 0.04) / 0.1)
        layer.translateBy(x: center.x, y: center.y)
        layer.scaleBy(x: spring, y: spring)
        layer.draw(icon, at: .zero)

        // Um brilho que atravessa o icone a cada 4 s, depois de assentar.
        let cycle = (since - 1.0).truncatingRemainder(dividingBy: 4)
        if since > 1.0, cycle < 0.9 {
            let side = Double(iconSide) * spring
            let frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            var sheen = context
            sheen.clip(to: Path(roundedRect: frame, cornerRadius: side * 0.2237, style: .continuous))
            let x = frame.minX - side * 0.5 + side * 2 * (cycle / 0.9)
            var band = Path()
            band.move(to: CGPoint(x: x, y: frame.minY))
            band.addLine(to: CGPoint(x: x + side * 0.22, y: frame.minY))
            band.addLine(to: CGPoint(x: x + side * 0.22 - side * 0.4, y: frame.maxY))
            band.addLine(to: CGPoint(x: x - side * 0.4, y: frame.maxY))
            band.closeSubpath()
            sheen.fill(band, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0)]),
                                                   startPoint: CGPoint(x: x - side * 0.2, y: frame.midY),
                                                   endPoint: CGPoint(x: x + side * 0.22, y: frame.midY)))
        }
    }
}

/// Os logos da cena da chave, decodificados uma vez (`byPreparingForDisplay`) e
/// guardados como `Image` pronta para o Canvas.
@MainActor
private enum ConvergeLogos {
    static var images: [String: Image] = [:]

    static func prepare() async {
        for id in ConvergeScene.ids where images[id] == nil {
            guard let raw = UIImage(named: "logo-\(id)") else { continue }
            let ready = await raw.byPreparingForDisplay() ?? raw
            images[id] = Image(uiImage: ready)
        }
    }
}

// MARK: - 3. As redes

/// O selo no centro e as moedas em duas orbitas, a de dentro num sentido e a de fora no
/// outro. Elas entram uma a uma; as de fora sao menores, mais longe.
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
        CoinLogo(coingeckoID: id, size: size, ringColor: Palette.rail)
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

// MARK: - 4. A assinatura

/// O BTC e o USDC frente a frente, ligados por um arco. O BTC pronto para sair pulsa,
/// esperando; o Face ID procura o rosto e confirma, e so entao ele percorre o arco e
/// chega ao USDC, que acende com uma onda e o sinal de feito.
private struct SignScene: View {
    let active: Bool
    @State private var coinsIn = false
    @State private var arc: CGFloat = 0
    @State private var waiting = false
    @State private var scanning = false
    @State private var spin = false
    @State private var confirmed = false
    @State private var travel: CGFloat = 0
    @State private var arrived = false

    var body: some View {
        VStack(spacing: Space.lg) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                let width = geo.size.width
                let coin = min(width * 0.24, 84)
                let from = CGPoint(x: coin / 2 + 8, y: geo.size.height * 0.62)
                let to = CGPoint(x: width - coin / 2 - 8, y: geo.size.height * 0.62)
                let control = CGPoint(x: width / 2, y: geo.size.height * 0.02)
                ZStack {
                    // O halo de cada moeda, na cor dela.
                    Circle().fill(Self.btc.opacity(0.32)).frame(width: coin * 1.5, height: coin * 1.5).blur(radius: 22)
                        .position(from).opacity(coinsIn ? 1 : 0)
                    Circle().fill(Self.usdc.opacity(arrived ? 0.55 : 0.3)).frame(width: coin * 1.5, height: coin * 1.5).blur(radius: 22)
                        .position(to).opacity(coinsIn ? 1 : 0)
                        .animation(.easeOut(duration: 0.5), value: arrived)
                    Path { path in
                        path.move(to: from)
                        path.addQuadCurve(to: to, control: control)
                    }
                    .trim(from: 0, to: arc)
                    .stroke(LinearGradient(colors: [Self.btc, Self.usdc], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 8]))
                    .opacity(0.85)
                    // O que sai: espera pulsando ao lado do BTC, fora do logo, e so anda depois
                    // do Face ID, com um rastro.
                    ForEach([0.0, 0.05, 0.1], id: \.self) { lag in
                        Circle().fill(lag == 0 ? Color.white : Self.btc)
                            .frame(width: lag == 0 ? 12 : 10 - lag * 30, height: lag == 0 ? 12 : 10 - lag * 30)
                            .shadow(color: Self.btc, radius: lag == 0 ? 10 : 0)
                            .opacity(lag == 0 ? 1 : (travel > 0 && travel < 1 ? 0.5 - lag * 3 : 0))
                            .scaleEffect(lag == 0 && waiting && travel == 0 ? 1.35 : 1)
                            .animation(waiting && travel == 0 ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: waiting)
                            .position(from)
                            .modifier(AlongCurve(progress: Self.leg(max(travel - lag, 0)), from: from, control: control, to: to))
                    }
                    .opacity(waiting && !arrived ? 1 : 0)
                    coinView("bitcoin", symbol: "BTC", size: coin)
                        .position(from)
                        .offset(x: coinsIn ? 0 : -60)
                        .opacity(coinsIn ? 1 : 0)
                    ZStack {
                        Circle().stroke(Palette.success, lineWidth: 2)
                            .frame(width: coin, height: coin)
                            .scaleEffect(arrived ? 1.7 : 1)
                            .opacity(arrived ? 0 : 0.0001)
                            .animation(.easeOut(duration: 0.7), value: arrived)
                        coinView("usd-coin", symbol: "USDC", size: coin)
                        Image(systemName: "checkmark")
                            .font(.system(size: coin * 0.17, weight: .bold)).foregroundStyle(Palette.void)
                            .frame(width: coin * 0.36, height: coin * 0.36)
                            .background(Circle().fill(Palette.success))
                            .overlay(Circle().stroke(Palette.rail, lineWidth: 3))
                            .offset(x: coin * 0.36, y: -coin * 0.42)
                            .scaleEffect(arrived ? 1 : 0.2)
                            .opacity(arrived ? 1 : 0)
                            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: arrived)
                    }
                    .position(to)
                    .offset(x: coinsIn ? 0 : 60)
                    .opacity(coinsIn ? 1 : 0)
                }
            }
            .frame(height: 170)
            biometry
                .opacity(scanning || confirmed ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .modifier(SceneRunner(active: active, reset: reset, finish: finish, run: run))
        .sensoryFeedback(.success, trigger: confirmed)
        .sensoryFeedback(.impact(weight: .medium), trigger: arrived) { _, new in new }
        .accessibilityHidden(true)
    }

    static let btc = Color(hex: 0xF7931A)
    static let usdc = Color(hex: 0x2775CA)

    /// O trecho do arco fora dos dois logos: a espera fica visivel ao lado do BTC e a
    /// chegada para na borda do USDC.
    static func leg(_ travel: CGFloat) -> CGFloat { 0.16 + 0.68 * travel }

    private func coinView(_ id: String, symbol: String, size: CGFloat) -> some View {
        VStack(spacing: 6) {
            CoinLogo(coingeckoID: id, size: size, ringColor: .clear)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
            Text(verbatim: symbol).typeStyle(.note).foregroundStyle(Palette.inkSoft)
        }
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
        coinsIn = false
        arc = 0
        waiting = false
        scanning = false
        spin = false
        confirmed = false
        travel = 0
        arrived = false
    }

    private func finish() {
        coinsIn = true
        arc = 1
        waiting = true
        confirmed = true
        travel = 1
        arrived = true
    }

    private func run() async {
        guard await pause(150) else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { coinsIn = true }
        guard await pause(450) else { return }
        withAnimation(.easeInOut(duration: 0.7)) { arc = 1 }
        guard await pause(650) else { return }
        waiting = true
        guard await pause(700) else { return }
        withAnimation(.easeOut(duration: 0.25)) { scanning = true }
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        guard await pause(1400) else { return }
        confirmed = true
        guard await pause(350) else { return }
        withAnimation(.easeInOut(duration: 0.8)) { travel = 1 }
        guard await pause(800) else { return }
        arrived = true
    }
}

/// Leva a view, posta no comeco da curva, ate o ponto `progress` de uma curva
/// quadratica, animando o progresso (como o `Shake` do PIN).
private struct AlongCurve: GeometryEffect {
    var progress: CGFloat
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = progress
        let x = (1 - t) * (1 - t) * from.x + 2 * (1 - t) * t * control.x + t * t * to.x
        let y = (1 - t) * (1 - t) * from.y + 2 * (1 - t) * t * control.y + t * t * to.y
        return ProjectionTransform(CGAffineTransform(translationX: x - from.x, y: y - from.y))
    }
}
