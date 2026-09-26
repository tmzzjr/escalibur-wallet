import EscaliburCore
import Foundation

// A ABI de contratos da Solidity (docs.soliditylang.org, abi-spec): tipos, valores,
// codificador e seletor. O decodificador estrito mora em ABIDecoder.swift.
//
// A carteira codifica pouca coisa (transfer, approve), mas decodifica muito: toda
// calldata que vai virar assinatura passa pelo decodificador antes, e e a partir
// dos valores decodificados que a tela de revisao e a validacao trabalham. Por isso
// os dois lados vivem juntos e sao testados um contra o outro e contra o solc.

public enum ABIError: Error, Equatable, Sendable {
    /// Texto de tipo ou assinatura que nao e ABI canonica.
    case invalidType(String)
    /// O valor nao tem a forma do tipo (endereco onde se esperava bool, etc.).
    case typeMismatch(expected: String)
    /// Inteiro fora da largura do tipo.
    case outOfRange(type: String)
    /// Numero de elementos ou de bytes diferente do que o tipo fixa.
    case wrongLength(type: String)
    /// Tipo grande demais para caber num buffer razoavel.
    case typeTooLarge
    /// A leitura sairia do buffer.
    case truncated
    /// Offset que nao aponta para onde a codificacao canonica poria o dado:
    /// fora do buffer, para tras, sobreposto ou deixando lacuna.
    case nonCanonicalOffset
    /// Comprimento de bytes, string ou array maior que o buffer comporta.
    case lengthOutOfBounds
    /// Bits que deviam ser zero (ou extensao de sinal) nao sao.
    case dirtyPadding
    /// Bool diferente de 0 ou 1.
    case invalidBool
    case invalidUTF8
    /// Bytes sobrando depois do ultimo campo.
    case trailingBytes(Int)
    /// A calldata nao comeca com o seletor da funcao esperada.
    case selectorMismatch
}

// MARK: Tipos

/// Um tipo ABI. `description` e a forma canonica usada no seletor (`uint256`, nunca
/// `uint`; tuplas entre parenteses).
public indirect enum ABIType: Hashable, Sendable, CustomStringConvertible {
    case address
    case bool
    case string
    case bytes
    /// `uint<N>`, N de 8 a 256, multiplo de 8.
    case uint(Int)
    /// `int<N>`, N de 8 a 256, multiplo de 8.
    case int(Int)
    /// `bytes<N>`, N de 1 a 32.
    case fixedBytes(Int)
    /// `T[]`
    case array(ABIType)
    /// `T[k]`
    case fixedArray(ABIType, Int)
    /// `(T1,T2,...)`
    case tuple([ABIType])

    public static let uint256 = ABIType.uint(256)

    /// Profundidade maxima de aninhamento aceita no texto. Tipo vindo de fora (os
    /// tipos de uma mensagem EIP-712 chegam do provedor) nao pode estourar a pilha.
    static let maxDepth = 32
    /// Maior `k` aceito em `T[k]`.
    static let maxFixedLength = 1 << 20

    /// Le um tipo em texto: `uint256`, `(address,uint256)[]`, `bytes32[2][]`.
    /// `uint` e `int` sao aceitos como sinonimos de `uint256` e `int256`.
    public init(_ text: String) throws {
        var parser = ABITypeParser(text)
        let type = try parser.parseType(depth: 0)
        guard parser.atEnd else { throw ABIError.invalidType(text) }
        self = type
    }

    public var description: String {
        switch self {
        case .address: return "address"
        case .bool: return "bool"
        case .string: return "string"
        case .bytes: return "bytes"
        case .uint(let bits): return "uint\(bits)"
        case .int(let bits): return "int\(bits)"
        case .fixedBytes(let size): return "bytes\(size)"
        case .array(let element): return "\(element)[]"
        case .fixedArray(let element, let count): return "\(element)[\(count)]"
        case .tuple(let components): return "(" + components.map(\.description).joined(separator: ",") + ")"
        }
    }

    /// Dinamico na ABI: codificado no rabo, com offset na cabeca.
    public var isDynamic: Bool {
        switch self {
        case .address, .bool, .uint, .int, .fixedBytes: return false
        case .string, .bytes, .array: return true
        case .fixedArray(let element, _): return element.isDynamic
        case .tuple(let components): return components.contains { $0.isDynamic }
        }
    }

    /// Confere larguras e tamanhos. Os casos do enum sao publicos, entao um
    /// `.uint(7)` montado a mao precisa ser recusado antes de codificar.
    func validate(depth: Int = 0) throws {
        guard depth <= Self.maxDepth else { throw ABIError.invalidType(description) }
        switch self {
        case .address, .bool, .string, .bytes: return
        case .uint(let bits), .int(let bits):
            guard bits >= 8, bits <= 256, bits % 8 == 0 else { throw ABIError.invalidType(description) }
        case .fixedBytes(let size):
            guard size >= 1, size <= 32 else { throw ABIError.invalidType(description) }
        case .array(let element):
            try element.validate(depth: depth + 1)
        case .fixedArray(let element, let count):
            guard count >= 1, count <= Self.maxFixedLength else { throw ABIError.invalidType(description) }
            try element.validate(depth: depth + 1)
        case .tuple(let components):
            guard !components.isEmpty else { throw ABIError.invalidType(description) }
            for component in components { try component.validate(depth: depth + 1) }
        }
    }

    /// Quantos bytes o tipo ocupa na cabeca: 32 para dinamico, o tamanho inteiro
    /// para estatico. Conta com estouro verificado, porque `T[k][k][k]` cresce rapido.
    func headSize() throws -> Int {
        if isDynamic { return 32 }
        switch self {
        case .fixedArray(let element, let count):
            let (size, overflow) = try element.headSize().multipliedReportingOverflow(by: count)
            guard !overflow, size <= ABI.maxEncodedSize else { throw ABIError.typeTooLarge }
            return size
        case .tuple(let components):
            var total = 0
            for component in components {
                let (sum, overflow) = total.addingReportingOverflow(try component.headSize())
                guard !overflow, sum <= ABI.maxEncodedSize else { throw ABIError.typeTooLarge }
                total = sum
            }
            return total
        default:
            return 32
        }
    }
}

