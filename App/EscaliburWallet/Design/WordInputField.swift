import EscaliburCore
import SwiftUI
import UIKit

/// Campo para digitar uma palavra da senha da carteira.
///
/// O `TextField` do SwiftUI nao desliga tudo que o teclado faz por conta propria:
/// previsao em linha, aspas e travessoes inteligentes, correcao ortografica e as
/// ferramentas de escrita continuam ligadas, e o que o teclado aprende fica no
/// dicionario do aparelho. Aqui cada uma e desligada no `UITextField`, como no campo
/// de senha (`SecureInputField`), mas com o texto visivel, porque o dono precisa ver
/// a palavra que digitou.
///
/// Com `ownKeyboard`, o teclado e o do proprio app (`WordKeyboardView`): o do iPhone nao
/// sobe, e nenhuma letra passa por ele.
struct WordInputField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String = ""
    var fontSize: CGFloat = 20
    var returnKey: UIReturnKeyType = .done
    /// O texto fica invisivel (so o cursor aparece): quem usa desenha por cima a forma
    /// cifrada (`LiveCipher`).
    var masked = false
    /// O teclado proprio no lugar do do iPhone.
    var ownKeyboard = false
    /// A tecla do globo do teclado proprio: a tela volta para o teclado do iPhone.
    var onSystemKeyboard: (() -> Void)?
    /// O toque em "Safe Keyboard": a tela abre a explicacao do teclado.
    var onKeyboardInfo: (() -> Void)?
    /// Os idiomas das palavras ja fechadas, para o teclado proprio sugerir os deles primeiro.
    var languages: Set<BIP39Language>? = nil
    /// O teclado do iPhone: so letras latinas, ou todos (o globo, para frases em japones,
    /// chines ou coreano, que o `.asciiCapable` esconde; segunda revisao, N4).
    var systemKeyboardType: UIKeyboardType = .asciiCapable
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = WordTextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.textContentType = nil
        field.keyboardType = .asciiCapable
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        if #available(iOS 18.0, *) { field.writingToolsBehavior = .none }
        field.keyboardAppearance = .dark
        field.returnKeyType = returnKey
        field.textColor = UIColor(Palette.ink)
        field.tintColor = UIColor(Palette.ink)
        field.font = .monospacedSystemFont(ofSize: fontSize, weight: .medium)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        context.coordinator.applyKeyboard(to: field, own: ownKeyboard)
        field.textColor = masked ? .clear : UIColor(Palette.ink)
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(Palette.inkDead)])
        // Desligado (a guarda de captura desliga a tela): nada de foco nem de teclado.
        field.isEnabled = context.environment.isEnabled
        if !field.isEnabled {
            if field.isFirstResponder { field.resignFirstResponder() }
        } else if isFocused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            // Dois saltos: quando o foco passa para outro campo na mesma atualizacao, o
            // outro assume primeiro e este ja nao e o primeiro respondedor. O teclado
            // nao desce e sobe entre uma palavra e a seguinte.
            DispatchQueue.main.async {
                DispatchQueue.main.async { if field.isFirstResponder { field.resignFirstResponder() } }
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: WordInputField

        /// O teclado proprio deste campo, montado na primeira vez que ele e pedido.
        private var keyboard: WordKeyboardInputView?
        private let model = WordKeyboardModel()

        init(_ parent: WordInputField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
            model.typed = field.text ?? ""
        }

        @MainActor
        func applyKeyboard(to field: UITextField, own: Bool) {
            model.typed = field.text ?? ""
            if model.languages != parent.languages { model.languages = parent.languages }
            (field as? WordTextField)?.ownKeyboard = own
            if field.keyboardType != parent.systemKeyboardType {
                field.keyboardType = parent.systemKeyboardType
                if field.isFirstResponder, !own { field.reloadInputViews() }
            }
            let offers = parent.onSystemKeyboard != nil
            if model.offersSystemKeyboard != offers { model.offersSystemKeyboard = offers }
            model.systemKeyboard = { [weak self] in self?.parent.onSystemKeyboard?() }
            let informs = parent.onKeyboardInfo != nil
            if model.offersInfo != informs { model.offersInfo = informs }
            model.info = { [weak self] in self?.parent.onKeyboardInfo?() }
            let showing = field.inputView != nil
            guard own != showing else { return }
            if own {
                if keyboard == nil {
                    model.insert = { [weak field] letter in field?.insertText(String(letter)) }
                    model.delete = { [weak field] in field?.deleteBackward() }
                    model.clear = { [weak self, weak field] in
                        guard let field else { return }
                        field.text = ""
                        self?.changed(field)
                    }
                    model.submit = { [weak self] in self?.parent.onSubmit() }
                    keyboard = WordKeyboardInputView(model: model)
                }
                field.inputView = keyboard
            } else {
                field.inputView = nil
            }
            if field.isFirstResponder { field.reloadInputViews() }
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        /// Ditado recusado quando o iOS informa o modo ditado: a voz pode ir para os servidores
        /// da Apple (conferir no aparelho, segunda revisao, N3). Com o teclado proprio,
        /// so entra uma letra que ainda forma palavra, venha de onde vier (o teclado fisico
        /// e o do Mac no Espelhamento tambem): revisao do teclado proprio, B2.
        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if field.textInputMode?.primaryLanguage == "dictation" { return false }
            guard parent.ownKeyboard, !string.isEmpty else { return true }
            guard string.count == 1, let letter = string.lowercased().first else { return false }
            return model.allowed.contains(letter)
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

/// O campo da palavra: com o teclado proprio, o menu dele nao cola, nem le texto pela
/// camera, que entrariam sem passar pelo filtro das letras. O Colar da tela (o PasteButton)
/// continua sendo o caminho de colar a frase.
final class WordTextField: UITextField {
    var ownKeyboard = false

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if ownKeyboard, [#selector(paste(_:)), #selector(pasteAndMatchStyle(_:)), #selector(captureTextFromCamera(_:))].contains(action) {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
