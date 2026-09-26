import CryptoKit
import Foundation

/// Validacao de frase de recuperacao BIP-39.
///
/// Duas coisas guiam este arquivo, e as duas sao decisoes de custodia, nao de estilo:
///
/// 1. **A normalizacao e o segredo.** A frase normalizada e a senha do PBKDF2 do
///    BIP-39. Um caractere invisivel que sobrevive a normalizacao e outra carteira,
///    valida e vazia, sem nenhum aviso. Por isso a limpeza aqui e explicita e nao
///    confia em NFKD sozinho: NFKD nao remove largura zero, nao remove soft hyphen e
///    nao converte o apostrofo curvo que o teclado do iOS insere sozinho.
///
/// 2. **O app nao e um resolvedor de frases.** Palavra fora da lista pode ser apontada,
///    porque a lista e publica e isso nao conta nada sobre o segredo do dono. Checksum
///    que falha com todas as palavras validas nao pode ser localizado: o app nao sabe
///    qual palavra esta errada, e fingir que sabe seria mentira. Nao existe corretor
///    de checksum aqui, e a ausencia dele e deliberada, explicada em `nota tecnica`
///    no fim do arquivo.
public enum Mnemonic {

    // MARK: Normalizacao

    /// Caracteres que atravessam a normalizacao NFKD intactos e mudam a carteira.
    private static let invisibles: Set<Unicode.Scalar> = [
        "\u{200B}",  // largura zero
        "\u{200C}",  // nao juntador de largura zero
        "\u{200D}",  // juntador de largura zero
        "\u{FEFF}",  // marca de ordem de byte
        "\u{00AD}",  // hifen suave
    ]

