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
    /// Abre o teclado assim que o campo aparece (quem tocou para digitar uma senha).
    var focusOnAppear = false
    /// Mostra o texto enquanto e `true` (o dono segura o dedo no campo). Compartilhado
    /// entre a passphrase e a repeticao: segurar em uma mostra as duas.
    var reveal: Binding<Bool>? = nil
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
        if focusOnAppear { DispatchQueue.main.async { field.becomeFirstResponder() } }
        if reveal != nil {
            let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
            press.minimumPressDuration = 0.35
            press.cancelsTouchesInView = true
            field.addGestureRecognizer(press)
        }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        Self.show(buffer, in: field, revealed: reveal?.wrappedValue == true)
    }

    /// Pontos, ou o texto enquanto o dono segura. O texto revelado vira uma `String` so
    /// para o UIKit desenhar (e o preco de mostrar), e sai do campo assim que ele solta.
    static func show(_ buffer: SecureBytes, in field: UITextField, revealed: Bool) {
        if revealed {
            if field.isSecureTextEntry { field.isSecureTextEntry = false }
            let text = buffer.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            if field.text != text { field.text = text }
        } else {
            if !field.isSecureTextEntry { field.isSecureTextEntry = true }
            let dots = String(repeating: "•", count: buffer.count)
            if field.text != dots { field.text = dots }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SecureInputField

        init(_ parent: SecureInputField) { self.parent = parent }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // Revelado, o campo so mostra: editar no meio do texto a mostra nao existe.
            guard parent.reveal?.wrappedValue != true else { return false }
            let buffer = parent.buffer
            // O buffer so cresce no fim. Uma troca a partir de `range.location` corta dali
            // em diante e escreve o novo: selecionar tudo e digitar apaga tudo e fica so a
            // tecla nova; apagar no fim tira o ultimo. O campo mostra um ponto por byte,
            // entao a posicao na tela e a posicao no buffer.
            let keep = min(max(range.location, 0), buffer.count)
            buffer.removeLast(buffer.count - keep)
            if !string.isEmpty {
                let bytes = Array(string.utf8)
                if buffer.count + bytes.count <= buffer.capacity {
                    bytes.withUnsafeBufferPointer { buffer.append(contentsOf: $0) }
                }
            }
            field.text = String(repeating: "•", count: buffer.count)
            parent.length = buffer.count
            return false
        }

        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began: parent.reveal?.wrappedValue = true
            case .ended, .cancelled, .failed: parent.reveal?.wrappedValue = false
            default: break
            }
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
    var focusOnAppear = false
    /// Segurar o dedo no campo mostra o texto (o mesmo estado nos dois campos de uma
    /// passphrase e da repeticao dela).
    var reveal: Binding<Bool>? = nil
    var onSubmit: (() -> Void)?

    var body: some View {
        SecureInputField(buffer: buffer, length: $length, placeholder: placeholder, focusOnAppear: focusOnAppear, reveal: reveal, onSubmit: onSubmit)
            .padding(.horizontal, Space.md)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 1))
            )
    }
}
