import EscaliburChains
import EscaliburCore
import Foundation

// JSON-RPC da Solana, tipado.
//
// O `JSONRPC` generico do modulo le numeros como `Double`, e lamports passam de
// 2^53 (9 milhoes de SOL) sem aviso. Aqui cada resposta e decodificada em struct
// com `UInt64` onde a rede manda u64, e o texto cru da resposta nunca vai para log.

/// Erro devolvido pelo no (o campo `error` do JSON-RPC).
public struct SolanaRPCError: Error, Sendable, Equatable, Decodable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// O no respondeu algo que nao faz sentido (altura de bloco fora do blockhash, conta
/// com dono inesperado). O pool passa para o proximo provedor.
public struct SolanaInconsistentResponse: Error, Sendable, Equatable {
    public let reason: String
}

enum SolanaRPC {
    private struct Request: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let method: String
        let params: [JSONValue]
    }

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: SolanaRPCError?
    }

    static func body(_ method: String, _ params: [JSONValue]) throws -> Data {
        try JSONEncoder().encode(Request(method: method, params: params))
    }

    /// Resultado obrigatorio: `null` e erro.
    static func decode<T: Decodable>(_ data: Data, method: String, as type: T.Type = T.self) throws -> T {
        guard let value = try decodeOptional(data, method: method, as: T.self) else { throw HTTPClient.Failure.invalidResponse }
        return value
    }

    /// Resultado que pode ser `null` (transacao que o no nao conhece, por exemplo).
    static func decodeOptional<T: Decodable>(_ data: Data, method: String, as type: T.Type = T.self) throws -> T? {
        let envelope: Envelope<T>
        do { envelope = try JSONDecoder().decode(Envelope<T>.self, from: data) } catch { throw HTTPClient.Failure.decoding(method) }
        if let error = envelope.error { throw error }
        return envelope.result
    }

    static func call<T: Decodable>(
        _ url: URL, _ method: String, _ params: [JSONValue], as type: T.Type = T.self, client: HTTPClient
    ) async throws -> T {
        let data = try await client.post(url, json: try body(method, params))
        return try decode(data, method: method, as: T.self)
    }

    static func callOptional<T: Decodable>(
        _ url: URL, _ method: String, _ params: [JSONValue], as type: T.Type = T.self, client: HTTPClient
    ) async throws -> T? {
        let data = try await client.post(url, json: try body(method, params))
        return try decodeOptional(data, method: method, as: T.self)
    }
}

// MARK: Formatos de resposta

struct RPCContext: Decodable, Sendable {
    let slot: UInt64
}

/// `{context, value}`, o envelope das leituras com commitment.
struct RPCContextual<V: Decodable & Sendable>: Decodable, Sendable {
    let context: RPCContext
    let value: V
}

/// `{context, value}` com `value` que pode ser `null` (conta inexistente).
struct RPCContextualOptional<V: Decodable & Sendable>: Decodable, Sendable {
    let context: RPCContext
    let value: V?
}

struct RPCBlockhash: Decodable, Sendable {
    let blockhash: String
    let lastValidBlockHeight: UInt64
}

struct RPCEpochInfo: Decodable, Sendable {
    let absoluteSlot: UInt64
    let blockHeight: UInt64
    let epoch: UInt64
}

struct RPCPrioritizationFee: Decodable, Sendable {
    let slot: UInt64
    let prioritizationFee: UInt64
}

/// Uma conta como o `getAccountInfo` devolve. `rentEpoch` fica de fora de proposito:
/// e u64::MAX nas contas isentas e nao serve para nada aqui.
struct RPCAccount: Decodable, Sendable {
    let lamports: UInt64
    let owner: String
    let executable: Bool
    let space: UInt64?
    let data: RPCAccountData
}

/// `data` vem como `["<base64>", "base64"]` ou, com `jsonParsed` e um parser
/// conhecido no no, como `{program, parsed, space}`. Campos u64 do `parsed` que
/// importam (taxa maxima do Token-2022) sao relidos com struct tipado a partir da
/// resposta crua, nunca deste `JSONValue`, que guarda numero como `Double`.
enum RPCAccountData: Decodable, Sendable {
    case encoded([UInt8])
    case parsed(program: String, parsed: JSONValue)

    private struct ParsedData: Decodable {
        let program: String
        let parsed: JSONValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let pair = try? container.decode([String].self) {
            guard pair.count == 2, pair[1] == "base64", let bytes = Data(base64Encoded: pair[0]) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "codificacao inesperada")
            }
            self = .encoded(Array(bytes))
            return
        }
        let object = try container.decode(ParsedData.self)
        self = .parsed(program: object.program, parsed: object.parsed)
    }

    var bytes: [UInt8]? {
        if case .encoded(let bytes) = self { return bytes }
        return nil
    }

    var parsed: JSONValue? {
        if case .parsed(_, let parsed) = self { return parsed }
        return nil
    }
}

struct RPCSimulation: Decodable, Sendable {
    let err: JSONValue?
    let logs: [String]?
    let accounts: [RPCAccount?]?
    let unitsConsumed: UInt64?
}

struct RPCSignatureStatus: Decodable, Sendable {
    let slot: UInt64
    let confirmationStatus: String?
    let err: JSONValue?
}

struct RPCSignatureInfo: Decodable, Sendable {
    let signature: String
    let slot: UInt64
    let err: JSONValue?
    let blockTime: Int64?
    let confirmationStatus: String?
}

extension JSONValue {
    /// Texto compacto e estavel de um erro de transacao, para exibir e comparar.
    var compactText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "erro" }
        return text
    }

    var isNull: Bool { self == .null }
}
