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
        /// Host fora do hosts.lock, ou esquema diferente de https.
        case hostNotAllowed
        case decoding(String)
    }

    public static let shared = HTTPClient()

    static let maxResponseBytes = 4 * 1024 * 1024
    static let userAgent = "EscaliburWallet"

    /// So para os testes: um `URLProtocol` no lugar da rede.
    private let protocolClasses: [AnyClass]?
    /// Os unicos hosts com que o cliente fala: gerados do hosts.lock
    /// (`AllowedHosts.swift`, conferido pelo verificar.sh). Um endereco montado em tempo
    /// de execucao, ou vindo de uma resposta, nao sai do aparelho.
    private let allowedHosts: Set<String>

    public override convenience init() { self.init(protocolClasses: nil, allowedHosts: AllowedHosts.all) }

    init(protocolClasses: [AnyClass]?, allowedHosts: Set<String> = AllowedHosts.all) {
        self.protocolClasses = protocolClasses
        self.allowedHosts = allowedHosts
        super.init()
    }

    /// Criada uma vez so, sob a trava: `lazy var` nao e seguro entre threads, e duas
    /// sessoes repetiriam `taskIdentifier`, trocando a leitura de uma pela de outra.
    private var session: URLSession {
        lock.withLock {
            if let existing = sessionStorage { return existing }
            let made = makeSession()
            sessionStorage = made
            return made
        }
    }
    private var sessionStorage: URLSession?

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
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
    }

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

    /// O corpo e lido em fluxo e cortado ao passar do limite. Resposta sem
    /// Content-Length (chunked) nao chega inteira na memoria antes de ser medida.
    ///
    /// Uma tarefa de dados com o delegado da sessao, e nao `bytes(for:)`: em algumas
    /// versoes do macOS (a do runner do CI) o fluxo de `bytes(for:)` parava de entregar
    /// o corpo, e o delegado classico mede cada pedaco igual em todas.
    private func perform(_ request: URLRequest) async throws -> Data {
        guard request.url?.scheme == "https", let host = request.url?.host, allowedHosts.contains(host) else {
            throw Failure.hostNotAllowed
        }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { transfers[ObjectIdentifier(task)] = Transfer(continuation) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Uma leitura em andamento: o corpo que ja chegou, a recusa (se houve) e quem espera.
    private final class Transfer {
        var data = Data()
        var failure: Failure?
        let continuation: CheckedContinuation<Data, Error>

        init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    }

    private let lock = NSLock()
    /// Pela identidade da tarefa, viva ate `didCompleteWithError` tirar a entrada daqui.
    private var transfers: [ObjectIdentifier: Transfer] = [:]

    private func transfer(_ task: URLSessionTask) -> Transfer? {
        lock.withLock { transfers[ObjectIdentifier(task)] }
    }

    static func failure(for error: Error) -> Failure {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return .offline
        case .timedOut: return .timeout
        default: return .invalidResponse
        }
    }
}

extension HTTPClient: URLSessionDataDelegate {
    /// Redirecionamento nunca e seguido: um provedor comprometido nao manda o app
    /// buscar dado em outro host.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    /// Status e tamanho anunciado sao conferidos antes de qualquer byte do corpo.
    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let transfer = transfer(dataTask) else { return completionHandler(.cancel) }
        let refusal: Failure?
        if let http = response as? HTTPURLResponse {
            if (300..<400).contains(http.statusCode) { refusal = .redirectRefused }
            else if !(200..<300).contains(http.statusCode) { refusal = .status(http.statusCode) }
            else if http.expectedContentLength > Int64(Self.maxResponseBytes) { refusal = .tooLarge }
            else { refusal = nil }
        } else {
            refusal = .invalidResponse
        }
        lock.withLock {
            transfer.failure = refusal
            if refusal == nil, response.expectedContentLength > 0 {
                transfer.data.reserveCapacity(Int(response.expectedContentLength))
            }
        }
        completionHandler(refusal == nil ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(dataTask) else { return }
        let over = lock.withLock { () -> Bool in
            guard transfer.failure == nil else { return false }
            transfer.data.append(data)
            guard transfer.data.count > Self.maxResponseBytes else { return false }
            transfer.failure = .tooLarge
            transfer.data = Data()
            return true
        }
        if over { dataTask.cancel() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: ObjectIdentifier(task)) }) else { return }
        if let failure = transfer.failure {
            transfer.continuation.resume(throwing: failure)
        } else if let error {
            transfer.continuation.resume(throwing: Self.failure(for: error))
        } else {
            transfer.continuation.resume(returning: transfer.data)
        }
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
