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
    /// Esconde os pontos (o cursor continua): a cifra viva e desenhada por cima.
    var concealed = false
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
        let revealed = reveal?.wrappedValue == true
        field.textColor = concealed && !revealed ? .clear : UIColor(Palette.ink)
        Self.show(buffer, in: field, revealed: revealed)
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
            let dots = String(repeating: "•", count: scalarCount(buffer))
            if field.text != dots { field.text = dots }
        }
    }

    /// Quantos caracteres (escalares Unicode) o buffer tem, contados pelos bytes que nao
    /// continuam um anterior (UTF-8: 10xxxxxx continua). Um ponto por caractere, e nao por
    /// byte: com um ponto por byte, o apagar tirava so o ultimo byte de "ç" e deixava o
    /// primeiro solto, um caractere invalido na senha (auditoria 4, C7-15).
    static func scalarCount(_ buffer: SecureBytes) -> Int {
        buffer.withUnsafeBytes { raw in raw.reduce(0) { $1 & 0xC0 == 0x80 ? $0 : $0 + 1 } }
    }

    /// Onde comeca o caractere numero `scalars` (ou o fim), em bytes.
    static func byteOffset(_ buffer: SecureBytes, scalars: Int) -> Int {
        buffer.withUnsafeBytes { raw in
            var seen = 0
            for (offset, byte) in raw.enumerated() where byte & 0xC0 != 0x80 {
                if seen == scalars { return offset }
                seen += 1
            }
            return raw.count
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
            // tecla nova; apagar no fim tira o ultimo caractere inteiro. O campo mostra um
            // ponto por caractere, entao a posicao na tela e o numero de caracteres.
            let keep = SecureInputField.byteOffset(buffer, scalars: max(range.location, 0))
            buffer.removeLast(buffer.count - keep)
            if !string.isEmpty {
                let bytes = Array(string.utf8)
                if buffer.count + bytes.count <= buffer.capacity {
                    bytes.withUnsafeBufferPointer { buffer.append(contentsOf: $0) }
                }
            }
            field.text = String(repeating: "•", count: SecureInputField.scalarCount(buffer))
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
    /// A cifra viva do que foi digitado (`LiveCipher`), no lugar dos pontos: os glifos
    /// trocam num relogio de 12 Hz, como os das palavras.
    var glyphs: ((UInt64) -> String)? = nil

    var body: some View {
        let ciphered = glyphs != nil && length > 0 && reveal?.wrappedValue != true
        SecureInputField(buffer: buffer, length: $length, placeholder: placeholder, focusOnAppear: focusOnAppear, reveal: reveal,
                         concealed: ciphered, onSubmit: onSubmit)
            .overlay(alignment: .leading) {
                if ciphered, let glyphs {
                    TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
                        Text(verbatim: glyphs(UInt64(context.date.timeIntervalSinceReferenceDate * 12)))
                            .font(.system(size: 17, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.inkSoft)
                            .lineLimit(1)
                    }
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, Space.md)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 1))
            )
    }
}
