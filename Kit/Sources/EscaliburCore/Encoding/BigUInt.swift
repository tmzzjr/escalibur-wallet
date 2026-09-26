import Foundation

/// Inteiro sem sinal de precisao arbitraria, para valores de token.
///
/// Dinheiro em cripto e inteiro: wei, satoshi, lamport, drop, stroop. Um `Double`
/// perde o ultimo digito de um saldo de 18 casas a partir de 9 mil unidades, e um
/// `Decimal` do Foundation para em 38 digitos, abaixo do teto de um uint256 que
/// aparece em toda approval. Este tipo cobre os dois casos e mais nada: soma,
/// subtracao que recusa ficar negativa, multiplicacao, divisao, e conversao exata
/// de e para texto decimal.
///
/// Limbs de 32 bits em little-endian, sem zeros a esquerda. Desempenho nao e o
/// objetivo: os numeros daqui tem no maximo 256 bits.
public struct BigUInt: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Limbs em little-endian. Vazio significa zero.
    public private(set) var limbs: [UInt32]

    public init() { limbs = [] }

    public init<T: BinaryInteger>(_ value: T) {
        precondition(value >= 0, "BigUInt nao representa negativos")
        var v = UInt64(value)
        var out = [UInt32]()
        while v > 0 {
            out.append(UInt32(truncatingIfNeeded: v))
            v >>= 32
        }
        limbs = out
    }

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    /// Bytes em big-endian, de qualquer tamanho.
    public init<S: Sequence>(bigEndian bytes: S) where S.Element == UInt8 {
        var out = [UInt32]()
        var current: UInt32 = 0
        var shift: UInt32 = 0
        for byte in Array(bytes).reversed() {
            current |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                out.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 { out.append(current) }
        self.init(limbs: out)
    }

    /// Texto decimal estrito: so digitos, sem sinal, sem espaco.
    public init?(decimal text: String) {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        var value = BigUInt()
        for c in text.utf8 {
            value = value.multiplied(bySmall: 10).adding(small: UInt32(c - 0x30))
        }
        self = value
    }

    /// Texto hexadecimal, com ou sem `0x`. Aceita numero impar de digitos, porque e
    /// assim que o JSON-RPC devolve quantidades (`0x1`).
    public init?(hex text: String) {
        var body = Substring(text)
        if body.hasPrefix("0x") || body.hasPrefix("0X") { body = body.dropFirst(2) }
        guard !body.isEmpty else { return nil }
        let padded = body.count % 2 == 1 ? "0" + body : String(body)
        guard let bytes = Hex.decode(padded) else { return nil }
        self.init(bigEndian: bytes)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    public var isZero: Bool { limbs.isEmpty }

    public var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    /// O valor cabe em 64 bits?
    public var uint64: UInt64? {
        switch limbs.count {
        case 0: return 0
        case 1: return UInt64(limbs[0])
        case 2: return UInt64(limbs[0]) | UInt64(limbs[1]) << 32
        default: return nil
        }
    }

    // MARK: Serializacao

    /// Big-endian minimo. Zero vira array vazio, que e o que o RLP espera.
    public var bigEndianBytes: [UInt8] {
        var out = [UInt8]()
        for limb in limbs.reversed() {
            out.append(contentsOf: limb.bigEndianByteArray)
        }
        while let first = out.first, first == 0 { out.removeFirst() }
        return out
    }

    /// Big-endian com zeros a esquerda ate `width` bytes. Estourar e erro de programa.
    public func bigEndianBytes(padTo width: Int) -> [UInt8]? {
        let raw = bigEndianBytes
        guard raw.count <= width else { return nil }
        return [UInt8](repeating: 0, count: width - raw.count) + raw
    }

    public var hexString: String {
        let raw = bigEndianBytes
        guard !raw.isEmpty else { return "0x0" }
        var text = Hex.encode(raw)
        while text.hasPrefix("0") && text.count > 1 { text.removeFirst() }
        return "0x" + text
    }

    public var description: String { decimalString }

    public var decimalString: String {
        guard !isZero else { return "0" }
        var digits = [UInt8]()
        var value = self
        // Nove digitos por vez: 10^9 cabe em UInt32.
        while !value.isZero {
            let (quotient, remainder) = value.divided(bySmall: 1_000_000_000)
            var chunk = remainder
            for _ in 0..<9 {
                digits.append(UInt8(chunk % 10) + 0x30)
                chunk /= 10
            }
            value = quotient
        }
        while digits.count > 1, digits.last == 0x30 { digits.removeLast() }
        return String(decoding: digits.reversed(), as: UTF8.self)
    }

    // MARK: Aritmetica

    public static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out = [UInt32]()
        out.reserveCapacity(max(a.limbs.count, b.limbs.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<max(a.limbs.count, b.limbs.count) {
            let sum = UInt64(i < a.limbs.count ? a.limbs[i] : 0)
                + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            out.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry > 0 { out.append(UInt32(carry)) }
        return BigUInt(limbs: out)
    }

    /// Subtracao que devolve `nil` em vez de dar a volta. Saldo menos custo que da
    /// negativo e uma condicao que a interface precisa ver, nao um numero enorme.
    public func subtractingReportingUnderflow(_ other: BigUInt) -> BigUInt? {
        guard self >= other else { return nil }
        var out = [UInt32]()
        var borrow: Int64 = 0
        for i in 0..<limbs.count {
            var diff = Int64(limbs[i]) - Int64(i < other.limbs.count ? other.limbs[i] : 0) - borrow
            if diff < 0 {
                diff += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            out.append(UInt32(diff))
        }
        return BigUInt(limbs: out)
    }

    public static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        guard let result = a.subtractingReportingUnderflow(b) else {
            preconditionFailure("BigUInt: subtracao negativa")
        }
        return result
    }

    public static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        guard !a.isZero, !b.isZero else { return BigUInt() }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let t = ai * UInt64(b.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            out[i + b.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: out)
    }

    func multiplied(bySmall factor: UInt32) -> BigUInt {
        guard factor != 0, !isZero else { return BigUInt() }
        var out = [UInt32]()
        var carry: UInt64 = 0
        for limb in limbs {
            let t = UInt64(limb) * UInt64(factor) + carry
            out.append(UInt32(truncatingIfNeeded: t))
            carry = t >> 32
        }
        if carry > 0 { out.append(UInt32(carry)) }
        return BigUInt(limbs: out)
    }

    func adding(small value: UInt32) -> BigUInt {
        self + BigUInt(value)
    }

    func divided(bySmall divisor: UInt32) -> (BigUInt, UInt32) {
        precondition(divisor != 0)
        var out = [UInt32](repeating: 0, count: limbs.count)
        var remainder: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let current = remainder << 32 | UInt64(limbs[i])
            out[i] = UInt32(current / UInt64(divisor))
            remainder = current % UInt64(divisor)
        }
        return (BigUInt(limbs: out), UInt32(remainder))
    }

    /// Divisao longa binaria. Para 256 bits sao 256 passos de deslocar e subtrair,
    /// que e mais legivel que o algoritmo D de Knuth e rapido o bastante aqui.
    public func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "BigUInt: divisao por zero")
        if self < divisor { return (BigUInt(), self) }
        if let small = divisor.uint64, small <= UInt64(UInt32.max) {
            let (q, r) = divided(bySmall: UInt32(small))
            return (q, BigUInt(r))
        }
        var quotient = [UInt32](repeating: 0, count: limbs.count)
        var remainder = BigUInt()
        for bit in stride(from: bitWidth - 1, through: 0, by: -1) {
            remainder = remainder.shiftedLeft(by: 1)
            if (limbs[bit / 32] >> (bit % 32)) & 1 == 1 {
                remainder = remainder + BigUInt(1)
            }
            if remainder >= divisor {
                remainder = remainder - divisor
                quotient[bit / 32] |= 1 << (bit % 32)
            }
        }
        return (BigUInt(limbs: quotient), remainder)
    }

    public static func / (a: BigUInt, b: BigUInt) -> BigUInt { a.quotientAndRemainder(dividingBy: b).quotient }
    public static func % (a: BigUInt, b: BigUInt) -> BigUInt { a.quotientAndRemainder(dividingBy: b).remainder }

    public func shiftedLeft(by bits: Int) -> BigUInt {
        guard !isZero, bits > 0 else { return self }
        let limbShift = bits / 32
        let bitShift = bits % 32
        var out = [UInt32](repeating: 0, count: limbShift)
        var carry: UInt32 = 0
        for limb in limbs {
            if bitShift == 0 {
                out.append(limb)
            } else {
                out.append(limb << bitShift | carry)
                carry = limb >> (32 - bitShift)
            }
        }
        if carry > 0 { out.append(carry) }
        return BigUInt(limbs: out)
    }

    public static func power(of base: UInt32, _ exponent: Int) -> BigUInt {
        var result = BigUInt(1)
        for _ in 0..<exponent { result = result.multiplied(bySmall: base) }
        return result
    }

    public static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    /// 2^256 - 1, o valor que uma approval "ilimitada" pede.
    public static let uint256Max = BigUInt(bigEndian: [UInt8](repeating: 0xFF, count: 32))
}

extension BigUInt: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) { self.init(value) }
}

extension BigUInt: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = BigUInt(decimal: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "BigUInt invalido"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(decimalString)
    }
}
