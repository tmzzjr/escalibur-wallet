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
// Como no C, as funcoes do corpo escrevem no destino que recebem e nenhuma aloca: todo
// elemento que passa perto do escalar mora numa area de trabalho de tamanho fixo
// (`Workspace`), alocada uma vez por multiplicacao e zerada com `memset_s` no fim. Antes
// cada soma e cada produto devolvia um vetor novo, a escada copiava o ponto a cada bit, e
// o heap ficava com os estados intermediarios sem ninguem zerar (auditoria 4, B3).
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
    /// `gf` do TweetNaCl. Aponta para dentro de uma `Workspace`; `Limbs` e o mesmo, so
    /// para ler (aceita tambem as constantes abaixo).
    typealias GF = UnsafeMutablePointer<Int64>
    typealias Limbs = UnsafePointer<Int64>

    static func gf(_ values: [Int64] = []) -> [Int64] {
        var out = [Int64](repeating: 0, count: 16)
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

    // MARK: Area de trabalho

    /// Um ponto em coordenadas estendidas (X, Y, Z, T): quatro elementos seguidos.
    struct Point {
        let base: GF
        subscript(_ i: Int) -> GF { base + 16 * i }
    }

    /// Tudo o que uma multiplicacao `s * Q` escreve: os dois pontos da escada, os
    /// temporarios de `addPoint`, `pack`, `inv25519` e `pack25519`, as 31 colunas do
    /// produto e os 32 bytes de `par25519`. Cada funcao usa so os seus, e nenhuma chama
    /// outra que use os mesmos no meio do caminho.
    struct Workspace {
        static let elements = 23
        static let columnCount = 31
        static let limbCount = elements * 16 + columnCount

        let limbs: GF
        let bytes: UnsafeMutablePointer<UInt8>

        private func element(_ index: Int) -> GF { limbs + 16 * index }

        var p: Point { Point(base: element(0)) }
        var q: Point { Point(base: element(4)) }
        // `addPoint`
        var a: GF { element(8) }
        var b: GF { element(9) }
        var c: GF { element(10) }
        var d: GF { element(11) }
        var t: GF { element(12) }
        var e: GF { element(13) }
        var f: GF { element(14) }
        var g: GF { element(15) }
        var h: GF { element(16) }
        // `pack`
        var tx: GF { element(17) }
        var ty: GF { element(18) }
        var zi: GF { element(19) }
        // `inv25519`
        var inverse: GF { element(20) }
        // `pack25519`
        var packT: GF { element(21) }
        var packM: GF { element(22) }
        // `mul`
        var columns: GF { limbs + 16 * Self.elements }
    }

    /// Roda `body` com uma area de trabalho nova e zerada, e a zera com `memset_s` na
    /// volta, antes de devolver a memoria.
    static func withWorkspace<R>(_ body: (Workspace) -> R) -> R {
        let limbCount = Workspace.limbCount
        let limbBytes = limbCount * MemoryLayout<Int64>.stride
        let limbs = GF.allocate(capacity: limbCount)
        limbs.initialize(repeating: 0, count: limbCount)
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
        bytes.initialize(repeating: 0, count: 32)
        defer {
            memset_s(limbs, limbBytes, 0, limbBytes)
            memset_s(bytes, 32, 0, 32)
            limbs.deallocate()
            bytes.deallocate()
        }
        return body(Workspace(limbs: limbs, bytes: bytes))
    }

    // MARK: Corpo

    static func set25519(_ r: GF, _ a: Limbs) {
        for i in 0..<16 { r[i] = a[i] }
    }

    /// `car25519`: propaga o vai-um; o do limb 15 volta ao 0 vezes 38 (2^256 = 38 mod p).
    static func car25519(_ o: GF) {
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
    static func sel25519(_ p: GF, _ q: GF, _ b: Int64) {
        let c = ~(b - 1)
        for i in 0..<16 {
            let t = c & (p[i] ^ q[i])
            p[i] ^= t
            q[i] ^= t
        }
    }

    /// `pack25519`: forma canonica em 32 bytes little-endian, escrita em `o`.
    static func pack25519(_ o: UnsafeMutablePointer<UInt8>, _ n: Limbs, _ w: Workspace) {
        let t = w.packT, m = w.packM
        set25519(t, n)
        car25519(t)
        car25519(t)
        car25519(t)
        for _ in 0..<2 {
            m[0] = t[0] - 0xffed
            for i in 1..<15 {
                m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let b = (m[15] >> 16) & 1
            m[14] &= 0xffff
            sel25519(t, m, 1 - b)
        }
        for i in 0..<16 {
            o[2 * i] = UInt8(truncatingIfNeeded: t[i] & 0xff)
            o[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
        }
    }

    static func par25519(_ a: Limbs, _ w: Workspace) -> UInt8 {
        pack25519(w.bytes, a, w)
        return w.bytes[0] & 1
    }

    /// `A`
    static func add(_ o: GF, _ a: Limbs, _ b: Limbs) {
        for i in 0..<16 { o[i] = a[i] + b[i] }
    }

    /// `Z`
    static func sub(_ o: GF, _ a: Limbs, _ b: Limbs) {
        for i in 0..<16 { o[i] = a[i] - b[i] }
    }

    /// `M`: produto escolar em 31 colunas; as de 16 a 30 voltam vezes 38. `o` pode ser
    /// `a` ou `b`: o produto inteiro fica nas colunas antes de `o` ser escrito.
    static func mul(_ o: GF, _ a: Limbs, _ b: Limbs, _ w: Workspace) {
        let t = w.columns
        for i in 0..<31 { t[i] = 0 }
        for i in 0..<16 {
            for j in 0..<16 { t[i + j] += a[i] * b[j] }
        }
        for i in 0..<15 { t[i] += 38 * t[i + 16] }
        for i in 0..<16 { o[i] = t[i] }
        car25519(o)
        car25519(o)
    }

    /// `inv25519`: a^(p-2), expoente publico e fixo.
    static func inv25519(_ o: GF, _ i: Limbs, _ w: Workspace) {
        let c = w.inverse
        set25519(c, i)
        for a in stride(from: 253, through: 0, by: -1) {
            mul(c, c, c, w)
            if a != 2, a != 4 { mul(c, c, i, w) }
        }
        set25519(o, c)
    }

    // MARK: Pontos (coordenadas estendidas X, Y, Z, T)

    /// `add`: p = p + q. `p` e `q` podem ser o mesmo ponto (a duplicacao da escada): tudo
    /// que le os dois acontece antes de `p` ser escrito, como no C.
    static func addPoint(_ p: Point, _ q: Point, _ w: Workspace) {
        let a = w.a, b = w.b, c = w.c, d = w.d, t = w.t
        let e = w.e, f = w.f, g = w.g, h = w.h
        sub(a, p[1], p[0])
        sub(t, q[1], q[0])
        mul(a, a, t, w)
        add(b, p[0], p[1])
        add(t, q[0], q[1])
        mul(b, b, t, w)
        mul(c, p[3], q[3], w)
        mul(c, c, d2, w)
        mul(d, p[2], q[2], w)
        add(d, d, d)
        sub(e, b, a)
        sub(f, d, c)
        add(g, d, c)
        add(h, b, a)
        mul(p[0], e, f, w)
        mul(p[1], h, g, w)
        mul(p[2], g, f, w)
        mul(p[3], e, h, w)
    }

    static func cswap(_ p: Point, _ q: Point, _ b: Int64) {
        for i in 0..<4 { sel25519(p[i], q[i], b) }
    }

    /// `pack`: y com o bit de sinal de x, em `r`.
    static func pack(_ r: UnsafeMutablePointer<UInt8>, _ p: Point, _ w: Workspace) {
        inv25519(w.zi, p[2], w)
        mul(w.tx, p[0], w.zi, w)
        mul(w.ty, p[1], w.zi, w)
        pack25519(r, w.ty, w)
        r[31] ^= par25519(w.tx, w) << 7
    }

    /// `scalarmult`: escada de Montgomery sobre os 256 bits de `s`, do mais alto ao mais
    /// baixo, com troca por mascara em cada bit. Os dois pontos ficam no lugar: nenhuma
    /// copia por bit.
    static func scalarmult(_ p: Point, _ q: Point, _ s: UnsafeRawBufferPointer, _ w: Workspace) {
        precondition(s.count == 32)
        set25519(p[0], gf0)
        set25519(p[1], gf1)
        set25519(p[2], gf1)
        set25519(p[3], gf0)
        for i in stride(from: 255, through: 0, by: -1) {
            let b = Int64((s[i / 8] >> UInt8(i & 7)) & 1)
            cswap(p, q, b)
            addPoint(q, p, w)
            addPoint(p, p, w)
            cswap(p, q, b)
        }
    }

    static func scalarbase(_ p: Point, _ s: UnsafeRawBufferPointer, _ w: Workspace) {
        let q = w.q
        set25519(q[0], baseX)
        set25519(q[1], baseY)
        set25519(q[2], gf1)
        mul(q[3], baseX, baseY, w)
        scalarmult(p, q, s, w)
    }

    /// s * B empacotado. O ponto e publico (a chave publica ou o R da assinatura); o
    /// caminho ate ele fica na area de trabalho, zerada na volta.
    static func scalarbasePacked(_ s: UnsafeRawBufferPointer) -> [UInt8] {
        withWorkspace { w in
            scalarbase(w.p, s, w)
            var out = [UInt8](repeating: 0, count: 32)
            out.withUnsafeMutableBufferPointer { pack($0.baseAddress!, w.p, w) }
            return out
        }
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
        //
        // Limite conhecido: o estado do `SHA512` do CryptoKit passou por kR, e nem ele nem
        // o digesto que `finalize` devolve sao zeraveis daqui (o tipo nao expoe a memoria
        // dele). O que e nosso, os 64 bytes copiados e o nonce reduzido, e zerado.
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

    /// Zera um vetor de trabalho que passou perto do escalar secreto, com `memset_s`: um
    /// laco de atribuicoes antes de a memoria ser solta pode sair como escrita morta.
    static func wipe(_ v: inout [Int64]) {
        v.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { memset_s(base, raw.count, 0, raw.count) }
        }
    }
}
