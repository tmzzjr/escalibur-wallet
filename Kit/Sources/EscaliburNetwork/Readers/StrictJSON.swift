import EscaliburCore
import Foundation

/// JSON estrito para as respostas dos provedores.
///
/// Por que nao `JSONDecoder` com `JSONValue` ou `JSONSerialization`: os dois passam
/// numero por `Double`, e saldo de 18 casas, nonce ou `balance` de 17 digitos em sun
/// perdem o ultimo digito em silencio. Aqui o numero fica como o texto literal e so
/// vira inteiro no acesso, com a largura pedida.
///
/// Estrito tambem na leitura: todo acesso diz o caminho do campo, e campo faltando ou
/// de tipo errado e erro (`ReaderError.malformed`), nunca zero. Chave duplicada e
/// recusada (dois leitores escolheriam valores diferentes), escape invalido, UTF-8
/// invalido e controle cru tambem. Profundidade e tamanho tem teto.
public indirect enum StrictJSON: Equatable, Sendable {
    case object([String: StrictJSON])
    case array([StrictJSON])
    case string(String)
    /// O texto literal, conferido pela gramatica do JSON.
    case number(String)
    case bool(Bool)
    case null

    static let maxDepth = 128
    static let maxSize = 4 * 1024 * 1024

    // MARK: Leitura

    public static func parse(_ data: Data) throws -> StrictJSON {
        let bytes = [UInt8](data)
        guard bytes.count <= maxSize else { throw ReaderError.malformed(field: "$") }
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let value: StrictJSON
        do {
            value = try parser.parseValue(depth: 0)
        } catch {
            throw ReaderError.malformed(field: "$")
        }
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw ReaderError.malformed(field: "$") }
        return value
    }

    // MARK: Escrita

    /// Serializa com as chaves em ordem: o corpo de uma requisicao sai sempre igual, o
    /// que deixa os testes com respostas gravadas reconhecerem a requisicao.
    public var serialized: Data { Data(Self.serialize(self).utf8) }

    static func serialize(_ value: StrictJSON) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let text): return text
        case .string(let text): return quote(text)
        case .array(let items): return "[" + items.map(serialize).joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.keys.sorted().map { quote($0) + ":" + serialize(fields[$0]!) }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Inteiro sem sinal como numero JSON.
    public static func int<T: BinaryInteger>(_ value: T) -> StrictJSON { .number(String(value)) }

    // MARK: Acesso estrito

    /// Um campo obrigatorio de objeto. `path` e so para a mensagem de erro.
    func field(_ key: String, _ path: String) throws -> StrictJSON {
        guard case .object(let fields) = self, let value = fields[key] else {
            throw ReaderError.malformed(field: path + "." + key)
        }
        return value
    }

    /// Campo opcional: ausente ou `null` viram `nil`; presente com outro tipo continua
    /// sendo lido pelo chamador com o rigor de sempre.
    func optionalField(_ key: String) -> StrictJSON? {
        guard case .object(let fields) = self, let value = fields[key] else { return nil }
        if case .null = value { return nil }
        return value
    }

    var objectValue: [String: StrictJSON]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    var arrayValue: [StrictJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    func object(_ path: String) throws -> [String: StrictJSON] {
        guard case .object(let fields) = self else { throw ReaderError.malformed(field: path) }
        return fields
    }

    func array(_ path: String) throws -> [StrictJSON] {
        guard case .array(let items) = self else { throw ReaderError.malformed(field: path) }
        return items
    }

    func string(_ path: String) throws -> String {
        guard case .string(let text) = self else { throw ReaderError.malformed(field: path) }
        return text
    }

    func bool(_ path: String) throws -> Bool {
        guard case .bool(let flag) = self else { throw ReaderError.malformed(field: path) }
        return flag
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Numero inteiro nao negativo, sem fracao nem expoente: `0`, `42`, `1790389821000`.
    func unsigned(_ path: String) throws -> BigUInt {
        guard case .number(let text) = self, let value = BigUInt(decimal: text) else {
            throw ReaderError.malformed(field: path)
        }
        return value
    }

    func uint64(_ path: String) throws -> UInt64 {
        guard let value = try unsigned(path).uint64 else { throw ReaderError.malformed(field: path) }
        return value
    }

    func uint32(_ path: String) throws -> UInt32 {
        guard let value = UInt32(exactly: try uint64(path)) else { throw ReaderError.malformed(field: path) }
        return value
    }

    /// Inteiro com sinal (codigos de saida da TVM, por exemplo).
    func int64(_ path: String) throws -> Int64 {
        guard case .number(let text) = self else { throw ReaderError.malformed(field: path) }
        let negative = text.hasPrefix("-")
        guard let magnitude = BigUInt(decimal: negative ? String(text.dropFirst()) : text)?.uint64,
              magnitude <= UInt64(Int64.max)
        else { throw ReaderError.malformed(field: path) }
        return negative ? -Int64(magnitude) : Int64(magnitude)
    }

    /// Texto so de digitos decimais: `"56775133590"`. Saldo em drops, nanoton, wei de
    /// indexador.
    func decimalString(_ path: String) throws -> BigUInt {
        guard case .string(let text) = self, text.count <= 80, let value = BigUInt(decimal: text) else {
            throw ReaderError.malformed(field: path)
        }
        return value
    }

    /// Inteiro que um provedor manda como numero e outro como texto (saldo em nanoton:
    /// numero na tonapi, texto na toncenter).
    func integer(_ path: String) throws -> BigUInt {
        switch self {
        case .number: return try unsigned(path)
        case .string: return try decimalString(path)
        default: throw ReaderError.malformed(field: path)
        }
    }

    /// Quantidade do JSON-RPC da EVM: `0x` seguido de hex, no maximo 256 bits.
    func quantity(_ path: String) throws -> BigUInt {
        guard case .string(let text) = self, text.hasPrefix("0x"), text.count > 2, text.count <= 66,
              let value = BigUInt(hex: text)
        else { throw ReaderError.malformed(field: path) }
        return value
    }

    /// Bytes em hex com `0x` (dado de `eth_call`, codigo de `eth_getCode`).
    func hexData(_ path: String) throws -> [UInt8] {
        guard case .string(let text) = self, text.hasPrefix("0x"), let bytes = Hex.decode(text) else {
            throw ReaderError.malformed(field: path)
        }
        return bytes
    }

    /// Decimal com ate `scale` casas, sem expoente, convertido para a unidade menor:
    /// `0.2` com escala 6 da 200000. Serve para a reserva do `server_info` (XRP).
    func scaledDecimal(_ path: String, scale: Int) throws -> BigUInt {
        guard case .number(let text) = self else { throw ReaderError.malformed(field: path) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw ReaderError.malformed(field: path) }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= scale,
              let value = BigUInt(decimal: String(parts[0]) + fraction + String(repeating: "0", count: scale - fraction.count))
        else { throw ReaderError.malformed(field: path) }
        return value
    }
}

// MARK: Parser

extension StrictJSON {
    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        struct Failure: Error {}

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard bytes.count - index >= expected.count, Array(bytes[index..<(index + expected.count)]) == expected else {
                throw Failure()
            }
            index += expected.count
        }

        mutating func parseValue(depth: Int) throws -> StrictJSON {
            guard depth <= StrictJSON.maxDepth, index < bytes.count else { throw Failure() }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try consume("true"); return .bool(true)
            case UInt8(ascii: "f"): try consume("false"); return .bool(false)
            case UInt8(ascii: "n"): try consume("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        mutating func parseObject(depth: Int) throws -> StrictJSON {
            index += 1
            var out = [String: StrictJSON]()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(out)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure() }
                let key = try parseString()
                guard out[key] == nil else { throw Failure() }
                skipWhitespace()
                try consume(":")
                skipWhitespace()
                out[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw Failure() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(out) }
                throw Failure()
            }
        }

        mutating func parseArray(depth: Int) throws -> StrictJSON {
            index += 1
            var out = [StrictJSON]()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(out)
            }
            while true {
                skipWhitespace()
                out.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw Failure() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(out) }
                throw Failure()
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var raw = [UInt8]()
            func flush() throws {
                guard !raw.isEmpty else { return }
                guard let text = String(bytes: raw, encoding: .utf8) else { throw Failure() }
                scalars.append(contentsOf: text.unicodeScalars)
                raw.removeAll()
            }
            while index < bytes.count {
                let c = bytes[index]
                switch c {
                case UInt8(ascii: "\""):
                    index += 1
                    try flush()
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    try flush()
                    index += 1
                    guard index < bytes.count else { throw Failure() }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        let unit = try parseHex4()
                        if (0xD800...0xDBFF).contains(unit) {
                            try consume("\\u")
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw Failure() }
                            guard let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) else { throw Failure() }
                            scalars.append(scalar)
                        } else {
                            guard let scalar = Unicode.Scalar(unit) else { throw Failure() }
                            scalars.append(scalar)
                        }
                    default:
                        throw Failure()
                    }
                default:
                    guard c >= 0x20 else { throw Failure() }
                    raw.append(c)
                    index += 1
                }
            }
            throw Failure()
        }

        mutating func parseHex4() throws -> UInt32 {
            guard bytes.count - index >= 4 else { throw Failure() }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[index]
                let digit: UInt32
                switch c {
                case 0x30...0x39: digit = UInt32(c - 0x30)
                case 0x61...0x66: digit = UInt32(c - 0x61 + 10)
                case 0x41...0x46: digit = UInt32(c - 0x41 + 10)
                default: throw Failure()
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, devolvido como texto.
        mutating func parseNumber() throws -> String {
            let start = index
            func digits() -> Int {
                let begin = index
                while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
                return index - begin
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw Failure() }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                guard digits() > 0 else { throw Failure() }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw Failure() }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw Failure() }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
