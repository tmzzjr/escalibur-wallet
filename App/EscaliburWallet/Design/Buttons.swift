import SwiftUI

/// Os quatro botoes do app. Nenhum usa `.disabled()` para escurecer: o estado
/// desligado e opaco e declarado, porque transparencia sobre preto lê como erro de
/// renderizacao, e o botao desligado precisa continuar dizendo o que falta.
struct PrimaryButton: View {
    let title: String
    var enabled: Bool = true
    var loading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: { if enabled && !loading { action() } }) {
            ZStack {
                if loading {
                    ProgressView().tint(Palette.onAccent)
                } else {
                    Text(title).typeStyle(.action)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Height.primary)
        }
        .buttonStyle(PrimaryStyle(enabled: enabled))
        // Desligado de verdade, nao so no desenho: o VoiceOver diz "esmaecido" e o
        // toque nem chega a acao.
        .disabled(!enabled)
    }
}

struct PrimaryStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Desligado continua legivel (4,8:1): o texto diz o que falta.
            .foregroundStyle(enabled ? Palette.onAccent : Palette.inkMuted)
            .background(
                Capsule(style: .continuous)
                    .fill(enabled ? (configuration.isPressed ? Palette.accentPress : Palette.accent) : Palette.rail)
            )
            .scaleEffect(configuration.isPressed && enabled ? 0.985 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = Height.secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)) }
                Text(title).typeStyle(.action)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
        .buttonStyle(SecondaryStyle())
    }
}

struct SecondaryStyle: ButtonStyle {
    var surface: Palette.Surface = .void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.ink)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? Palette.rail : Palette.body)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Palette.edge, lineWidth: 1)
                    )
            )
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct TertiaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .typeStyle(.body)
                .frame(minHeight: Height.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(TertiaryStyle())
    }
}

struct TertiaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Palette.ink : Palette.inkSoft)
    }
}

struct DestructiveButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .typeStyle(.action)
                .frame(maxWidth: .infinity)
                .frame(height: Height.secondary)
        }
        .buttonStyle(DestructiveStyle())
    }
}

struct DestructiveStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.down)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? Palette.downPress : Palette.downTint)
            )
    }
}

/// Rodape fixo de acao: margens de 20, area segura mais 8, fundo solido.
struct ActionFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Space.sm) { content }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xs)
            .background(Palette.void)
    }
}

/// Estilo de linha pressionavel de borda a borda.
struct RowStyle: ButtonStyle {
    var surface: Palette.Surface = .void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Palette.pressed(on: surface) : Color.clear)
    }
}

/// Circulo de acao rapida (Enviar, Receber, Trocar, Limite).
struct QuickAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: Height.quickAction, height: Height.quickAction)
                    .background(Circle().fill(Palette.rail))
                Text(title)
                    .typeStyle(.label)
                    .foregroundStyle(Palette.inkSoft)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(QuickActionStyle())
    }
}

private struct QuickActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A acao de receber quando falta saldo: lima chapado, texto escuro, em capsula. O
/// unico botao lima do app, para "o que fazer agora" nao se perder na tela.
struct AccentButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 16, weight: .bold)) }
                Text(title).typeStyle(.action)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Height.primary)
        }
        .buttonStyle(AccentStyle())
    }
}

