import EscaliburCore
import Foundation

/// Quanto custa adivinhar uma senha de envelope, dito em tempo e com numero.
///
/// A referencia e a tabela do README do Escalibur: o "crime organizado" testa cerca
/// de 1,2 × 10^5 senhas por segundo contra um cofre com os parametros de referencia
/// (512 MiB, t = 4, 4 GiB de trafego de memoria por chute). Parametros mais leves
/// deixam o chute mais barato na mesma proporcao.
///
/// A estimativa de entropia e conservadora e simples: palavras sorteadas da lista
/// BIP-39 valem 11 bits cada; o resto e contado por pedacos (palavra de dicionario,
/// ano, digitos, simbolos), porque "Bitcoin2024!" tem 12 caracteres e quase nenhuma
/// entropia.
enum PasswordCost {
    static let referenceGuessesPerSecond = 1.2e5
    static let referenceTrafficMiB = 4096.0

    static func bits(_ password: SecureBytes) -> Double {
        var text = password.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        defer { text = "" }
        return bits(of: text)
    }

    static func bits(of text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let tokens = text.lowercased().split(separator: " ").map(String.init)
        if tokens.count >= 3, let list = try? WordlistStore.shared.wordlist(for: .english), tokens.allSatisfy({ list.contains($0) }) {
            return Double(tokens.count) * 11
        }
        var total = 0.0
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c.isLetter {
                let run = text[index...].prefix { $0.isLetter }
                // Sequencia de letras: palavra de dicionario (cerca de 15 bits) se for
                // longa, senao letra por letra.
                total += run.count >= 4 ? 15 + (run.contains { $0.isUppercase } ? 1 : 0) : Double(run.count) * 4.7
                index = run.endIndex
            } else if c.isNumber {
                let run = text[index...].prefix { $0.isNumber }
                let isYear = run.count == 4 && (run.hasPrefix("19") || run.hasPrefix("20"))
                total += isYear ? 7 : Double(run.count) * 3.32
                index = run.endIndex
            } else {
                total += c == " " ? 1 : 5
                index = text.index(after: index)
            }
        }
        return total
    }

    /// Segundos para o crime organizado achar a senha, em media.
    static func seconds(bits: Double, kdf: KDFParameters) -> Double {
        let rate = referenceGuessesPerSecond * referenceTrafficMiB / max(kdf.memoryTrafficMiB, 1)
        return pow(2, bits) / 2 / rate
    }

    /// "4 segundos", "6 dias", "485 anos", "3,7 milhões de anos".
    static func describe(_ seconds: Double) -> String {
        let minute = 60.0, hour = 3600.0, day = 86_400.0, year = 31_557_600.0
        func plural(_ value: Double, _ one: String, _ many: String) -> String {
            let rounded = Int(value.rounded())
            return rounded <= 1 ? "1 \(one)" : "\(Fmt.grouped(Double(rounded), fractionDigits: 0)) \(many)"
        }
        switch seconds {
        case ..<1: return "menos de 1 segundo"
        case ..<minute: return plural(seconds, "segundo", "segundos")
        case ..<hour: return plural(seconds / minute, "minuto", "minutos")
        case ..<day: return plural(seconds / hour, "hora", "horas")
        case ..<year: return plural(seconds / day, "dia", "dias")
        case ..<(1e6 * year): return plural(seconds / year, "ano", "anos")
        case ..<(1e9 * year): return "\(Fmt.grouped(seconds / year / 1e6, fractionDigits: 1, trimZeros: true)) milhões de anos"
        default: return "mais de 1 bilhão de anos"
        }
    }

    /// Seis palavras BIP-39 sorteadas: 66 bits. Nenhuma pode estar na frase da
    /// propria carteira, para o papel da frase nunca abrir o envelope.
    static func suggestion(avoiding phraseWords: Set<String>, count: Int = 6) throws -> [String] {
        let list = try WordlistStore.shared.wordlist(for: .english)
        var out: [String] = []
        while out.count < count {
            var bytes = [UInt8](repeating: 0, count: 2)
            guard SecRandomCopyBytes(kSecRandomDefault, 2, &bytes) == errSecSuccess else { throw CryptoError.randomnessUnavailable }
            let index = (Int(bytes[0]) << 8 | Int(bytes[1])) & 0x7FF
            let word = list.words[index]
            if !phraseWords.contains(word), !out.contains(word) { out.append(word) }
        }
        return out
    }
}
