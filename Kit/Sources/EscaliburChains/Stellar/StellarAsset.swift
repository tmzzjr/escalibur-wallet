import EscaliburCore
import Foundation

/// Um ativo Stellar: o XLM nativo, ou codigo mais emissor.
///
/// **Codigo sozinho nao identifica ativo.** Qualquer conta pode emitir um "USDC";
/// o que distingue o verdadeiro e o emissor. Por isso a igualdade compara os dois, a
/// tela mostra o emissor inteiro, e o planejamento so aceita ativos da lista curada
/// que o chamador passa (codigo e emissor exatos).
public struct StellarAsset: Hashable, Sendable, CustomStringConvertible {
    /// "XLM" no nativo; de 1 a 12 caracteres ASCII alfanumericos nos outros.
    public let code: String
    /// `nil` so no XLM.
    public let issuer: StellarAccountID?

    public static let native = StellarAsset(uncheckedCode: "XLM", issuer: nil)

    private init(uncheckedCode code: String, issuer: StellarAccountID?) {
        self.code = code
        self.issuer = issuer
    }

    public init(code: String, issuer: StellarAccountID) throws {
        guard Self.isValidCode(code) else { throw StellarXDRError.invalidAssetCode }
        self.init(uncheckedCode: code, issuer: issuer)
    }

    public init(code: String, issuer: String) throws {
        guard let account = StellarAccountID(address: issuer) else { throw StellarXDRError.invalidAccount }
        try self.init(code: code, issuer: account)
    }

    public var isNative: Bool { issuer == nil }

    public var description: String {
        guard let issuer else { return code }
        return "\(code):\(issuer.address)"
    }

    /// A regra do stellar-core (`isAssetValid`): so letras e digitos ASCII, de 1 a
    /// 12. Ate 4 vira alphanum4; de 5 a 12, alphanum12. Assim cada codigo tem uma so
    /// codificacao e o decodificador consegue exigir a forma canonica.
    static func isValidCode(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        return (1...12).contains(bytes.count) && bytes.allSatisfy(isAlphanumeric)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    static let typeNative: Int32 = 0
    static let typeAlphanum4: Int32 = 1
    static let typeAlphanum12: Int32 = 2
    static let typePoolShare: Int32 = 3

    func encode(to writer: inout StellarXDRWriter) {
        guard let issuer else {
            writer.int32(Self.typeNative)
            return
        }
        let bytes = Array(code.utf8)
        let width = bytes.count <= 4 ? 4 : 12
        writer.int32(width == 4 ? Self.typeAlphanum4 : Self.typeAlphanum12)
        writer.fixedOpaque(bytes + [UInt8](repeating: 0, count: width - bytes.count))
        issuer.encode(to: &writer)
    }

    static func decode(from reader: inout StellarXDRReader) throws -> StellarAsset {
        let type = try reader.int32()
        let code: String
        switch type {
        case typeNative:
            return .native
        case typeAlphanum4:
            code = try decodeCode(try reader.fixedOpaque(4), minimumLength: 1)
        case typeAlphanum12:
            code = try decodeCode(try reader.fixedOpaque(12), minimumLength: 5)
        case typePoolShare:
            throw StellarXDRError.unsupported("cota de pool de liquidez")
        default:
            throw StellarXDRError.unknownDiscriminant(field: "Asset", value: type)
        }
        return try StellarAsset(code: code, issuer: try StellarAccountID.decode(from: &reader))
    }

    /// Zeros so no fim, nada de zero no meio, e o tamanho minimo do tipo: um
    /// alphanum12 com 4 letras seria a segunda grafia de um alphanum4.
    private static func decodeCode(_ raw: [UInt8], minimumLength: Int) throws -> String {
        let length = raw.firstIndex(of: 0) ?? raw.count
        guard length >= minimumLength,
              raw[length...].allSatisfy({ $0 == 0 }),
              raw[..<length].allSatisfy(isAlphanumeric)
        else { throw StellarXDRError.invalidAssetCode }
        return String(decoding: raw[..<length], as: UTF8.self)
    }
}

/// O memo da transacao. O tipo importa tanto quanto o valor: corretora que espera
/// memo ID e recebe o mesmo numero como texto nao credita o deposito.
public enum StellarMemo: Hashable, Sendable {
    case none
    /// Ate 28 bytes. Bytes, nao `String`, porque a rede aceita texto que nao e UTF-8
    /// e o decodificador precisa devolver exatamente o que leu.
    case text([UInt8])
    case id(UInt64)
    case hash([UInt8])
    case returnHash([UInt8])

