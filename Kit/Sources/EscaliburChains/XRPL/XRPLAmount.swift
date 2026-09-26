import EscaliburCore
import Foundation

/// Um valor do XRP Ledger: XRP em drops, ou um token emitido (moeda + emissor).
///
/// Referencia do formato: xrpl.org "Binary Format", secao Amount Fields, e
/// ripple-binary-codec src/types/amount.ts.
public enum XRPLAmount: Sendable, Hashable {
    case xrp(drops: BigUInt)
    case issued(XRPLIssuedAmount)

    /// O teto do XRP: 100 bilhoes de XRP, 10^17 drops. Acima disso o rippled recusa.
    public static let maxDrops = BigUInt(100_000_000_000) * BigUInt(1_000_000)

    public var isZero: Bool {
        switch self {
        case .xrp(let drops): return drops.isZero
        case .issued(let issued): return issued.value.isZero
        }
    }

    public var isXRP: Bool {
        if case .xrp = self { return true }
        return false
    }

    /// 8 bytes para XRP; 48 (valor, moeda, emissor) para token.
    public func serialized() throws -> [UInt8] {
        switch self {
        case .xrp(let drops):
            // Bit 63 zerado (nao e token), bit 62 ligado (positivo), 62 bits de drops.
            guard drops <= Self.maxDrops, let raw = drops.uint64 else {
                throw XRPLCodecError.invalidAmount(drops.decimalString)
            }
            return (0x4000_0000_0000_0000 | raw).bigEndianByteArray
        case .issued(let issued):
            return issued.value.serializedValue.bigEndianByteArray + issued.currency.bytes + issued.issuer
        }
    }

    /// Le um Amount do JSON do rippled: texto de drops, ou `{currency, issuer, value}`.
    ///
    /// Leitura, nao construcao: aceita qualquer moeda que o ledger aceite, inclusive as
    /// que a carteira nunca montaria (ver `XRPLCurrency.init(ledgerCode:)`). MPT e
    /// recusado, porque a carteira ainda nao mostra esse tipo de ativo.
    public static func fromJSON(_ any: Any) throws -> XRPLAmount {
        if let text = any as? String {
            guard !text.isEmpty, text.count <= 18, let drops = BigUInt(decimal: text), drops <= maxDrops else {
                throw XRPLCodecError.invalidAmount(text)
            }
            return .xrp(drops: drops)
        }
        guard let object = any as? [String: Any],
              let currencyText = object["currency"] as? String,
              let issuerText = object["issuer"] as? String,
              let valueText = object["value"] as? String,
              object["mpt_issuance_id"] == nil
        else { throw XRPLCodecError.invalidAmount("\(any)") }
        let currency = try XRPLCurrency(ledgerCode: currencyText)
        return .issued(try XRPLIssuedAmount(value: XRPLDecimal(valueText), currency: currency, issuer: issuerText))
    }
}

/// Um valor de token: quanto, de que moeda, emitido por quem.
///
/// O emissor e parte da identidade do ativo. "USD" de um emissor e "USD" de outro sao
/// ativos diferentes, e qualquer conta pode emitir um "USD": e o golpe do emissor falso.
public struct XRPLIssuedAmount: Sendable, Hashable {
    public let value: XRPLDecimal
    public let currency: XRPLCurrency
    /// Os 20 bytes da conta emissora.
    public let issuer: [UInt8]

    public init(value: XRPLDecimal, currency: XRPLCurrency, issuer: String) throws {
        guard let account = XRPLAddress.accountID(issuer) else { throw XRPLCodecError.invalidAccount(issuer) }
        self.value = value
        self.currency = currency
        self.issuer = account
    }

    public var issuerAddress: String { XRPLAddress.classic(accountID: issuer) ?? "" }
}

