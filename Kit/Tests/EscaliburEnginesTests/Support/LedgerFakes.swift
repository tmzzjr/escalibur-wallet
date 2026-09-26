import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation
@testable import EscaliburNetwork

/// Respostas gravadas em `Fixtures/<familia>/` (ver o LEIA-ME de cada pasta).
enum EngineFixture {
    static func data(_ family: String, _ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/" + family) else {
            throw Missing(name: family + "/" + name)
        }
        return try Data(contentsOf: url)
    }

    static func text(_ family: String, _ name: String) throws -> String {
        String(decoding: try data(family, name), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A gravacao com trechos trocados. Cada teste que usa isto diz o que trocou e por que.
    static func data(_ family: String, _ name: String, replacing pairs: [(String, String)]) throws -> Data {
        var text = String(decoding: try data(family, name), as: UTF8.self)
        for (old, new) in pairs {
            precondition(text.contains(old), "a gravacao \(name) nao tem o trecho a trocar")
            text = text.replacingOccurrences(of: old, with: new)
        }
        return Data(text.utf8)
    }

    struct Missing: Error { let name: String }

    static let live = ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"

    static func provider(_ name: String, _ base: String) -> ProviderPool.Provider {
        ProviderPool.Provider(name: name, baseURL: URL(string: base)!)
    }
}

/// Rede de mentira para os leitores de UTXO e Stellar: responde por host e caminho e
/// registra o que saiu, para o teste conferir o que foi perguntado a quem.
final class FakeHTTP: ChainReaderTransport, @unchecked Sendable {
    typealias Handler = @Sendable (_ url: URL, _ body: Data?) throws -> Data

    struct Request {
        let url: URL
        let body: Data?
    }

    private let lock = NSLock()
    private var exact: [String: Handler] = [:]
    private var prefixes: [(String, Handler)] = []
    private var log: [Request] = []

    /// `key` e host mais caminho, sem query: "esplora-a.test/api/blocks/tip/height".
    func on(_ key: String, _ handler: @escaping Handler) { lock.withLock { exact[key] = handler } }
    func on(_ key: String, data: Data) { on(key) { _, _ in data } }
    func on(_ key: String, status: Int) { on(key) { _, _ in throw HTTPClient.Failure.status(status) } }
    func onPrefix(_ prefix: String, _ handler: @escaping Handler) { lock.withLock { prefixes.append((prefix, handler)) } }

    var requests: [Request] { lock.withLock { log } }

    func fetch(_ url: URL) async throws -> Data { try handle(Request(url: url, body: nil)) }

    func send(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws -> Data {
        try handle(Request(url: url, body: body))
    }

    private func handle(_ request: Request) throws -> Data {
        let key = (request.url.host ?? "") + request.url.path
        let handler: Handler? = lock.withLock {
            log.append(request)
            return exact[key] ?? prefixes.last { key.hasPrefix($0.0) }?.1
        }
        guard let handler else { throw HTTPClient.Failure.status(404) }
        return try handler(request.url, request.body)
    }
}

/// Rede de mentira para o leitor do XRP Ledger (JSON-RPC por POST): responde por host e
/// metodo, com a conta do primeiro parametro quando o metodo e de conta.
final class FakeRPC: ReaderTransport, @unchecked Sendable {
    typealias Handler = @Sendable (_ host: String, _ params: [String: Any]) throws -> Data?

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var log: [(host: String, method: String, params: [String: Any])] = []

    func on(_ method: String, _ handler: @escaping Handler) { lock.withLock { handlers[method] = handler } }
    func on(_ method: String, data: Data) { on(method) { _, _ in data } }

    var calls: [(host: String, method: String, params: [String: Any])] { lock.withLock { log } }

    func send(_ request: ReaderRequest) async throws -> Data {
        guard let body = request.body, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = object["method"] as? String
        else { throw HTTPClient.Failure.status(400) }
        let params = (object["params"] as? [[String: Any]])?.first ?? [:]
        let host = request.url.host ?? ""
        let handler: Handler? = lock.withLock {
            log.append((host, method, params))
            return handlers[method]
        }
        guard let handler, let data = try handler(host, params) else { throw HTTPClient.Failure.status(404) }
        return data
    }
}

/// Contas publicas usadas nos testes. Nenhuma chave privada existe aqui.
enum TestAccounts {
    /// A frase "abandon" x11 + "about", sem passphrase (vetor publico do BIP-39), pelo
    /// `AccountDeriver` da carteira: caminho, endereco, chave publica e a xpub da conta.
    /// Conferidos contra o BIP-84 (bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu) e contra
    /// o endereco Dogecoin que a Blockcypher mostra com historico.
    static let bitcoin = utxo(
        "bitcoin", "m/84'/0'/0'/0/0", "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
        key: "0330d54fd0dd420a6e5f8d3624f5f3482cae350f79d5f0753bf5beef9c2d91af3c",
        xpub: "02707a62fdacc26ea9b63b1c197906f56ee0180d0bcf1966e1a2da34f5f3a09a9b",
        chainCode: "4a53a0ab21b9dc95869c4e92a161194e03c0ef3ff5014ac692f433c4765490fc"
    )
    static let dogecoin = utxo(
        "dogecoin", "m/44'/3'/0'/0/0", "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC",
        key: "02cc6b0dc33aabcf3a23643e5e2919a80c50fb3dd2129ce409bbc5f0d4643d05e0",
        xpub: "03358886064042d4c8b36952d7beb50cb54e8a31084862a954a5140bececf361c5",
        chainCode: "7e5b0a75d73ef310f9f7056f8478af77d6e7dd61bd1d41fa7c7961732766968c"
    )

    /// rEb8TK3gBgk5auZkwc6sHnwrGVJH8DuaLh assina com a chave mestra 02F52B01... (lida do
    /// `SigningPubKey` da transacao 692B5317..., a mesma dos testes do leitor).
    static let xrpl = DerivedAccount(
        chainID: "xrpl", path: DerivationPath("m/44'/144'/0'/0/0")!, address: "rEb8TK3gBgk5auZkwc6sHnwrGVJH8DuaLh",
        publicKey: Hex.decode("02F52B0157F76581EE932D6EDF8DBC1AD876042C8633D16FC81D17838E67BFD4B1")!, accountXPub: nil
    )

    /// GA5XIGA5...: conta publica movimentada, com XLM e USDC da Circle. Na Stellar a
    /// chave publica e o proprio endereco.
    static let stellarAddress = "GA5XIGA5C7QTPTWXQHY6MCJRMTRZDOSHR6EFIBNDQTCQHG262N4GGKTM"
    static let stellar = DerivedAccount(
        chainID: "stellar", path: DerivationPath("m/44'/148'/0'")!, address: stellarAddress,
        publicKey: StellarKey.publicKey(of: stellarAddress)!, accountXPub: nil
    )

    private static func utxo(_ chain: String, _ path: String, _ address: String, key: String, xpub: String, chainCode: String) -> DerivedAccount {
        DerivedAccount(
            chainID: chain, path: DerivationPath(path)!, address: address, publicKey: Hex.decode(key)!,
            accountXPub: try! ExtendedPublicKey(publicKey: Hex.decode(xpub)!, chainCode: Hex.decode(chainCode)!)
        )
    }
}