    public static let maxTextBytes = 28

    public enum Problem: Error, Equatable, Sendable {
        case textTooLong
        case notAnUnsignedInteger
        case hashMustBe32Bytes
    }

    /// Texto digitado pelo dono, em UTF-8, sem nenhuma normalizacao: o memo que a
    /// corretora mostra e comparado byte a byte.
    public static func fromText(_ text: String) throws -> StellarMemo {
        let bytes = Array(text.utf8)
        guard bytes.count <= maxTextBytes else { throw Problem.textTooLong }
        return .text(bytes)
    }

    /// Memo ID a partir do texto decimal. Estrito como o js-stellar-base: so
    /// digitos, sem sinal, sem ponto, ate 2^64 - 1. O limite importa: antes da
    /// correcao dele, "18446744073709551616" virava 0 em silencio.
    public static func fromID(_ decimal: String) throws -> StellarMemo {
        guard !decimal.isEmpty, decimal.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = UInt64(decimal)
        else { throw Problem.notAnUnsignedInteger }
        return .id(value)
    }

    public static func fromHash(hex: String) throws -> StellarMemo {
        guard let bytes = Hex.decode(hex), bytes.count == 32 else { throw Problem.hashMustBe32Bytes }
        return .hash(bytes)
    }

    var isValid: Bool {
        switch self {
        case .none, .id: return true
        case .text(let bytes): return bytes.count <= Self.maxTextBytes
        case .hash(let bytes), .returnHash(let bytes): return bytes.count == 32
        }
    }

    public var isNone: Bool { self == .none }

    /// Tipo e valor como a tela mostra.
    public var reviewLabel: String {
        switch self {
        case .none: return "Memo"
        case .text: return "Memo (texto)"
        case .id: return "Memo (ID)"
        case .hash: return "Memo (hash)"
        case .returnHash: return "Memo (retorno)"
        }
    }

    /// O memo para a conferencia contra o digitado; sem memo, nenhum.
    public var recipientTag: String? {
        if case .none = self { return nil }
        return reviewValue
    }

    public var reviewValue: String {
        switch self {
        case .none: return "sem memo"
        case .text(let bytes):
            // Texto que nao e UTF-8 aparece em hex, marcado, para nunca ser
            // mostrado como outra coisa.
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            return "hex " + Hex.encode(bytes)
        case .id(let value): return String(value)
        case .hash(let bytes), .returnHash(let bytes): return Hex.encode(bytes)
        }
    }

    func encode(to writer: inout StellarXDRWriter) {
        switch self {
        case .none:
            writer.int32(0)
        case .text(let bytes):
            writer.int32(1)
            writer.variableOpaque(bytes)
        case .id(let value):
            writer.int32(2)
            writer.uint64(value)
        case .hash(let bytes):
            writer.int32(3)
            writer.fixedOpaque(bytes)
        case .returnHash(let bytes):
            writer.int32(4)
            writer.fixedOpaque(bytes)
        }
    }

    static func decode(from reader: inout StellarXDRReader) throws -> StellarMemo {
        let type = try reader.int32()
        switch type {
        case 0: return .none
        case 1: return .text(try reader.variableOpaque(max: maxTextBytes, field: "Memo.text"))
        case 2: return .id(try reader.uint64())
        case 3: return .hash(try reader.fixedOpaque(32))
        case 4: return .returnHash(try reader.fixedOpaque(32))
        default: throw StellarXDRError.unknownDiscriminant(field: "Memo", value: type)
        }
    }
}

/// Preco de oferta como fracao `n/d` de int32: quanto do ativo comprado por unidade
/// do vendido.
///
/// O preco e sempre calculado **aqui**, a partir das quantidades inteiras que o dono
/// digitou, nunca recebido pronto de API. Quando a fracao exata nao cabe em int32,
/// a aproximacao e sempre **para cima** (a menor fracao representavel que nao e
/// menor que a pedida): a oferta pode demorar mais a executar, mas nunca entrega
/// menos do que o minimo que o dono viu na tela.
public struct StellarPrice: Hashable, Sendable, CustomStringConvertible {
    public let n: Int32
    public let d: Int32

