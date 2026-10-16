import EscaliburChains
import EscaliburCore
import Foundation

/// Toda formatacao de numero, valor e data que o usuario le, num lugar so.
///
/// Regras (docs/design/sistema-visual.md): o formato da regiao do aparelho (no Brasil,
/// "R$ 1.234,56"), sempre com algarismos latinos, NBSP entre simbolo e numero, sinal de
/// menos U+2212 e nunca hifen ou travessao, cripto truncado para baixo (o "Max" nunca
/// passa do saldo real), abreviacao so em dado de mercado.
enum Fmt {
    /// A regiao do aparelho, lida uma vez ao abrir. Algarismos latinos em qualquer idioma:
    /// endereco, valor e PIN ficam nos mesmos algarismos que a rede e o papel usam.
    static let locale: Locale = {
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.numberingSystem = "latn"
        return Locale(components: components)
    }()
    static let minus = "\u{2212}"
    static let nbsp = "\u{00A0}"

    /// Separadores da sessao, os mesmos do texto que o Kit monta (`NumberStyle`).
    static var decimal: String { NumberStyle.current.decimal }

    /// Chamado uma vez, ao abrir o app.
    static func adoptRegion() {
        NumberStyle.adopt(NumberStyle(locale: locale))
    }

    /// Onde a regiao poe o simbolo da moeda: antes ("R$ 10,00", "$10.00") ou depois
    /// ("10,00 €").
    static let symbolFirst: Bool = {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        return (formatter.positiveFormat ?? "¤").trimmingCharacters(in: .whitespaces).hasPrefix("¤")
    }()

    /// Simbolo e numero na ordem da regiao, com NBSP entre os dois.
    static func money(_ body: String, symbol: String, sign: String = "") -> String {
        symbolFirst ? "\(sign)\(symbol)\(nbsp)\(body)" : "\(sign)\(body)\(nbsp)\(symbol)"
    }

    /// O simbolo de cada moeda como a regiao escreve: "US$" no Brasil, "$" nos EUA.
    static func currencySymbol(_ code: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.currencySymbol ?? code
    }

    fileprivate static let symbols: [String: String] = Dictionary(
        uniqueKeysWithValues: ["BRL", "USD", "EUR"].map { ($0, currencySymbol($0)) }
    )

    /// "cerca de 1 segundo", "cerca de 4 segundos": estimativa de espera.
    static func aboutSeconds(_ seconds: Double) -> String {
        let n = max(1, Int(seconds.rounded()))
        return n == 1 ? String(localized: "cerca de 1 segundo") : String(localized: "cerca de \(n) segundos")
    }

    /// Em que unidade o saldo total aparece: as duas moedas do app, o euro e o bitcoin.
    /// A conversao usa o preco do bitcoin em cada moeda, a mesma cotacao para todas.
    enum DisplayUnit: String, CaseIterable, Codable, Sendable {
        case brl, usd, eur, btc

        var symbol: String { self == .btc ? "₿" : fiat.symbol }

        var fractionDigits: Int { self == .btc ? 8 : 2 }

        var name: String {
            switch self {
            case .brl: return String(localized: "Real")
            case .usd: return String(localized: "Dólar")
            case .eur: return String(localized: "Euro")
            case .btc: return "Bitcoin"
            }
        }

        init(_ currency: Currency) {
            switch currency {
            case .brl: self = .brl
            case .usd: self = .usd
            case .eur: self = .eur
            }
        }

        /// A moeda em que os precos sao buscados e mostrados para esta unidade. Com o
        /// bitcoin, o dolar: o preco de cada moeda vem em dolar, e a pagina da moeda converte.
        var fiat: Currency {
            switch self {
            case .brl: return .brl
            case .usd, .btc: return .usd
            case .eur: return .eur
            }
        }
    }

    enum Currency: String, CaseIterable, Codable, Sendable {
        case brl = "BRL"
        case usd = "USD"
        case eur = "EUR"

        var symbol: String { Fmt.symbols[rawValue] ?? rawValue }

        var coingeckoID: String { rawValue.lowercased() }
    }

    // MARK: Fiat

    /// "R$ 1.234,56", "< R$ 0,01", "−R$ 12,30".
    static func fiat(_ value: Double, _ currency: Currency = .brl, signed: Bool = false) -> String {
        guard value.isFinite else { return money("0\(decimal)00", symbol: currency.symbol) }
        let magnitude = abs(value)
        if magnitude > 0, magnitude < 0.01 {
            return "< " + money("0\(decimal)01", symbol: currency.symbol)
        }
        let body = grouped(magnitude, fractionDigits: 2)
        let sign = value < 0 ? minus : (signed && value > 0 ? "+" : "")
        return money(body, symbol: currency.symbol, sign: sign)
    }

