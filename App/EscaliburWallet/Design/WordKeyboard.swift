import EscaliburCore
import SwiftUI
import UIKit

/// O que o teclado proprio sabe e faz: o que esta digitado na posicao, e o que cada tecla
/// manda para o campo.
@MainActor
@Observable
final class WordKeyboardModel {
    /// Fora da observacao: o campo escreve aqui a cada desenho, e um valor observado
    /// regravado no `updateUIView` redesenhava o campo sem parar.
    @ObservationIgnored var typed = "" { didSet { if typed != oldValue { refresh() } } }
    /// Os idiomas das palavras ja fechadas (`WordLexicon.languages`): as sugestoes deles vem
    /// primeiro. As letras acesas sao sempre as de todas as listas latinas: uma primeira
    /// palavra no idioma errado nao apaga letra nenhuma das seguintes (segunda revisao, N1).
    @ObservationIgnored var languages: Set<BIP39Language>? { didSet { if languages != oldValue { refresh() } } }
    private(set) var allowed: Set<Character> = []
    private(set) var canSubmit = false
    /// So na animacao dos Ajustes: a tecla que aparece apertada.
    var pressed: Character?

    /// O globo aparece so onde a tela oferece o teclado do iPhone.
    var offersSystemKeyboard = false
    /// "Safe Keyboard" vira um toque so onde a tela sabe abrir a explicacao.
    var offersInfo = false

    @ObservationIgnored var insert: (Character) -> Void = { _ in }
    @ObservationIgnored var delete: () -> Void = {}
    @ObservationIgnored var clear: () -> Void = {}
    @ObservationIgnored var submit: () -> Void = {}
    @ObservationIgnored var systemKeyboard: () -> Void = {}
    @ObservationIgnored var info: () -> Void = {}

    init() { refresh() }

    private func refresh() {
        let letters = WordLexicon.nextLetters(after: typed)
        if letters != allowed { allowed = letters }
        let submit = !typed.isEmpty && !WordLexicon.completions(typed, preferring: languages, limit: 1).isEmpty
        if submit != canSubmit { canSubmit = submit }
    }
}

/// O teclado proprio das palavras (pedido do dono, 16/10/2026; auditoria 4, C7-12). O
/// teclado do iPhone ve cada letra: sugere, aprende palavras para o dicionario do aparelho
/// e mostra o balao da tecla. Este e desenhado pelo proprio app, dentro do processo dele:
/// as letras vao direto para o campo, sem previsao, sem ditado, sem aprendizado e sem
/// balao. So acendem as letras que ainda formam uma palavra da lista, entao um erro de
/// digitacao nem entra. O do iPhone fica a um toque, para as frases em japones, chines ou
/// coreano, que este nao escreve.
struct WordKeyboardView: View {
    let model: WordKeyboardModel
    /// Na animacao dos Ajustes: nada responde ao toque.
    var demo = false

