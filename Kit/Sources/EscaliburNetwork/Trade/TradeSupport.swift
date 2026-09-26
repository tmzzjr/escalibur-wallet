import EscaliburChains
import EscaliburCore
import Foundation

// Apoio dos clientes de troca: erros, leitura estrita das respostas e o recorte de
// JSON cru.
//
// Nenhum valor monetario de resposta passa por `Double`: quantias chegam como texto
// decimal (ou hex) e viram `BigUInt`; numero JSON onde se espera quantia e recusado. O
// que o provedor diz serve para montar a `TradeProposal`; quem decide e a validacao em
// EscaliburChains/Trade.

public enum TradeProviderError: Error, Equatable, Sendable {
    /// O provedor nao atende esta rede ou este par na v1.
    case unsupported(TradeProvider)
    /// O provedor respondeu, mas sem rota.
    case noRoute(TradeProvider)
    /// Resposta fora do formato conferido: campo faltando, numero onde devia vir texto.
    case badResponse(TradeProvider, String)
    case http(TradeProvider, HTTPClient.Failure)
    /// O circuit breaker tirou o provedor da vez.
    case benched(TradeProvider)
    /// A cotacao chegou, mas a validacao recusou.
    case refused(TradeProvider, TradeRefusal)
    /// O prazo duro passou antes da resposta.
    case timedOut(TradeProvider)
}

/// O que o agregador pede a um provedor.
public struct TradeQuoteRequest: Sendable, Equatable {
    public let intent: TradeIntent
    /// Preco do gas em wei (a De¹ exige; os outros ignoram).
    public let gasPriceWei: BigUInt

    public init(intent: TradeIntent, gasPriceWei: BigUInt) {
        self.intent = intent
        self.gasPriceWei = gasPriceWei
    }
}

/// Um provedor de cotacao: pede, le a resposta e devolve a proposta crua.
public protocol TradeQuoteSource: Sendable {
    var provider: TradeProvider { get }
    func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal
}

enum TradeWire {
    /// Endereco em minusculas, como as APIs aceitam (algumas recusam checksum errado,
    /// nenhuma recusa minusculas).
    static func lower(_ address: EVMAddress) -> String {
        "0x" + Hex.encode(address.bytes)
    }

    /// Token vendido ou comprado com a sentinela do provedor para o nativo.
    static func token(_ asset: TradeAsset, native: String) -> String {
        asset.contract.map(lower) ?? native
    }

    static let eeee = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    static let zero = "0x0000000000000000000000000000000000000000"

    static func amount(_ text: String?, _ provider: TradeProvider, _ field: String) throws -> BigUInt {
        guard let text, !text.isEmpty else { throw TradeProviderError.badResponse(provider, field) }
        if text.hasPrefix("0x") {
            guard let value = BigUInt(hex: text) else { throw TradeProviderError.badResponse(provider, field) }
            return value
        }
        guard let value = BigUInt(decimal: text) else { throw TradeProviderError.badResponse(provider, field) }
        return value
    }

    static func address(_ text: String?, _ provider: TradeProvider, _ field: String) throws -> EVMAddress {
        guard let text, let bytes = Hex.decode(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text), let address = EVMAddress(bytes: bytes) else {
            throw TradeProviderError.badResponse(provider, field)
        }
        return address
    }

    static func bytes(_ text: String?, _ provider: TradeProvider, _ field: String) throws -> [UInt8] {
        guard let text, text.hasPrefix("0x"), let bytes = Hex.decode(String(text.dropFirst(2))), bytes.count >= 4 else {
            throw TradeProviderError.badResponse(provider, field)
        }
        return bytes
    }

