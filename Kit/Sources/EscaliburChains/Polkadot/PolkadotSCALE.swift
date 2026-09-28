import EscaliburCore
import Foundation

/// O pedaco do SCALE (a codificacao do Substrate) que a transferencia de DOT usa:
/// inteiros little-endian, inteiros compactos e a era de uma transacao mortal.
///
/// Referencia: docs.substrate.io, "SCALE encoding" (tabela do `Compact`), e
/// `sp_runtime::generic::Era` (codificacao de dois bytes da era mortal). Os vetores dos
/// testes vem do wallet-core da Trust Wallet e do polkadot-js.
public enum PolkadotSCALE {
    public enum Failure: Error, Equatable, Sendable {
        case truncated
        /// Compacto fora da forma minima ou maior que o tipo: o mesmo numero teria duas
        /// escritas, e a carteira so aceita a canonica.
        case nonCanonical
        case trailingBytes
    }

    /// Inteiro compacto, na forma minima.
    public static func compact(_ value: BigUInt) -> [UInt8] {
        if let small = value.uint64, small < (1 << 30) {
            let v = UInt32(small)
            switch v {
            case 0..<(1 << 6): return [UInt8(v << 2)]
            case 0..<(1 << 14): return Array(UInt16(v << 2 | 0b01).littleEndianByteArray)
            default: return Array((v << 2 | 0b10).littleEndianByteArray)
            }
        }
        let bytes = Array(value.bigEndianBytes.reversed())
        return [UInt8((bytes.count - 4) << 2 | 0b11)] + bytes
    }

    public static func compact<T: UnsignedInteger>(_ value: T) -> [UInt8] { compact(BigUInt(value)) }

    /// Le o SCALE por dentro, sempre conferindo o tamanho.
    public struct Reader {
        public let bytes: [UInt8]
        public private(set) var offset = 0

        public init(_ bytes: [UInt8]) { self.bytes = bytes }

        public var remaining: Int { bytes.count - offset }

        public mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, remaining >= count else { throw Failure.truncated }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        public mutating func byte() throws -> UInt8 { try take(1)[0] }

        public mutating func uint32() throws -> UInt32 {
            try take(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }

        /// Um inteiro little-endian de `width` bytes (u128 = 16).
        public mutating func unsigned(width: Int) throws -> BigUInt {
            BigUInt(bigEndian: try take(width).reversed())
        }

        /// Inteiro compacto; recusa a forma nao minima.
        public mutating func compact() throws -> BigUInt {
            let first = try byte()
            let value: BigUInt
            switch first & 0b11 {
            case 0b00:
                return BigUInt(first >> 2)
            case 0b01:
                let v = (UInt32(first) | UInt32(try byte()) << 8) >> 2
                guard v >= (1 << 6) else { throw Failure.nonCanonical }
                return BigUInt(v)
            case 0b10:
                let rest = try take(3)
                let v = (UInt32(first) | UInt32(rest[0]) << 8 | UInt32(rest[1]) << 16 | UInt32(rest[2]) << 24) >> 2
                guard v >= (1 << 14) else { throw Failure.nonCanonical }
                return BigUInt(v)
            default:
                let count = Int(first >> 2) + 4
                let raw = try take(count)
                guard raw.last != 0 else { throw Failure.nonCanonical }
                value = BigUInt(bigEndian: raw.reversed())
                guard value >= BigUInt(1 << 30) else { throw Failure.nonCanonical }
                return value
            }
        }

        public func requireEnd() throws {
            guard remaining == 0 else { throw Failure.trailingBytes }
        }
    }
}

/// A era de uma transacao mortal: a transacao so vale de `birth` ate `birth + period - 1`.
///
/// `sp_runtime::generic::Era::mortal(period, current)`: o periodo sobe para a potencia de
/// dois seguinte (entre 4 e 65.536), a fase e `current % period`, quantizada em
/// `max(period >> 12, 1)`; a codificacao e `min(15, max(1, tz(period) - 1)) | (fase /
/// fator) << 4`, em dois bytes little-endian. Era imortal (um byte 0) a carteira nunca
/// monta: uma transacao sem prazo poderia entrar a qualquer hora.
public struct PolkadotEra: Equatable, Sendable {
    public let period: UInt64
    public let phase: UInt64

    public init(period requested: UInt64, current: UInt64) {
        var period: UInt64 = 4
        while period < requested && period < (1 << 16) { period <<= 1 }
        let factor = max(period >> 12, 1)
        self.period = period
        self.phase = (current % period) / factor * factor
    }

    init?(period: UInt64, phase: UInt64) {
        guard period >= 4, period <= (1 << 16), period & (period - 1) == 0, phase < period else { return nil }
        self.period = period
        self.phase = phase
    }

    /// O bloco cujo hash entra no que se assina (`CheckMortality`).
    public func birth(current: UInt64) -> UInt64 {
        (max(current, phase) - phase) / period * period + phase
    }

    /// O ultimo bloco em que a transacao ainda pode entrar.
    public func death(current: UInt64) -> UInt64 { birth(current: current) + period - 1 }

    public var encoded: [UInt8] {
        let factor = max(period >> 12, 1)
        let low = UInt64(min(15, max(1, period.trailingZeroBitCount - 1)))
        return Array(UInt16(low | (phase / factor) << 4).littleEndianByteArray)
    }

    /// Le dois bytes de era mortal. Imortal e recusada.
    public static func decode(_ reader: inout PolkadotSCALE.Reader) throws -> PolkadotEra {
        let first = try reader.byte()
        guard first != 0 else { throw PolkadotSCALE.Failure.nonCanonical }
        let encoded = UInt64(first) | UInt64(try reader.byte()) << 8
        let period = UInt64(2) << (encoded % (1 << 4))
        let factor = max(period >> 12, 1)
        guard let era = PolkadotEra(period: period, phase: (encoded >> 4) * factor), era.encoded == [first, UInt8(encoded >> 8)] else {
            throw PolkadotSCALE.Failure.nonCanonical
        }
        return era
    }
}
