import SwiftUI

/// Ajustes, Seguranca, Teclado proprio (pedido do dono, 16/10/2026): opcional, desligado
/// por padrao, e sempre ligado no modo reforcado. No topo, o teclado digitando sozinho
/// mostra o que muda: so as letras da lista acendem, a tecla nao mostra balao, e a
/// palavra entra cifrada.
struct OwnKeyboardView: View {
    @Environment(AppSession.self) private var session
    @State private var error: String?

    private var on: Bool { session.ownKeyboardOn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // O titulo e o interruptor em cima, a animacao embaixo, e os idiomas logo abaixo
                // dela (pedido do dono, 16/10/2026).
                Text("Safe Keyboard").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.sm)
                Text("As palavras da carteira digitadas num teclado desenhado pela Escalibur, no lugar do teclado do iPhone.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: Binding(get: { on }, set: { set($0) })) {
                    Text("Usar o Safe Keyboard").typeStyle(.body).foregroundStyle(Palette.ink)
                }
                .tint(Palette.success)
                .disabled(session.hardenedModeOn)
                .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                .accessibilityIdentifier("teclado-proprio")
                .padding(.top, Space.lg)
                if let note = error ?? (session.hardenedModeOn ? String(localized: "No Super Security, o Safe Keyboard fica sempre ligado.") : nil) {
                    Text(note)
                        .typeStyle(.note).foregroundStyle(error == nil ? Palette.inkMuted : Palette.down)
                        .padding(.top, Space.xs)
                        .fixedSize(horizontal: false, vertical: true)
                }

                KeyboardDemo()
                    .padding(.top, Space.lg)
                Text("Ele escreve as palavras em inglês, português, espanhol, francês, italiano e tcheco. Para japonês, chinês ou coreano, o globo do teclado traz o do iPhone.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
                // Pedido do dono (16/10/2026): menos itens, e o que tranquiliza, dito sem rodeio.
                VStack(alignment: .leading, spacing: Space.md) {
                    point("eye.slash", String(localized: "O teclado do iPhone não recebe as letras"),
                          String(localized: "Sem previsão, ditado nem palavra aprendida no dicionário do aparelho. E as palavras nunca saem do iPhone."))
                    point("wifi.slash", String(localized: "Sem internet"),
                          String(localized: "O teclado não tem conexão nenhuma, e a tela das palavras fica sem internet enquanto está aberta."))
                }
                .padding(Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                .padding(.top, Space.lg)

            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.lg)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func set(_ value: Bool) {
        let previous = session.metadata.settings.ownKeyboard
        session.metadata.settings.ownKeyboard = value
        do {
            try session.persist()
            error = nil
        } catch {
            session.metadata.settings.ownKeyboard = previous
            self.error = String(localized: "Não foi possível salvar. Tente de novo.")
        }
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.control))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                Text(detail).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// O teclado proprio digitando sozinho, em escala: a tecla escurece sem balao, as letras
/// que nao formam palavra apagam, o campo mostra a palavra cifrada, e no fim a sugestao
/// fecha a palavra. Palavras da lista em ingles, nunca uma frase de verdade.
struct KeyboardDemo: View {
    /// O fundo do cartao: o da tela por baixo pede outro tom (a folha ja e `body`).
    var surface = Palette.body
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Com o globo, como na tela de digitar as palavras.
    @State private var model: WordKeyboardModel = {
        let model = WordKeyboardModel()
        model.offersSystemKeyboard = true
        return model
    }()
    @State private var letters = 0
    @State private var word = 0
    @State private var sealed = false

    private static let words = ["abandon", "zebra", "orbit"]
    private let scale: CGFloat = 0.84

