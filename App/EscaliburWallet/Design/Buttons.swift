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
                    ProgressView().tint(Palette.onLime)
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
            .foregroundStyle(enabled ? Palette.onLime : Palette.inkMuted)
            .background(
                Capsule(style: .continuous)
                    .fill(enabled ? (configuration.isPressed ? Palette.limePress : Palette.lime) : Palette.rail)
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
            .foregroundStyle(Palette.onLime)
            .background(Capsule(style: .continuous).fill(Palette.lime.opacity(configuration.isPressed ? 0.8 : 1)))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// O botao primario de copiar. No toque, a capsula da um pulo curto, o icone de
/// copiar vira visto com um quique, o rotulo sobe e da lugar a `doneTitle`, e uma faixa
/// clara atravessa a capsula da esquerda para a direita. Depois de 2 segundos volta,
/// pelo caminho inverso. Com Reduzir Movimento, so troca o icone e o texto.
struct CopyButton: View {
    var title = "Copiar endereço"
    var doneTitle = "Endereço copiado"
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