struct AccentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.onAccent)
            .background(Capsule(style: .continuous).fill(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// O botao primario de copiar. No toque, a capsula da um pulo curto, o icone de
/// copiar vira visto com um quique, o rotulo sobe e da lugar a `doneTitle`, e uma faixa
/// clara atravessa a capsula da esquerda para a direita. Depois de 2 segundos volta,
/// pelo caminho inverso. Com Reduzir Movimento, so troca o icone e o texto.
struct CopyButton: View {
    var title = String(localized: "Copiar endereço")
    var doneTitle = String(localized: "Endereço copiado")
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var taps = 0
    @State private var reset: Task<Void, Never>?

    var body: some View {
        let still = reduceMotion
        Button {
            action()
            taps += 1
            reset?.cancel()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { copied = true }
            reset = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { copied = false }
            }
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 16, weight: .bold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .symbolEffect(.bounce, value: taps)
                    .frame(width: 20)
                ZStack {
                    Text(copied ? doneTitle : title)
                        .typeStyle(.action)
                        .id(copied)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }
                .clipped()
            }
            .frame(maxWidth: .infinity)
            .frame(height: Height.primary)
            .background {
                if !still {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let band = width * 0.45
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.6), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            // De -1 (fora, a esquerda) a 1 (fora, a direita); parada, some.
                            .keyframeAnimator(initialValue: CGFloat(-1), trigger: taps) { view, x in
                                view.offset(x: (width + band) * (x + 1) / 2 - band).opacity(x > -1 && x < 1 ? 1 : 0)
                            } keyframes: { _ in
                                CubicKeyframe(1, duration: 0.65)
                            }
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(Capsule(style: .continuous))
            .keyframeAnimator(initialValue: 1.0, trigger: taps) { view, scale in
                view.scaleEffect(still ? 1 : scale)
            } keyframes: { _ in
                SpringKeyframe(0.96, duration: 0.08)
                SpringKeyframe(1.025, duration: 0.18)
                SpringKeyframe(1, duration: 0.28)
            }
        }
        .buttonStyle(PrimaryStyle())
        .sensoryFeedback(.success, trigger: taps)
        .accessibilityLabel(copied ? doneTitle : title)
    }
}

/// Um botao que so dispara depois de segurado por `holdSeconds`: o fundo enche enquanto o
/// dedo esta em cima, e soltar antes cancela. Para o "usar mesmo assim" de um risco
/// grande, que nao pode sair de um toque sem querer. Com 0 segundos, e um toque comum.
struct HoldButton: View {
    let title: String
    var holdSeconds: Double = 2
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        Text(title).typeStyle(.action).foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity).frame(height: Height.secondary)
            .background(
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Palette.rail)
                    GeometryReader { geometry in
                        Capsule(style: .continuous).fill(Palette.downTint)
                            .frame(width: geometry.size.width * progress)
                    }
                }
            )
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .onTapGesture { if holdSeconds <= 0 { action() } }
            .onLongPressGesture(minimumDuration: max(holdSeconds, 0.01), maximumDistance: 40) {
                guard holdSeconds > 0 else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                action()
            } onPressingChanged: { pressing in
                guard holdSeconds > 0 else { return }
                holding = pressing
                withAnimation(pressing ? .linear(duration: holdSeconds) : .easeOut(duration: 0.2)) { progress = pressing ? 1 : 0 }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(holdSeconds > 0 ? "Segure por \(Int(holdSeconds)) segundos" : "")
    }
}

/// Deslizar para seguir: o trilho com o cadeado que o dedo leva ate o fim. Para passos
/// que pedem atencao (digitar as palavras): um toque sem querer nao segue. O verde
/// cresce atras do cadeado em pixels quadrados (`PixelFill`, pedido do dono, 15/10/2026),
/// o texto escurece onde o verde ja firmou, e em repouso o cadeado da uma espiada para a
/// direita de tempos em tempos. Soltou antes do fim, volta. No VoiceOver, o toque duplo
/// confirma.
struct SlideToConfirm: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void
    @State private var offset: CGFloat = 0
    @State private var hint: CGFloat = 0
    @State private var dragging = false
    @State private var done = false
    @State private var doneAt: Date?
    /// Depois da onda final a grade nao muda mais: a linha do tempo para.
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let height: CGFloat = 64

    private func label(_ color: Color, knob: CGFloat) -> some View {
        HStack(spacing: Space.xs) {
            Text(title).typeStyle(.action)
            Image(systemName: "chevron.forward.2").font(.system(size: 13, weight: .bold))
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(.leading, knob * 0.8)
    }

    var body: some View {
        GeometryReader { geo in
            let knob = height - 8
            let travel = max(geo.size.width - knob - 8, 1)
            let shift = min(offset + hint, travel)
            let showing = enabled && (shift > 0 || done)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.rail)
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !showing || settled)) { timeline in
                    let pixels = PixelFill(edge: 4 + shift + knob / 2, width: geo.size.width, doneAt: done ? doneAt ?? .distantPast : nil,
                                           now: timeline.date, still: reduceMotion)
                    ZStack(alignment: .leading) {
                        Canvas { context, size in pixels.draw(&context, size: size) }
                            .clipShape(Capsule())
                            .opacity(showing ? 1 : 0)
                        label(enabled ? Palette.ink : Palette.inkMuted, knob: knob)
                        // A mesma frase, escura, so onde o verde ja firmou.
                        label(Palette.void, knob: knob)
                            .mask(alignment: .leading) { Rectangle().frame(width: max(pixels.solid, 0)) }
                            .opacity(showing ? 1 : 0)
                    }
                }
                Circle()
                    .fill(enabled ? Color.white : Palette.control)
                    .frame(width: knob, height: knob)
                    .overlay {
                        Image(systemName: done ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(enabled ? Palette.success : Palette.inkMuted)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .offset(x: 4 + shift)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard enabled, !done else { return }
                                dragging = true
                                hint = 0
                                offset = min(max(value.translation.width, 0), travel)
                            }
                            .onEnded { _ in
                                dragging = false
                                guard enabled, !done else { return }
                                if offset > travel * 0.85 {
                                    doneAt = Date()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                        offset = travel
                                        done = true
                                    }
                                    Task {
                                        try? await Task.sleep(for: .milliseconds(320))
                                        action()
                                        try? await Task.sleep(for: .milliseconds(Int(PixelFill.finale * 1000)))
                                        settled = true
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: height)
        .sensoryFeedback(.success, trigger: done) { _, new in new }
        .sensoryFeedback(.selection, trigger: offset > 0) { old, new in !old && new }
        // Quem volta para esta tela encontra o cadeado fechado no comeco de novo.
        .onAppear {
            offset = 0
            hint = 0
            done = false
            doneAt = nil
            settled = false
        }
        // A espiada: o cadeado anda um pouco e volta, para dizer que desliza.
        .task(id: enabled) {
            guard enabled, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2600))
                guard !Task.isCancelled, !dragging, !done, offset == 0 else { continue }
                withAnimation(.easeOut(duration: 0.3)) { hint = 16 }
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { hint = 0 }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { action() } }
        // Depois do elemento montado: assim o VoiceOver (e o teste) le "desabilitado".
        .disabled(!enabled)
    }
}

