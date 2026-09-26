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
}
