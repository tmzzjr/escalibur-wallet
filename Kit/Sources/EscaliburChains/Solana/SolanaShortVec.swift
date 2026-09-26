import Foundation

/// compact-u16 (o "short_vec" do solana-sdk): o comprimento das listas da mensagem,
/// em 1 a 3 bytes, 7 bits por byte, little-endian, bit alto = continua.
///
/// A leitura segue as regras do `solana-short-vec`, que e o que o validador aplica:
/// no maximo 3 bytes, valor ate 0xFFFF, e **nenhuma codificacao alternativa**
/// (`80 00` para zero, `81 80 00` para um). Aceitar alias deixaria duas sequencias
/// de bytes diferentes com o mesmo significado, e uma mensagem que a carteira
/// decodifica de um jeito e o no de outro e exatamente o que um atacante procura.
public enum SolanaShortVec {
    public enum Problem: Error, Equatable, Sendable {
        case truncated
        case alias
        case overflow
    }

    public static func encode(_ value: Int) -> [UInt8] {
        precondition((0...0xFFFF).contains(value), "compact-u16 fora do intervalo")
        var remaining = value
        var out = [UInt8]()
        while true {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining == 0 {
                out.append(byte)
                return out
            }
            byte |= 0x80
            out.append(byte)
        }
    }

    /// Le um compact-u16 a partir de `offset`. Devolve o valor e quantos bytes leu.
    public static func decode(_ bytes: [UInt8], at offset: Int = 0) throws -> (value: Int, length: Int) {
        var value = 0
        for index in 0..<3 {
            guard offset + index < bytes.count else { throw Problem.truncated }
            let byte = bytes[offset + index]
            let chunk = Int(byte & 0x7F)
            // Um byte final zero depois do primeiro e um alias de um valor mais curto.
            if byte == 0, index > 0 { throw Problem.alias }
            value |= chunk << (7 * index)
            if byte & 0x80 == 0 {
                guard value <= 0xFFFF else { throw Problem.overflow }
                return (value, index + 1)
            }
            // O terceiro byte so carrega 2 bits (16 - 14); continuar alem dele estoura.
            if index == 2 { throw Problem.overflow }
        }
        throw Problem.overflow
    }
}

/// Leitor sequencial de bytes para decodificar mensagem e transacao. Cada leitura
/// confere o limite antes, e o fim da mensagem tem de coincidir com o fim dos bytes.
struct SolanaByteReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw SolanaShortVec.Problem.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw SolanaShortVec.Problem.truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func shortVecLength() throws -> Int {
        let (value, length) = try SolanaShortVec.decode(bytes, at: offset)
        offset += length
        return value
    }

    mutating func peek() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }
}
