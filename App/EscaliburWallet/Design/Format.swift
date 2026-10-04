import EscaliburCore
import Foundation

/// Toda formatacao de numero, valor e data que o usuario le, num lugar so.
///
/// Regras (docs/design/sistema-visual.md): pt_BR, NBSP depois do simbolo, sinal de
/// menos U+2212 e nunca hifen ou travessao, cripto truncado para baixo (o "Max"
/// nunca passa do saldo real), abreviacao so em dado de mercado.
enum Fmt {
    static let locale = Locale(identifier: "pt_BR")
    static let minus = "\u{2212}"
    static let nbsp = "\u{00A0}"

    /// "cerca de 1 segundo", "cerca de 4 segundos": estimativa de espera.
    static func aboutSeconds(_ seconds: Double) -> String {
        let n = max(1, Int(seconds.rounded()))
        return n == 1 ? "cerca de 1 segundo" : "cerca de \(n) segundos"
    }

    /// Em que unidade o saldo total aparece: as duas moedas do app, o euro e o bitcoin.
    /// A conversao usa o preco do bitcoin em cada moeda, a mesma cotacao para todas.
    enum DisplayUnit: String, CaseIterable, Codable, Sendable {
        case brl, usd, eur, btc

        var symbol: String {
            switch self {
            case .brl: return "R$"
            case .usd: return "US$"
            case .eur: return "€"
            case .btc: return "₿"
            }
        }

        var fractionDigits: Int { self == .btc ? 8 : 2 }

        var name: String {
            switch self {
            case .brl: return "Real"
            case .usd: return "Dólar"
            case .eur: return "Euro"
            case .btc: return "Bitcoin"
            }
        }

        init(_ currency: Currency) { self = currency == .brl ? .brl : .usd }
    }

    enum Currency: String, CaseIterable, Codable, Sendable {
        case brl = "BRL"
        case usd = "USD"

        var symbol: String { self == .brl ? "R$" : "US$" }
        var coingeckoID: String { rawValue.lowercased() }
    }

    // MARK: Fiat

    /// "R$ 1.234,56", "< R$ 0,01", "−R$ 12,30".
    static func fiat(_ value: Double, _ currency: Currency = .brl, signed: Bool = false) -> String {
        guard value.isFinite else { return "\(currency.symbol)\(nbsp)0,00" }
        let magnitude = abs(value)
        if magnitude > 0, magnitude < 0.01 {
            return "< \(currency.symbol)\(nbsp)0,01"
        }
        let body = grouped(magnitude, fractionDigits: 2)
        let sign = value < 0 ? minus : (signed && value > 0 ? "+" : "")
        return "\(sign)\(currency.symbol)\(nbsp)\(body)"
    }

    /// Preco unitario com casas pela faixa, e zeros em subscrito abaixo de 0,0001.
    static func price(_ value: Double, _ currency: Currency = .brl) -> String {
        guard value.isFinite, value > 0 else { return "\(currency.symbol)\(nbsp)0,00" }
        let body: String
        switch value {
        case 1...: body = grouped(value, fractionDigits: 2)
        case 0.01..<1: body = grouped(value, fractionDigits: 4)
        case 0.0001..<0.01: body = grouped(value, fractionDigits: 6)
        default: body = subscriptZeros(value)
        }
        return "\(currency.symbol)\(nbsp)\(body)"
    }

