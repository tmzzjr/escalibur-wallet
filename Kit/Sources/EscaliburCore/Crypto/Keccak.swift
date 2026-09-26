import Foundation

/// Keccak-256 como a Ethereum usa: o Keccak original, com padding 0x01, e nao o
/// SHA3-256 padronizado depois pelo NIST, que usa 0x06.
///
/// O CryptoKit nao oferece nenhum dos dois ate o iOS 26, e trazer uma biblioteca
/// inteira para uma permutacao de 24 rodadas seria dependencia sem motivo. A
/// implementacao segue a especificacao de referencia do time Keccak linha a linha,
/// e os vetores em KeccakTests conferem o resultado.
public enum Keccak {
    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]

    private static let rotations: [Int] = [
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14,
    ]

    @inline(__always)
    private static func rotl(_ x: UInt64, _ n: Int) -> UInt64 {
        n == 0 ? x : (x << UInt64(n)) | (x >> UInt64(64 - n))
    }

    private static func permute(_ a: inout [UInt64]) {
        var b = [UInt64](repeating: 0, count: 25)
        var c = [UInt64](repeating: 0, count: 5)
        var d = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            // theta
            for x in 0..<5 { c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] }
            for x in 0..<5 { d[x] = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1) }
            for i in 0..<25 { a[i] ^= d[i % 5] }
            // rho e pi
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(a[x + 5 * y], rotations[x + 5 * y])
                }
            }
            // chi
            for y in 0..<5 {
                for x in 0..<5 {
                    a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }
            // iota
            a[0] ^= roundConstants[round]
        }
    }

    public static func hash256<S: Sequence>(_ input: S) -> [UInt8] where S.Element == UInt8 {
        sponge256(input, domain: 0x01)
    }

    /// A mesma esponja com o byte de dominio do SHA3 (0x06). Existe so para os
    /// testes conferirem a permutacao contra o SHA3-256 do sistema em mensagens de
    /// varios blocos, onde vetor publicado de Keccak e raro.
    static func sha3_256ForTesting<S: Sequence>(_ input: S) -> [UInt8] where S.Element == UInt8 {
        sponge256(input, domain: 0x06)
    }

    private static func sponge256<S: Sequence>(_ input: S, domain: UInt8) -> [UInt8] where S.Element == UInt8 {
        let rate = 136  // (1600 - 2 * 256) / 8
        var state = [UInt64](repeating: 0, count: 25)
        var message = Array(input)
        // pad10*1 com o byte de dominio (0x01 no Keccak original da Ethereum)
        message.append(domain)
        while message.count % rate != 0 { message.append(0x00) }
        message[message.count - 1] |= 0x80

        var offset = 0
        while offset < message.count {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for j in 0..<8 { lane |= UInt64(message[offset + i * 8 + j]) << (8 * UInt64(j)) }
                state[i] ^= lane
            }
            permute(&state)
            offset += rate
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for i in 0..<4 {
            for j in 0..<8 { out.append(UInt8((state[i] >> (8 * UInt64(j))) & 0xFF)) }
        }
        return out
    }
}
