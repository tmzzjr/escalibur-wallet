import CryptoKit
import Foundation

/// Os dez idiomas do BIP-39.
///
/// O app gera frase nova so em ingles, mas importa nos dez. O motivo e concreto: um
/// dono com frase em espanhol que digita aqui e recebe "palavra invalida" conclui que
/// a frase dele esta errada, e frase que o dono acha que esta errada e frase que ele
/// joga fora.
public enum BIP39Language: String, CaseIterable, Hashable, Sendable {
    case english
    case japanese
    case chineseSimplified = "chinese_simplified"
    case chineseTraditional = "chinese_traditional"
    case french
    case italian
    case korean
    case spanish
    case czech
    case portuguese

    /// O separador do japones e o espaco ideografico. Ele decompoe para espaco comum
    /// na normalizacao, mas ao devolver a frase ao dono ela volta no separador dele.
    public var separator: String {
        self == .japanese ? "\u{3000}" : " "
    }

    public var displayName: String {
        switch self {
        case .english: "Inglês"
        case .japanese: "Japonês"
        case .chineseSimplified: "Chinês simplificado"
        case .chineseTraditional: "Chinês tradicional"
        case .french: "Francês"
        case .italian: "Italiano"
        case .korean: "Coreano"
        case .spanish: "Espanhol"
        case .czech: "Tcheco"
        case .portuguese: "Português"
        }
    }
}

public enum WordlistError: Error {
    /// O recurso nao esta no bundle, ou o digesto nao confere. Nos dois casos a
    /// instalacao esta corrompida e o app nao pode abrir cofre nenhum: abrir com uma
    /// lista adulterada significaria abrir a carteira errada em silencio.
    case corruptInstallation(BIP39Language)
    /// O mesmo, para a lista do SLIP-39.
    case corruptSLIP39
}

/// Uma lista carregada e conferida, com os dois indices que o app usa: posicao para
/// palavra, e palavra para posicao.
public struct Wordlist: Sendable {
    /// O idioma, quando a lista é uma das dez do BIP-39. A lista do SLIP-39 não é de
    /// idioma nenhum — é uma lista só, e por isso aqui fica vazio.
    public let language: BIP39Language?
    public let words: [String]
    private let index: [String: UInt16]

    fileprivate init(language: BIP39Language?, words: [String]) {
        self.language = language
        self.words = words
        var index = [String: UInt16](minimumCapacity: words.count)
        for (position, word) in words.enumerated() {
            index[word] = UInt16(position)
        }
        self.index = index
    }

    public func position(of word: String) -> UInt16? {
        index[word]
    }

    public func contains(_ word: String) -> Bool {
        index[word] != nil
    }

    /// Palavras da lista que comecam pelo prefixo dado, para o teclado proprio do app.
    ///
    /// Nao existe atalho de "quatro primeiras letras": ele so vale em ingles, e aqui a
    /// mesma tela atende dez idiomas.
    public func completions(forPrefix prefix: String, limit: Int = 6) -> [String] {
        guard !prefix.isEmpty else { return [] }
        var found: [String] = []
        for word in words where word.hasPrefix(prefix) {
            found.append(word)
            if found.count == limit { break }
        }
        return found
    }

    /// Sugestoes para uma palavra que nao esta na lista.
    ///
    /// So e chamada quando a palavra nao pertence a lista, e usa exclusivamente a
    /// palavra digitada contra um dicionario publico. Nunca ve as outras palavras da
    /// frase, e por isso nao e um oraculo sobre o segredo do dono.
    public func suggestions(for typed: String, limit: Int = 3) -> [String] {
        guard !typed.isEmpty else { return [] }
        var scored: [(word: String, distance: Int, shared: Int)] = []
        for word in words {
            let distance = Self.damerauLevenshtein(typed, word, ceiling: 2)
            guard distance <= 2 else { continue }
            scored.append((word, distance, Self.sharedPrefix(typed, word)))
        }
        scored.sort { left, right in
            left.distance != right.distance
                ? left.distance < right.distance
                : left.shared > right.shared
        }
        return scored.prefix(limit).map(\.word)
    }

