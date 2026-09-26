import EscaliburCore
import Foundation

/// Por que o codec recusou montar os bytes.
public enum XRPLCodecError: Error, Equatable, Sendable {
    /// O valor nao e do tipo do campo (um Amount num campo UInt32, por exemplo).
    case typeMismatch(field: String)
    case duplicateField(String)
    /// Hash, conta ou chave com tamanho errado.
    case invalidLength(field: String)
    /// Mais bytes do que o prefixo de tamanho do protocolo representa (918.744).
    case valueTooLong(Int)
    case invalidAmount(String)
    case invalidCurrency(String)
    case invalidAccount(String)
    case invalidPath
}

/// O valor de um campo, ja no tipo do protocolo.
public indirect enum XRPLValue: Sendable, Equatable {
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case uint64(UInt64)
    case hash128([UInt8])
    case hash160([UInt8])
    case hash256([UInt8])
    case blob([UInt8])
    /// Os 20 bytes da conta (nunca o texto r...).
    case accountID([UInt8])
    case amount(XRPLAmount)
    case object(XRPLObject)
    case array([XRPLArrayElement])
    case pathSet([[XRPLPathStep]])

    var type: XRPLType {
        switch self {
        case .uint8: return .uint8
        case .uint16: return .uint16
        case .uint32: return .uint32
        case .uint64: return .uint64
        case .hash128: return .hash128
        case .hash160: return .hash160
        case .hash256: return .hash256
        case .blob: return .blob
        case .accountID: return .accountID
        case .amount: return .amount
        case .object: return .stObject
        case .array: return .stArray
        case .pathSet: return .pathSet
        }
    }
}

/// Um elemento de STArray: o objeto e o campo que o embrulha (Memo dentro de Memos).
public struct XRPLArrayElement: Sendable, Equatable {
    public let field: XRPLField
    public let object: XRPLObject

    public init(_ field: XRPLField, _ object: XRPLObject) {
        self.field = field
        self.object = object
    }
}

/// Um passo de caminho de pagamento. Cada parte presente liga um bit do byte de tipo.
public struct XRPLPathStep: Sendable, Equatable {
    public let account: [UInt8]?
    public let currency: [UInt8]?
    public let issuer: [UInt8]?

    public init(account: [UInt8]? = nil, currency: [UInt8]? = nil, issuer: [UInt8]? = nil) {
        self.account = account
        self.currency = currency
        self.issuer = issuer
    }
}

/// Um STObject: campos com valor, serializados na ordem canonica.
public struct XRPLObject: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let field: XRPLField
        public let value: XRPLValue
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Acrescenta um campo. O tipo do valor tem de ser o do campo, e campo repetido e
    /// recusado: o rippled rejeita objeto com campo duplicado, e aceitar aqui seria
    /// assinar algo que a rede nunca aplicaria.
    public mutating func set(_ field: XRPLField, _ value: XRPLValue) throws {
        guard value.type == field.type else { throw XRPLCodecError.typeMismatch(field: field.name) }
        guard !entries.contains(where: { $0.field.name == field.name }) else {
            throw XRPLCodecError.duplicateField(field.name)
        }
        entries.append(Entry(field: field, value: value))
    }

    public subscript(field: XRPLField) -> XRPLValue? {
        entries.first { $0.field == field }?.value
    }

    /// Os bytes do objeto, sem marcador de fim (o objeto de topo nao tem um).
    ///
    /// Com `signingFieldsOnly`, fica de fora o que nao entra no digesto (TxnSignature).
    /// O filtro vale so para o nivel de cima, como no rippled e no ripple-binary-codec.
    public func serialized(signingFieldsOnly: Bool = false) throws -> [UInt8] {
        var out = [UInt8]()
        let chosen = entries
            .filter { $0.field.isSerialized && (!signingFieldsOnly || $0.field.isSigningField) }
            .sorted { XRPLField.canonicalOrder($0.field, $1.field) }
        for entry in chosen {
            out += entry.field.header
            out += try XRPLBinary.encode(entry.value, field: entry.field)
        }
        return out
    }
}

/// As regras de baixo nivel do formato binario.
///
/// Referencia: xrpl.org, "Binary Format" (docs/references/protocol/binary-format), e o
/// ripple-binary-codec (src/serdes/binary-serializer.ts, src/types/*.ts).
public enum XRPLBinary {

