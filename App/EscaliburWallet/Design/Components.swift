import SwiftUI

// MARK: Banner

/// Aviso que fica na pagina ate ser resolvido. Tres naturezas, e cada uma tem um
/// fundo so: risco, falha, neutro.
struct Banner: View {
    enum Kind { case caution, failure, neutral }

    let kind: Kind
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle).typeStyle(.note).fontWeight(.semibold).foregroundStyle(Palette.ink)
                            .frame(minHeight: 32, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(background)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(kind == .neutral ? Palette.edge : .clear, lineWidth: 1)
                )
        )
    }

    private var icon: String {
        switch kind {
        case .caution: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .neutral: return "info.circle"
        }
    }

    private var iconColor: Color {
        switch kind {
        case .caution: return Palette.caution
        case .failure: return Palette.down
        case .neutral: return Palette.inkSoft
        }
    }

    private var background: Color {
        switch kind {
        case .caution: return Palette.cautionTint
        case .failure: return Palette.downTint
        case .neutral: return Palette.body
        }
    }
}

// MARK: Badge de status

struct StatusBadge: View {
    enum Kind { case pending, open, partial, done, closed, failed }

    let kind: Kind
    let text: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            if kind == .pending {
                Circle().fill(Palette.inkSoft).frame(width: 6, height: 6)
                    .opacity(pulse ? 1 : 0.45)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                    }
            }
            Text(text).typeStyle(.label)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Space.xs)
        .frame(height: Height.badge)
        .background(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous).fill(background))
    }

    private var foreground: Color {
        switch kind {
        case .pending: return Palette.inkSoft
        case .open, .partial: return Palette.ink
        case .done: return Palette.up
        case .closed: return Palette.inkMuted
        case .failed: return Palette.down
        }
    }

    private var background: Color {
        switch kind {
        case .pending, .closed: return Palette.rail
        case .open, .partial: return Palette.control
        case .done: return Palette.upTint
        case .failed: return Palette.downTint
        }
    }
}

// MARK: Selecao

/// A selecao do app em vidro liquido (iOS 26), sem cor: o material da vez, um pouco
/// mais claro que o trilho. Antes do iOS 26, material fino com borda clara.
struct SelectionGlass: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if !active {
            content
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(Color.white.opacity(0.06)).interactive(), in: Capsule(style: .continuous))
        } else {
            content
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
    }
}

// MARK: Chip

struct Chip: View {
    let title: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .typeStyle(.label)
                .foregroundStyle(selected ? Palette.ink : Palette.inkSoft)
                .padding(.horizontal, Space.sm)
                .frame(height: Height.chip)
                .background {
                    if !selected {
                        Capsule(style: .continuous).stroke(Palette.edge, lineWidth: 1)
                    }
                }
                .modifier(SelectionGlass(active: selected))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

// MARK: Escolha exclusiva

/// O unico desenho de escolha exclusiva do app ("Imediata | Limite", "12 | 24
/// palavras"): trilho body, segmento de vidro que desliza.
///
/// O segmento e uma capsula so, que vive no trilho e anda ate a opcao escolhida.
/// Antes eram duas capsulas com `matchedGeometryEffect`, uma no fundo de cada botao,
/// inseridas e removidas a cada toque, e o estilo `.plain` apagava o rotulo tocado:
/// com o dedo em cima, o lado tocado apagava e o outro seguia aceso, e na troca a
/// capsula nova nascia no lugar da velha, do outro lado.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    private var selectedIndex: Int { options.firstIndex { $0.0 == selection } ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let (value, title) = options[index]
                Button {
                    withAnimation(Motion.select) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(index == selectedIndex ? Palette.ink : Palette.inkMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SegmentStyle())
                .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
            }
        }
        .background(alignment: .leading) {
            GeometryReader { proxy in
                let width = proxy.size.width / CGFloat(max(options.count, 1))
                Color.clear
                    .frame(width: width, height: proxy.size.height)
                    .modifier(SelectionGlass(active: true))
                    .offset(x: width * CGFloat(selectedIndex))
            }
            .accessibilityHidden(true)
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Palette.body))
        .animation(Motion.select, value: selectedIndex)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Toque sem apagar o rotulo: so um leve encolher, para o lado tocado nunca parecer
