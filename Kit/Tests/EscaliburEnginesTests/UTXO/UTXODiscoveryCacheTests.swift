@testable import EscaliburChains
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// A varredura guardada: telas ao mesmo tempo dividem a leitura, e endereco ja visto
/// usado nao e perguntado de novo. Sem rede (as gravacoes de UTXOEngineTests).
@Suite("Varredura UTXO guardada")
struct UTXODiscoveryCacheTests {
    /// Uma conta so deste teste (numero 41), para o cache do processo nao misturar com
    /// os outros testes que rodam junto. Os enderecos saem da mesma xpub.
    static func account() throws -> UTXOAccount {
        let base = try UTXOEngineTests.account()
        return try UTXOAccount(chain: .bitcoin, kind: base.kind, account: 41, accountKey: base.accountKey)
    }

    @Test("Duas telas ao mesmo tempo esperam a mesma varredura; usado nao e perguntado de novo")
    func sharedAndRemembered() async throws {
        let fake = try UTXOEngineTests.network()
        let reader = try UTXOReader(chain: .bitcoin, transport: fake, providers: UTXOEngineTests.providers)
        let account = try Self.account()
        let usage = UTXOUsage(receiveUsed: 0, changeUsed: 0)

        async let first = UTXODiscoveryCache.discover(account, usage: usage, reader: reader)
        async let second = UTXODiscoveryCache.discover(account, usage: usage, reader: reader)
        let (a, b) = try await (first, second)
        #expect(a.usedReceiveIndices == [0] && a.usedChangeIndices == [0])
        #expect(b.usedReceiveIndices == a.usedReceiveIndices)
        // Uma varredura so: 21 enderecos em cada cadeia (o usado e 20 livres).
        let once = fake.requests.count
        #expect(once == 42)

        // Dentro da validade, nenhuma consulta.
        _ = try await UTXODiscoveryCache.discover(account, usage: usage, reader: reader, maxAge: UTXODiscoveryCache.displayLifetime)
        #expect(fake.requests.count == once)

        // Vencida (validade zero), varre de novo, mas sem perguntar pelos dois usados.
        let again = try await UTXODiscoveryCache.discover(account, usage: usage, reader: reader, maxAge: 0)
        #expect(again.usedReceiveIndices == [0] && again.usedChangeIndices == [0])
        #expect(fake.requests.count - once == 40)
        let used = try [account.address(change: false, index: 0), account.address(change: true, index: 0)].map(\.address)
        #expect(!fake.requests.dropFirst(once).contains { used.contains($0.url.lastPathComponent) })
        #expect(UTXODiscoveryCache.knownUsed(account).count == 2)
    }
}