    /// Cabecalho de campo. Tipo e ordinal abaixo de 16 cabem num nibble cada; acima
    /// disso vao num byte proprio, com o nibble correspondente zerado.
    public static func fieldHeader(type: UInt16, nth: UInt16) -> [UInt8] {
        let t = UInt8(truncatingIfNeeded: type)
        let n = UInt8(truncatingIfNeeded: nth)
        switch (type < 16, nth < 16) {
        case (true, true): return [t << 4 | n]
        case (true, false): return [t << 4, n]
        case (false, true): return [n, t]
        case (false, false): return [0, t, n]
        }
    }

    /// Prefixo de tamanho: 1 byte ate 192, 2 bytes ate 12.480, 3 bytes ate 918.744.
    public static func lengthPrefix(_ length: Int) throws -> [UInt8] {
        switch length {
        case 0...192:
            return [UInt8(length)]
        case 193...12_480:
            let l = length - 193
            return [UInt8(193 + (l >> 8)), UInt8(l & 0xFF)]
        case 12_481...918_744:
            let l = length - 12_481
            return [UInt8(241 + (l >> 16)), UInt8((l >> 8) & 0xFF), UInt8(l & 0xFF)]
        default:
            throw XRPLCodecError.valueTooLong(length)
        }
    }

    static func encode(_ value: XRPLValue, field: XRPLField) throws -> [UInt8] {
        switch value {
        case .uint8(let v): return [v]
        case .uint16(let v): return v.bigEndianByteArray
        case .uint32(let v): return v.bigEndianByteArray
        case .uint64(let v): return v.bigEndianByteArray
        case .hash128(let bytes): return try fixed(bytes, 16, field)
        case .hash160(let bytes): return try fixed(bytes, 20, field)
        case .hash256(let bytes): return try fixed(bytes, 32, field)
        case .blob(let bytes):
            return try lengthPrefix(bytes.count) + bytes
        case .accountID(let bytes):
            return try lengthPrefix(20) + fixed(bytes, 20, field)
        case .amount(let amount):
            return try amount.serialized()
        case .object(let object):
            return try object.serialized() + XRPLField.objectEndMarker.header
        case .array(let elements):
            var out = [UInt8]()
            for element in elements {
                guard element.field.type == .stObject else { throw XRPLCodecError.typeMismatch(field: element.field.name) }
                out += element.field.header
                out += try element.object.serialized()
                out += XRPLField.objectEndMarker.header
            }
            return out + XRPLField.arrayEndMarker.header
        case .pathSet(let paths):
            return try encodePathSet(paths)
        }
    }

    private static func fixed(_ bytes: [UInt8], _ size: Int, _ field: XRPLField) throws -> [UInt8] {
        guard bytes.count == size else { throw XRPLCodecError.invalidLength(field: field.name) }
        return bytes
    }

    /// PathSet: passos com byte de tipo (0x01 conta, 0x10 moeda, 0x20 emissor), 0xFF
    /// entre caminhos e 0x00 no fim.
    private static func encodePathSet(_ paths: [[XRPLPathStep]]) throws -> [UInt8] {
        guard !paths.isEmpty else { throw XRPLCodecError.invalidPath }
        var out = [UInt8]()
        for (index, path) in paths.enumerated() {
            guard !path.isEmpty else { throw XRPLCodecError.invalidPath }
            if index > 0 { out.append(0xFF) }
            for step in path {
                var type: UInt8 = 0
                var body = [UInt8]()
                if let account = step.account {
                    guard account.count == 20 else { throw XRPLCodecError.invalidPath }
                    type |= 0x01
                    body += account
                }
                if let currency = step.currency {
                    guard currency.count == 20 else { throw XRPLCodecError.invalidPath }
                    type |= 0x10
                    body += currency
                }
                if let issuer = step.issuer {
                    guard issuer.count == 20 else { throw XRPLCodecError.invalidPath }
                    type |= 0x20
                    body += issuer
                }
                guard type != 0 else { throw XRPLCodecError.invalidPath }
                out.append(type)
                out += body
            }
        }
        out.append(0x00)
        return out
    }

    /// Hex maiusculo, a forma que o rippled e os exploradores mostram.
    static func hexUpper(_ bytes: [UInt8]) -> String {
        Hex.encode(bytes).uppercased()
    }
}

public extension XRPLAddress {
    /// O endereco classico (r...) de uma conta de 20 bytes.
    static func classic(accountID: [UInt8]) -> String? {
        guard accountID.count == 20 else { return nil }
        return Base58.ripple.encodeCheck([0x00] + accountID)
    }
}
