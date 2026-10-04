import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Testing
@testable import EscaliburWallet

/// Importar sem a tela: as palavras entram no PhraseEntry como a tela poe, e a carteira
/// tem de sair montada e com a previa dos enderecos.
@MainActor
struct ImportPipelineTests {
    @Test func typedWordsBecomeAWallet() async throws {
        let entry = PhraseEntry()
        for index in 0..<11 { entry.set("abandon", at: index) }
        entry.set("about", at: 11)
        let phrase = entry.phrase()
        guard case .valid(let language) = BIP39.validate(phrase) else { Issue.record("frase invalida"); return }
        let secret = try WalletSecret.from(phrase: phrase, language: language, passphrase: SecureBytes(capacity: 256))
        phrase.wipe()
        #expect(secret.entropy.count == 16, "entropia com \(secret.entropy.count) bytes")
        let preview = try await ImportPreview.make(secret)
        #expect(preview.addresses.first?.1 == "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
    }
}
