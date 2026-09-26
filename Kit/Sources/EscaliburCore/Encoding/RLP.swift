import Foundation

/// Recursive Length Prefix, a serializacao das transacoes da Ethereum.
///
/// So codificacao: a carteira monta transacoes, nao interpreta as dos outros por RLP.
public indirect enum RLP: Sendable, Equatable {
    case bytes([UInt8])
    case list([RLP])

    /// Inteiro como RLP: big-endian minimo, zero vira string vazia (0x80).
    public static func uint(_ value: BigUInt) -> RLP { .bytes(value.bigEndianBytes) }

    public var encoded: [UInt8] {
        switch self {
        case .bytes(let bytes):
            if bytes.count == 1, bytes[0] < 0x80 { return bytes }
            return Self.header(length: bytes.count, offset: 0x80) + bytes
        case .list(let items):
            let body = items.flatMap(\.encoded)
            return Self.header(length: body.count, offset: 0xC0) + body
        }
    }

    private static func header(length: Int, offset: UInt8) -> [UInt8] {
        if length < 56 { return [offset + UInt8(length)] }
        let lengthBytes = BigUInt(length).bigEndianBytes
        return [offset + 55 + UInt8(lengthBytes.count)] + lengthBytes
    }
}
