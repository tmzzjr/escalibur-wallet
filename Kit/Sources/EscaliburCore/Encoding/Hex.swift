import Foundation

/// Hexadecimal sem surpresa: minusculas na saida, prefixo `0x` opcional na entrada,
/// e recusa explicita de qualquer coisa que nao seja par de digitos.
///
/// Aceitar hex "quase certo" (numero impar de digitos, espaco no meio) e como
/// endereco e calldata chegam truncados sem ninguem notar.
public enum Hex {
    public static func encode<S: Sequence>(_ bytes: S, prefix: Bool = false) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        if prefix { out.append(contentsOf: [0x30, 0x78]) }
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ text: String) -> [UInt8]? {
        var utf8 = Array(text.utf8)
        if utf8.count >= 2, utf8[0] == 0x30, utf8[1] == 0x78 || utf8[1] == 0x58 {
            utf8.removeFirst(2)
        }
        guard utf8.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

public extension Array where Element == UInt8 {
    init?(hex: String) {
        guard let bytes = Hex.decode(hex) else { return nil }
        self = bytes
    }

    var hex: String { Hex.encode(self) }
}

public extension Data {
    var hex: String { Hex.encode(self) }
}

extension FixedWidthInteger {
    /// Os bytes do inteiro em big-endian, do tamanho do tipo.
    var bigEndianByteArray: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }

    /// Os bytes do inteiro em little-endian, do tamanho do tipo.
    var littleEndianByteArray: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}
