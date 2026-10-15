import EscaliburChains
import EscaliburCore
import SwiftUI

/// Depois do primeiro PIN e antes da primeira carteira: o que a Escalibur e, em tres
/// passos com uma cena cada (pedido do dono, 15/10/2026). Substitui a lista de cinco
/// promessas que vinha antes de criar e de importar.
///
/// 1. As chaves: nuvem, servidor, conta e e-mail tentam chegar ao iPhone e ficam de fora.
/// 2. As redes: as moedas de verdade entram uma a uma e giram em volta do selo.
/// 3. A assinatura: a revisao marca o comeco e o fim do endereco, e o Face ID confirma.
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
                    title: String(localized: "Suas chaves nascem e ficam aqui"),
                    text: String(localized: "Sem servidor, sem conta e sem e-mail. A Escalibur não vê, não guarda e não consegue mover nada seu.")
                ) { KeysScene(active: page == 0) }
                .tag(0)
                TourPage(
                    title: String(localized: "Suas moedas, todas aqui"),
                    text: String(localized: "Bitcoin, Ethereum, Solana e mais \(Chain.all.count - 3) redes. Envie, receba, troque e leve entre redes, com a taxa à vista antes de assinar.")
                ) { NetworksScene(active: page == 1) }
                .tag(1)
                TourPage(
                    title: String(localized: "Nada sai sem você"),
                    text: String(localized: "Cada envio passa pela sua revisão e pelo seu \(KeyServices.biometryName) ou PIN. O código é aberto: qualquer pessoa pode conferir.")
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

// MARK: - 1. As chaves

/// O iPhone com o selo no meio. Nuvem, servidor, conta e e-mail tentam chegar, um de
/// cada vez: o tracejado vai ate a borda do aparelho e para, e quem tentou fica riscado.
/// No fim, o cadeado fecha dentro do iPhone.
private struct KeysScene: View {
    let active: Bool
    @State private var phoneIn = false
    @State private var reaching = -1
    @State private var blocked = 0
    @State private var hits = 0
    @State private var sealed = false

    private struct Outsider {
        let icon: String
        let name: String
        let anchor: UnitPoint
    }

    private static let outsiders: [Outsider] = [
        .init(icon: "icloud", name: String(localized: "Nuvem"), anchor: UnitPoint(x: 0.17, y: 0.2)),
        .init(icon: "server.rack", name: String(localized: "Servidor"), anchor: UnitPoint(x: 0.83, y: 0.26)),
        .init(icon: "person.crop.circle", name: String(localized: "Conta"), anchor: UnitPoint(x: 0.17, y: 0.74)),
        .init(icon: "envelope", name: String(localized: "E-mail"), anchor: UnitPoint(x: 0.83, y: 0.8)),
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let phoneWidth = min(size.width * 0.3, size.height * 0.3)
            let phone = CGRect(x: center.x - phoneWidth / 2, y: center.y - phoneWidth, width: phoneWidth, height: phoneWidth * 2)
            ZStack {
                ForEach(Self.outsiders.indices, id: \.self) { index in
                    let from = CGPoint(x: size.width * Self.outsiders[index].anchor.x, y: size.height * Self.outsiders[index].anchor.y)
                    let to = Self.edgePoint(from: from, toward: phone)
                    Path { path in
                        path.move(to: from)
                        path.addLine(to: to)
                    }
                    .trim(from: 0, to: reaching == index || blocked > index ? 1 : 0)
                    .stroke(Palette.inkMuted, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 6]))
                    .opacity(blocked > index ? 0 : 1)
                    outsider(index, blocked: blocked > index).position(from)
                }
                phoneView(width: phoneWidth)
                    .position(center)
                    .scaleEffect(phoneIn ? 1 : 0.86)
                    .opacity(phoneIn ? 1 : 0)
            }
        }
        .modifier(SceneRunner(active: active, reset: reset, finish: finish, run: run))
        .sensoryFeedback(.impact(weight: .light), trigger: hits)
        .sensoryFeedback(.success, trigger: sealed)
        .accessibilityHidden(true)
    }

    private func outsider(_ index: Int, blocked: Bool) -> some View {
        let item = Self.outsiders[index]
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(Palette.control).frame(width: 52, height: 52)
                Image(systemName: item.icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.inkSoft)
                // O risco de quem ficou de fora.
                Capsule().fill(Palette.down).frame(width: 3, height: 58).rotationEffect(.degrees(-45))
                    .scaleEffect(y: blocked ? 1 : 0, anchor: .top)
            }
            Text(item.name).typeStyle(.note).foregroundStyle(Palette.inkMuted)
        }
        .opacity(blocked ? 0.55 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: blocked)
    }

    private func phoneView(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.2, style: .continuous)
        return ZStack {
            shape.fill(Palette.void)
            shape.stroke(sealed ? Palette.accent : Color(hex: 0x5A5A62), lineWidth: 2)
            // A borda acende onde o tracejado bate.
            shape.stroke(Palette.accent.opacity(0.9), lineWidth: 3)
                .opacity(hits % 2 == 1 ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: hits)
            VStack(spacing: width * 0.12) {
                WalletBadge(size: width * 0.42)
                Image(systemName: sealed ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: width * 0.14, weight: .semibold))
                    .foregroundStyle(sealed ? Palette.ink : Palette.inkMuted)
                    .contentTransition(.symbolEffect(.replace))
            }
            Capsule().fill(Palette.rail).frame(width: width * 0.32, height: width * 0.09)
                .offset(y: -width + width * 0.12)
        }
        .frame(width: width, height: width * 2)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: sealed)
    }

    /// O ponto da borda do iPhone na direcao de quem tenta chegar.
    static func edgePoint(from: CGPoint, toward rect: CGRect) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = from.x - center.x
        let dy = from.y - center.y
        let scale = min(rect.width / 2 / max(abs(dx), 0.001), rect.height / 2 / max(abs(dy), 0.001))
        return CGPoint(x: center.x + dx * scale * 1.06, y: center.y + dy * scale * 1.06)
    }

    private func reset() {
        phoneIn = false
        reaching = -1
        blocked = 0
        sealed = false
    }

    private func finish() {
        phoneIn = true
        blocked = Self.outsiders.count
        sealed = true
    }

    private func run() async {
        guard await pause(150) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { phoneIn = true }
        guard await pause(450) else { return }
        for index in Self.outsiders.indices {
            withAnimation(.easeIn(duration: 0.42)) { reaching = index }
            guard await pause(440) else { return }
            hits += 1
            withAnimation(.easeOut(duration: 0.25)) { blocked = index + 1 }
            guard await pause(240) else { return }
            hits += 1
        }
        guard await pause(150) else { return }
        sealed = true
    }
}

