import Testing
@testable import EscaliburCore

@Suite("Forca da senha do envelope")
struct PasswordStrengthTests {
    func secure(_ text: String) -> SecureBytes {
        let bytes = SecureBytes(capacity: max(text.utf8.count, 1))
        bytes.replaceAll(with: Array(text.utf8))
        return bytes
    }

    @Test("Seis palavras sorteadas passam; padroes comuns nao")
    func verdicts() {
        #expect(PasswordStrength.verdict(secure("crane violin orbit maple harbor tunnel")) == .strong)
        #expect(PasswordStrength.bits(secure("Crane Violin Orbit Maple Harbor Tunnel")) == 66)
        #expect(PasswordStrength.verdict(secure("12345678")) == .digitsOnly)
        if case .weak = PasswordStrength.verdict(secure("Bitcoin2024!")) {} else { Issue.record("Bitcoin2024! passou") }
        if case .weak = PasswordStrength.verdict(secure("crane violin orbit maple harbor")) {} else { Issue.record("5 palavras passaram") }
        #expect(PasswordStrength.verdict(secure("k7#Qp!2vZr@9mW")) == .strong)
        #expect(PasswordStrength.bits(secure("")) == 0)
    }

    @Test("Sugestao: seis palavras distintas, nenhuma da frase da carteira")
    func suggestion() throws {
        let phrase = secure("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        for _ in 0..<50 {
            let words = try PasswordStrength.suggestion(avoiding: phrase)
            #expect(words.count == 6)
            #expect(Set(words).count == 6)
            #expect(!words.contains("abandon") && !words.contains("about"))
        }
    }

    @Test("Reusar duas palavras da frase e recusado")
    func reuse() {
        let phrase = secure("legal winner thank year wave sausage worth useful legal winner thank yellow")
        #expect(PasswordStrength.reusesPhrase(secure("Legal-Winner 2024 casa"), phrase: phrase))
        #expect(!PasswordStrength.reusesPhrase(secure("legal crane violin"), phrase: phrase))
    }
}
