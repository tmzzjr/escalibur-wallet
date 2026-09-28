import CryptoKit
import Foundation

// Ed25519 com chave estendida: a assinatura da Cardano (BIP32-Ed25519, Khovratovich e
// Law, a derivacao das carteiras Shelley pela CIP-1852).
//
// Na Ed25519 comum a chave privada e uma semente de 32 bytes, e o escalar sai do
// SHA-512 dela. Na BIP32-Ed25519 a chave ja e o par (kL, kR): kL e o escalar, kR faz o
// papel da metade de cima do SHA-512 na hora de sortear o nonce. Chave filha nasce
// somando ao escalar, sem passar por hash, entao nao existe semente que o CryptoKit
// aceite para ela: `Curve25519.Signing` so assina a partir da semente. Aqui estao as
// duas operacoes que faltam, e so elas: A = kL * B e a assinatura. A verificacao e a
// Ed25519 de sempre e fica no CryptoKit (`Ed25519.verify`).
//
// A aritmetica e o TweetNaCl (dominio publico, Bernstein, van Gastel, Janssen, Lange,
// Schwabe, Smetsers) linha a linha, o mesmo porte de `Edwards25519.swift` em
// EscaliburChains, agora com a parte que toca segredo: `sel25519`, `cswap`, `add`,
// `scalarmult`, `scalarbase`, `pack`, `modL` e `reduce` seguem o C com os mesmos nomes,
// e quem audita pode por os dois lado a lado. O escalar secreto so decide trocas por
// mascara (`sel25519`), nunca um desvio nem um indice: a escada de Montgomery gasta o
// mesmo tempo para qualquer chave.
//
// A prova de que esta certo esta nos testes: com kL e kR tirados de uma semente como
// manda a RFC 8032 (SHA-512, com os bits de kL ajustados), a assinatura daqui e byte a
// byte a dos vetores da RFC, porque a Ed25519 e deterministica; e com as chaves das
// carteiras Cardano, a chave publica e a dos vetores do wallet-core e da CIP-19.
extension Ed25519 {
    /// A chave publica de uma chave estendida: A = kL * B, com kL como esta (sem hash e
    /// sem ajuste de bits, que a derivacao ja fez). `extendedKey` tem 64 bytes (kL e kR)
    /// ou so os 32 de kL.
    public static func publicKey(extendedKey: SecureBytes) throws -> [UInt8] {
        guard extendedKey.count == 64 || extendedKey.count == 32 else { throw Failure.invalidSeed }
        return extendedKey.withUnsafeBytes { raw in
            Ed25519Extended.scalarbasePacked(UnsafeRawBufferPointer(rebasing: raw[0..<32]))
        }
    }

    /// Assinatura Ed25519 com a chave estendida (kL, kR), como a Cardano confere:
    /// r = SHA-512(kR || m) mod L, R = r * B, S = r + SHA-512(R || A || m) * kL mod L.
    /// Deterministica: a mesma chave e a mesma mensagem dao sempre a mesma assinatura.
    public static func signExtended(_ message: [UInt8], extendedKey: SecureBytes) throws -> [UInt8] {
        guard extendedKey.count == 64 else { throw Failure.invalidSeed }
        return extendedKey.withUnsafeBytes { raw in
            let kL = UnsafeRawBufferPointer(rebasing: raw[0..<32])
            let kR = UnsafeRawBufferPointer(rebasing: raw[32..<64])
            return Ed25519Extended.sign(message, kL: kL, kR: kR)
        }
    }
}

/// A aritmetica da curva para as duas operacoes acima. Nada daqui e publico.
enum Ed25519Extended {
    /// Elemento do corpo de ordem p = 2^255 - 19: 16 limbs de 16 bits em Int64, como o
    /// `gf` do TweetNaCl.
    typealias GF = [Int64]

    static func gf(_ values: [Int64] = []) -> GF {
        var out = GF(repeating: 0, count: 16)
        for (index, value) in values.enumerated() { out[index] = value }
        return out
    }

