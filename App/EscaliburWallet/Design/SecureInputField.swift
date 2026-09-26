import EscaliburCore
import SwiftUI
import UIKit

/// Campo de senha que escreve direto num buffer seguro.
///
/// O `SecureField` do SwiftUI guarda o texto numa `String`, que cresce realocando e
/// deixa no heap cada prefixo digitado ("c", "co", "cor"...). Aqui o `UITextField`
/// nunca guarda o texto: cada tecla vira bytes no `SecureBytes` e o campo mostra so
/// pontos. Teclado do sistema forcado (teclados de terceiros ja estao bloqueados no
/// app), sem correcao, sem sugestao, sem ferramentas de escrita.
struct SecureInputField: UIViewRepresentable {
    let buffer: SecureBytes
    @Binding var length: Int
    var placeholder: String = ""
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.isSecureTextEntry = true
        field.textContentType = nil
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        if #available(iOS 18.0, *) { field.writingToolsBehavior = .none }
        field.keyboardAppearance = .dark
        field.returnKeyType = .done
        field.textColor = UIColor(Palette.ink)
        field.tintColor = UIColor(Palette.ink)
        field.font = .systemFont(ofSize: 20, weight: .medium)
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(Palette.inkDead)])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        let display = String(repeating: "•", count: buffer.count)
        if field.text != display { field.text = display }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SecureInputField

        init(_ parent: SecureInputField) { self.parent = parent }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let buffer = parent.buffer
            if string.isEmpty {
                // Apagar: so do fim, que e onde o cursor de um campo cifrado fica.
                buffer.removeLast(max(range.length, 1))
            } else {
                let bytes = Array(string.utf8)
                if buffer.count + bytes.count <= buffer.capacity {
                    bytes.withUnsafeBufferPointer { buffer.append(contentsOf: $0) }
                }
            }
            field.text = String(repeating: "•", count: buffer.count)
            parent.length = buffer.count
            return false
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit?()
            return true
        }
    }
}

/// O campo de senha com moldura, no padrao de campo do app.
struct PasswordBox: View {
    let buffer: SecureBytes
    @Binding var length: Int
    var placeholder: String
    var onSubmit: (() -> Void)?

    var body: some View {
        SecureInputField(buffer: buffer, length: $length, placeholder: placeholder, onSubmit: onSubmit)
            .padding(.horizontal, Space.md)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 1))
            )
    }
}