    /// Um valor na unidade escolhida no total da Carteira: R$, US$, € com centavos e
    /// "< R$ 0,01" abaixo disso; ₿ com ate 8 casas.
    static func value(_ value: Double, unit: DisplayUnit) -> String {
        guard value.isFinite else { return money("0", symbol: unit.symbol) }
        if unit == .btc {
            let magnitude = abs(value)
            if magnitude > 0, magnitude < 0.00000001 { return "< " + money("0\(decimal)00000001", symbol: unit.symbol) }
            return money(grouped(magnitude, fractionDigits: 8, trimZeros: true), symbol: unit.symbol, sign: value < 0 ? minus : "")
        }
        let magnitude = abs(value)
        if magnitude > 0, magnitude < 0.01 { return "< " + money("0\(decimal)01", symbol: unit.symbol) }
        return money(grouped(magnitude, fractionDigits: 2), symbol: unit.symbol, sign: value < 0 ? minus : "")
    }

    /// Preco unitario na unidade escolhida no total, com as casas pela faixa.
    static func price(_ value: Double, unit: DisplayUnit) -> String {
        guard unit != .btc else {
            guard value.isFinite, value > 0 else { return money("0", symbol: unit.symbol) }
            return money(value >= 0.00000001 ? grouped(value, fractionDigits: 8, trimZeros: true) : subscriptZeros(value), symbol: unit.symbol)
        }
        return priceBody(value, symbol: unit.symbol)
    }

    /// Preco unitario com casas pela faixa, e zeros em subscrito abaixo de 0,0001.
    static func price(_ value: Double, _ currency: Currency = .brl) -> String {
        priceBody(value, symbol: currency.symbol)
    }

    private static func priceBody(_ value: Double, symbol: String) -> String {
        guard value.isFinite, value > 0 else { return money("0\(decimal)00", symbol: symbol) }
        let body: String
        switch value {
        case 1...: body = grouped(value, fractionDigits: 2)
        case 0.01..<1: body = grouped(value, fractionDigits: 4)
        case 0.0001..<0.01: body = grouped(value, fractionDigits: 6)
        default: body = subscriptZeros(value)
        }
        return money(body, symbol: symbol)
    }

