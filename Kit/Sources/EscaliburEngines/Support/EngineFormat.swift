import EscaliburCore
import Foundation

/// Numeros para as notas que o motor escreve (reserva, taxa, bloco): virgula decimal e
/// ponto de milhar, sem arredondar e sem ponto flutuante.
enum EngineFormat {
    /// `units` na menor unidade, com `decimals` casas: 123456789 e 8 casas viram "1,23456789".
    static func amount(_ units: BigUInt, decimals: Int, symbol: String) -> String {
        "\(decimal(units, decimals: decimals)) \(symbol)"
    }

    static func decimal(_ units: BigUInt, decimals: Int) -> String {
        let digits = units.decimalString
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let cut = padded.index(padded.endIndex, offsetBy: -decimals)
        var fraction = String(padded[cut...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let whole = grouped(String(padded[..<cut]))
        return fraction.isEmpty ? whole : "\(whole),\(fraction)"
    }

    /// 107244179 vira "107.244.179".
    static func grouped<T: BinaryInteger>(_ value: T) -> String { grouped(String(value)) }

    private static func grouped(_ digits: String) -> String {
        var out = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { out.append(".") }
            out.append(character)
        }
        return String(out.reversed())
    }
}
