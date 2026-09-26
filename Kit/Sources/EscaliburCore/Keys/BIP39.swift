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

    /// A seed de 64 bytes: PBKDF2-HMAC-SHA512(frase NFKD, "mnemonic" + passphrase NFKD, 2048).
    ///
    /// `phrase` precisa ja estar na forma canonica de `Mnemonic.canonicalize`. A
    /// funcao nao normaliza de novo, porque os bytes que entram aqui sao exatamente os
    /// que o formato `.esclbr` grava, e normalizar duas vezes esconderia um bug de
    /// gravacao em vez de revela-lo.
    public static func seed(phrase: SecureBytes, passphrase: String = "") throws -> SecureBytes {
        var salt = Array(("mnemonic" + passphrase.decomposedStringWithCompatibilityMapping).utf8)
        defer { salt.resetBytes() }
        return try Hash.pbkdf2SHA512(password: phrase, salt: salt, rounds: 2048, length: 64)
    }

    /// Valida uma frase ja em buffer. Devolve o idioma em que ela fecha.
    ///
    /// Passa pela `String` do Swift porque o validador do Escalibur trabalha com
    /// palavras; a janela e curta e a `String` sai de escopo aqui.
    public static func validate(_ phrase: SecureBytes) -> Mnemonic.Validation {
        let text = phrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        return Mnemonic.validate(text)
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
