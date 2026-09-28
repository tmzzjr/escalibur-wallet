import Foundation
import Testing
@testable import EscaliburNetwork

/// Um servidor de mentira: responde pelo caminho da URL.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        switch url.path {
        case "/pequeno":
            let body = Data("{\"ok\":true}".utf8)
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(body.count)"])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
        case "/sem-tamanho":
            // Chunked: sem Content-Length, 5 MB em pedacos.
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            let chunk = Data(repeating: 0x61, count: 256 * 1024)
            for _ in 0..<20 { client.urlProtocol(self, didLoad: chunk) }
        case "/anuncia-grande":
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(10 * 1024 * 1024)"])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 1024))
        case "/erro":
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        default:
            client.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Cliente HTTP: limites")
struct HTTPClientTests {
    let client = HTTPClient(protocolClasses: [StubProtocol.self], allowedHosts: ["stub.example"])

    @Test("Resposta pequena passa")
    func small() async throws {
        let data = try await client.get(URL(string: "https://stub.example/pequeno")!)
        #expect(data == Data("{\"ok\":true}".utf8))
    }

    @Test("Sem Content-Length, o corte acontece no meio do fluxo")
    func chunkedTooLarge() async {
        await #expect(throws: HTTPClient.Failure.tooLarge) {
            try await client.get(URL(string: "https://stub.example/sem-tamanho")!)
        }
    }

    @Test("Content-Length acima do limite e recusado antes do corpo")
    func announcedTooLarge() async {
        await #expect(throws: HTTPClient.Failure.tooLarge) {
            try await client.get(URL(string: "https://stub.example/anuncia-grande")!)
        }
    }

    @Test("Muitas leituras ao mesmo tempo num cliente novo: todas voltam, cada uma com a sua")
    func concurrentFreshClient() async throws {
        let fresh = HTTPClient(protocolClasses: [StubProtocol.self], allowedHosts: ["stub.example"])
        let answers = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<64 {
                group.addTask { try await fresh.get(URL(string: "https://stub.example/pequeno")!) }
            }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        #expect(answers.count == 64)
        #expect(answers.allSatisfy { $0 == Data("{\"ok\":true}".utf8) })
    }

    @Test("Status de erro e so HTTPS")
    func statusAndScheme() async {
        await #expect(throws: HTTPClient.Failure.status(503)) {
            try await client.get(URL(string: "https://stub.example/erro")!)
        }
        await #expect(throws: HTTPClient.Failure.hostNotAllowed) {
            try await client.get(URL(string: "http://stub.example/pequeno")!)
        }
    }

    @Test("Host fora da lista nao sai do aparelho")
    func hostNotAllowed() async {
        await #expect(throws: HTTPClient.Failure.hostNotAllowed) {
            try await client.get(URL(string: "https://outro.example/pequeno")!)
        }
        #expect(AllowedHosts.all.contains("mempool.space"))
        #expect(!AllowedHosts.all.contains("stub.example"))
    }
}