// MARK: - 2. As redes

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

// MARK: - 3. A assinatura

/// A revisao de um envio: o cartao sobe, o comeco e o fim do endereco acendem (o que se
/// confere contra a origem), o Face ID procura o rosto e confirma.
private struct SignScene: View {
    let active: Bool
    @State private var cardIn = false
    @State private var headMarked = false
    @State private var tailMarked = false
    @State private var scanning = false
    @State private var spin = false
    @State private var confirmed = false

    private static let address = "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"

    var body: some View {
        VStack(spacing: Space.lg) {
            Spacer(minLength: 0)
            card
                .offset(y: cardIn ? 0 : 36)
                .opacity(cardIn ? 1 : 0)
            biometry
                .opacity(scanning || confirmed ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .modifier(SceneRunner(active: active, reset: reset, finish: finish, run: run))
        .sensoryFeedback(.success, trigger: confirmed)
        .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Revisão").typeStyle(.note).foregroundStyle(Palette.plateMuted)
            Text("Enviar \(Fmt.crypto(BigUInt(250_000_000_000_000_000), decimals: 18, symbol: "ETH", style: .full))")
                .typeStyle(.title).foregroundStyle(Palette.plateInk)
            Text("Para").typeStyle(.note).foregroundStyle(Palette.plateMuted).padding(.top, Space.xs)
            addressText
                .font(TypeStyle.mono.font)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Taxa da rede").typeStyle(.note).foregroundStyle(Palette.plateMuted)
                Spacer()
                Text(Fmt.crypto(BigUInt(42_000_000_000_000), decimals: 18, symbol: "ETH", style: .full))
                    .typeStyle(.note).foregroundStyle(Palette.plateInk)
            }
            .padding(.top, Space.xs)
        }
        .padding(Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LacquerPlate(cut: 20).fill(Palette.live))
    }

    /// O endereco com as pontas marcadas: e o que o dono confere contra a origem.
    private var addressText: Text {
        let head = String(Self.address.prefix(6))
        let tail = String(Self.address.suffix(4))
        let middle = String(Self.address.dropFirst(6).dropLast(4))
        return Text(head).fontWeight(.bold).foregroundColor(headMarked ? Palette.accent : Palette.plateInk)
            + Text(middle).foregroundColor(Palette.plateMuted)
            + Text(tail).fontWeight(.bold).foregroundColor(tailMarked ? Palette.accent : Palette.plateInk)
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
        cardIn = false
        headMarked = false
        tailMarked = false
        scanning = false
        spin = false
        confirmed = false
    }

    private func finish() {
        cardIn = true
        headMarked = true
        tailMarked = true
        confirmed = true
    }

    private func run() async {
        guard await pause(150) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { cardIn = true }
        guard await pause(650) else { return }
        withAnimation(.easeOut(duration: 0.3)) { headMarked = true }
        guard await pause(450) else { return }
        withAnimation(.easeOut(duration: 0.3)) { tailMarked = true }
        guard await pause(550) else { return }
        withAnimation(.easeOut(duration: 0.25)) { scanning = true }
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        guard await pause(1400) else { return }
        confirmed = true
    }
}
