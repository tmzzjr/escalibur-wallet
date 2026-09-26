import EscaliburChains
import EscaliburCore
import Foundation
@testable import EscaliburNetwork

/// Apoio dos testes dos leitores de UTXO e Stellar (ReaderB*).
enum ReaderBTest {
    /// A zpub de "abandon" x11 + "about" em m/84'/0'/0': publica, do proprio BIP-84
    /// (bips/bip-0084.mediawiki, "Test vectors"). Primeiro recebimento
    /// bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu; primeiro troco
    /// bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el.
    static let abandonZpub = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"
    static let abandonReceive0 = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
    static let abandonChange0 = "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el"

    /// Chave estendida serializada (BIP-32): versao 4, profundidade 1, pai 4, filho 4,
    /// chain code 32, chave 33.
    static func extendedKey(_ text: String) throws -> ExtendedPublicKey {
        guard let raw = Base58.bitcoin.decodeCheck(text), raw.count == 78 else { throw ChainReaderError.malformedResponse(field: "xpub") }
        return try ExtendedPublicKey(publicKey: Array(raw[45..<78]), chainCode: Array(raw[13..<45]))
    }

    static func abandonAccount(chain: Chain = .bitcoin, kind: UTXOInputKind = .p2wpkh) throws -> UTXOAccount {
        try UTXOAccount(chain: chain, kind: kind, account: 0, accountKey: extendedKey(abandonZpub))
    }

    static let live = ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "FixturesB") else {
            throw ChainReaderError.malformedResponse(field: name)
        }
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try fixture(name), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A fixture com trechos trocados, para simular provedor mentindo ou divergindo.
    static func fixture(_ name: String, replacing pairs: [(String, String)]) throws -> Data {
        var text = String(decoding: try fixture(name), as: UTF8.self)
        for (old, new) in pairs {
            precondition(text.contains(old), "fixture \(name) nao contem o trecho a trocar")
            text = text.replacingOccurrences(of: old, with: new)
        }
        return Data(text.utf8)
    }

    static func provider(_ name: String, _ base: String) -> ProviderPool.Provider {
        ProviderPool.Provider(name: name, baseURL: URL(string: base)!)
    }

    /// Tres Esplora de mentira, na ordem do app: mempool, blockstream, emzy.
    static let esploraProviders = [
        provider("mempool", "https://esplora-a.test/api"),
        provider("blockstream", "https://esplora-b.test/api"),
        provider("emzy", "https://esplora-c.test/api"),
    ]
    static let horizonProviders = [
        provider("sdf", "https://horizon-a.test"),
        provider("lobstr", "https://horizon-b.test"),
    ]

    /// Uma moeda real de 98.089 sat (fixtures esplora-utxo.json e esplora-tx-hex.txt),
    /// num endereco que ja gastou antes e por isso tem a chave publica na witness.
    static let fundedAddress = "bc1q7mful77lv7ynvsjfnrnadzawrfrgcqaqe9test"
    static let fundedPublicKey = "0216836d4c920ae8af0f672b87f194dcee5fed60e4d3f0f877cb35025f3b7ca87b"
    static let fundedTxid = "27d9f98446480c9ac44b44c968cc2f942ae45a2908c218ee773bb64aeb011fee"

    /// Um endereco "da carteira" montado a mao a partir de uma chave publica conhecida.
    /// So para teste: no app todo endereco sai de `UTXOAccount.address`.
    static func derived(
        publicKeyHex: String, chain: Chain = .bitcoin, kind: UTXOInputKind = .p2wpkh, index: UInt32 = 7
    ) throws -> UTXODerivedAddress {
        guard let key = Hex.decode(publicKeyHex) else { throw ChainReaderError.malformedResponse(field: "key") }
        let script = kind.scriptPubKey(publicKey: key)
        guard let address = UTXOScript.address(for: script, chain: chain) else { throw ChainReaderError.unsupportedAccount }
        let h = DerivationPath.hardened
        return UTXODerivedAddress(
            address: address, path: DerivationPath(components: [h(kind.purpose), h(chain.coinType), h(0), 0, index]),
            publicKey: key, scriptPubKey: script, isChange: false, index: index
        )
    }
}

/// Rede de mentira: responde por host e caminho, e registra tudo o que saiu.
final class ReaderBFakeTransport: ChainReaderTransport, @unchecked Sendable {
    typealias Handler = @Sendable (_ url: URL, _ body: Data?) throws -> Data

    struct Request {
        let url: URL
        let body: Data?
        let contentType: String?
    }

    private let lock = NSLock()
    private var exact: [String: Handler] = [:]
    private var prefixes: [(String, Handler)] = []
    private var log: [Request] = []

    /// `key` e host + caminho, sem query: "esplora-a.test/api/blocks/tip/height".
    func on(_ key: String, _ handler: @escaping Handler) {
        lock.withLock { exact[key] = handler }
    }

    func on(_ key: String, data: Data) { on(key) { _, _ in data } }
    func on(_ key: String, text: String) { on(key, data: Data(text.utf8)) }
    func on(_ key: String, status: Int) { on(key) { _, _ in throw HTTPClient.Failure.status(status) } }

    func onPrefix(_ prefix: String, _ handler: @escaping Handler) {
        lock.withLock { prefixes.append((prefix, handler)) }
    }

    var requests: [Request] { lock.withLock { log } }

    func fetch(_ url: URL) async throws -> Data { try handle(Request(url: url, body: nil, contentType: nil)) }

    func send(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws -> Data {
        try handle(Request(url: url, body: body, contentType: contentType))
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
