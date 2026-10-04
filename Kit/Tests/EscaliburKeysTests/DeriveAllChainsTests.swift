import EscaliburChains
import EscaliburCore
import Testing
@testable import EscaliburKeys

/// Importar deriva todas as redes de uma vez: uma rede que recuse uma frase valida
/// derruba a importacao inteira. Frases sorteadas de todos os tamanhos, com e sem
/// passphrase, precisam derivar em todas.
@Suite("Derivacao em todas as redes")
struct DeriveAllChainsTests {
    @Test("Frases sorteadas de 12 a 24 palavras, com e sem passphrase, derivam todas as redes", arguments: Mnemonic.validWordCounts)
    func randomPhrases(words: Int) throws {
        for round in 0..<10 {
            let passphrase = SecureBytes(capacity: 32)
            if round % 2 == 1 { passphrase.replaceAll(with: Array("lanterna \(round)".utf8)) }
            let secret = try WalletSecret.from(phrase: BIP39.generate(wordCount: words), language: .english, passphrase: passphrase)
            defer { secret.wipe() }
            do {
                let (accounts, _) = try AccountDeriver.derive(secret)
                #expect(Set(accounts.map(\.chainID)) == Set(Chain.all.map(\.id)), "faltou rede com \(words) palavras")
            } catch {
                Issue.record("\(words) palavras, rodada \(round): \(error)")
            }
        }
    }
}
