import Foundation

/// Base32 RFC 4648 sem padding, e o CRC16-XModem que a StrKey do Stellar anexa.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    public static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = buffer << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ text: String) -> [UInt8]? {
        var out = [UInt8]()
        var buffer = 0
        var bits = 0
        for c in text.utf8 {
            let value: Int
            switch c {
            case 0x41...0x5A: value = Int(c - 0x41)
            case 0x32...0x37: value = Int(c - 0x32) + 26
            default: return nil
            }
            buffer = buffer << 5 | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        // Os bits que sobram precisam ser zero: senao ha duas grafias para o mesmo
        // valor, e a StrKey exige forma canonica.
        guard bits < 5, buffer & ((1 << bits) - 1) == 0 else { return nil }
        return out
    }
}

public enum CRC16 {
    /// CRC16-XModem (polinomio 0x1021, inicial 0), little-endian na StrKey.
    public static func xmodem(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
