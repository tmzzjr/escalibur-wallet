import Foundation
import Testing
@testable import EscaliburCore

/// O medidor da senha do envelope, no modelo do zxcvbn: o que o atacante testa primeiro
/// (listas, repeticoes, sequencias, datas) custa pouco, e so o resto vai por forca bruta.
@Suite("Forca da senha do envelope")
struct PasswordStrengthTests {
    func secure(_ text: String) -> SecureBytes {
        let bytes = SecureBytes(capacity: max(text.utf8.count, 1))
        bytes.replaceAll(with: Array(text.utf8))
        return bytes
    }

    func bits(_ text: String) -> Double { PasswordStrength.bits(secure(text)) }

    @Test("Os buracos do medidor antigo (auditoria de 14/10/2026) agora dao fraco")
    func oldHoles() {
        // O antigo dava 66, 60, 63 e 72 bits a estas.
        #expect(bits("abandon abandon abandon abandon abandon abandon") < 20)
        #expect(bits("!!!!!!!!!!!!") < 12)
        #expect(bits("cavalo correto bateria grampo") < 50)
        #expect(bits("minha casa tem um gato") < 35)
    }

    @Test("Padroes comuns custam pouco")
    func patterns() {
        #expect(bits("123456") < 2)
        #expect(bits("qwerty123") < 12)
        #expect(bits("Bitcoin2024!") < 30)
        #expect(bits("Senha@24") < 30)
        #expect(bits("s3nh@forte") < 30)
        #expect(bits("joao1990") < 15)
        #expect(bits("01/02/1990") < 35)
        #expect(bits("correcthorsebatterystaple") < 55)
    }

    @Test("Seis palavras sorteadas e caracteres aleatorios longos passam; cinco palavras nao")
    func verdicts() {
        #expect(PasswordStrength.verdict(secure("crane violin orbit maple harbor tunnel")) == .strong)
        #expect(bits("Crane Violin Orbit Maple Harbor Tunnel") > bits("crane violin orbit maple harbor tunnel"))
        #expect(PasswordStrength.verdict(secure("k7#Qp!2vZr@9mW")) == .strong)
        if case .weak = PasswordStrength.verdict(secure("crane violin orbit maple harbor")) {} else { Issue.record("5 palavras passaram") }
        #expect(PasswordStrength.verdict(secure("abc")) == .tooShort)
        #expect(PasswordStrength.verdict(secure("")) == .tooShort)
        if case .digitsOnly = PasswordStrength.verdict(secure("4821")) {} else { Issue.record("PIN nao foi marcado") }
        #expect(PasswordStrength.suggestionBits() == 66)
    }

    @Test("Caracteres contados como escalares, nao bytes")
    func length() {
        #expect(PasswordStrength.scalarCount(secure("ação")) == 4)
        #expect(PasswordStrength.scalarCount(secure("abcd")) == 4)
        #expect(PasswordStrength.verdict(secure("açã")) == .tooShort)
    }

    /// A tela mede fora da thread principal e depois da ultima tecla; isto e so a guarda
    /// contra o medidor ficar ordens de grandeza mais lento.
    @Test("Rapido o bastante para a tela")
    func speed() {
        PasswordStrength.preload()
        let long = secure("Correct-Horse-Battery-Staple 1987! minha frase bem comprida e boba 42")
        let start = Date()
        for _ in 0..<5 { _ = PasswordStrength.bits(long) }
        #expect(Date().timeIntervalSince(start) / 5 < 1.0)
    }

    @Test("Sugestao: seis palavras distintas, nenhuma da frase da carteira, escritas direto no buffer")
    func suggestion() throws {
        let phrase = secure("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        let list = try WordlistStore.shared.wordlist(for: .english)
        for _ in 0..<50 {
            let indices = try PasswordStrength.suggestionIndices(avoiding: phrase)
            #expect(indices.count == 6 && Set(indices).count == 6)
            let words = indices.map { list.words[$0] }
            #expect(!words.contains("abandon") && !words.contains("about"))
            let buffer = SecureBytes(capacity: 128)
            try PasswordStrength.write(indices, into: buffer)
            #expect(buffer.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == words.joined(separator: " "))
        }
    }

    @Test("Reusar duas palavras da frase e recusado")
    func reuse() {
        let phrase = secure("legal winner thank year wave sausage worth useful legal winner thank yellow")
        #expect(PasswordStrength.reusesPhrase(secure("Legal-Winner 2024 casa"), phrase: phrase))
        #expect(!PasswordStrength.reusesPhrase(secure("legal crane violin"), phrase: phrase))
    }
}
