import Foundation

/// CBOR (RFC 8949), so o que a transacao da Cardano usa: inteiros sem sinal, bytes,
/// listas, mapas, tags e os simples `true`, `false` e `null`.
///
/// A escrita e sempre a forma canonica (cabecalho mais curto, comprimento definido), a
/// mesma do cardano-serialization-lib. A leitura e estrita: comprimento indefinido,
/// cabecalho mais longo que o necessario, texto, negativo, ponto flutuante e sobra de
/// bytes sao recusados. Assim, ler e escrever de novo devolve os mesmos bytes, e o hash
/// do corpo calculado aqui e o do corpo que vai para a rede.
indirect enum CBOR: Equatable, Sendable {
    case unsigned(UInt64)
    case bytes([UInt8])
    case array([CBOR])
    case map([Pair])
    case tag(UInt64, CBOR)
    case bool(Bool)
    case null

    struct Pair: Equatable, Sendable {
        let key: CBOR
        let value: CBOR
    }

    enum DecodingError: Error, Equatable {
        case truncated
        case unsupported
        case nonCanonical
        case trailingBytes
        case tooDeep
    }

    // MARK: Escrita

    var encoded: [UInt8] {
        var out: [UInt8] = []
        write(into: &out)
        return out
    }

    func write(into out: inout [UInt8]) {
        switch self {
        case .unsigned(let value):
            Self.head(0, value, into: &out)
        case .bytes(let bytes):
            Self.head(2, UInt64(bytes.count), into: &out)
            out += bytes
        case .array(let items):
            Self.head(4, UInt64(items.count), into: &out)
            for item in items { item.write(into: &out) }
        case .map(let pairs):
            Self.head(5, UInt64(pairs.count), into: &out)
            for pair in pairs {
                pair.key.write(into: &out)
                pair.value.write(into: &out)
            }
        case .tag(let tag, let value):
            Self.head(6, tag, into: &out)
            value.write(into: &out)
        case .bool(let value):
            out.append(value ? 0xF5 : 0xF4)
        case .null:
            out.append(0xF6)
        }
    }

    static func head(_ major: UInt8, _ value: UInt64, into out: inout [UInt8]) {
        let top = major << 5
        switch value {
        case 0..<24:
            out.append(top | UInt8(value))
        case 24...0xFF:
            out += [top | 24, UInt8(value)]
        case 0x100...0xFFFF:
            out += [top | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
        case 0x1_0000...0xFFFF_FFFF:
            out.append(top | 26)
            out += (0..<4).map { UInt8((value >> (24 - 8 * UInt64($0))) & 0xFF) }
        default:
            out.append(top | 27)
            out += (0..<8).map { UInt8((value >> (56 - 8 * UInt64($0))) & 0xFF) }
        }
    }

    // MARK: Leitura

    /// Le exatamente um item que ocupa todos os bytes.
    static func decode(_ bytes: [UInt8]) throws -> CBOR {
        var reader = Reader(bytes: bytes)
        let value = try reader.item(depth: 0)
        guard reader.offset == bytes.count else { throw DecodingError.trailingBytes }
        return value
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0
        static let maxDepth = 16

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw DecodingError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        /// O argumento do cabecalho, recusando forma mais longa que a necessaria.
        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24:
                return UInt64(info)
            case 24, 25, 26, 27:
                let length = 1 << Int(info - 24)
                var value: UInt64 = 0
                for _ in 0..<length { value = value << 8 | UInt64(try byte()) }
                let minimum: UInt64 = info == 24 ? 24 : info == 25 ? 0x100 : info == 26 ? 0x1_0000 : 0x1_0000_0000
                guard value >= minimum else { throw DecodingError.nonCanonical }
                return value
            default:
                // 28 a 30 sao reservados; 31 e comprimento indefinido.
                throw DecodingError.unsupported
            }
        }

        mutating func item(depth: Int) throws -> CBOR {
            guard depth <= Self.maxDepth else { throw DecodingError.tooDeep }
            let initial = try byte()
            let major = initial >> 5
            let info = initial & 0x1F
            switch major {
            case 0:
                return .unsigned(try argument(info))
            case 2:
                let length = try argument(info)
                guard length <= UInt64(bytes.count - offset) else { throw DecodingError.truncated }
                let start = offset
                offset += Int(length)
                return .bytes(Array(bytes[start..<offset]))
            case 4:
                let count = try argument(info)
                guard count <= UInt64(bytes.count - offset) else { throw DecodingError.truncated }
                var items: [CBOR] = []
                for _ in 0..<count { items.append(try item(depth: depth + 1)) }
                return .array(items)
            case 5:
                let count = try argument(info)
                guard count <= UInt64(bytes.count - offset) else { throw DecodingError.truncated }
                var pairs: [Pair] = []
                for _ in 0..<count {
                    let key = try item(depth: depth + 1)
                    pairs.append(Pair(key: key, value: try item(depth: depth + 1)))
                }
                return .map(pairs)
            case 6:
                let tag = try argument(info)
                return .tag(tag, try item(depth: depth + 1))
            case 7:
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                default: throw DecodingError.unsupported
                }
            default:
                // Negativo (1), texto (3): a transacao de envio nao tem.
                throw DecodingError.unsupported
            }
        }
    }

    // MARK: Acesso

    var unsigned: UInt64? { if case .unsigned(let value) = self { return value } else { return nil } }
    var byteString: [UInt8]? { if case .bytes(let value) = self { return value } else { return nil } }
    var items: [CBOR]? { if case .array(let value) = self { return value } else { return nil } }
    var pairs: [Pair]? { if case .map(let value) = self { return value } else { return nil } }
}
