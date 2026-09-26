import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Testes dos leitores: respostas gravadas em `Fixtures/leitores/<rede>/` e um transporte
/// que devolve essas respostas conforme a requisicao, sem rede.
enum ReaderFixtures {
    static func data(_ family: String, _ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/leitores/" + family) else {
            throw FixtureMissing(name: family + "/" + name)
        }
        return try Data(contentsOf: url)
    }

    static func json(_ family: String, _ name: String) throws -> StrictJSON {
        try StrictJSON.parse(try data(family, name))
    }

    struct FixtureMissing: Error { let name: String }
}

/// Um transporte que responde por regra: cada regra olha a requisicao (host, caminho,
/// metodo do JSON-RPC) e devolve os bytes gravados, ou lanca. Guarda o que foi pedido,
/// para o teste conferir que o endereco foi no corpo e nao no caminho.
final class FixtureTransport: ReaderTransport, @unchecked Sendable {
    typealias Rule = @Sendable (ReaderRequest, StrictJSON?) throws -> Data?

    private let lock = NSLock()
    private let rules: [Rule]
    private var log: [ReaderRequest] = []

    init(_ rules: [Rule]) {
        self.rules = rules
    }

    var requests: [ReaderRequest] {
        lock.withLock { log }
    }

    func send(_ request: ReaderRequest) async throws -> Data {
        lock.withLock { log.append(request) }
        let body = request.body.flatMap { try? StrictJSON.parse($0) }
        for rule in rules {
            if let data = try rule(request, body) { return data }
        }
        throw HTTPClient.Failure.status(404)
    }

    /// O `method` de um corpo JSON-RPC (EVM, XRPL, toncenter v2).
    static func method(_ body: StrictJSON?) -> String? {
        guard case .object(let fields)? = body, case .string(let method)? = fields["method"] else { return nil }
        return method
    }

    static func params(_ body: StrictJSON?) -> [StrictJSON] {
        guard case .object(let fields)? = body, case .array(let params)? = fields["params"] else { return [] }
        return params
    }
}

/// Resposta JSON-RPC 2.0 com `result`.
func rpcResult(_ result: String) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}".utf8)
}

func rpcError(code: Int, message: String) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\(code),\"message\":\"\(message)\"}}".utf8)
}

/// Provedores de mentira para os testes: o host diz quem e quem.
func testProviders(_ names: String...) -> [ProviderPool.Provider] {
    names.map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test")!) }
}

/// Os testes ao vivo so rodam com ESCALIBUR_REDE=1; o detalhe so sai com
/// ESCALIBUR_REDE_DETALHE=1.
enum Live {
    static let enabled = ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"
    static let verbose = ProcessInfo.processInfo.environment["ESCALIBUR_REDE_DETALHE"] == "1"

    static func note(_ text: @autoclosure () -> String) {
        if verbose { print("[ao vivo] " + text()) }
    }
}