    /// "+2,31%". Zero sai sem sinal. A partir de 1.000%, sem casas.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0,00%" }
        let rounded = (value * 100).rounded() / 100
        if rounded == 0 { return "0,00%" }
        let sign = rounded > 0 ? "+" : minus
        let digits = abs(rounded) >= 1000 ? 0 : 2
        return "\(sign)\(grouped(abs(rounded), fractionDigits: digits))%"
    }

    /// "12,3 mil", "812 mi", "45,2 bi". So para capitalizacao, volume e liquidez.
    static func compact(_ value: Double, _ currency: Currency? = nil) -> String {
        let units: [(Double, String)] = [(1e12, "tri"), (1e9, "bi"), (1e6, "mi"), (1e3, "mil")]
        var text = grouped(value, fractionDigits: 0)
        for (threshold, name) in units where value >= threshold {
            let scaled = value / threshold
            let digits = scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2)
            text = "\(grouped(scaled, fractionDigits: digits, trimZeros: true)) \(name)"
            break
        }
        if let currency { return "\(currency.symbol)\(nbsp)\(text)" }
        return text
    }

    // MARK: Cripto

    enum CryptoStyle {
        /// Lista: ate 6 algarismos significativos, no maximo 8 casas.
        case list
        /// Revisao, envio e detalhe: precisao cheia ate as casas do token, limitada a 8.
        case full
        /// Stablecoin: 2 casas.
        case stable
    }

    /// Valor de token a partir do inteiro da rede, truncado para baixo.
    static func crypto(_ amount: BigUInt, decimals: Int, symbol: String? = nil, style: CryptoStyle = .list) -> String {
        let (whole, fraction) = split(amount, decimals: decimals)
        var fractionDigits: Int
        switch style {
        case .stable:
            fractionDigits = 2
        case .full:
            fractionDigits = min(decimals, 8)
        case .list:
            let wholeDigits = whole == "0" ? 0 : whole.count
            if wholeDigits >= 6 {
                fractionDigits = 0
            } else if wholeDigits > 0 {
                fractionDigits = min(6 - wholeDigits, 8)
            } else {
                // Abaixo de 1: 6 significativos contados a partir do primeiro nao zero.
                let leadingZeros = fraction.prefix { $0 == "0" }.count
                fractionDigits = min(leadingZeros + 6, 8)
            }
        }
        var fractionText = String(fraction.prefix(fractionDigits))
        if style != .stable {
            while fractionText.hasSuffix("0") { fractionText.removeLast() }
        }
        let isZeroShown = whole == "0" && fractionText.allSatisfy { $0 == "0" }
        var text: String
        if isZeroShown && !amount.isZero {
            text = "< 0," + String(repeating: "0", count: max(fractionDigits - 1, 0)) + "1"
        } else {
            text = groupedInteger(whole) + (fractionText.isEmpty ? "" : "," + fractionText)
        }
        if let symbol { text += " \(symbol)" }
        return text
    }

    /// Converte um inteiro da rede para `Double`, para multiplicar por preco. So para
    /// exibir em moeda local, nunca para montar transacao.
    static func double(_ amount: BigUInt, decimals: Int) -> Double {
        let (whole, fraction) = split(amount, decimals: decimals)
        return Double("\(whole).\(fraction.isEmpty ? "0" : String(fraction.prefix(18)))") ?? 0
    }

    /// Le o valor digitado ("1,5" ou "1.5") para o inteiro da rede, sem passar por
    /// ponto flutuante. Casas demais sao recusadas, nao arredondadas.
    static func parseAmount(_ text: String, decimals: Int) -> BigUInt? {
        let cleaned = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: ",")
        let parts = cleaned.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= decimals else { return nil }
        let digits = whole + fraction + String(repeating: "0", count: decimals - fraction.count)
        return BigUInt(decimal: String(digits.drop { $0 == "0" }).isEmpty ? "0" : String(digits.drop { $0 == "0" }))
    }

    /// O inteiro da rede em texto decimal simples ("0.5"), para os campos editaveis.
    static func plainDecimal(_ amount: BigUInt, decimals: Int) -> String {
        let (whole, fraction) = split(amount, decimals: decimals)
        var trimmed = fraction
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        return trimmed.isEmpty ? whole : "\(whole),\(trimmed)"
    }

    // MARK: Endereco e data

    /// "0x71C7…976F": 6 mais 4, com reticencia de verdade.
    static func address(_ text: String, head: Int = 6, tail: Int = 4) -> String {
        guard text.count > head + tail + 1 else { return text }
        return "\(text.prefix(head))…\(text.suffix(tail))"
    }

    /// "14:32", ou "ontem, 14:32" e "3 out, 14:32" quando nao e de hoje: a hora de um
    /// dado de mercado que ficou antigo.
    static func stamp(_ date: Date, now: Date = .now) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
        let calendar = Calendar(identifier: .gregorian)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInYesterday(date) { return "ontem, \(time)" }
        let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale)).replacingOccurrences(of: ".", with: "")
        return "\(day), \(time)"
    }

    /// "7 de mai de 2021".
    static func longDay(_ date: Date) -> String {
        let day = date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)).replacingOccurrences(of: ".", with: "")
        return day
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "agora" }
        if seconds < 3600 { return "há \(Int(seconds / 60)) min" }
        let calendar = Calendar(identifier: .gregorian)
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
        if calendar.isDateInToday(date) { return "Hoje, \(time)" }
        if calendar.isDateInYesterday(date) { return "Ontem, \(time)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale)).replacingOccurrences(of: ".", with: "")
        if !sameYear { day += " \(calendar.component(.year, from: date))" }
        return sameYear ? "\(day), \(time)" : day
    }

    // MARK: Interno

    private static func split(_ amount: BigUInt, decimals: Int) -> (String, String) {
        let digits = amount.decimalString
        guard decimals > 0 else { return (digits, "") }
        if digits.count <= decimals {
            return ("0", String(repeating: "0", count: decimals - digits.count) + digits)
        }
        let cut = digits.index(digits.endIndex, offsetBy: -decimals)
        return (String(digits[..<cut]), String(digits[cut...]))
    }

    private static func groupedInteger(_ digits: String) -> String {
        var out = ""
        for (index, c) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { out.append(".") }
            out.append(c)
        }
        return String(out.reversed())
    }

    static func grouped(_ value: Double, fractionDigits: Int, trimZeros: Bool = false) -> String {
        var style = FloatingPointFormatStyle<Double>.number.locale(locale)
            .grouping(.automatic)
            .rounded(rule: .toNearestOrAwayFromZero)
        style = trimZeros
            ? style.precision(.fractionLength(0...fractionDigits))
            : style.precision(.fractionLength(fractionDigits))
        return value.formatted(style)
    }

    private static func subscriptZeros(_ value: Double) -> String {
        // 0,00005234 vira 0,0₄5234: o subscrito conta os zeros depois da virgula.
        let text = String(format: "%.18f", value)
        guard let dot = text.firstIndex(of: ".") else { return text }
        let fraction = text[text.index(after: dot)...]
        let zeros = fraction.prefix { $0 == "0" }.count
        let significant = fraction.dropFirst(zeros).prefix(4)
        let subscripts = Array("₀₁₂₃₄₅₆₇₈₉")
        let sub = String(zeros).compactMap { $0.wholeNumberValue.map { subscripts[$0] } }
        return "0,0" + String(sub) + significant
    }
}
