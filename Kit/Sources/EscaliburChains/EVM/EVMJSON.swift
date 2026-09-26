import Foundation

/// Um leitor de JSON pequeno e estrito, para dados tipados EIP-712 vindos de fora.
///
/// Por que nao `JSONSerialization`: ele converte numero para `Double`/`NSDecimalNumber`,
/// e um `uint256` de 78 digitos perde precisao em silencio, entao a carteira assinaria
/// um valor diferente do que mostrou. Aqui o numero fica como o texto literal, e so
/// vira inteiro na hora de codificar, com a largura do tipo.
///
/// Estrito tambem no resto: chave duplicada e recusada (dois leitores escolheriam
/// valores diferentes), escape invalido e surrogate solto sao recusados, e ha teto de
/// profundidade e de tamanho.
indirect enum EVMJSON: Equatable, Sendable {
    case object([String: EVMJSON])
    case array([EVMJSON])
    case string(String)
    /// O texto literal, conferido pela gramatica do JSON.
    case number(String)
    case bool(Bool)
    case null

    enum Failure: Error, Equatable {
        case syntax(offset: Int)
        case duplicateKey(String)
        case tooDeep
        case tooLarge
    }

    static let maxDepth = 64
    static let maxSize = 1 << 20

    static func parse(_ text: String) throws -> EVMJSON {
        let bytes = Array(text.utf8)
        guard bytes.count <= maxSize else { throw Failure.tooLarge }
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw Failure.syntax(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        func fail() -> Failure { .syntax(offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard bytes.count - index >= expected.count, Array(bytes[index..<(index + expected.count)]) == expected else { throw fail() }
            index += expected.count
        }

        mutating func parseValue(depth: Int) throws -> EVMJSON {
            guard depth <= EVMJSON.maxDepth else { throw Failure.tooDeep }
            guard index < bytes.count else { throw fail() }
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

        mutating func parseObject(depth: Int) throws -> EVMJSON {
            index += 1
            var out = [String: EVMJSON]()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(out)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail() }
                let key = try parseString()
                guard out[key] == nil else { throw Failure.duplicateKey(key) }
                skipWhitespace()
                try consume(":")
                skipWhitespace()
                out[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw fail() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(out) }
                throw fail()
            }
        }

        mutating func parseArray(depth: Int) throws -> EVMJSON {
            index += 1
            var out = [EVMJSON]()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(out)
            }
            while true {
                skipWhitespace()
                out.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw fail() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(out) }
                throw fail()
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var raw = [UInt8]()
            func flush() throws {
                guard !raw.isEmpty else { return }
                guard ABIReader.isValidUTF8(raw) else { throw fail() }
                scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
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
                    guard index < bytes.count else { throw fail() }
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
                            // Par de surrogates: o segundo precisa vir logo em seguida.
                            try consume("\\u")
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw fail() }
                            let value = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                            guard let scalar = Unicode.Scalar(value) else { throw fail() }
                            scalars.append(scalar)
                        } else {
                            guard let scalar = Unicode.Scalar(unit) else { throw fail() }
                            scalars.append(scalar)
                        }
                    default:
                        throw fail()
                    }
                default:
                    // Caractere de controle cru nao e JSON.
                    guard c >= 0x20 else { throw fail() }
                    raw.append(c)
                    index += 1
                }
            }
            throw fail()
        }

        mutating func parseHex4() throws -> UInt32 {
            guard bytes.count - index >= 4 else { throw fail() }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[index]
                let digit: UInt32
                switch c {
                case 0x30...0x39: digit = UInt32(c - 0x30)
                case 0x61...0x66: digit = UInt32(c - 0x61 + 10)
                case 0x41...0x46: digit = UInt32(c - 0x41 + 10)
                default: throw fail()
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
            guard index < bytes.count else { throw fail() }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                guard digits() > 0 else { throw fail() }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw fail() }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw fail() }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
