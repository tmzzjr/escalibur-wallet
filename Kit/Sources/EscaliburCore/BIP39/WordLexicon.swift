import Foundation

/// As palavras de todas as listas BIP-39 que o app le, para as sugestoes e para o teclado
/// proprio das palavras. Nas listas de alfabeto latino (ingles, portugues, espanhol,
/// frances, italiano, tcheco) a busca ignora acento: o teclado proprio so tem de a a z, e
/// a forma sem acento e unica dentro de cada uma das seis listas (conferido em
/// `WordLexiconTests`). Nas outras (japones, chines, coreano), o prefixo exato.
///
/// Sem acento, "abaco" e o "abaco" italiano e o "ábaco" espanhol: a mesma letra serve a
/// dois idiomas. Por isso as sugestoes poem primeiro o idioma das palavras ja fechadas (sem
/// travar: uma primeira palavra no idioma errado nao apaga letra nenhuma das seguintes,
/// segunda revisao, N1), a palavra exata vem antes das que so comecam assim, e no fim
/// `resolve` acha o idioma em que a frase inteira fecha (revisao do teclado proprio, M2).
/// As palavras ja fechadas sao lidas direto dos buffers seguros, sem virar `String` (N2).
public enum WordLexicon {
    public struct Entry: Sendable {
        public let word: String
        /// A palavra sem acento, so nas listas latinas.
        public let folded: String?
        public let language: BIP39Language
    }

    /// Monta as listas e os indices de uma vez, fora da tela principal: a primeira tela de
    /// digitar as palavras travava montando tudo na hora (visto no app de verdade,
    /// 16/10/2026). A checagem do aparelho chama enquanto confere.
    public static func warmUp() {
        _ = entries
        _ = byLanguage
        _ = wordSets
        _ = foldedIndex
        _ = foldedPositions
        _ = nfkdWords
    }

    public static let latin: [BIP39Language] = [.english, .portuguese, .spanish, .french, .italian, .czech]
    public static let others: [BIP39Language] = [.japanese, .korean, .chineseSimplified, .chineseTraditional]

    /// Todas as palavras, na ordem dos idiomas acima.
    public static let entries: [Entry] = {
        var out: [Entry] = []
        for language in latin + others {
            guard let list = try? WordlistStore.shared.wordlist(for: language) else { continue }
            let isLatin = latin.contains(language)
            out += list.words.map { Entry(word: $0, folded: isLatin ? fold($0) : nil, language: language) }
        }
        return out
    }()

    /// As palavras de cada idioma, para a busca so olhar os idiomas que valem.
    static let byLanguage: [BIP39Language: [Entry]] = Dictionary(grouping: entries, by: \.language)
    static let wordSets: [BIP39Language: Set<String>] = byLanguage.mapValues { Set($0.map(\.word)) }

    /// Os idiomas pedidos, na ordem de sempre.
    private static func ordered(_ languages: Set<BIP39Language>?) -> [BIP39Language] {
        (latin + others).filter { languages?.contains($0) ?? true }
    }

    /// Por idioma latino, a forma sem acento e a palavra de verdade.
    static let foldedIndex: [BIP39Language: [String: String]] = {
        var out: [BIP39Language: [String: String]] = [:]
        for entry in entries {
            guard let folded = entry.folded else { continue }
            out[entry.language, default: [:]][folded] = entry.word
        }
        return out
    }()

    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private static func matches(_ entry: Entry, canonical: String, folded: String) -> Bool {
        entry.folded.map { $0.hasPrefix(folded) } ?? entry.word.hasPrefix(canonical)
    }

