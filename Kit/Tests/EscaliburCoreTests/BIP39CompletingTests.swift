import Testing
@testable import EscaliburCore

/// Completar a ultima palavra das palavras que o dono escolheu: as primeiras ficam, a
/// ultima fecha o checksum, e os bits livres saem do sorteio.
@Suite("BIP-39: completar a ultima palavra")
struct BIP39CompletingTests {
    func secure(_ text: String) -> SecureBytes {
        let bytes = SecureBytes(capacity: max(text.utf8.count, 1))
        bytes.replaceAll(with: Array(text.utf8))
        return bytes
    }

    func text(_ bytes: SecureBytes) -> String { bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } }

    @Test("Vetores oficiais: as primeiras palavras e os bits livres do vetor dao a ultima do vetor")
    func vectors() throws {
        // Do vectors.json do Trezor (ingles): "abandon" x11 + "about" tem entropia zero, e
        // os 7 bits livres sao 0; "legal winner ... yellow" tem entropia 0x7f..7f, livres 1111111.
        let about = try BIP39.completing(secure(Array(repeating: "abandon", count: 11).joined(separator: " ")), store: .shared, freeBits: 0)
        #expect(text(about) == Array(repeating: "abandon", count: 11).joined(separator: " ") + " about")
        let legal = try BIP39.completing(secure("legal winner thank year wave sausage worth useful legal winner thank"), store: .shared, freeBits: 0x7f)
        #expect(text(legal) == "legal winner thank year wave sausage worth useful legal winner thank yellow")
        // 24 palavras: "abandon" x23 + "art", entropia zero, 3 bits livres 0.
        let art = try BIP39.completing(secure(Array(repeating: "abandon", count: 23).joined(separator: " ")), store: .shared, freeBits: 0)
        #expect(text(art) == Array(repeating: "abandon", count: 23).joined(separator: " ") + " art")
    }

    @Test("Sorteio de verdade: a frase sempre fecha, as primeiras ficam, e a ultima varia")
    func drawn() throws {
        let first = "zoo vocal tiger ocean march liquid hotel frog dance bone acid"
        var last = Set<String>()
        for _ in 0..<64 {
            let full = try BIP39.completing(secure(first))
            let words = text(full).split(separator: " ").map(String.init)
            #expect(words.count == 12)
            #expect(words.prefix(11).joined(separator: " ") == first)
            #expect(BIP39.validate(full) == .valid(language: .english))
            last.insert(words[11])
        }
        // 128 possiveis: em 64 sorteios, quase certamente mais de 20 diferentes.
        #expect(last.count > 20)
        let long = try BIP39.completing(secure(Array(repeating: "zoo", count: 23).joined(separator: " ")))
        #expect(BIP39.validate(long) == .valid(language: .english))
    }

    @Test("Recusa: tamanho que nao e 11 nem 23, palavra fora da lista em ingles")
    func refusals() {
        #expect(throws: CryptoError.self) { try BIP39.completing(secure("abandon abandon")) }
        #expect(throws: CryptoError.self) { try BIP39.completing(secure(Array(repeating: "abandon", count: 12).joined(separator: " "))) }
        #expect(throws: CryptoError.self) { try BIP39.completing(secure(Array(repeating: "abandon", count: 10).joined(separator: " ") + " abaco")) }
    }

    @Test("Montada como a tela monta: um buffer por palavra, juntados com espaco num buffer maior")
    func asTheScreenBuilds() throws {
        let words = ["zoo", "vocal", "tiger", "ocean", "march", "liquid", "hotel", "frog", "dance", "bone", "acid"]
        let slots = words.map { word -> SecureBytes in
            let slot = SecureBytes(capacity: 32)
            slot.replaceAll(with: Array(Mnemonic.canonicalize(word).utf8.prefix(32)))
            return slot
        }
        let out = SecureBytes(capacity: words.count * 33)
        for (index, slot) in slots.enumerated() {
            if index > 0 { out.append(0x20) }
            slot.withUnsafeBytes { out.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        }
        let full = try BIP39.completing(out)
        #expect(BIP39.validate(full) == .valid(language: .english))
    }
}