/// Leitor do texto de tipo. Estrito: sem espaco, sem zero a esquerda, sem `tuple`
/// por extenso, sem `fixed`/`ufixed` (que nenhum contrato que a carteira fala usa).
struct ABITypeParser {
    private let chars: [UInt8]
    private var index = 0
    private let original: String

    init(_ text: String) {
        chars = Array(text.utf8)
        original = text
    }

    var atEnd: Bool { index == chars.count }

    mutating func peek() -> UInt8? { index < chars.count ? chars[index] : nil }

    mutating func expect(_ c: UInt8) throws {
        guard peek() == c else { throw ABIError.invalidType(original) }
        index += 1
    }

    /// Lista `(T1,T2,...)`. `allowEmpty` so vale para a lista de argumentos de uma
    /// funcao; tupla vazia como tipo nao existe na Solidity.
    mutating func parseList(depth: Int, allowEmpty: Bool) throws -> [ABIType] {
        try expect(UInt8(ascii: "("))
        var items = [ABIType]()
        if peek() == UInt8(ascii: ")") {
            guard allowEmpty else { throw ABIError.invalidType(original) }
            index += 1
            return items
        }
        while true {
            items.append(try parseType(depth: depth + 1))
            if peek() == UInt8(ascii: ",") {
                index += 1
                continue
            }
            try expect(UInt8(ascii: ")"))
            return items
        }
    }

    mutating func parseType(depth: Int) throws -> ABIType {
        guard depth <= ABIType.maxDepth else { throw ABIError.invalidType(original) }
        var type: ABIType
        if peek() == UInt8(ascii: "(") {
            type = .tuple(try parseList(depth: depth, allowEmpty: false))
        } else {
            let start = index
            while let c = peek(), (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) { index += 1 }
            let word = String(decoding: chars[start..<index], as: UTF8.self)
            guard let base = Self.base(word) else { throw ABIError.invalidType(original) }
            type = base
        }
        // Sufixos de array, da esquerda para a direita: `T[2][]` e array dinamico
        // de `T[2]`.
        var suffixes = 0
        while peek() == UInt8(ascii: "[") {
            index += 1
            suffixes += 1
            guard depth + suffixes <= ABIType.maxDepth else { throw ABIError.invalidType(original) }
            let start = index
            while let c = peek(), c >= 0x30, c <= 0x39 { index += 1 }
            let digits = chars[start..<index]
            try expect(UInt8(ascii: "]"))
            if digits.isEmpty {
                type = .array(type)
            } else {
                guard digits.first != 0x30, digits.count <= 7,
                      let count = Int(String(decoding: digits, as: UTF8.self)),
                      count >= 1, count <= ABIType.maxFixedLength
                else { throw ABIError.invalidType(original) }
                type = .fixedArray(type, count)
            }
        }
        return type
    }