/// O verde do `SlideToConfirm` em pixels, acendendo em ordem (pedido do dono, 15/10/2026:
/// pixels, mas com cara de seguranca, nada de pisca-pisca). Longe do cadeado, a grade
/// firme; na frente que avanca, cada pixel nasce pequeno e claro e encaixa no lugar, numa
/// varredura diagonal suave, como um cofre trancando. No fim, a varredura corre o resto do
/// trilho e as juntas fecham num verde so. Sem sorteio: o mesmo gesto da sempre o mesmo
/// desenho.
struct PixelFill {
    /// Ate onde o verde chega: o centro do cadeado.
    let edge: CGFloat
    let width: CGFloat
    /// Quando o dedo levou o cadeado ate o fim; nil enquanto nao chegou.
    let doneAt: Date?
    let now: Date
    /// Reduzir Movimento: o fim vem sem a varredura.
    let still: Bool

    static let cell: CGFloat = 6
    static let gap: CGFloat = 1.5
    /// A largura da frente onde os pixels ainda estao encaixando.
    static let frontier: CGFloat = 48
    /// Quanto a linha de baixo atrasa em relacao a de cima: a varredura sai na diagonal.
    static let slant: CGFloat = 0.55
    /// A varredura do fim e o fechar das juntas, em segundos.
    static let wave = 0.34
    static let finale = 0.8

    private var elapsed: Double? { doneAt.map { now.timeIntervalSince($0) } }

    /// A borda do verde, ja com a varredura do fim.
    var reach: CGFloat {
        guard let elapsed else { return edge }
        if still { return width * 2 + Self.frontier }
        let end = width + Self.frontier + 64
        return edge + (end - edge) * CGFloat(Self.easeOut(elapsed / Self.wave))
    }

    /// Ate onde o verde ja firmou em todas as linhas: o texto escurece ate aqui.
    var solid: CGFloat { reach - Self.frontier - 32 }

    /// As juntas da grade: 0 com a grade marcada, 1 com o verde inteiro.
    private var merge: Double {
        guard let elapsed else { return 0 }
        if still { return 1 }
        return Self.smooth((elapsed - Self.wave * 0.8) / (Self.finale - Self.wave))
    }

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        let pitch = Self.cell + Self.gap
        let columns = Int((size.width / pitch).rounded(.up))
        let rows = Int(((size.height + Self.gap) / pitch).rounded(.up))
        let top = (size.height - (CGFloat(rows) * pitch - Self.gap)) / 2
        let green = Palette.success
        let reach = self.reach

        // Por baixo da parte firme, as juntas: um verde mais fundo que fecha no fim.
        if solid > 0 {
            context.fill(Path(CGRect(x: 0, y: 0, width: min(solid, size.width), height: size.height)),
                         with: .color(green.opacity(0.55 + 0.45 * merge)))
        }
        let middle = CGFloat(rows - 1) / 2
        for column in 0..<columns {
            let x = CGFloat(column) * pitch
            if x - reach > Self.frontier { break }
            for row in 0..<rows {
                // A linha do meio acompanha o cadeado; as de baixo vem um pouco atras.
                let lag = (CGFloat(row) - middle) * pitch * Self.slant
                let progress = Self.smooth(Double((reach - lag - (x + Self.cell / 2)) / Self.frontier))
                guard progress > 0.02 else { continue }
                // Nasce menor e encaixa no tamanho cheio.
                let inset = Self.cell * 0.32 * CGFloat(1 - progress)
                let square = CGRect(x: x + inset, y: top + CGFloat(row) * pitch + inset,
                                    width: Self.cell - 2 * inset, height: Self.cell - 2 * inset)
                context.fill(Path(roundedRect: square, cornerRadius: 1.4), with: .color(green.opacity(0.4 + 0.6 * progress)))
            }
        }
    }

    private static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func easeOut(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return 1 - (1 - t) * (1 - t) * (1 - t)
    }
}

/// Desliga o "voltar arrastando pelo meio da tela" do iOS 26 enquanto a tela esta na
/// frente: arrastar o cadeado do `SlideToConfirm` para a direita voltava a tela anterior.
/// O botao voltar e o gesto pela borda continuam.
struct ContentSwipeBackDisabled: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            setContentPop(false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            setContentPop(true)
        }

        private func setContentPop(_ enabled: Bool) {
            if #available(iOS 26, *) { navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = enabled }
        }
    }
}
