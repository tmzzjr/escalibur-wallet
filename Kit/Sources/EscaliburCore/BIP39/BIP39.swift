import CryptoKit
import Foundation

/// Geracao de frase e derivacao da seed BIP-39, sempre em buffer seguro.
///
/// A validacao, a normalizacao e as listas de palavras sao as do Escalibur
/// (`Mnemonic`, `Wordlist`), sem alteracao: uma frase que o cofre aceita e a mesma
/// que a carteira aceita, byte a byte.
public enum BIP39 {
    /// Sorteia uma frase nova em ingles, direto para um buffer seguro, na forma
    /// canonica (minusculas, um espaco entre palavras).
    ///
    /// Ingles e so ingles na geracao: e a lista que todo outro software importa, e
    /// uma frase em portugues que a outra carteira nao le e um backup que falha no
    /// dia em que precisa funcionar.
    public static func generate(wordCount: Int = 12, store: WordlistStore = .shared) throws -> SecureBytes {
        guard Mnemonic.validWordCounts.contains(wordCount) else {
            throw CryptoError.malformedVault("tamanho de frase fora do padrão")
        }
        let entropyBytes = wordCount * 4 / 3
        let entropy = try SecureBytes.random(count: entropyBytes)
        defer { entropy.wipe() }
        return try phrase(fromEntropy: entropy, store: store)
    }

    /// A frase de uma entropia dada. Publico para os vetores oficiais do BIP-39.
    public static func phrase(fromEntropy entropy: SecureBytes, language: BIP39Language = .english, store: WordlistStore = .shared) throws -> SecureBytes {
        guard [16, 20, 24, 28, 32].contains(entropy.count) else {
            throw CryptoError.malformedVault("entropia com tamanho fora do padrão")
        }
        let list = try store.wordlist(for: language)
        let checksumBits = entropy.count / 4
        let digest = entropy.withUnsafeBytes { Array(SHA256.hash(data: $0)) }

        // Os bits ficam num array de vida curta, zerado na saida.
        var bits = [UInt8]()
        bits.reserveCapacity(entropy.count * 8 + checksumBits)
        defer { bits.resetBytes() }
        entropy.withUnsafeBytes { raw in
            for byte in raw { for i in 0..<8 { bits.append((byte >> (7 - i)) & 1) } }
        }
        for i in 0..<checksumBits { bits.append((digest[i / 8] >> (7 - i % 8)) & 1) }

        let wordCount = bits.count / 11
        // Maior palavra de qualquer lista em UTF-8 NFKD cabe folgada em 32 bytes.
        let out = SecureBytes(capacity: wordCount * 33)
        for w in 0..<wordCount {
            var index = 0
            for b in 0..<11 { index = index << 1 | Int(bits[w * 11 + b]) }
            if w > 0 { out.append(0x20) }
            let word = Array(list.words[index].decomposedStringWithCompatibilityMapping.utf8)
            word.withUnsafeBufferPointer { out.append(contentsOf: $0) }
        }
        return out
    }