    /// A forma sem acento, sobre os bytes NFKD da palavra: tira as marcas combinantes de
    /// U+0300 a U+036F (em UTF-8, CC 80 a CD AF). Nas seis listas latinas sobra so a-z.
    static func foldBytes(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if index + 1 < bytes.count {
                let next = bytes[index + 1]
                if (byte == 0xCC && (0x80...0xBF).contains(next)) || (byte == 0xCD && (0x80...0xAF).contains(next)) {
                    index += 2
                    continue
                }
            }
            out.append(byte)
            index += 1
        }
        return out
    }

    /// Por idioma latino, a forma sem acento em bytes e a posicao na lista.
    static let foldedPositions: [BIP39Language: [[UInt8]: UInt16]] = {
        var out: [BIP39Language: [[UInt8]: UInt16]] = [:]
        for language in latin {
            guard let list = try? WordlistStore.shared.wordlist(for: language) else { continue }
            var index: [[UInt8]: UInt16] = [:]
            for (position, word) in list.words.enumerated() {
                let bytes = Array(word.decomposedStringWithCompatibilityMapping.utf8)
                index[bytes.withUnsafeBytes(foldBytes)] = UInt16(position)
            }
            out[language] = index
        }
        return out
    }()

    /// Por idioma latino, cada palavra da lista em bytes NFKD, para montar a frase sem `String`.
    static let nfkdWords: [BIP39Language: [[UInt8]]] = {
        var out: [BIP39Language: [[UInt8]]] = [:]
        for language in latin {
            guard let list = try? WordlistStore.shared.wordlist(for: language) else { continue }
            out[language] = list.words.map { Array($0.decomposedStringWithCompatibilityMapping.utf8) }
        }
        return out
    }()

    /// A posicao de uma palavra (bytes NFKD, como `Mnemonic.canonicalize` grava) na lista de
    /// um idioma: sem acento nas latinas, exata nas outras. Os bytes de passagem sao zerados.
    private static func position(of word: SecureBytes, in language: BIP39Language) -> UInt16? {
        word.withUnsafeBytes { raw -> UInt16? in
            if latin.contains(language) {
                var folded = foldBytes(raw)
                defer { folded.resetBytes() }
                return foldedPositions[language]?[folded]
            }
            var exact = Array(raw.bindMemory(to: UInt8.self))
            defer { exact.resetBytes() }
            return (try? WordlistStore.shared.wordlist(for: language))?.position(nfkd: exact)
        }
    }

    /// Os idiomas em que todas estas palavras existem (sem acento nas latinas), lidas dos
    /// buffers seguros. Nil sem palavra nenhuma: qualquer idioma serve.
    public static func languages(containing words: [SecureBytes]) -> Set<BIP39Language>? {
        let filled = words.filter { $0.count > 0 }
        guard !filled.isEmpty else { return nil }
        var found = Set<BIP39Language>()
        for language in latin + others where filled.allSatisfy({ position(of: $0, in: language) != nil }) {
            found.insert(language)
        }
        return found
    }

    /// Ate `limit` palavras que comecam com o que foi digitado. Os idiomas preferidos (os das
    /// palavras ja fechadas; nil: todos) vem antes, mas os outros nunca somem: primeiro a
    /// palavra exata, depois a exata sem acento (as duas nos preferidos e depois nos outros),
    /// depois as que so comecam assim. A primeira e a que o Seguinte escolhe.
    public static func completions(_ typed: String, preferring preferred: Set<BIP39Language>? = nil, limit: Int = 4) -> [String] {
        let canonical = Mnemonic.canonicalize(typed)
        guard !canonical.isEmpty, limit > 0 else { return [] }
        let folded = fold(canonical)
        let all = latin + others
        let first = all.filter { preferred?.contains($0) ?? true }
        let rest = all.filter { !(preferred?.contains($0) ?? true) }
        var found: [String] = []
        func add(_ word: String) { if !found.contains(word) { found.append(word) } }
        for group in [first, rest] {
            for language in group where wordSets[language]?.contains(canonical) == true { add(canonical) }
            for language in group { if let word = foldedIndex[language]?[folded] { add(word) } }
        }
        for group in [first, rest] {
            for language in group {
                for entry in byLanguage[language] ?? [] where matches(entry, canonical: canonical, folded: folded) {
                    if found.count >= limit { break }
                    add(entry.word)
                }
                if found.count >= limit { break }
            }
        }
        return Array(found.prefix(limit))
    }

    /// As letras que ainda formam alguma palavra das listas latinas dadas (nil: todas)
    /// depois do que foi digitado: so elas acendem no teclado proprio.
    public static func nextLetters(after typed: String, languages: Set<BIP39Language>? = nil) -> Set<Character> {
        let prefix = fold(Mnemonic.canonicalize(typed))
        var letters = Set<Character>()
        for language in ordered(languages) where latin.contains(language) {
            for entry in byLanguage[language] ?? [] {
            guard let folded = entry.folded, folded.count > prefix.count, folded.hasPrefix(prefix) else { continue }
            let next = folded[folded.index(folded.startIndex, offsetBy: prefix.count)]
            if next.isASCII, next.isLetter { letters.insert(next) }
            }
        }
        return letters
    }

    /// Digitada sem acento (ou com uma palavra de outro idioma que se escreve igual), a
    /// frase nao fecha como esta. Aqui cada palavra vira a do idioma latino em que a frase
    /// inteira fecha: so devolve se exatamente um idioma fechar, com a frase canonica num
    /// buffer seguro. Tudo pelos bytes: nenhuma palavra vira `String`.
    public static func resolve(_ words: [SecureBytes], store: WordlistStore = .shared) -> (phrase: SecureBytes, language: BIP39Language)? {
        var found: [(SecureBytes, BIP39Language)] = []
        for language in latin {
            guard let lists = nfkdWords[language] else { continue }
            var positions: [UInt16] = []
            defer { positions.resetIndices() }
            for word in words {
                guard let position = position(of: word, in: language) else { break }
                positions.append(position)
            }
            guard positions.count == words.count, !positions.isEmpty else { continue }
            let size = positions.reduce(positions.count) { $0 + lists[Int($1)].count }
            let candidate = SecureBytes(capacity: size)
            for (offset, position) in positions.enumerated() {
                if offset > 0 { candidate.append(0x20) }
                lists[Int(position)].withUnsafeBufferPointer { candidate.append(contentsOf: $0) }
            }
            if case .valid(let closing) = BIP39.validate(candidate, store: store), closing == language {
                found.append((candidate, language))
            } else {
                candidate.wipe()
            }
        }
        guard found.count == 1 else {
            found.forEach { $0.0.wipe() }
            return nil
        }
        return (found[0].0, found[0].1)
    }
}