    /// A forma canonica da frase: NFKD, sem invisiveis, minusculas, palavras separadas
    /// por um unico espaco comum.
    ///
    /// A ordem importa. Descompor primeiro faz o espaco ideografico do japones (U+3000)
    /// e o espaco inquebravel (U+00A0) virarem espaco comum, e so entao a divisao por
    /// espaco em branco enxerga as palavras certas.
    public static func canonicalize(_ raw: String) -> String {
        var decomposed = raw.decomposedStringWithCompatibilityMapping
        decomposed.unicodeScalars.removeAll { invisibles.contains($0) }
        // `lowercased()` de String em Swift nao depende de locale, entao o "I" turco
        // nao e um problema aqui. Ele seria em `NSString.lowercased(with:)`.
        let lowered = decomposed.lowercased()
        return lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func words(in raw: String) -> [String] {
        let canonical = canonicalize(raw)
        return canonical.isEmpty ? [] : canonical.split(separator: " ").map(String.init)
    }

    // MARK: Tamanho

    /// Os cinco tamanhos do padrao. `ENT = palavras * 32 / 3` e `CS = ENT / 32`.
    public static let validWordCounts = [12, 15, 18, 21, 24]

    public static func entropyBits(forWordCount count: Int) -> Int? {
        validWordCounts.contains(count) ? count * 32 / 3 : nil
    }

    // MARK: Resultado

    public enum Validation: Equatable {
        /// A frase fecha. `language` e o idioma em que ela fecha.
        case valid(language: BIP39Language)

        /// Faltam ou sobram palavras. O dono ve a contagem, o que e informacao dele
        /// mesmo e nao revela nada.
        case wrongLength(count: Int)

        /// Classe A: estas posicoes tem palavras que nao existem na lista. Pode ser
        /// apontado por posicao, porque a lista e publica.
        case unknownWords(positions: [Int], language: BIP39Language)

        /// A frase nao fecha em nenhum dos dez idiomas, com todas as palavras
        /// pertencendo a algum deles. Palavras de idiomas diferentes misturadas caem
        /// aqui.
        case mixedLanguages

        /// Classe B: todas as palavras existem, o tamanho esta certo, e o checksum nao
        /// fecha. **Sem posicao.** O app nao sabe qual palavra esta trocada, e a
        /// interface nao pode sugerir que sabe.
        case checksumFailed(language: BIP39Language)

        /// A frase fecha em mais de um idioma. Acontece de forma raríssima e o dono
        /// precisa desempatar, porque a escolha muda a carteira.
        case ambiguousLanguage([BIP39Language])
    }

    // MARK: Validacao

    /// Gera uma frase valida de 12 palavras, do gerador do sistema.
    ///
    /// Existe para **uma** finalidade: o conteudo do compartimento isca. A isca
    /// precisa ser uma frase que fecha, porque uma frase que nao fecha denuncia a
    /// farsa no primeiro validador; e precisa vir do CSPRNG, porque uma frase
    /// escolhida por uma pessoa sob pressa tem padrao. Doze palavras, e nao vinte e
    /// quatro: e o tamanho mais comum em circulacao, entao e o que menos chama
    /// atencao.
    ///
    /// A frase gerada e uma carteira de verdade, valida e vazia. Quem quiser dar
    /// mais textura a isca pode depositar nela um troco.
    public static func generate(
        wordCount: Int = 12,
        language: BIP39Language = .english,
        store: WordlistStore = .shared
    ) throws -> String {
        // A isca precisa se parecer com o cofre que imita: uma frase de 12 palavras
        // no lugar de 24, ou em ingles no lugar do espanhol do dono, e uma encenacao
        // que nao fecha, e encenacao que nao fecha convida exatamente a conclusao
        // que a isca existe para impedir.
        guard validWordCounts.contains(wordCount) else {
            throw CryptoError.malformedVault("tamanho de frase fora do padrão")
        }
        let entropyBytes = wordCount * 11 / 33 * 4
        var entropy = [UInt8](repeating: 0, count: entropyBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
            throw CryptoError.randomnessUnavailable
        }
        defer { entropy.resetBytes() }

        // O digito verificador do padrao: os ENT/32 primeiros bits do SHA-256 da
        // entropia, anexados ao fim, fechando um total que divide em indices de 11.
        let checksumBits = entropyBytes / 4
        let digest = Array(SHA256.hash(data: Data(entropy)))

        var bits = entropy.flatMap { byte in (0..<8).map { (byte >> (7 - $0)) & 1 } }
        bits += (0..<checksumBits).map { (digest[$0 / 8] >> (7 - $0 % 8)) & 1 }

        let list = try store.wordlist(for: language)
        let words = stride(from: 0, to: bits.count, by: 11).map { start -> String in
            let index = bits[start..<start + 11].reduce(0) { Int($0) << 1 | Int($1) }
            return list.words[index]
        }
        return words.joined(separator: " ")
    }

    public static func validate(_ raw: String, store: WordlistStore = .shared) -> Validation {
        let words = words(in: raw)

        guard validWordCounts.contains(words.count) else {
            return .wrongLength(count: words.count)
        }

        // Idioma nao se adivinha por palavra solta: `abandon` existe em ingles e em
        // frances. So conta o idioma em que **todas** as palavras pertencem a lista.
        var candidates: [(language: BIP39Language, wordlist: Wordlist)] = []
        var closestMisses: [(language: BIP39Language, positions: [Int], wordlist: Wordlist)] = []

        for language in BIP39Language.allCases {
            guard let wordlist = try? store.wordlist(for: language) else { continue }
            var missing: [Int] = []
            for (position, word) in words.enumerated() where !wordlist.contains(word) {
                missing.append(position)
            }
            if missing.isEmpty {
                candidates.append((language, wordlist))
            } else {
                closestMisses.append((language, missing, wordlist))
            }
        }

        guard !candidates.isEmpty else {
            // Nenhum idioma cobre a frase inteira. O idioma que erra menos e o palpite
            // util para apontar as posicoes ao dono; se todos erram quase tudo, e
            // mistura de idiomas e nao erro de digitacao.
            guard let best = closestMisses.min(by: { $0.positions.count < $1.positions.count })
            else {
                return .mixedLanguages
            }
            let ratio = Double(best.positions.count) / Double(words.count)
            return ratio > 0.5
                ? .mixedLanguages
                : .unknownWords(positions: best.positions, language: best.language)
        }

        let closing = candidates.filter { checksumCloses(words, in: $0.wordlist) }

        switch closing.count {
        case 0:
            return .checksumFailed(language: candidates[0].language)
        case 1:
            return .valid(language: closing[0].language)
        default:
            return .ambiguousLanguage(closing.map(\.language))
        }
    }

    // MARK: Checksum

    /// Concatena os indices em 11 bits big-endian, separa entropia e checksum, e
    /// compara com os primeiros CS bits de SHA-256 da entropia.
    public static func checksumCloses(_ words: [String], in wordlist: Wordlist) -> Bool {
        guard let entropyBits = entropyBits(forWordCount: words.count) else { return false }
        let checksumBits = entropyBits / 32

        var bits = [Bool]()
        bits.reserveCapacity(words.count * 11)
        for word in words {
            guard let position = wordlist.position(of: word) else { return false }
            for shift in stride(from: 10, through: 0, by: -1) {
                bits.append((position >> UInt16(shift)) & 1 == 1)
            }
        }

        var entropy = [UInt8](repeating: 0, count: entropyBits / 8)
        // A entropia sai daqui zerada de proposito: ela e o segredo, e um `defer` que
        // sempre roda e mais barato que confiar em quem chama.
        defer { entropy.resetBytes() }

        for index in 0..<entropyBits where bits[index] {
            entropy[index / 8] |= UInt8(0x80 >> (index % 8))
        }

        var digest = Array(SHA256.hash(data: entropy))
        defer { digest.resetBytes() }

        for offset in 0..<checksumBits {
            let expected = (digest[offset / 8] >> UInt8(7 - offset % 8)) & 1 == 1
            if bits[entropyBits + offset] != expected { return false }
        }
        return true
    }
}

extension Array where Element == UInt16 {
    /// Zera indices de palavra (eles reconstroem a frase).
    mutating func resetIndices() {
        withUnsafeMutableBytes { if let base = $0.baseAddress { memset_s(base, $0.count, 0, $0.count) } }
        removeAll()
    }
}

extension Array where Element == UInt8 {
    /// Zeragem que o otimizador nao tem permissao para remover.
    ///
    /// Isto encurta a janela em que o segredo existe em memoria. Nao a fecha: com ARC
    /// e copy-on-write nao ha como garantir que uma copia nao ficou para tras. A
    /// honestidade sobre esse limite esta em docs/custodia.md.
    public mutating func resetBytes() {
        withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            memset_s(base, buffer.count, 0, buffer.count)
        }
    }
}

// MARK: - Nota tecnica: por que nao existe corretor de checksum
//
// A tentacao obvia e, quando o checksum falha, varrer as substituicoes de uma palavra
// e devolver ao dono as que fecham. Duas razoes para nao fazer:
//
// 1. Nao resolve. Numa frase de 12 palavras o checksum tem 4 bits, entao das
//    12 x 2047 = 24.564 substituicoes possiveis cerca de uma em dezesseis fecha:
//    aproximadamente 1.535 candidatas, todas indistinguiveis entre si sem derivar
//    endereco e comparar com algo que o dono saiba de cor. Em 24 palavras sao 8 bits e
//    ainda restam ~190. Entregar centenas de frases nao e ajuda.
//
// 2. E uma arma. Quem tem uma frase parcial (papel rasgado, foto tremida, uma palavra
//    ilegivel) usaria o app como resolvedor. O Escalibur nao vai ser essa ferramenta.
//
// O que substitui, e e honesto, e a conferencia por endereco derivado: o dono compara
// com um endereco que ele reconhece. Se ele nao reconhece nenhum, nenhum resolvedor
// resolveria mesmo.