    /// O caminho inverso: a entropia de uma frase valida, em buffer seguro.
    ///
    /// A carteira guarda a entropia (16 a 32 bytes) e nao as palavras. A frase e a
    /// seed sao reconstruidas quando preciso, e a entropia e o menor segredo que
    /// reconstroi as duas. A frase e lida sobre os bytes, palavra a palavra.
    public static func entropy(fromPhrase phrase: SecureBytes, language: BIP39Language, store: WordlistStore = .shared) throws -> SecureBytes {
        let list = try store.wordlist(for: language)
        var indices = try phrase.withUnsafeBytes { raw -> [UInt16] in
            let ranges = tokens(raw)
            guard Mnemonic.validWordCounts.contains(ranges.count) else {
                throw CryptoError.malformedVault("tamanho de frase fora do padrão")
            }
            var out: [UInt16] = []
            for range in ranges {
                guard let index = lookup(raw, range, in: list) else {
                    out.resetIndices()
                    throw CryptoError.malformedVault("palavra fora da lista")
                }
                out.append(index)
            }
            return out
        }
        defer { indices.resetIndices() }

        let entropyBits = indices.count * 32 / 3
        var bits = [UInt8]()
        defer { bits.resetBytes() }
        for index in indices {
            for b in (0..<11).reversed() { bits.append(UInt8((Int(index) >> b) & 1)) }
        }
        let out = SecureBytes(capacity: entropyBits / 8)
        for byteIndex in 0..<(entropyBits / 8) {
            var byte: UInt8 = 0
            for b in 0..<8 { byte = byte << 1 | bits[byteIndex * 8 + b] }
            out.append(byte)
        }
        // O checksum precisa fechar: entropia de frase invalida nao sai daqui.
        let digest = out.withUnsafeBytes { Array(SHA256.hash(data: $0)) }
        for i in 0..<(entropyBits / 32) where bits[entropyBits + i] != (digest[i / 8] >> (7 - i % 8)) & 1 {
            out.wipe()
            throw CryptoError.malformedVault("checksum da frase não fecha")
        }
        return out
    }

    /// A seed de 64 bytes: PBKDF2-HMAC-SHA512(frase NFKD, "mnemonic" + passphrase NFKD, 2048).
    ///
    /// `phrase` precisa ja estar na forma canonica de `Mnemonic.canonicalize`. A
    /// funcao nao normaliza de novo, porque os bytes que entram aqui sao exatamente os
    /// que o formato `.esclbr` grava, e normalizar duas vezes esconderia um bug de
    /// gravacao em vez de revela-lo.
    public static func seed(phrase: SecureBytes, passphrase: String = "") throws -> SecureBytes {
        var bytes = Array(passphrase.decomposedStringWithCompatibilityMapping.utf8)
        defer { bytes.resetBytes() }
        let normalized = SecureBytes(capacity: max(bytes.count, 1))
        normalized.replaceAll(with: bytes)
        defer { normalized.wipe() }
        return try seed(phrase: phrase, normalizedPassphrase: normalized)
    }

    /// A seed com a 25a palavra vinda de buffer seguro. A passphrase passa so por
    /// NFKD: sem minusculas, sem trim, sem colapsar espacos (BIP-39).
    ///
    /// ASCII ja e NFKD, e e o caso comum: os bytes vao direto para o sal, sem `String`.
    /// Fora do ASCII a normalizacao precisa do Unicode do sistema, e so ai a 25a
    /// palavra passa por uma `String` de vida curta. A importacao ja grava NFKD
    /// (`WalletSecret.from`), entao isto e idempotente.
    public static func seed(phrase: SecureBytes, passphrase: SecureBytes) throws -> SecureBytes {
        let ascii = passphrase.withUnsafeBytes { raw in raw.allSatisfy { $0 < 0x80 } }
        if ascii { return try seed(phrase: phrase, normalizedPassphrase: passphrase) }
        let normalized = nfkd(passphrase)
        defer { normalized.wipe() }
        return try seed(phrase: phrase, normalizedPassphrase: normalized)
    }

    /// NFKD de um segredo em buffer. Unica passagem por `String`, curta, zerada.
    public static func nfkd(_ secret: SecureBytes) -> SecureBytes {
        var text = secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        var bytes = Array(text.decomposedStringWithCompatibilityMapping.utf8)
        text = ""
        defer { bytes.resetBytes() }
        let out = SecureBytes(capacity: max(bytes.count, 1))
        out.replaceAll(with: bytes)
        return out
    }

