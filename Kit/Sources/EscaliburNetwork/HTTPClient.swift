import EscaliburChains
import Foundation

/// O unico ponto do app que fala com a internet.
///
/// Configuracao de docs/seguranca.md §5.1: sessao efemera sem cache, sem cookies e
/// sem credenciais guardadas (nada de `Cache.db` revelando quais tokens o dono olha),
/// sem seguir redirecionamento, resposta limitada a 4 MB, timeouts curtos, e um
/// User-Agent constante que nao entrega versao do app nem do iOS.
public final class HTTPClient: NSObject, @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case offline
        case timeout
        case status(Int)
        case tooLarge
        case redirectRefused
        case invalidResponse
        case decoding(String)
    }

    public static let shared = HTTPClient()

    static let maxResponseBytes = 4 * 1024 * 1024
    static let userAgent = "EscaliburWallet"

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Language": "en"]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    // MARK: Requisicoes

    public func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 10) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await perform(request)
    }

    public func post(_ url: URL, json body: Data, headers: [String: String] = [:], timeout: TimeInterval = 10) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await perform(request)
    }

    /// PUT e DELETE com corpo JSON, pelas mesmas regras de `get`/`post`. A CoW so aceita
    /// cancelamento em `DELETE /api/v1/orders` e registro de appData em `PUT`.
    public func send(_ method: String, _ url: URL, json body: Data?, headers: [String: String] = [:], timeout: TimeInterval = 10) async throws -> Data {
        guard ["PUT", "DELETE"].contains(method) else { throw Failure.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await perform(request)
    }

    public func getJSON<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:]) async throws -> T {
        let data = try await get(url, headers: headers)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.decoding(String(describing: type))
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        guard request.url?.scheme == "https" else { throw Failure.invalidResponse }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            guard data.count <= Self.maxResponseBytes else { throw Failure.tooLarge }
            guard (200..<300).contains(http.statusCode) else {
                if (300..<400).contains(http.statusCode) { throw Failure.redirectRefused }
                throw Failure.status(http.statusCode)
            }
            return data
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: throw Failure.offline
            case .timedOut: throw Failure.timeout
            default: throw Failure.invalidResponse
            }
        }
    }
}

extension HTTPClient: URLSessionTaskDelegate, URLSessionDataDelegate {
    /// Redirecionamento nunca e seguido: um provedor comprometido nao manda o app
    /// buscar dado em outro host.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    /// Resposta que anuncia mais que o limite e cortada antes de baixar.
    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        response.expectedContentLength > Int64(Self.maxResponseBytes) ? .cancel : .allow
    }
}

/// Um conjunto de provedores equivalentes para o mesmo servico, com contingencia.
///
/// Circuit breaker simples: tres falhas seguidas tiram o provedor por 60 segundos.
/// A ordem de preferencia e fixa no codigo; nenhuma resposta de rede acrescenta
/// provedor.
public actor ProviderPool {
    public struct Provider: Sendable, Hashable {
        public let name: String
        public let baseURL: URL

        public init(name: String, baseURL: URL) {
            self.name = name
            self.baseURL = baseURL
        }
    }

    public let providers: [Provider]
    private var failures: [String: Int] = [:]
    private var benchedUntil: [String: Date] = [:]

    public init(_ providers: [Provider]) {
        self.providers = providers
    }

    /// Os provedores disponiveis agora, na ordem de preferencia.
    public func available(now: Date = .now) -> [Provider] {
        let live = providers.filter { (benchedUntil[$0.name] ?? .distantPast) <= now }
        return live.isEmpty ? providers : live
    }

    public func reportSuccess(_ provider: Provider) {
        failures[provider.name] = 0
    }

    public func reportFailure(_ provider: Provider, now: Date = .now) {
        let count = (failures[provider.name] ?? 0) + 1
        failures[provider.name] = count
        if count >= 3 {
            benchedUntil[provider.name] = now.addingTimeInterval(60)
            failures[provider.name] = 0
        }
    }

    /// Tenta cada provedor em ordem ate um responder.
    public func first<T: Sendable>(_ operation: @Sendable (Provider) async throws -> T) async throws -> T {
        var lastError: Error = HTTPClient.Failure.offline
        for provider in available() {
            do {
                let value = try await operation(provider)
                reportSuccess(provider)
                return value
            } catch {
                reportFailure(provider)
                lastError = error
            }
        }
        throw lastError
    }

    /// Pergunta a provedores distintos e exige que dois concordem. Nonce, sequence e
    /// saldo que vao para uma transacao passam por aqui (docs/seguranca.md §5.5).
    ///
    /// Nunca aceita uma resposta so: com menos de dois provedores respondendo, falha.
    /// Os que estao no banco do circuit breaker entram no fim da fila, porque um
    /// consenso que so tem um provedor vivo nao e consenso.
    public func agreeing<T: Sendable & Equatable>(_ operation: @Sendable (Provider) async throws -> T) async throws -> T {
        let live = available()
        let candidates = live + providers.filter { !live.contains($0) }
        var answers: [T] = []
        for provider in candidates {
            do {
                let value = try await operation(provider)
                reportSuccess(provider)
                if answers.contains(value) { return value }
                answers.append(value)
            } catch {
                reportFailure(provider)
            }
        }
        throw ConsensusFailure(answers: answers.count)
    }
}

public struct ConsensusFailure: Error, Sendable {
    public let answers: Int
}

/// JSON-RPC 2.0 sobre HTTPS.
public struct JSONRPC: Sendable {
    public struct RPCError: Error, Sendable, Decodable {
        public let code: Int
        public let message: String
    }

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: RPCError?
    }

    public static func call<T: Decodable>(_ url: URL, method: String, params: [JSONValue], as type: T.Type, client: HTTPClient = .shared) async throws -> T {
        let body: [String: JSONValue] = [
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": .array(params),
        ]
        let data = try await client.post(url, json: try JSONEncoder().encode(body))
        let envelope: Envelope<T>
        do { envelope = try JSONDecoder().decode(Envelope<T>.self, from: data) } catch { throw HTTPClient.Failure.decoding(method) }
        if let error = envelope.error { throw error }
        guard let result = envelope.result else { throw HTTPClient.Failure.invalidResponse }
        return result
    }
}

/// Um valor JSON qualquer, para montar parametros sem `[String: Any]`.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}