    public enum Problem: Error, Equatable, Sendable {
        case zero
        /// Nao existe fracao de int32 perto o bastante: preco grande ou pequeno demais.
        case notRepresentable
    }

    /// Erro relativo maximo da aproximacao para cima: 1 ponto-base. Acima disso a
    /// ordem seria outra ordem, e o dono precisa decidir de novo.
    static let maxRelativeErrorDenominator: UInt32 = 10_000

    init(n: Int32, d: Int32) {
        self.n = n
        self.d = d
    }

    public var description: String { "\(n)/\(d)" }

    /// A menor fracao `n/d`, com `n` e `d` em int32 positivo, tal que
    /// `n/d >= receive/sell`. Exata quando a fracao reduzida cabe.
    public static func atLeast(receive: BigUInt, forSelling sell: BigUInt) throws -> StellarPrice {
        guard !receive.isZero, !sell.isZero else { throw Problem.zero }
        let divisor = gcd(receive, sell)
        let p = receive / divisor
        let q = sell / divisor
        let limit = BigUInt(UInt32(Int32.max))
        let (n, d): (BigUInt, BigUInt)
        if p <= limit, q <= limit {
            (n, d) = (p, q)
        } else {
            guard let upper = bestUpperApproximation(p, q, limit: limit) else { throw Problem.notRepresentable }
            (n, d) = upper
            // n/d - p/q <= (1/10000) * p/q  <=>  (n*q - p*d) * 10000 <= p*d
            let excess = n * q - p * d
            guard excess * BigUInt(maxRelativeErrorDenominator) <= p * d else { throw Problem.notRepresentable }
        }
        guard let nn = n.uint64, let dd = d.uint64 else { throw Problem.notRepresentable }
        return StellarPrice(n: Int32(nn), d: Int32(dd))
    }

    /// Melhor aproximacao por cima de p/q com numerador e denominador <= limit, pelas
    /// fracoes continuas. Convergentes de indice impar ficam acima de p/q; entre dois
    /// deles, os semiconvergentes tambem. Quando o proximo convergente estoura o
    /// limite, a resposta e o maior semiconvergente que cabe (indice impar) ou o
    /// ultimo convergente de cima (indice par).
    static func bestUpperApproximation(_ p: BigUInt, _ q: BigUInt, limit: BigUInt) -> (BigUInt, BigUInt)? {
        var (h2, h1) = (BigUInt(0), BigUInt(1))   // h(i-2), h(i-1)
        var (k2, k1) = (BigUInt(1), BigUInt(0))   // k(i-2), k(i-1)
        var (numerator, denominator) = (p, q)
        var index = 0
        while !denominator.isZero {
            let (a, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
            let h = a * h1 + h2
            let k = a * k1 + k2
            if h > limit || k > limit {
                if index % 2 == 1 {
                    // Maior t em [0, a) com t*h1 + h2 e t*k1 + k2 dentro do limite.
                    let tH = h1.isZero ? a : (limit - h2) / h1
                    let tK = k1.isZero ? a : (limit - k2) / k1
                    let t = min(tH, tK, a)
                    let candidate = (t * h1 + h2, t * k1 + k2)
                    return candidate.1.isZero ? nil : candidate
                }
                return k1.isZero ? nil : (h1, k1)
            }
            (h2, h1) = (h1, h)
            (k2, k1) = (k1, k)
            (numerator, denominator) = (denominator, remainder)
            index += 1
        }
        return (h1, k1)
    }

    private static func gcd(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var (x, y) = (a, b)
        while !y.isZero { (x, y) = (y, x % y) }
        return x
    }

    func encode(to writer: inout StellarXDRWriter) {
        writer.int32(n)
        writer.int32(d)
    }

    static func decode(from reader: inout StellarXDRReader) throws -> StellarPrice {
        StellarPrice(n: try reader.int32(), d: try reader.int32())
    }
}
