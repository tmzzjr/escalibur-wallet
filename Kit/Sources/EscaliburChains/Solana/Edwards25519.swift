import Foundation

// A pergunta "estes 32 bytes sao um ponto da curva Ed25519?".
//
// A Solana precisa dela para derivar endereco de programa (PDA) e conta de token
// associada (ATA): `find_program_address` tenta bumps de 255 para baixo e aceita o
// primeiro hash que **nao** e ponto da curva, porque um endereco fora da curva nao
// tem chave privada e so o programa consegue assinar por ele. Errar esta checagem
// num unico bump muda o endereco derivado, e um envio de token iria para uma conta
// que ninguem controla.
//
// O CryptoKit nao expoe decompressao de ponto, entao ela esta escrita aqui, sobre
// dados publicos (enderecos e hashes), sem segredo nenhum: nao precisa ser de tempo
// constante, precisa ser correta e legivel.
//
// A aritmetica e um porte linha a linha do TweetNaCl (dominio publico, Bernstein,
// van Gastel, Janssen, Lange, Schwabe, Smetsers): o elemento de campo e um vetor de
// 16 limbs de 16 bits em Int64, e `carry`, `packed`, `+`, `-`, `*`, `pow2523` e a
// decompressao seguem `car25519`, `pack25519`, `A`, `Z`, `M`, `pow2523` e `unpackneg`.
// Quem audita pode por o C ao lado. Em Swift a aritmetica de Int64 aborta em
// estouro em vez de dar a volta, entao um erro de limite aqui derruba o teste em
// vez de produzir um endereco errado em silencio.
//
// A semantica e a do curve25519-dalek, que e o que o validador da Solana usa
// (`solana-address`, `bytes_are_curve_point` → `CompressedEdwardsY::decompress`):
//   1. o bit 255 (sinal de x) e ignorado para decidir se o ponto existe;
//   2. y maior ou igual a p **nao** e recusado: e reduzido mod p;
//   3. x = 0 com bit de sinal 1 **nao** e recusado.
// A RFC 8032 recusa (2) e (3), e o @noble/curves com zip215 = false tambem (e o
// que o `isOnCurve` do web3.js 1.x chama, entao ele diverge do validador ai). Para
// um hash SHA-256 a chance de cair nesses casos e da ordem de 2^-250, mas o que
// vale e a regra da rede, e os testes cobrem os dois casos de borda.

/// Elemento do corpo primo de ordem p = 2^255 - 19.
struct FieldElement25519: Equatable {
    /// 16 limbs de 16 bits, little-endian. Fora de `pack` os limbs podem sair do
    /// intervalo [0, 2^16) e ficar negativos; `pack` devolve a forma canonica.
    var limbs: [Int64]

    init(limbs: [Int64]) {
        precondition(limbs.count == 16)
        self.limbs = limbs
    }

    static let zero = FieldElement25519(limbs: [Int64](repeating: 0, count: 16))
    static let one = FieldElement25519(limbs: [1] + [Int64](repeating: 0, count: 15))

    /// d = -121665 / 121666 mod p, a constante da curva de Edwards.
    static let d = FieldElement25519(limbs: [
        0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
        0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203,
    ])

    /// Raiz quadrada de -1 mod p: 2^((p-1)/4).
    static let sqrtMinusOne = FieldElement25519(limbs: [
        0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
        0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83,
    ])

    /// `unpack25519`: le 32 bytes little-endian e descarta o bit 255. Nao reduz mod
    /// p: um valor entre p e 2^255 - 1 segue como esta e a aritmetica o reduz.
    init(unpacking bytes: [UInt8]) {
        precondition(bytes.count == 32)
        var out = [Int64](repeating: 0, count: 16)
        for i in 0..<16 {
            out[i] = Int64(bytes[2 * i]) + (Int64(bytes[2 * i + 1]) << 8)
        }
        out[15] &= 0x7fff
        self.limbs = out
    }

    /// `car25519`: propaga o vai-um. O vai-um do limb 15 representa multiplos de
    /// 2^256, e 2^256 = 2 * 2^255 ≡ 2 * 19 = 38 (mod p), por isso volta ao limb 0
    /// multiplicado por 38. O deslocamento de 2^16 antes do `>>` vem do C, onde
    /// deslocar negativo para a direita e indefinido; em Swift o `>>` de Int64 e
    /// aritmetico e o resultado e o mesmo.
    static func carry(_ o: inout [Int64]) {
        for i in 0..<16 {
            o[i] += 1 << 16
            let c = o[i] >> 16
            if i < 15 {
                o[i + 1] += c - 1
            } else {
                o[0] += 38 * (c - 1)
            }
            o[i] -= c << 16
        }
    }