    private static func sharedPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    /// Damerau-Levenshtein com teto: passou do teto, para de calcular. Poda o laco
    /// sobre 2048 palavras a cada tecla digitada.
    public static func damerauLevenshtein(_ a: String, _ b: String, ceiling: Int) -> Int {
        let source = Array(a.unicodeScalars)
        let target = Array(b.unicodeScalars)
        if abs(source.count - target.count) > ceiling { return ceiling + 1 }
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previousPrevious = [Int](repeating: 0, count: target.count + 1)
        var previous = Array(0...target.count)
        var current = [Int](repeating: 0, count: target.count + 1)

        for i in 1...source.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...target.count {
                let substitution = source[i - 1] == target[j - 1] ? 0 : 1
                var best = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + substitution
                )
                if i > 1, j > 1,
                   source[i - 1] == target[j - 2],
                   source[i - 2] == target[j - 1] {
                    best = min(best, previousPrevious[j - 2] + 1)
                }
                current[j] = best
                rowBest = min(rowBest, best)
            }
            if rowBest > ceiling { return ceiling + 1 }
            previousPrevious = previous
            previous = current
            current = [Int](repeating: 0, count: target.count + 1)
        }
        return previous[target.count]
    }
}

/// Carrega e confere as listas embarcadas, uma vez por idioma.
///
/// A lista e publica e nao precisa de sigilo. O que ela precisa e de integridade, e e
/// so isso que este tipo protege.
public final class WordlistStore: @unchecked Sendable {
    public static let shared = WordlistStore()

    private let lock = NSLock()
    private var loaded: [BIP39Language: Wordlist] = [:]
    private var slip39Loaded: Wordlist?
    private let bundle: Bundle

    init(bundle: Bundle = .module) {
        self.bundle = bundle
    }

    public func wordlist(for language: BIP39Language) throws -> Wordlist {
        lock.lock()
        defer { lock.unlock() }
        if let cached = loaded[language] { return cached }

        guard
            let url = bundle.url(forResource: language.rawValue, withExtension: "txt", subdirectory: "Wordlists")
                ?? bundle.url(forResource: language.rawValue, withExtension: "txt"),
            let data = try? Data(contentsOf: url)
        else {
            throw WordlistError.corruptInstallation(language)
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == WordlistDigest.sha256[language] else {
            throw WordlistError.corruptInstallation(language)
        }

        guard
            let text = String(data: data, encoding: .utf8)
        else {
            throw WordlistError.corruptInstallation(language)
        }
        let words = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard words.count == 2048 else {
            throw WordlistError.corruptInstallation(language)
        }

        let wordlist = Wordlist(language: language, words: words)
        loaded[language] = wordlist
        return wordlist
    }

    /// A lista de 1024 palavras do SLIP-39.
    ///
    /// Ela passa pela mesma conferência de digesto das dez do BIP-39, e pelo mesmo
    /// motivo: uma palavra trocada é outro segredo reconstruído, sem aviso.
    public func slip39() throws -> Wordlist {
        lock.lock()
        defer { lock.unlock() }
        if let slip39Loaded { return slip39Loaded }

        guard
            let url = bundle.url(forResource: "slip39", withExtension: "txt"),
            let data = try? Data(contentsOf: url)
        else {
            throw WordlistError.corruptSLIP39
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard
            digest == WordlistDigest.slip39,
            let text = String(data: data, encoding: .utf8)
        else {
            throw WordlistError.corruptSLIP39
        }

        let words = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard words.count == 1024 else { throw WordlistError.corruptSLIP39 }

        let wordlist = Wordlist(language: nil, words: words)
        slip39Loaded = wordlist
        return wordlist
    }
}