    static func base(_ word: String) -> ABIType? {
        switch word {
        case "address": return .address
        case "bool": return .bool
        case "string": return .string
        case "bytes": return .bytes
        case "uint": return .uint(256)
        case "int": return .int(256)
        default: break
        }
        func width(_ prefix: String) -> Int? {
            guard word.hasPrefix(prefix) else { return nil }
            let digits = word.dropFirst(prefix.count)
            guard !digits.isEmpty, digits.first != "0", digits.allSatisfy(\.isNumber), digits.count <= 3 else { return nil }
            return Int(digits)
        }
        if let bits = width("uint"), bits % 8 == 0, (8...256).contains(bits) { return .uint(bits) }
        if let bits = width("int"), bits % 8 == 0, (8...256).contains(bits) { return .int(bits) }
        if let size = width("bytes"), (1...32).contains(size) { return .fixedBytes(size) }
        return nil
    }
}

// MARK: Valores

/// Inteiro com sinal de precisao arbitraria, para `int<N>`. Zero nunca e negativo.
public struct ABISignedInteger: Hashable, Sendable, CustomStringConvertible {
    public let magnitude: BigUInt
    public let isNegative: Bool

    public init(magnitude: BigUInt, negative: Bool) {
        self.magnitude = magnitude
        self.isNegative = negative && !magnitude.isZero
    }

    public init<T: BinaryInteger>(_ value: T) {
        self.init(magnitude: BigUInt(value.magnitude), negative: value < 0)
    }

    /// Decimal estrito com `-` opcional: `-128`, `42`.
    public init?(decimal text: String) {
        if text.hasPrefix("-") {
            guard let magnitude = BigUInt(decimal: String(text.dropFirst())) else { return nil }
            self.init(magnitude: magnitude, negative: true)
        } else {
            guard let magnitude = BigUInt(decimal: text) else { return nil }
            self.init(magnitude: magnitude, negative: false)
        }
    }

    public var description: String { (isNegative ? "-" : "") + magnitude.decimalString }

    static let twoTo256 = BigUInt(1).shiftedLeft(by: 256)

    /// Complemento de dois em 256 bits.
    var word: [UInt8] {
        let raw = isNegative ? Self.twoTo256 - magnitude : magnitude
        return raw.bigEndianBytes(padTo: 32) ?? [UInt8](repeating: 0, count: 32)
    }

    /// Cabe em `int<bits>`? De -2^(bits-1) a 2^(bits-1) - 1.
    func fits(bits: Int) -> Bool {
        let limit = BigUInt(1).shiftedLeft(by: bits - 1)
        return isNegative ? magnitude <= limit : magnitude < limit
    }

    /// Le uma palavra de 32 bytes em complemento de dois.
    static func fromWord(_ word: [UInt8]) -> ABISignedInteger {
        let value = BigUInt(bigEndian: word)
        if word[0] & 0x80 != 0 {
            return ABISignedInteger(magnitude: twoTo256 - value, negative: true)
        }
        return ABISignedInteger(magnitude: value, negative: false)
    }
}