    private static func seed(phrase: SecureBytes, normalizedPassphrase: SecureBytes) throws -> SecureBytes {
        let salt = SecureBytes(capacity: 8 + normalizedPassphrase.count)
        defer { salt.wipe() }
        Array("mnemonic".utf8).withUnsafeBufferPointer { salt.append(contentsOf: $0) }
        normalizedPassphrase.withUnsafeBytes { salt.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        return try Hash.pbkdf2SHA512(password: phrase, salt: salt, rounds: 2048, length: 64)
    }

    /// Valida uma frase ja em buffer. Devolve o idioma em que ela fecha.
    ///
    /// Frase canonica (a que o app gera, grava e le do envelope): tudo sobre os
    /// bytes, sem `String`. So quando a frase nao fecha pelos bytes, ou nao esta na
    /// forma canonica, o validador do Escalibur (`Mnemonic.validate`) da o
    /// diagnostico exato, e ai a frase passa por uma `String` de vida curta.
    public static func validate(_ phrase: SecureBytes, store: WordlistStore = .shared) -> Mnemonic.Validation {
        if let language = closingLanguage(phrase, store: store) { return .valid(language: language) }
        let text = phrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        return Mnemonic.validate(text, store: store)
    }

    /// O idioma em que a frase canonica fecha, pelos bytes. Nil se nao fechar em
    /// exatamente um idioma (ambiguo, errado ou fora da forma canonica).
    static func closingLanguage(_ phrase: SecureBytes, store: WordlistStore) -> BIP39Language? {
        phrase.withUnsafeBytes { raw -> BIP39Language? in
            let ranges = tokens(raw)
            guard Mnemonic.validWordCounts.contains(ranges.count) else { return nil }
            var closing: [BIP39Language] = []
            for language in BIP39Language.allCases {
                guard let list = try? store.wordlist(for: language) else { continue }
                var indices: [UInt16] = []
                defer { indices.resetIndices() }
                for range in ranges {
                    guard let index = list.position(nfkd: Array(raw[range])) else { break }
                    indices.append(index)
                }
                if indices.count == ranges.count, checksumCloses(indices) { closing.append(language) }
            }
            return closing.count == 1 ? closing[0] : nil
        }
    }

    /// As palavras de uma frase canonica: separadas por um espaco so, sem espaco nas
    /// pontas. Fora disso, nenhuma palavra (e a validacao cai no diagnostico completo).
    static func tokens(_ raw: UnsafeRawBufferPointer) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for index in 0...raw.count {
            if index == raw.count || raw[index] == 0x20 {
                guard index > start else { return [] }
                out.append(start..<index)
                start = index + 1
            }
        }
        return out
    }

    /// Posicao de uma palavra: pelos bytes NFKD; se a frase veio em outra forma
    /// Unicode equivalente (NFC de um envelope antigo), pela comparacao de `String`
    /// daquela palavra so.
    static func lookup(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, in list: Wordlist) -> UInt16? {
        var key = Array(raw[range])
        defer { key.resetBytes() }
        if let index = list.position(nfkd: key) { return index }
        return list.position(of: String(decoding: key, as: UTF8.self))
    }

    static func checksumCloses(_ indices: [UInt16]) -> Bool {
        guard let entropyBits = Mnemonic.entropyBits(forWordCount: indices.count) else { return false }
        var bits = [UInt8]()
        defer { bits.resetBytes() }
        for index in indices {
            for b in (0..<11).reversed() { bits.append(UInt8((Int(index) >> b) & 1)) }
        }
        var entropy = [UInt8](repeating: 0, count: entropyBits / 8)
        defer { entropy.resetBytes() }
        for i in 0..<entropyBits where bits[i] == 1 { entropy[i / 8] |= UInt8(0x80 >> (i % 8)) }
        var digest = Array(SHA256.hash(data: entropy))
        defer { digest.resetBytes() }
        for i in 0..<(entropyBits / 32) where bits[entropyBits + i] != (digest[i / 8] >> (7 - i % 8)) & 1 {
            return false
        }
        return true
    }

    /// Copia uma frase digitada para a forma canonica, direto num buffer seguro.
    public static func canonical(_ raw: String) -> SecureBytes {
        var bytes = Array(Mnemonic.canonicalize(raw).utf8)
        defer { bytes.resetBytes() }
        let out = SecureBytes(capacity: max(bytes.count, 1))
        out.replaceAll(with: bytes)
        return out
    }
}