    /// `pack25519`: a forma canonica, 0 <= x < p, em 32 bytes little-endian.
    var packed: [UInt8] {
        var t = limbs
        Self.carry(&t)
        Self.carry(&t)
        Self.carry(&t)
        // Duas subtracoes condicionais de p: depois das tres passadas o valor esta
        // abaixo de 2p, e cada passada tira p se o resultado nao ficar negativo.
        for _ in 0..<2 {
            var m = [Int64](repeating: 0, count: 16)
            m[0] = t[0] - 0xffed
            for i in 1..<15 {
                m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let borrow = (m[15] >> 16) & 1
            m[14] &= 0xffff
            if borrow == 0 { t = m }
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            out[2 * i] = UInt8(t[i] & 0xff)
            out[2 * i + 1] = UInt8((t[i] >> 8) & 0xff)
        }
        return out
    }

    /// `par25519`: o bit menos significativo da forma canonica, que e o "sinal" de x.
    var parity: UInt8 { packed[0] & 1 }

    /// `neq25519` invertido: igualdade como elementos do corpo, pela forma canonica.
    static func == (a: FieldElement25519, b: FieldElement25519) -> Bool {
        a.packed == b.packed
    }

    /// `A`
    static func + (a: FieldElement25519, b: FieldElement25519) -> FieldElement25519 {
        FieldElement25519(limbs: (0..<16).map { a.limbs[$0] + b.limbs[$0] })
    }

    /// `Z`
    static func - (a: FieldElement25519, b: FieldElement25519) -> FieldElement25519 {
        FieldElement25519(limbs: (0..<16).map { a.limbs[$0] - b.limbs[$0] })
    }

    /// `M`: produto escolar de 16 x 16 limbs em 31 colunas, com as colunas 16 a 30
    /// dobradas de volta multiplicadas por 38 (mesmo motivo do `carry`).
    static func * (a: FieldElement25519, b: FieldElement25519) -> FieldElement25519 {
        let x = a.limbs, y = b.limbs
        var t = [Int64](repeating: 0, count: 31)
        for i in 0..<16 {
            for j in 0..<16 {
                t[i + j] += x[i] * y[j]
            }
        }
        for i in 0..<15 {
            t[i] += 38 * t[i + 16]
        }
        t.removeLast(15)
        carry(&t)
        carry(&t)
        return FieldElement25519(limbs: t)
    }

    /// `S`
    var squared: FieldElement25519 { self * self }

    /// `pow2523`: x^((p-5)/8) = x^(2^252 - 3). O laco eleva ao quadrado 251 vezes e
    /// multiplica por x em todas as posicoes menos a de indice 1, o que monta o
    /// expoente binario 1111...1101 (252 bits).
    func pow2523() -> FieldElement25519 {
        var c = self
        for a in stride(from: 250, through: 0, by: -1) {
            c = c.squared
            if a != 1 { c = c * self }
        }
        return c
    }
}

/// Decompressao de ponto da curva de Edwards torcida -x^2 + y^2 = 1 + d x^2 y^2.
enum Edwards25519 {
    /// O ponto afim (x, y) codificado nos 32 bytes, ou `nil` se nao ha x que feche a
    /// equacao da curva. Segue a RFC 8032 §5.1.3 passo a passo, com as duas
    /// diferencas do dalek descritas no alto do arquivo.
    static func decompress(_ bytes: [UInt8]) -> (x: FieldElement25519, y: FieldElement25519)? {
        guard bytes.count == 32 else { return nil }
        let y = FieldElement25519(unpacking: bytes)
        let one = FieldElement25519.one

        // x^2 = u / v, com u = y^2 - 1 e v = d y^2 + 1. O v nunca e zero: d nao e
        // quadrado e -1 e, entao -1/d nao e quadrado e d y^2 = -1 nao tem solucao.
        let y2 = y.squared
        let u = y2 - one
        let v = y2 * FieldElement25519.d + one

        // Candidato a raiz: x = u v^3 (u v^7)^((p-5)/8), a forma da RFC que evita
        // uma inversao separada.
        let v2 = v.squared
        let v3 = v2 * v
        let v7 = v3 * v3 * v
        var x = u * v3 * (u * v7).pow2523()

        // Conferencia: se v x^2 = u, x e raiz. Se v x^2 = -u, a raiz e x * sqrt(-1).
        // Qualquer outra coisa quer dizer que u/v nao e quadrado: nao ha ponto.
        if x.squared * v != u {
            x = x * FieldElement25519.sqrtMinusOne
        }
        guard x.squared * v == u else { return nil }

        // O bit 255 escolhe entre x e -x. O dalek nao recusa x = 0 com sinal 1.
        let sign = bytes[31] >> 7
        if x.parity != sign {
            x = FieldElement25519.zero - x
        }
        return (x, y)
    }

    /// Os bytes sao a codificacao de um ponto da curva, pela regra do validador da
    /// Solana. Uma chave publica Ed25519 de verdade sempre esta na curva; um PDA
    /// nunca esta.
    static func isOnCurve(_ bytes: [UInt8]) -> Bool {
        decompress(bytes) != nil
    }
}