/// Um valor ABI. Arrays fixos e dinamicos usam `.array`; o tipo diz qual e.
public indirect enum ABIValue: Hashable, Sendable {
    case address(EVMAddress)
    case uint(BigUInt)
    case int(ABISignedInteger)
    case bool(Bool)
    /// `bytes<N>`: exatamente N bytes, sem o preenchimento.
    case fixedBytes([UInt8])
    case bytes([UInt8])
    case string(String)
    case array([ABIValue])
    case tuple([ABIValue])

    public var addressValue: EVMAddress? {
        if case .address(let value) = self { return value }
        return nil
    }

    public var uintValue: BigUInt? {
        if case .uint(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var bytesValue: [UInt8]? {
        switch self {
        case .bytes(let value), .fixedBytes(let value): return value
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [ABIValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var tupleValue: [ABIValue]? {
        if case .tuple(let value) = self { return value }
        return nil
    }
}

// MARK: Codificacao

public enum ABI {
    /// Teto do tamanho de uma codificacao. Calldata real tem poucos KB; o teto so
    /// existe para conta de tamanho nunca estourar `Int`.
    static let maxEncodedSize = 1 << 26

    /// `abi.encode(v1, v2, ...)`: os valores como uma tupla.
    public static func encode(_ values: [ABIValue], types: [ABIType]) throws -> [UInt8] {
        for type in types { try type.validate() }
        return try encodeTuple(values, types: types)
    }

    /// Os 4 primeiros bytes do keccak da assinatura canonica.
    public static func selector(_ signature: String) throws -> [UInt8] {
        try ABIFunction(signature).selector
    }

    static func encodeTuple(_ values: [ABIValue], types: [ABIType]) throws -> [UInt8] {
        guard values.count == types.count else { throw ABIError.wrongLength(type: "(" + types.map(\.description).joined(separator: ",") + ")") }
        var headSize = 0
        for type in types { headSize += try type.headSize() }
        var head = [UInt8]()
        var tail = [UInt8]()
        head.reserveCapacity(headSize)
        for (value, type) in zip(values, types) {
            if type.isDynamic {
                head += word(BigUInt(headSize + tail.count))
                tail += try encode(value, as: type)
            } else {
                head += try encode(value, as: type)
            }
            guard head.count + tail.count <= maxEncodedSize else { throw ABIError.typeTooLarge }
        }
        return head + tail
    }

    static func encode(_ value: ABIValue, as type: ABIType) throws -> [UInt8] {
        switch (type, value) {
        case (.address, .address(let address)):
            return address.abiWord
        case (.uint(let bits), .uint(let number)):
            guard number.bitWidth <= bits else { throw ABIError.outOfRange(type: type.description) }
            return word(number)
        case (.int(let bits), .int(let number)):
            guard number.fits(bits: bits) else { throw ABIError.outOfRange(type: type.description) }
            return number.word
        case (.bool, .bool(let flag)):
            return word(BigUInt(flag ? 1 : 0))
        case (.fixedBytes(let size), .fixedBytes(let raw)):
            guard raw.count == size else { throw ABIError.wrongLength(type: type.description) }
            return raw + [UInt8](repeating: 0, count: 32 - size)
        case (.bytes, .bytes(let raw)):
            return encodeDynamicBytes(raw)
        case (.string, .string(let text)):
            return encodeDynamicBytes(Array(text.utf8))
        case (.fixedArray(let element, let count), .array(let items)):
            guard items.count == count else { throw ABIError.wrongLength(type: type.description) }
            return try encodeTuple(items, types: Array(repeating: element, count: count))
        case (.array(let element), .array(let items)):
            return word(BigUInt(items.count)) + (try encodeTuple(items, types: Array(repeating: element, count: items.count)))
        case (.tuple(let components), .tuple(let items)):
            return try encodeTuple(items, types: components)
        default:
            throw ABIError.typeMismatch(expected: type.description)
        }
    }

    static func encodeDynamicBytes(_ raw: [UInt8]) -> [UInt8] {
        let padding = (32 - raw.count % 32) % 32
        return word(BigUInt(raw.count)) + raw + [UInt8](repeating: 0, count: padding)
    }

    /// Inteiro sem sinal numa palavra de 32 bytes. So chamado com valor que cabe.
    static func word(_ value: BigUInt) -> [UInt8] {
        value.bigEndianBytes(padTo: 32) ?? [UInt8](repeating: 0, count: 32)
    }
}

// MARK: Funcao

/// Uma funcao de contrato: nome, argumentos e o seletor que sai da assinatura.
public struct ABIFunction: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public let inputs: [ABIType]
    /// `transfer(address,uint256)`, sempre na forma canonica.
    public let signature: String
    public let selector: [UInt8]

    /// Le `nome(tipo,tipo,...)`. Aceita `uint`/`int`, mas o seletor sai sempre da
    /// forma canonica (`uint256`), como manda a especificacao.
    public init(_ text: String) throws {
        let bytes = Array(text.utf8)
        guard let open = bytes.firstIndex(of: UInt8(ascii: "(")) else { throw ABIError.invalidType(text) }
        let name = String(decoding: bytes[..<open], as: UTF8.self)
        var parser = ABITypeParser(String(decoding: bytes[open...], as: UTF8.self))
        let inputs = try parser.parseList(depth: 0, allowEmpty: true)
        guard parser.atEnd else { throw ABIError.invalidType(text) }
        try self.init(name: name, inputs: inputs)
    }

    public init(name: String, inputs: [ABIType]) throws {
        guard Self.isIdentifier(name) else { throw ABIError.invalidType(name) }
        for input in inputs { try input.validate(depth: 1) }
        self.name = name
        self.inputs = inputs
        self.signature = name + "(" + inputs.map(\.description).joined(separator: ",") + ")"
        self.selector = Array(Hash.keccak256(Array(signature.utf8)).prefix(4))
    }

    public var description: String { signature }

    /// Seletor seguido dos argumentos codificados.
    public func encodeCall(_ arguments: [ABIValue]) throws -> [UInt8] {
        selector + (try ABI.encodeTuple(arguments, types: inputs))
    }

    /// Confere o seletor e decodifica os argumentos, sem aceitar byte sobrando.
    public func decodeCall(_ calldata: [UInt8]) throws -> [ABIValue] {
        guard calldata.count >= 4, Array(calldata.prefix(4)) == selector else { throw ABIError.selectorMismatch }
        return try ABI.decode(inputs, from: Array(calldata.dropFirst(4)))
    }

    /// Identificador da Solidity: letra, `_` ou `$`, seguidos tambem de digitos.
    static func isIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let first = bytes.first, bytes.count <= 256 else { return false }
        func letter(_ c: UInt8) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$")
        }
        return letter(first) && bytes.dropFirst().allSatisfy { letter($0) || ($0 >= 0x30 && $0 <= 0x39) }
    }
}
