import EscaliburCore
import Foundation

/// Um numero decimal exato, como o dono digita ou o oraculo devolve: `mantissa / 10^scale`.
/// Serve ao preco-alvo da ordem limite e ao preco de oraculo; nunca passa por `Double`.
public struct TradeDecimal: Sendable, Equatable {
    public let mantissa: BigUInt
    public let scale: Int

    /// Aceita digitos com um separador decimal, virgula ou ponto (`3000`, `3000,5`,
    /// `0.00042`). Recusa sinal, expoente, separador de milhar e mais de 36 casas.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        var integer = ""
        var fraction = ""
        var seenSeparator = false
        for character in trimmed {
            if character == "," || character == "." {
                guard !seenSeparator else { return nil }
                seenSeparator = true
            } else if character.isASCII, character.isNumber {
                if seenSeparator { fraction.append(character) } else { integer.append(character) }
            } else {
                return nil
            }
        }
        guard !(integer.isEmpty && fraction.isEmpty), fraction.count <= 36 else { return nil }
        guard let mantissa = BigUInt(decimal: (integer.isEmpty ? "0" : integer) + fraction) else { return nil }
        self.mantissa = mantissa
        self.scale = fraction.count
    }

    public init(mantissa: BigUInt, scale: Int) {
        self.mantissa = mantissa
        self.scale = scale
    }

    public var isZero: Bool { mantissa.isZero }
}

/// Texto da revisao da troca. Valores exatos pelo `EVMText`; preco e percentual com
/// casas limitadas e o sinal "≈" quando arredondam.
enum TradeText {
    static func amount(_ value: BigUInt, _ asset: TradeAsset) -> String {
        EVMText.amount(value, decimals: asset.decimals, symbol: asset.symbol)
    }

    /// `50` bps -> "0,5%".
    static func percent(bps: Int) -> String {
        let negative = bps < 0
        let magnitude = abs(bps)
        let integer = magnitude / 100
        var fraction = String(format: "%02d", magnitude % 100)
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return (negative ? "-" : "") + (fraction.isEmpty ? "\(integer)%" : "\(integer),\(fraction)%")
    }

    static func percent(bps: UInt32) -> String { percent(bps: Int(bps)) }

    /// Numero com as casas cortadas: guarda 2 casas, ou 4 algarismos significativos
    /// quando o numero e menor que 1. Corta, nunca arredonda para cima.
    static func approximate(_ value: BigUInt, decimals: Int) -> (text: String, exact: Bool) {
        let full = EVMText.number(value, decimals: decimals)
        guard let comma = full.firstIndex(of: ",") else { return (full, true) }
        let integerPart = full[..<comma]
        let fraction = Array(full[full.index(after: comma)...])
        let leadingZeros = integerPart == "0" ? fraction.prefix { $0 == "0" }.count : 0
        let keep = integerPart == "0" ? leadingZeros + 4 : 2
        guard fraction.count > keep else { return (full, true) }
        var cut = Array(fraction.prefix(keep))
        while cut.last == "0" { cut.removeLast() }
        return (cut.isEmpty ? String(integerPart) : String(integerPart) + "," + String(cut), false)
    }

    /// "1 ETH ≈ 2.692,43 USDC": quanto do vendido custa uma unidade inteira do comprado,
    /// pela troca `amountIn -> out`.
    static func price(amountIn: BigUInt, out: BigUInt, sell: TradeAsset, buy: TradeAsset) -> String {
        guard !out.isZero else { return "-" }
        let perUnit = amountIn * BigUInt.power(of: 10, buy.decimals) / out
        let (text, exact) = approximate(perUnit, decimals: sell.decimals)
        return "1\u{00A0}\(buy.symbol) \(exact ? "=" : "≈") \(text)\u{00A0}\(sell.symbol)"
    }

    static func shortAddress(_ address: EVMAddress) -> String {
        let text = address.checksummed
        return String(text.prefix(6)) + "…" + String(text.suffix(4))
    }
}