    /// "+2,31%". Zero sai sem sinal. A partir de 1.000%, sem casas.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0\(decimal)00%" }
        let rounded = (value * 100).rounded() / 100
        if rounded == 0 { return "0\(decimal)00%" }
        let sign = rounded > 0 ? "+" : minus
        let digits = abs(rounded) >= 1000 ? 0 : 2
        return "\(sign)\(grouped(abs(rounded), fractionDigits: digits))%"
    }

    /// "12,3 mil", "812 mi", "45,2 bi" no Brasil; "12.3K", "812M", "45.2B" nos EUA. So
    /// para capitalizacao, volume e liquidez.
    static func compact(_ value: Double, _ currency: Currency? = nil) -> String {
        var text = grouped(value, fractionDigits: 0)
        if value >= 1000 {
            text = value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(locale))
        }
        if let currency { return money(text, symbol: currency.symbol) }
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
            text = "< 0" + decimal + String(repeating: "0", count: max(fractionDigits - 1, 0)) + "1"
        } else {
            text = NumberStyle.current.decimal(groupedInteger(whole), fractionText)
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
    /// ponto flutuante. Casas demais sao recusadas, nao arredondadas. Onde a virgula separa
    /// milhar (ingles, japones), ela nao vale como decimal: "1,000" colado seria lido como 1.
    static func parseAmount(_ text: String, decimals: Int) -> BigUInt? {
        let raw = text.replacingOccurrences(of: " ", with: "")
        if decimal == ".", raw.contains(",") { return nil }
        let cleaned = raw.replacingOccurrences(of: ".", with: ",")
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
        return NumberStyle.current.decimal(whole, trimmed)
    }

    // MARK: Endereco e data

    /// "0x71C7A3…976F": o prefixo que a rede impoe inteiro, e 6 mais 4 do corpo, com
    /// reticencia de verdade. Os 6 do comeco sao do corpo: do texto inteiro, a Cardano
    /// mostrava "addr1q" e nenhum caractere que o atacante precisasse gerar, e o sosia
    /// que casava so os 4 do fim saia identico na Atividade (revisao dos enderecos
    /// parecidos, B-5). O corpo e o mesmo que `AddressPoisoning` compara.
    ///
    /// Sem a rede (texto que nao se sabe de onde e), 6 mais 4 do texto inteiro.
    static func address(_ text: String, chain: Chain? = nil, head: Int = 6, tail: Int = 4) -> String {
        guard let chain else {
            guard text.count > head + tail + 1 else { return text }
            return "\(text.prefix(head))…\(text.suffix(tail))"
        }
        let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = AddressPoisoning.bodySegment(shown, chain: chain)
        guard body.length > head + tail + 1 else { return shown }
        let characters = Array(shown)
        let end = body.start + body.length
        return String(characters[..<(body.start + head)]) + "…" + String(characters[(end - tail)...])
    }

    /// "14:32", ou "ontem, 14:32" e "3 out, 14:32" quando nao e de hoje: a hora de um
    /// dado de mercado que ficou antigo.
    static func stamp(_ date: Date, now: Date = .now) -> String {
        let time = clock(date)
        let calendar = Calendar(identifier: .gregorian)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInYesterday(date) { return String(localized: "ontem, \(time)") }
        return String(localized: "\(shortDay(date)), \(time)")
    }

    /// "7 de mai de 2021".
    static func longDay(_ date: Date) -> String {
        withoutAbbreviationDots(date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)))
    }

    /// `inSentence`: no meio de uma frase ("Valores de hoje, 14:32"), com as palavras
    /// na caixa que o idioma usa ali, em vez de baixar a caixa de tudo (o que estragaria
    /// "Oct" no ingles).
    static func relative(_ date: Date, now: Date = .now, inSentence: Bool = false) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "agora") }
        if seconds < 3600 { return String(localized: "há \(Int(seconds / 60)) min") }
        let calendar = Calendar(identifier: .gregorian)
        let time = clock(date)
        if calendar.isDateInToday(date) { return inSentence ? String(localized: "hoje, \(time)") : String(localized: "Hoje, \(time)") }
        if calendar.isDateInYesterday(date) { return inSentence ? String(localized: "ontem, \(time)") : String(localized: "Ontem, \(time)") }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        if !sameYear { return withoutAbbreviationDots(date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))) }
        return String(localized: "\(shortDay(date)), \(time)")
    }

    /// O nome do idioma de uma lista de palavras, como a regiao escreve ("inglês" no
    /// Brasil, "English" nos EUA).
    static func languageName(_ language: BIP39Language) -> String {
        let code: String
        switch language {
        case .english: code = "en"
        case .japanese: code = "ja"
        case .chineseSimplified: code = "zh-Hans"
        case .chineseTraditional: code = "zh-Hant"
        case .french: code = "fr"
        case .italian: code = "it"
        case .korean: code = "ko"
        case .spanish: code = "es"
        case .czech: code = "cs"
        case .portuguese: code = "pt"
        }
        return Locale(identifier: Bundle.main.preferredLocalizations.first ?? "pt-BR").localizedString(forIdentifier: code) ?? language.displayName
    }

    /// "14:32" no Brasil, "2:32 PM" nos EUA.
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// "3 out" no Brasil, "Oct 3" nos EUA.
    private static func shortDay(_ date: Date) -> String {
        withoutAbbreviationDots(date.formatted(.dateTime.day().month(.abbreviated).locale(locale)))
    }

    /// O portugues abrevia o mes com ponto ("out."); na tela fica sem. Em outros idiomas o
    /// ponto pode ser parte da data ("3. Okt."), e fica.
    private static func withoutAbbreviationDots(_ text: String) -> String {
        locale.language.languageCode == .portuguese ? text.replacingOccurrences(of: ".", with: "") : text
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
        NumberStyle.current.group(digits)
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

    /// O preco digitado com muitos zeros depois da virgula, resumido: "0,00000000001234"
    /// vira "0,0₁₀1234". Nil quando ha menos de 4 zeros (ja se le de relance).
    static func compactZeros(_ text: String) -> String? {
        let normalized = text.replacingOccurrences(of: ".", with: ",")
        let parts = normalized.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].allSatisfy({ $0 == "0" }), parts[1].allSatisfy(\.isNumber) else { return nil }
        let zeros = parts[1].prefix { $0 == "0" }.count
        let rest = parts[1].dropFirst(zeros)
        guard zeros >= 4, !rest.isEmpty else { return nil }
        let subscripts = Array("₀₁₂₃₄₅₆₇₈₉")
        let sub = String(zeros).compactMap { $0.wholeNumberValue.map { subscripts[$0] } }
        return "0\(decimal)0" + String(sub) + rest.prefix(8)
    }

    static func subscriptZeros(_ value: Double) -> String {
        // 0,00005234 vira 0,0₄5234: o subscrito conta os zeros depois da virgula. Pela
        // notacao cientifica, e nao por "%.18f": abaixo de 10^-18 as 18 casas sao todas
        // zero e o preco sumia (o BNB Frog Inu, perto de 4,8 x 10^-19, saia "0,0₁₈").
        guard value.isFinite, value > 0 else { return "0" }
        let parts = String(format: "%.3e", value).split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]), exponent < 0 else { return grouped(value, fractionDigits: 4) }
        let significant = parts[0].filter(\.isNumber)
        let zeros = -exponent - 1
        let subscripts = Array("₀₁₂₃₄₅₆₇₈₉")
        let sub = String(zeros).compactMap { $0.wholeNumberValue.map { subscripts[$0] } }
        return "0\(decimal)0" + String(sub) + significant
    }
}