/// O numero decimal de um token: mantissa de 16 digitos e expoente de base 10.
///
/// Normalizado como o rippled: mantissa em [10^15, 10^16) e expoente em [-96, 80], ou
/// zero. Mais de 16 digitos significativos e recusado, em vez de arredondado: um valor
/// arredondado em silencio e um valor diferente do que a tela mostrou.
public struct XRPLDecimal: Sendable, Hashable, CustomStringConvertible {
    public static let minExponent = -96
    public static let maxExponent = 80
    /// 0, ou um valor em [10^15, 10^16).
    public let mantissa: UInt64
    public let exponent: Int
    public let isNegative: Bool

    /// Le "4.2", "-1", "0.00012", "1e-7", "123.000". Sem espaco, sem separador de milhar.
    public init(_ text: String) throws {
        // Um texto de milhares de digitos so serve para gastar CPU; o maior valor
        // valido tem 16 digitos com ate ~100 zeros de cada lado.
        guard !text.isEmpty, text.utf8.count <= 256 else { throw XRPLCodecError.invalidAmount(text) }
        var chars = Array(text.utf8)
        var negative = false
        if chars.first == UInt8(ascii: "-") {
            negative = true
            chars.removeFirst()
        }

        var mantissaPart = chars
        var exponentValue = 0
        if let e = chars.firstIndex(where: { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }) {
            mantissaPart = Array(chars[..<e])
            var expChars = Array(chars[(e + 1)...])
            var expNegative = false
            if let first = expChars.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") {
                expNegative = first == UInt8(ascii: "-")
                expChars.removeFirst()
            }
            guard !expChars.isEmpty, expChars.count <= 4, expChars.allSatisfy(Self.isDigit) else {
                throw XRPLCodecError.invalidAmount(text)
            }
            exponentValue = Int(String(decoding: expChars, as: UTF8.self))! * (expNegative ? -1 : 1)
        }

        var digits = [UInt8]()
        var fractionDigits = 0
        var seenPoint = false
        for c in mantissaPart {
            if c == UInt8(ascii: ".") {
                guard !seenPoint else { throw XRPLCodecError.invalidAmount(text) }
                seenPoint = true
            } else if Self.isDigit(c) {
                digits.append(c - 0x30)
                if seenPoint { fractionDigits += 1 }
            } else {
                throw XRPLCodecError.invalidAmount(text)
            }
        }
        guard !digits.isEmpty else { throw XRPLCodecError.invalidAmount(text) }

        var exponent = exponentValue - fractionDigits
        while let first = digits.first, first == 0 { digits.removeFirst() }
        guard !digits.isEmpty else {
            self.mantissa = 0
            self.exponent = 0
            self.isNegative = false
            return
        }
        while let last = digits.last, last == 0 {
            digits.removeLast()
            exponent += 1
        }
        guard digits.count <= 16 else { throw XRPLCodecError.invalidAmount(text) }

        var mantissa: UInt64 = 0
        for d in digits { mantissa = mantissa * 10 + UInt64(d) }
        for _ in digits.count..<16 {
            mantissa *= 10
            exponent -= 1
        }
        guard (Self.minExponent...Self.maxExponent).contains(exponent) else { throw XRPLCodecError.invalidAmount(text) }
        self.mantissa = mantissa
        self.exponent = exponent
        self.isNegative = negative
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    public var isZero: Bool { mantissa == 0 }

    /// Os 8 bytes do valor: bit 63 ligado (token), bit 62 = positivo, 8 bits de
    /// expoente + 97, 54 bits de mantissa. Zero e 0x8000000000000000, sem bit de sinal.
    var serializedValue: UInt64 {
        guard mantissa != 0 else { return 0x8000_0000_0000_0000 }
        var raw: UInt64 = 0x8000_0000_0000_0000 | mantissa
        if !isNegative { raw |= 0x4000_0000_0000_0000 }
        raw |= UInt64(exponent + 97) << 54
        return raw
    }

