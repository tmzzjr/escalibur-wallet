import EscaliburCore
import Foundation

// XDR (RFC 4506), o formato binario de tudo o que a Stellar assina.
//
// So o subconjunto que a carteira usa: inteiros de 32 e 64 bits em big-endian,
// opaco fixo e variavel com preenchimento ate multiplo de 4, e o booleano. A leitura
// e estrita de proposito: preenchimento diferente de zero, booleano fora de 0/1,
// tamanho acima do teto e bytes sobrando no fim sao recusados. Um decodificador
// frouxo aceita duas grafias para a mesma transacao, e a que a tela mostra pode nao
// ser a que o no executa.

public enum StellarXDRError: Error, Equatable, Sendable {
    case truncated
    case trailingBytes
    case nonZeroPadding
    case invalidBoolean
    case lengthExceeded(field: String)
    case unknownDiscriminant(field: String, value: Int32)
    /// Estrutura valida na rede, mas fora do que a carteira monta ou confere
    /// (fee bump, precondicoes V2, Soroban, operacoes que ela nao usa).
    case unsupported(String)
    /// SetOptions e AccountMerge: trocam quem controla a conta ou a esvaziam
    /// inteira. A carteira nao monta e nao aceita.
    case forbiddenOperation(String)
    case invalidAccount
    case invalidAssetCode
    case invalidMemo
    case invalidAmount(field: String)
    case invalidPrice
    /// Oferta com o mesmo ativo dos dois lados.
    case invalidOffer
    case invalidOperationCount
    case invalidBase64
}

struct StellarXDRWriter {
    private(set) var bytes: [UInt8] = []

    mutating func int32(_ value: Int32) {
        bytes += UInt32(bitPattern: value).bigEndianByteArray
    }

    mutating func uint32(_ value: UInt32) {
        bytes += value.bigEndianByteArray
    }

    mutating func int64(_ value: Int64) {
        bytes += UInt64(bitPattern: value).bigEndianByteArray
    }

    mutating func uint64(_ value: UInt64) {
        bytes += value.bigEndianByteArray
    }

    mutating func bool(_ value: Bool) {
        uint32(value ? 1 : 0)
    }

    /// `opaque x[n]`: os bytes e o preenchimento com zeros ate multiplo de 4.
    mutating func fixedOpaque(_ data: [UInt8]) {
        bytes += data
        bytes += [UInt8](repeating: 0, count: Self.padding(data.count))
    }

    /// `opaque x<max>` e `string x<max>`: tamanho em uint32, bytes, preenchimento.
    mutating func variableOpaque(_ data: [UInt8]) {
        uint32(UInt32(data.count))
        fixedOpaque(data)
    }

    static func padding(_ count: Int) -> Int {
        (4 - count % 4) % 4
    }
}

struct StellarXDRReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset == bytes.count }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, bytes.count - offset >= count else { throw StellarXDRError.truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func uint32() throws -> UInt32 {
        try take(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    mutating func int32() throws -> Int32 {
        Int32(bitPattern: try uint32())
    }

    mutating func uint64() throws -> UInt64 {
        try take(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    mutating func int64() throws -> Int64 {
        Int64(bitPattern: try uint64())
    }

    mutating func bool() throws -> Bool {
        switch try uint32() {
        case 0: return false
        case 1: return true
        default: throw StellarXDRError.invalidBoolean
        }
    }

    mutating func fixedOpaque(_ count: Int) throws -> [UInt8] {
        let data = Array(try take(count))
        let pad = try take(StellarXDRWriter.padding(count))
        guard pad.allSatisfy({ $0 == 0 }) else { throw StellarXDRError.nonZeroPadding }
        return data
    }

    mutating func variableOpaque(max: Int, field: String) throws -> [UInt8] {
        let count = try uint32()
        guard count <= UInt32(max) else { throw StellarXDRError.lengthExceeded(field: field) }
        return try fixedOpaque(Int(count))
    }

    /// Tamanho de um array `T x<max>`, ja conferido contra o teto.
    mutating func arrayCount(max: Int, field: String) throws -> Int {
        let count = try uint32()
        guard count <= UInt32(max) else { throw StellarXDRError.lengthExceeded(field: field) }
        return Int(count)
    }

    func finish() throws {
        guard isAtEnd else { throw StellarXDRError.trailingBytes }
    }
}