    private static let rows: [[Character]] = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
    static let keyHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 10
    static let height: CGFloat = keyHeight * 4 + rowSpacing * 3 + 8 + 6

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 6
            let unit = (geo.size.width - 6 - spacing * 9) / 10
            VStack(spacing: Self.rowSpacing) {
                HStack(spacing: spacing) { ForEach(Self.rows[0], id: \.self) { letter($0, width: unit) } }
                HStack(spacing: spacing) { ForEach(Self.rows[1], id: \.self) { letter($0, width: unit) } }
                HStack(spacing: spacing) {
                    Color.clear.frame(width: unit * 1.4, height: Self.keyHeight)
                    Spacer(minLength: 0)
                    ForEach(Self.rows[2], id: \.self) { letter($0, width: unit) }
                    Spacer(minLength: 0)
                    key(width: unit * 1.4, enabled: !model.typed.isEmpty, label: "Apagar", identifier: "teclado-apagar") {
                        model.delete()
                    } content: {
                        Image(systemName: "delete.left").font(.system(size: 18, weight: .medium))
                    }
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in if !demo { model.clear() } })
                }
                HStack(spacing: spacing) {
                    // O globo e o Seguinte com a mesma largura: o nome do teclado fica no centro.
                    if model.offersSystemKeyboard {
                        key(width: unit * 2.5, enabled: true, label: String(localized: "Usar o teclado do iPhone"), identifier: "teclado-sistema") {
                            model.systemKeyboard()
                        } content: {
                            Image(systemName: "globe").font(.system(size: 18, weight: .medium))
                        }
                    } else {
                        Color.clear.frame(width: unit * 2.5, height: Self.keyHeight)
                    }
                    // O nome do teclado abre a explicacao dele (pedido do dono, 16/10/2026).
                    Button { if !demo { model.info() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                            Text("Safe Keyboard").typeStyle(.note)
                            if model.offersInfo {
                                Image(systemName: "info.circle").font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .foregroundStyle(Palette.inkMuted)
                        .frame(maxWidth: .infinity, minHeight: Self.keyHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.offersInfo || demo)
                    .accessibilityLabel(Text("Sobre o Safe Keyboard"))
                    .accessibilityIdentifier("teclado-sobre")
                    key(width: unit * 2.5, enabled: model.canSubmit, label: String(localized: "Seguinte"), identifier: "teclado-seguinte", strong: true) {
                        model.submit()
                    } content: {
                        Text("Seguinte").typeStyle(.action)
                    }
                }
            }
            .padding(.horizontal, 3)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .frame(height: Self.height)
        .background(Palette.body)
    }

    private func letter(_ character: Character, width: CGFloat) -> some View {
        let enabled = model.allowed.contains(character)
        return key(width: width, enabled: enabled, label: String(character), identifier: "teclado-\(character)", pressed: model.pressed == character) {
            model.insert(character)
        } content: {
            Text(String(character)).font(.system(size: 22, weight: .regular))
        }
    }

    private func key(width: CGFloat, enabled: Bool, label: String, identifier: String, strong: Bool = false, pressed: Bool = false,
                     action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button {
            guard !demo else { return }
            UIDevice.current.playInputClick()
            action()
        } label: {
            content()
                .foregroundStyle(enabled ? (strong ? Palette.onLive : Palette.ink) : Palette.inkDead)
                .frame(width: width, height: Self.keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyStyle(fill: strong && enabled ? Palette.live : (enabled ? Palette.control : Palette.rail),
                              pressedFill: strong ? Palette.livePress : Palette.edgeStrong, forced: pressed))
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// A tecla apertada so muda de tom: nada de balao com a letra em cima, que uma gravacao
/// ou quem olha por cima do ombro leria.
private struct KeyStyle: ButtonStyle {
    let fill: Color
    let pressedFill: Color
    var forced = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isPressed || forced ? pressedFill : fill))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed || forced)
    }
}

/// O teclado proprio como `inputView` do campo: o iOS o sobe no lugar do dele, e nenhum
/// teclado do sistema chega a ver o campo. Os cliques soam como os do teclado do iPhone.
final class WordKeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    private let host: UIHostingController<WordKeyboardView>
    /// As teclas acesas e a tecla apertada dizem a palavra: o teclado fica na camada que sai
    /// em branco na captura e na gravacao, como as palavras (`SecureCanvas`). Ele e desenhado
    /// pelo app, numa janela do app, e por isso a camada vale nele; o do iPhone, nao.
    private let secure: SecureCanvas?

    var enableInputClicksWhenVisible: Bool { true }

    @MainActor
    init(model: WordKeyboardModel) {
        host = UIHostingController(rootView: WordKeyboardView(model: model))
        secure = SecureCanvas()
        // Ja nasce com a altura de verdade, contando a faixa de baixo do iPhone: nascendo com
        // so a das teclas, a tela posicionava as sugestoes por essa altura e o teclado, ao
        // crescer, cortava a parte de baixo delas (pedido do dono, 16/10/2026).
        let bottom = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.bottom ?? 0
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: WordKeyboardView.height + bottom), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = UIColor(Palette.body)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        if let canvas = secure?.view {
            canvas.translatesAutoresizingMaskIntoConstraints = false
            addSubview(canvas)
            NSLayoutConstraint.activate([
                canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
                canvas.topAnchor.constraint(equalTo: topAnchor),
                canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        (secure?.view ?? self).addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: WordKeyboardView.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