    static let gf0 = gf()
    static let gf1 = gf([1])
    /// 2d, com d = -121665/121666 a constante da curva.
    static let d2 = gf([0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
                        0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406])
    /// O ponto base B da RFC 8032, coordenadas x e y.
    static let baseX = gf([0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
                           0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169])
    static let baseY = gf([0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
                           0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666])
    /// A ordem do subgrupo, L = 2^252 + 27742317777372353535851937790883648493, little-endian.
    static let order: [Int64] = [0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]

    // MARK: Corpo

    /// `car25519`: propaga o vai-um; o do limb 15 volta ao 0 vezes 38 (2^256 = 38 mod p).
    static func car25519(_ o: inout GF) {
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

    /// `sel25519`: troca p e q quando b = 1, por mascara, sem desvio.
    static func sel25519(_ p: inout GF, _ q: inout GF, _ b: Int64) {
        let c = ~(b - 1)
        for i in 0..<16 {
            let t = c & (p[i] ^ q[i])
            p[i] ^= t
            q[i] ^= t
        }
    }

    /// `pack25519`: forma canonica em 32 bytes little-endian.
    static func pack25519(_ n: GF) -> [UInt8] {
        var t = n
        car25519(&t)
        car25519(&t)
        car25519(&t)
        var m = gf()
        for _ in 0..<2 {
            m[0] = t[0] - 0xffed
            for i in 1..<15 {
                m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let b = (m[15] >> 16) & 1
            m[14] &= 0xffff
            sel25519(&t, &m, 1 - b)
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            out[2 * i] = UInt8(truncatingIfNeeded: t[i] & 0xff)
            out[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
        }
        return out
    }

    static func par25519(_ a: GF) -> UInt8 { pack25519(a)[0] & 1 }

    /// `A`
    static func add(_ a: GF, _ b: GF) -> GF {
        var o = gf()
        for i in 0..<16 { o[i] = a[i] + b[i] }
        return o
    }

    /// `Z`
    static func sub(_ a: GF, _ b: GF) -> GF {
        var o = gf()
        for i in 0..<16 { o[i] = a[i] - b[i] }
        return o
    }

    /// `M`: produto escolar em 31 colunas; as de 16 a 30 voltam vezes 38.
    static func mul(_ a: GF, _ b: GF) -> GF {
        var t = [Int64](repeating: 0, count: 31)
        t.withUnsafeMutableBufferPointer { t in
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    for i in 0..<16 {
                        for j in 0..<16 { t[i + j] += a[i] * b[j] }
                    }
                }
            }
            for i in 0..<15 { t[i] += 38 * t[i + 16] }
        }
        var o = Array(t[0..<16])
        car25519(&o)
        car25519(&o)
        return o
    }

    /// `inv25519`: a^(p-2), expoente publico e fixo.
    static func inv25519(_ i: GF) -> GF {
        var c = i
        for a in stride(from: 253, through: 0, by: -1) {
            c = mul(c, c)
            if a != 2, a != 4 { c = mul(c, i) }
        }
        return c
    }

    // MARK: Pontos (coordenadas estendidas X, Y, Z, T)

    typealias Point = [GF]

    /// `add`: p = p + q.
    static func addPoint(_ p: inout Point, _ q: Point) {
        var a = mul(sub(p[1], p[0]), sub(q[1], q[0]))
        var b = mul(add(p[0], p[1]), add(q[0], q[1]))
        var c = mul(mul(p[3], q[3]), d2)
        var d = mul(p[2], q[2])
        d = add(d, d)
        let e = sub(b, a), f = sub(d, c), g = add(d, c), h = add(b, a)
        p[0] = mul(e, f)
        p[1] = mul(h, g)
        p[2] = mul(g, f)
        p[3] = mul(e, h)
        wipe(&a); wipe(&b); wipe(&c); wipe(&d)
    }

    static func cswap(_ p: inout Point, _ q: inout Point, _ b: Int64) {
        for i in 0..<4 { sel25519(&p[i], &q[i], b) }
    }

    /// `pack`: y com o bit de sinal de x.
    static func pack(_ p: Point) -> [UInt8] {
        let zi = inv25519(p[2])
        let tx = mul(p[0], zi)
        let ty = mul(p[1], zi)
        var r = pack25519(ty)
        r[31] ^= par25519(tx) << 7
        return r
    }

    /// `scalarmult`: escada de Montgomery sobre os 256 bits de `s`, do mais alto ao mais
    /// baixo, com troca por mascara em cada bit.
    static func scalarmult(_ q: Point, _ s: UnsafeRawBufferPointer) -> Point {
        precondition(s.count == 32)
        var p: Point = [gf0, gf1, gf1, gf0]
        var q = q
        for i in stride(from: 255, through: 0, by: -1) {
            let b = Int64((s[i / 8] >> UInt8(i & 7)) & 1)
            cswap(&p, &q, b)
            addPoint(&q, p)
            let doubled = p
            addPoint(&p, doubled)
            cswap(&p, &q, b)
        }
        for i in 0..<4 { wipe(&q[i]) }
        return p
    }

    static func scalarbase(_ s: UnsafeRawBufferPointer) -> Point {
        scalarmult([baseX, baseY, gf1, mul(baseX, baseY)], s)
    }

    static func scalarbasePacked(_ s: UnsafeRawBufferPointer) -> [UInt8] {
        var point = scalarbase(s)
        defer { for i in 0..<4 { wipe(&point[i]) } }
        return pack(point)
    }

    // MARK: Escalares mod L

    /// `modL`: reduz os 64 limbs de `x` modulo L e devolve 32 bytes.
    static func modL(_ x: inout [Int64]) -> [UInt8] {
        precondition(x.count == 64)
        for i in stride(from: 63, through: 32, by: -1) {
            var carry: Int64 = 0
            var j = i - 32
            while j < i - 12 {
                x[j] += carry - 16 * x[i] * order[j - (i - 32)]
                carry = (x[j] + 128) >> 8
                x[j] -= carry << 8
                j += 1
            }
            x[j] += carry
            x[i] = 0
        }
        var carry: Int64 = 0
        for j in 0..<32 {
            x[j] += carry - (x[31] >> 4) * order[j]
            carry = x[j] >> 8
            x[j] &= 255
        }
        for j in 0..<32 { x[j] -= carry * order[j] }
        var r = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            x[i + 1] += x[i] >> 8
            r[i] = UInt8(truncatingIfNeeded: x[i] & 255)
        }
        return r
    }