    /// Impacto em bps pelos valores em dolar que o provedor informa (texto decimal):
    /// (entrada - saida) / entrada. So para os degraus de risco e o gatilho da divisao.
    static func impactBps(inUSD: String?, outUSD: String?) -> Int? {
        guard let inText = inUSD, let outText = outUSD, let a = TradeDecimal(inText), let b = TradeDecimal(outText), !a.isZero else { return nil }
        let scale = max(a.scale, b.scale)
        let x = a.mantissa * BigUInt.power(of: 10, scale - a.scale)
        let y = b.mantissa * BigUInt.power(of: 10, scale - b.scale)
        guard x > y else { return 0 }
        let bps = (x - y) * 10_000 / x
        return Int(min(bps.uint64 ?? 10_000, 10_000))
    }

    /// "0.02%" ou "-0,01%" (De¹): bps, negativo vira zero.
    static func percentText(_ text: String?) -> Int? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix("%") { text.removeLast() }
        if text.hasPrefix("-") { return 0 }
        guard let value = TradeDecimal(text) else { return nil }
        let bps = value.mantissa * BigUInt.power(of: 10, 2) / BigUInt.power(of: 10, value.scale)
        return Int(min(bps.uint64 ?? 10_000, 10_000))
    }

    static func url(_ base: URL, _ path: String, _ query: [(String, String)]) throws -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { throw HTTPClient.Failure.invalidResponse }
        return url
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ provider: TradeProvider) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TradeProviderError.badResponse(provider, "json")
        }
    }
}

/// Recorte de um valor JSON de dentro de uma resposta, byte a byte, sem reserializar.
///
/// A KyberSwap exige que o `routeSummary` volte no `route/build` exatamente como veio
/// (ele carrega um checksum). Reserializar com `JSONSerialization` trocaria numero,
/// ordem de chave e escape. Aqui o valor da chave de topo e copiado tal qual.
enum RawJSON {
    enum Failure: Error { case malformed, missing }

    /// O valor cru da chave `key` no objeto em `path` (chaves de objetos aninhados, a
    /// partir da raiz).
    static func value(_ data: Data, path: [String]) throws -> Data {
        let bytes = [UInt8](data)
        var range = 0..<bytes.count
        for key in path { range = try member(bytes, key, in: range) }
        return Data(bytes[range])
    }

    /// Procura `key` no objeto que comeca em `range` e devolve o intervalo do valor.
    static func member(_ b: [UInt8], _ key: String, in range: Range<Int>) throws -> Range<Int> {
        var i = range.lowerBound
        skipSpace(b, &i)
        guard i < range.upperBound, b[i] == UInt8(ascii: "{") else { throw Failure.malformed }
        i += 1
        let wanted = Array(key.utf8)
        while i < range.upperBound {
            skipSpace(b, &i)
            guard i < range.upperBound else { break }
            if b[i] == UInt8(ascii: "}") { break }
            let keyRange = try string(b, &i)
            skipSpace(b, &i)
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw Failure.malformed }
            i += 1
            skipSpace(b, &i)
            let start = i
            try skipValue(b, &i)
            let found = Array(b[(keyRange.lowerBound + 1)..<(keyRange.upperBound - 1)])
            if found == wanted { return start..<i }
            skipSpace(b, &i)
            if i < b.count, b[i] == UInt8(ascii: ",") { i += 1 }
        }
        throw Failure.missing
    }

    static func skipSpace(_ b: [UInt8], _ i: inout Int) {
        while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
    }

    /// Uma string JSON a partir das aspas; devolve o intervalo com as aspas.
    static func string(_ b: [UInt8], _ i: inout Int) throws -> Range<Int> {
        guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw Failure.malformed }
        let start = i
        i += 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { i += 1; return start..<i }
            i += 1
        }
        throw Failure.malformed
    }

    static func skipValue(_ b: [UInt8], _ i: inout Int) throws {
        guard i < b.count else { throw Failure.malformed }
        switch b[i] {
        case UInt8(ascii: "\""):
            _ = try string(b, &i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while i < b.count {
                switch b[i] {
                case UInt8(ascii: "\""): _ = try string(b, &i); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { i += 1; return }
                default: break
                }
                i += 1
            }
            throw Failure.malformed
        default:
            while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
        }
    }
}