    var body: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text(String(format: "%02d", word + 1))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.inkSoft)
                TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate * 12)
                    Text(verbatim: glyphs(sealed ? 4 : letters, tick: reduceMotion ? 0 : tick))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !sealed, letters > 0 {
                    Text(Self.words[word]).typeStyle(.label).foregroundStyle(Palette.ink)
                        .padding(.horizontal, Space.sm).frame(height: 28)
                        .background(Capsule().fill(Palette.control))
                        .transition(.opacity)
                }
            }
            // Sem contorno: com ele, o campo da animacao parecia algo para tocar.
            .padding(.horizontal, Space.md)
            .frame(height: 44)

            GeometryReader { geo in
                WordKeyboardView(model: model, demo: true)
                    .frame(width: geo.size.width / scale)
                    .scaleEffect(scale, anchor: .topLeading)
            }
            .frame(height: WordKeyboardView.height * scale)
            .allowsHitTesting(false)
        }
        .padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(surface))
        .accessibilityElement()
        .accessibilityLabel("Animação: o Safe Keyboard digitando uma palavra da lista")
        .task {
            guard !reduceMotion else {
                model.typed = "aban"
                letters = 4
                return
            }
            while !Task.isCancelled {
                for (index, text) in Self.words.enumerated() {
                    word = index
                    sealed = false
                    letters = 0
                    model.typed = ""
                    try? await Task.sleep(for: .milliseconds(700))
                    // Ate a palavra ser a unica da lista com esse comeco, como quem digita de verdade.
                    let stop = min(text.count, max(4, text.count - 2))
                    for letter in text.prefix(stop) {
                        model.pressed = letter
                        try? await Task.sleep(for: .milliseconds(170))
                        model.pressed = nil
                        model.typed.append(letter)
                        withAnimation(.easeOut(duration: 0.15)) { letters += 1 }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { sealed = true }
                    model.typed = ""
                    try? await Task.sleep(for: .milliseconds(1100))
                    if Task.isCancelled { return }
                }
            }
        }
    }

    /// Glifos que trocam a cada tique, como a cifra viva da tela de importar.
    private func glyphs(_ count: Int, tick: Int) -> String {
        guard count > 0 else { return "palavra" }
        let alphabet = Array("0123456789ABCDEF")
        return String((0..<count).map { alphabet[Int(PixelFill.noise($0, word, tick) * 16) % 16] })
    }
}

/// O toque em "Safe Keyboard", na tela de digitar as palavras: o que o teclado e,
/// com a animacao, e o botao de desligar. No modo reforcado ele nao desliga; o botao
/// troca para o teclado do iPhone so nesta tela.
struct KeyboardInfoSheet: View {
    @Environment(AppSession.self) private var session
    let onSystemKeyboard: () -> Void
    let onClose: () -> Void
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                KeyboardDemo(surface: Palette.void).padding(.top, Space.md)
                Text("Safe Keyboard").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.lg)
                Text("Feito para a segurança das palavras: desenhado pelo próprio app, no lugar do teclado do iPhone.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Space.md) {
                    point("wifi.slash", String(localized: "Sem conexão com a internet"),
                          String(localized: "O teclado não fala com rede nenhuma, e esta tela inteira fica sem internet enquanto está aberta."))
                    point("eye.slash", String(localized: "O teclado do iPhone não recebe as letras"),
                          String(localized: "Nada de previsão, ditado ou palavra aprendida. E as palavras nunca saem do iPhone."))
                    point("lock.fill", String(localized: "Cifrado na tela"),
                          String(localized: "Na tela, cada letra vira um símbolo que muda. Nada é gravado no iPhone."))
                    Text("As sugestões e as teclas acesas mostram a palavra: digite longe de olhos e câmeras.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
                .padding(.top, Space.lg)
                if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.md)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.sm) {
                PrimaryButton(title: String(localized: "Continuar digitando")) { onClose() }
                if session.hardenedModeOn {
                    SecondaryButton(title: String(localized: "Usar o teclado do iPhone nesta tela")) {
                        onSystemKeyboard()
                        onClose()
                    }
                    Text("No Super Security, o Safe Keyboard volta na próxima vez.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                } else {
                    SecondaryButton(title: String(localized: "Desativar o Safe Keyboard")) { disable() }
                        .accessibilityIdentifier("teclado-desativar")
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xs)
            .background(Palette.body)
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
    }

    private func disable() {
        let previous = session.metadata.settings.ownKeyboard
        session.metadata.settings.ownKeyboard = false
        do {
            try session.persist()
            onClose()
        } catch {
            session.metadata.settings.ownKeyboard = previous
            self.error = String(localized: "Não foi possível salvar. Tente de novo.")
        }
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.control))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                Text(detail).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
