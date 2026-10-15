import EscaliburCore
import Testing
@testable import EscaliburWallet

/// As palavras que o "Como funciona" do envelope revela sao de exemplo: todas da lista
/// BIP-39, mas sem fechar o checksum. Assim ninguem consegue abrir carteira com elas, nem
/// mandar moeda para um endereco que saia delas.
@MainActor
struct EnvelopeCipherCardTests {
    @Test func sampleWordsAreNotAPhrase() {
        let words = EnvelopeCipherCard.sample
        #expect(words.count == 12)
        let validation = Mnemonic.validate(words.joined(separator: " "))
        if case .checksumFailed(language: .english) = validation {} else {
            Issue.record("as palavras de exemplo deviam falhar so no checksum, e deu \(validation)")
        }
    }

    /// O cifrado do desenho e sempre quatro glifos da cifra viva, e troca a cada quadro.
    @Test func glyphsLookLikeTheLiveCipher() {
        let a = EnvelopeCipherCard.glyphs(0, tick: 1)
        #expect(a.count == 4)
        #expect(a.allSatisfy { LiveCipher.alphabet.contains($0) })
        #expect((1...8).contains { EnvelopeCipherCard.glyphs(0, tick: $0 + 1) != a })
    }

    /// Uma palavra nao repete a vizinha deslocada de uma casa: entregaria o sorteio. Por
    /// acaso, tres glifos iguais saem 1 vez em 4096; com o defeito, saiam todas.
    @Test func neighboursAreNotShiftedCopies() {
        var shifted = 0
        for tick in UInt64(0)..<50 {
            for i in 0..<11 where EnvelopeCipherCard.glyphs(i, tick: tick).dropFirst() == EnvelopeCipherCard.glyphs(i + 1, tick: tick).dropLast() {
                shifted += 1
            }
        }
        #expect(shifted <= 3)
    }
}
