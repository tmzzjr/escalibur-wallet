import EscaliburCore
import Foundation

/// Quanto custa adivinhar uma senha de envelope, dito em tempo e com numero.
///
/// A referencia e a tabela do README do Escalibur: o "crime organizado" testa cerca
/// de 1,2 × 10^5 senhas por segundo contra um cofre com os parametros de referencia
/// (512 MiB, t = 4, 4 GiB de trafego de memoria por chute). Parametros mais leves
/// deixam o chute mais barato na mesma proporcao.
///
/// Os bits vem de `PasswordStrength` (EscaliburCore), contados sobre os bytes.
enum PasswordCost {
    static let referenceGuessesPerSecond = 1.2e5
    static let referenceTrafficMiB = 4096.0

    /// Segundos para o crime organizado achar a senha, em media.
    static func seconds(bits: Double, kdf: KDFParameters) -> Double {
        let rate = referenceGuessesPerSecond * referenceTrafficMiB / max(kdf.memoryTrafficMiB, 1)
        return pow(2, bits) / 2 / rate
    }

    /// Um Estado testa 100 vezes mais rapido que o crime organizado (README do Escalibur).
    static func stateSeconds(bits: Double, kdf: KDFParameters) -> Double { seconds(bits: bits, kdf: kdf) / 100 }

    /// As faixas da tela, pelo tempo real com os parametros deste envelope (auditoria
    /// do envelope, 14/10/2026, C2).
    enum Band: Equatable {
        /// O crime organizado abre em menos de 1 dia.
        case veryWeak
        /// De 1 dia a 10 anos para o crime organizado.
        case weak
        /// Mais de 10 anos para o crime organizado, mas um Estado abre em menos de 1.000.
        case fair
        /// Nem um Estado abre em 1.000 anos.
        case strong

        /// Abaixo de forte, o lacre pede o "sim" explicito.
        var needsConsent: Bool { self != .strong }
        /// Muito fraca e fraca: o "usar mesmo assim" exige segurar o botao.
        var needsHold: Bool { self == .veryWeak || self == .weak }
    }

    static func band(bits: Double, kdf: KDFParameters) -> Band {
        let year = 31_557_600.0
        let crime = seconds(bits: bits, kdf: kdf)
        if crime < 86_400 { return .veryWeak }
        if crime < 10 * year { return .weak }
        if stateSeconds(bits: bits, kdf: kdf) < 1_000 * year { return .fair }
        return .strong
    }

    /// A frase da faixa, com o tempo calculado.
    static func text(bits: Double, kdf: KDFParameters) -> String {
        switch band(bits: bits, kdf: kdf) {
        case .veryWeak: return String(localized: "Muito fraca. Quem pegar o arquivo abre em \(describe(seconds(bits: bits, kdf: kdf))).")
        case .weak: return String(localized: "Fraca. Um grupo com placas de vídeo abre em \(describe(seconds(bits: bits, kdf: kdf))).")
        case .fair: return String(localized: "Média. Um grupo com placas de vídeo levaria \(describe(seconds(bits: bits, kdf: kdf))), e um governo, \(describe(stateSeconds(bits: bits, kdf: kdf))).")
        case .strong: return String(localized: "Forte. Nem um governo abre em tempo útil.")
        }
    }

    /// "4 segundos", "6 dias", "485 anos", "3,7 milhões de anos". Cada unidade e uma frase
    /// inteira, no singular e no plural, para a traducao.
    static func describe(_ seconds: Double) -> String {
        let minute = 60.0, hour = 3600.0, day = 86_400.0, year = 31_557_600.0
        func count(_ value: Double) -> (one: Bool, text: String) {
            let rounded = max(Int(value.rounded()), 1)
            return (rounded == 1, Fmt.grouped(Double(rounded), fractionDigits: 0))
        }
        switch seconds {
        case ..<1: return String(localized: "menos de 1 segundo")
        case ..<minute:
            let n = count(seconds)
            return n.one ? String(localized: "1 segundo") : String(localized: "\(n.text) segundos")
        case ..<hour:
            let n = count(seconds / minute)
            return n.one ? String(localized: "1 minuto") : String(localized: "\(n.text) minutos")
        case ..<day:
            let n = count(seconds / hour)
            return n.one ? String(localized: "1 hora") : String(localized: "\(n.text) horas")
        case ..<year:
            let n = count(seconds / day)
            return n.one ? String(localized: "1 dia") : String(localized: "\(n.text) dias")
        case ..<(1e6 * year):
            let n = count(seconds / year)
            return n.one ? String(localized: "1 ano") : String(localized: "\(n.text) anos")
        case ..<(1e9 * year): return String(localized: "\(Fmt.grouped(seconds / year / 1e6, fractionDigits: 1, trimZeros: true)) milhões de anos")
        default: return String(localized: "mais de 1 bilhão de anos")
        }
    }
}
