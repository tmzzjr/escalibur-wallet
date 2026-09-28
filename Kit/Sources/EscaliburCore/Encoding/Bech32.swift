import Foundation

/// Bech32 (BIP-173) e Bech32m (BIP-350), e os enderecos SegWit que eles carregam.
///
/// A regra que mais importa aqui e a do BIP-350: versao 0 so vale em Bech32, e
/// versao 1 em diante so vale em Bech32m. Aceitar um endereco v1 codificado em
/// Bech32 antigo e o bug que manda saldo para um script que ninguem consegue gastar.
public enum Bech32 {
    public enum Variant: Sendable {
        case bech32
        case bech32m

        var constant: UInt32 {
            switch self {
            case .bech32: return 1
            case .bech32m: return 0x2BC8_30A3
            }
        }
    }

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    private static let reverse: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (index, c) in charset.enumerated() { table[Int(c)] = Int8(index) }
        return table
    }()

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generator: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]
        var checksum: UInt32 = 1
        for value in values {
            let top = checksum >> 25
            checksum = (checksum & 0x1FF_FFFF) << 5 ^ UInt32(value)
            for i in 0..<5 where (top >> i) & 1 == 1 {
                checksum ^= generator[i]
            }
        }
        return checksum
    }

    private static func expand(_ hrp: [UInt8]) -> [UInt8] {
        hrp.map { $0 >> 5 } + [0] + hrp.map { $0 & 31 }
    }

    public static func encode(hrp: String, data: [UInt8], variant: Variant) -> String {
        let hrpBytes = Array(hrp.lowercased().utf8)
        let values = expand(hrpBytes) + data + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ variant.constant
        let checksum = (0..<6).map { UInt8((mod >> (5 * (5 - $0))) & 31) }
        let body = (data + checksum).map { charset[Int($0)] }
        return String(decoding: hrpBytes + [0x31] + body, as: UTF8.self)
    }

    public static func decode(_ text: String) -> (hrp: String, data: [UInt8], variant: Variant)? {
        decode(text, maxLength: 90)
    }

    /// O mesmo, com outro teto de tamanho. O BIP-173 limita a 90 caracteres; a Cardano
    /// (CIP-19) usa o mesmo checksum sem esse limite, e um endereco base tem 103.
    public static func decode(_ text: String, maxLength: Int) -> (hrp: String, data: [UInt8], variant: Variant)? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 8, bytes.count <= maxLength else { return nil }
        // Caixa mista e invalida por especificacao.
        let hasLower = bytes.contains { $0 >= 0x61 && $0 <= 0x7A }
        let hasUpper = bytes.contains { $0 >= 0x41 && $0 <= 0x5A }
        guard !(hasLower && hasUpper) else { return nil }
        let lowered = Array(text.lowercased().utf8)
        guard lowered.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { return nil }
        guard let separator = lowered.lastIndex(of: 0x31), separator >= 1, separator + 7 <= lowered.count else {
            return nil
        }
        let hrp = Array(lowered[..<separator])
        var data = [UInt8]()
        for c in lowered[(separator + 1)...] {
            guard c < 128, reverse[Int(c)] >= 0 else { return nil }
            data.append(UInt8(reverse[Int(c)]))
        }
        let check = polymod(expand(hrp) + data)
        let variant: Variant
        switch check {
        case Variant.bech32.constant: variant = .bech32
        case Variant.bech32m.constant: variant = .bech32m
        default: return nil
        }
        return (String(decoding: hrp, as: UTF8.self), Array(data.dropLast(6)), variant)
    }

    /// Reagrupa bits. `pad` e verdadeiro na ida (8 para 5) e falso na volta.
    public static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        var out = [UInt8]()
        let maxValue = (1 << to) - 1
        for value in data {
            guard Int(value) >> from == 0 else { return nil }
            accumulator = accumulator << from | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((accumulator >> bits) & maxValue))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((accumulator << (to - bits)) & maxValue)) }
        } else if bits >= from || (accumulator << (to - bits)) & maxValue != 0 {
            return nil
        }
        return out
    }

    // MARK: SegWit

    public static func segwitEncode(hrp: String, version: UInt8, program: [UInt8]) -> String? {
        guard version <= 16, let converted = convertBits(program, from: 8, to: 5, pad: true) else { return nil }
        let text = encode(hrp: hrp, data: [version] + converted, variant: version == 0 ? .bech32 : .bech32m)
        // Ida e volta: nunca devolver um endereco que o proprio decodificador recusa.
        guard let back = segwitDecode(hrp: hrp, address: text), back.version == version, back.program == program else {
            return nil
        }
        return text
    }

    public static func segwitDecode(hrp: String, address: String) -> (version: UInt8, program: [UInt8])? {
        guard let decoded = decode(address), decoded.hrp == hrp.lowercased(), let version = decoded.data.first,
              version <= 16,
              let program = convertBits(Array(decoded.data.dropFirst()), from: 5, to: 8, pad: false),
              program.count >= 2, program.count <= 40
        else { return nil }
        if version == 0 {
            guard decoded.variant == .bech32, program.count == 20 || program.count == 32 else { return nil }
        } else {
            guard decoded.variant == .bech32m else { return nil }
        }
        return (version, program)
    }
}
