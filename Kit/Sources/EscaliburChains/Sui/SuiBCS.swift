import EscaliburCore
import Foundation

// BCS (Binary Canonical Serialization), so o que a transacao da Sui usa: ULEB128 para
// tamanho e variante de enum, inteiros em little-endian, bytes com prefixo de tamanho e
// arrays fixos sem prefixo. Especificacao: github.com/diem/bcs (README, "Detailed
// specifications") e o `@mysten/bcs` do SDK oficial.
//
// A leitura e estrita: ULEB128 nao canonico (zeros a mais) ou acima de 2^32 - 1 e
// recusado, como no `bcs` de referencia. Duas grafias para os mesmos campos dariam dois
// digestos para a mesma transacao.

struct SuiBCSWriter {
    private(set) var bytes: [UInt8] = []

    mutating func uleb128(_ value: UInt64) {
        var rest = value
        repeat {
            let low = UInt8(rest & 0x7F)
            rest >>= 7
            bytes.append(rest == 0 ? low : low | 0x80)
        } while rest != 0
    }

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes += value.littleEndianByteArray }
    mutating func u64(_ value: UInt64) { bytes += value.littleEndianByteArray }
    /// Array de tamanho fixo (endereco, id de objeto): sem prefixo.
    mutating func fixed(_ value: [UInt8]) { bytes += value }
    /// `vector<u8>`: tamanho em ULEB128 e os bytes.
    mutating func vector(_ value: [UInt8]) {
        uleb128(UInt64(value.count))
        bytes += value
    }
}

struct SuiBCSReader {
    enum Failure: Error, Equatable {
        case truncated
        case nonCanonicalLength
        case trailingBytes
    }

    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, bytes.count - offset >= count else { throw Failure.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }

    mutating func u16() throws -> UInt16 {
        try take(2).enumerated().reduce(UInt16(0)) { $0 | UInt16($1.element) << (8 * UInt16($1.offset)) }
    }

    mutating func u64() throws -> UInt64 {
        try take(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    /// ULEB128 canonico, ate 2^32 - 1 (o limite do BCS para tamanhos e variantes).
    mutating func uleb128() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            let digit = UInt64(byte & 0x7F)
            // Um sexto grupo de 7 bits ja passaria de 32 bits.
            guard shift <= 28 else { throw Failure.nonCanonicalLength }
            value |= digit << shift
            if byte & 0x80 == 0 {
                // Zero a mais no fim (0x80 0x00) seria outra grafia do mesmo numero.
                guard byte != 0 || shift == 0 else { throw Failure.nonCanonicalLength }
                break
            }
            shift += 7
        }
        guard value <= UInt64(UInt32.max) else { throw Failure.nonCanonicalLength }
        return value
    }

    mutating func vector(max: Int) throws -> [UInt8] {
        let count = try uleb128()
        guard count <= UInt64(max) else { throw Failure.nonCanonicalLength }
        return try take(Int(count))
    }

    func finish() throws {
        guard isAtEnd else { throw Failure.trailingBytes }
    }
}