    /// O valor em texto decimal simples, com ponto: "4.2", "0.00012", "-1".
    public var decimalString: String {
        guard mantissa != 0 else { return "0" }
        var m = mantissa
        var e = exponent
        while m % 10 == 0 {
            m /= 10
            e += 1
        }
        let digits = String(m)
        var text: String
        if e >= 0 {
            text = digits + String(repeating: "0", count: e)
        } else if digits.count > -e {
            let split = digits.index(digits.endIndex, offsetBy: e)
            text = String(digits[..<split]) + "." + String(digits[split...])
        } else {
            text = "0." + String(repeating: "0", count: -e - digits.count) + digits
        }
        return (isNegative ? "-" : "") + text
    }

    public var description: String { decimalString }
}

/// O codigo de moeda de um token: 3 caracteres no formato padrao, ou 160 bits.
public struct XRPLCurrency: Sendable, Hashable {
    /// Os 20 bytes que vao na serializacao.
    public let bytes: [UInt8]

    /// Os caracteres que o rippled aceita num codigo de 3 letras (isoCharSet em
    /// src/libxrpl/protocol/UintTypes.cpp).
    static let isoCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789<>(){}[]|?!@#$%^&*".utf8
    )

    /// Codigo para montar transacao: "USD", ou 40 digitos hex ("534F4C4F0000...").
    ///
    /// Recusa "XRP" em qualquer caixa e o codigo todo zero. O ledger aceita "xrp"
    /// minusculo como token, e e exatamente o que um golpista emitiria para aparecer
    /// ao lado do XRP de verdade. Hex que comeca com 0x00 so vale no formato padrao.
    public init(code: String) throws {
        let candidate = try XRPLCurrency(ledgerCode: code)
        if let iso = candidate.isoCode, iso.uppercased() == "XRP" {
            throw XRPLCodecError.invalidCurrency(code)
        }
        if candidate.bytes[0] == 0x00, candidate.isoCode == nil {
            throw XRPLCodecError.invalidCurrency(code)
        }
        self = candidate
    }

    /// Codigo como o ledger aceita, para leitura. So recusa o que nao e moeda nenhuma:
    /// o todo zero (que e o XRP) e o "XRP" maiusculo no formato padrao.
    init(ledgerCode code: String) throws {
        if code.utf8.count == 3 {
            let chars = Array(code.utf8)
            guard chars.allSatisfy(Self.isoCharacters.contains), code != "XRP" else {
                throw XRPLCodecError.invalidCurrency(code)
            }
            bytes = [UInt8](repeating: 0, count: 12) + chars + [UInt8](repeating: 0, count: 5)
            return
        }
        guard code.utf8.count == 40, let raw = Hex.decode(code), raw.count == 20 else {
            throw XRPLCodecError.invalidCurrency(code)
        }
        guard raw.contains(where: { $0 != 0 }) else { throw XRPLCodecError.invalidCurrency(code) }
        if Self.standardISO(raw) == "XRP" { throw XRPLCodecError.invalidCurrency(code) }
        bytes = raw
    }

    /// O codigo de 3 caracteres, se estiver no formato padrao (12 zeros, 3 ASCII, 5 zeros).
    public var isoCode: String? { Self.standardISO(bytes) }

    private static func standardISO(_ raw: [UInt8]) -> String? {
        guard raw.count == 20, raw[0..<12].allSatisfy({ $0 == 0 }), raw[15..<20].allSatisfy({ $0 == 0 }) else {
            return nil
        }
        let chars = Array(raw[12..<15])
        guard chars.allSatisfy(isoCharacters.contains) else { return nil }
        return String(decoding: chars, as: UTF8.self)
    }

    /// Como mostrar: o codigo de 3 letras, ou o texto ASCII de um codigo de 160 bits
    /// ("SOLO"), ou o hex quando nao ha texto legivel.
    public var displayCode: String {
        if let iso = isoCode { return iso }
        var trimmed = bytes
        while let last = trimmed.last, last == 0 { trimmed.removeLast() }
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) {
            return String(decoding: trimmed, as: UTF8.self)
        }
        return XRPLBinary.hexUpper(bytes)
    }

    /// O codigo como o JSON do rippled escreve: 3 letras ou 40 hex maiusculos.
    public var code: String { isoCode ?? XRPLBinary.hexUpper(bytes) }
}
