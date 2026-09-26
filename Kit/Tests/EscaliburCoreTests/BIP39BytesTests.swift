import Testing
@testable import EscaliburCore

@Suite("BIP-39 sobre os bytes")
struct BIP39BytesTests {
    func secure(_ text: String) -> SecureBytes {
        let bytes = SecureBytes(capacity: max(text.utf8.count, 1))
        bytes.replaceAll(with: Array(text.utf8))
        return bytes
    }

    @Test("Validar pelos bytes da o mesmo veredito do validador do Escalibur, nos dez idiomas")
    func sameVerdict() throws {
        for language in BIP39Language.allCases {
            for count in [12, 24] {
                let phrase = try Mnemonic.generate(wordCount: count, language: language)
                let canonical = Mnemonic.canonicalize(phrase)
                #expect(BIP39.validate(secure(canonical)) == Mnemonic.validate(phrase), "\(language) \(count)")
                #expect(BIP39.closingLanguage(secure(canonical), store: .shared) != nil || Mnemonic.validate(phrase) != .valid(language: language))

                // Troca a ultima palavra: checksum que nao fecha, ou palavra fora.
                var words = canonical.split(separator: " ").map(String.init)
                let list = try WordlistStore.shared.wordlist(for: language)
                words[words.count - 1] = list.words[(Int(list.position(of: words.last!) ?? 0) + 1) % 2048]
                let broken = words.joined(separator: " ")
                #expect(BIP39.validate(secure(broken)) == Mnemonic.validate(broken), "\(language) quebrada")

                // Tamanho errado e forma nao canonica.
                let short = words.dropLast().joined(separator: " ")
                #expect(BIP39.validate(secure(short)) == Mnemonic.validate(short))
                let messy = "  " + canonical.uppercased().replacingOccurrences(of: " ", with: "   ") + " "
                #expect(BIP39.validate(secure(messy)) == Mnemonic.validate(messy), "\(language) baguncada")
            }
        }
    }

    @Test("Entropia ida e volta pelos bytes, nos dez idiomas")
    func entropyRoundTrip() throws {
        for language in BIP39Language.allCases {
            let entropy = try SecureBytes.random(count: 32)
            let phrase = try BIP39.phrase(fromEntropy: entropy, language: language)
            let back = try BIP39.entropy(fromPhrase: phrase, language: language)
            #expect(Hash.constantTimeEqual(back, entropy), "\(language)")
        }
    }

    @Test("25a palavra: bytes ASCII e caminho NFKD dao a mesma seed do vetor")
    func passphraseSeed() throws {
        let phrase = BIP39.canonical("legal winner thank year wave sausage worth useful legal winner thank yellow")
        let viaBytes = try BIP39.seed(phrase: phrase, passphrase: secure("TREZOR"))
        let viaString = try BIP39.seed(phrase: phrase, passphrase: "TREZOR")
        #expect(Hash.constantTimeEqual(viaBytes, viaString))
        #expect(viaBytes.withUnsafeBytes { Array($0) }.hex.hasPrefix("2e8905819b8723fe"))
        // Fora do ASCII: NFC e NFKD da mesma senha dao a mesma seed.
        let nfc = try BIP39.seed(phrase: phrase, passphrase: secure("canção"))
        let nfkd = try BIP39.seed(phrase: phrase, passphrase: secure("canção".decomposedStringWithCompatibilityMapping))
        #expect(Hash.constantTimeEqual(nfc, nfkd))
    }
}