/// desmarcado enquanto o dedo esta em cima.
private struct SegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// MARK: Titulo de aba

/// O titulo de cada aba, sempre na mesma altura, para o texto nao pular ao trocar.
struct TabTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title).typeStyle(.title).foregroundStyle(Palette.ink)
            Spacer()
            trailing
        }
        .frame(height: Height.bar)
        .padding(.horizontal, Space.gutter)
    }
}

extension TabTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

// MARK: Busca

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var surface: Color = Palette.body

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.inkMuted)
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(Palette.inkMuted))
                .typeStyle(.body).foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .padding(.horizontal, Space.md)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(surface))
    }
}

// MARK: Card

struct Card<Content: View>: View {
    var surface: Color = Palette.body
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(surface)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1))
            )
    }
}

// MARK: Esqueleto

struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 12
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.badge, style: .continuous)
            .fill(Palette.body)
            .frame(width: width, height: height)
            .opacity(reduceMotion ? 0.7 : (dim ? 0.55 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: Cabecalho de folha

struct SheetHeader: View {
    let title: String
    var close: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center) {
            Text(title).typeStyle(.title).foregroundStyle(Palette.ink)
            Spacer()
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.inkSoft)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.control))
                        .frame(width: Height.touch, height: Height.touch)
                }
                .accessibilityLabel("Fechar")
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.lg)
    }
}

// MARK: Toast

@MainActor
@Observable
final class ToastCenter {
    struct Toast: Equatable, Identifiable {
        enum Kind { case success, failure, info }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    var current: Toast?
    /// A janela propria do aviso, acima de tudo, inclusive de folhas e telas cheias:
    /// desenhado na raiz, o aviso ficava atras da folha de Receber e ninguem via o
    /// "Endereco copiado".
    private var window: UIWindow?

    func show(_ text: String, kind: Toast.Kind = .success) {
        attachWindow()
        let toast = Toast(kind: kind, text: text)
        withAnimation(Motion.toastIn) { current = toast }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if current?.id == toast.id {
                withAnimation(.easeIn(duration: 0.2)) { current = nil }
            }
        }
    }
}

extension ToastCenter {
    fileprivate func attachWindow() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let host = UIHostingController(rootView: ToastLayer(center: self))
        host.view.backgroundColor = .clear
        let overlay = PassthroughWindow(windowScene: scene)
        overlay.windowLevel = .normal + 1
        overlay.rootViewController = host
        overlay.overrideUserInterfaceStyle = .dark
        overlay.isHidden = false
        window = overlay
    }
}

/// Janela que so mostra: nenhum toque para nela, tudo segue para o app embaixo.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private struct ToastLayer: View {
    let center: ToastCenter

    var body: some View {
        // No alto da tela: por cima de folhas, o rodape e onde ficam os botoes de acao.
        ZStack(alignment: .top) {
            Color.clear
            if let toast = center.current {
                ToastView(toast: toast).padding(.top, Space.xs)
            }
        }
        .ignoresSafeArea(.keyboard)
    }
}

struct ToastView: View {
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
            Text(toast.text).typeStyle(.body).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.rail)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        )
        .padding(.horizontal, Space.gutter)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var icon: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    private var color: Color {
        switch toast.kind {
        case .success: return Palette.up
        case .failure: return Palette.down
        case .info: return Palette.inkSoft
        }
    }
}

// MARK: Pontos de sigilo

/// O que aparece no lugar de um valor quando os saldos estao ocultos.
enum Redaction {
    static let fiat = "R$ ••••••"
    static let short = "••••"
}

// MARK: Faixa da barra de status

extension View {
    /// Nas abas sem barra de navegacao, o conteudo rolado passaria por baixo do
    /// relogio e da bateria. A faixa da barra de status leva o fundo da tela, chapado,
    /// e o conteudo some por baixo dela como numa barra de verdade.
    func statusBarBackdrop() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0).background(Palette.void.ignoresSafeArea(edges: .top))
        }
    }
}