    /// `reduce`: 64 bytes little-endian mod L.
    static func reduce(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count == 64)
        var x = bytes.map { Int64($0) }
        defer { wipe(&x) }
        return modL(&x)
    }

    // MARK: Assinatura

    static func sign(_ message: [UInt8], kL: UnsafeRawBufferPointer, kR: UnsafeRawBufferPointer) -> [UInt8] {
        let publicKey = scalarbasePacked(kL)

        // O nonce: r = SHA-512(kR || m) mod L. Segredo: vive so ate o fim da funcao.
        var hasher = SHA512()
        hasher.update(bufferPointer: kR)
        hasher.update(data: message)
        var nonceWide = Array(hasher.finalize())
        var r = reduce(nonceWide)
        nonceWide.resetBytes()
        defer { r.resetBytes() }

        let commitment: [UInt8] = r.withUnsafeBytes { scalarbasePacked($0) }

        var challenge = SHA512()
        challenge.update(data: commitment)
        challenge.update(data: publicKey)
        challenge.update(data: message)
        let h = reduce(Array(challenge.finalize()))

        // S = r + h * kL mod L, com kL como esta (a chave estendida nao e reduzida).
        var x = [Int64](repeating: 0, count: 64)
        defer { wipe(&x) }
        for i in 0..<32 { x[i] = Int64(r[i]) }
        for i in 0..<32 {
            for j in 0..<32 { x[i + j] += Int64(h[i]) * Int64(kL[j]) }
        }
        let s = modL(&x)
        return commitment + s
    }

    /// Zera um vetor de trabalho que passou perto do escalar secreto.
    static func wipe(_ v: inout [Int64]) {
        for i in v.indices { v[i] = 0 }
    }
}
