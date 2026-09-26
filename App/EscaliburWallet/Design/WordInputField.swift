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
struct WordInputField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String = ""
    var fontSize: CGFloat = 20
    var returnKey: UIReturnKeyType = .done
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
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
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(Palette.inkDead)])
        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: WordInputField

        init(_ parent: WordInputField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
