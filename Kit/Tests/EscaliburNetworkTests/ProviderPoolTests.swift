import Foundation
import Testing
@testable import EscaliburNetwork

@Suite("Pool de provedores: consenso")
struct ProviderPoolTests {
    static func providers(_ names: [String]) -> [ProviderPool.Provider] {
        names.map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).example")!) }
    }

    @Test("Um provedor so nunca e consenso")
    func single() async {
        let pool = ProviderPool(Self.providers(["a"]))
        await #expect(throws: ConsensusFailure.self) { try await pool.agreeing { _ in 7 } }
    }

    @Test("Dois que concordam; divergencia chama o terceiro")
    func agreement() async throws {
        let pool = ProviderPool(Self.providers(["a", "b", "c"]))
        #expect(try await pool.agreeing { _ in 7 } == 7)
        let answers = ["a": 1, "b": 2, "c": 2]
        #expect(try await pool.agreeing { answers[$0.name] ?? 0 } == 2)
        let split = ["a": 1, "b": 2, "c": 3]
        await #expect(throws: ConsensusFailure.self) { try await pool.agreeing { split[$0.name] ?? 0 } }
    }

    @Test("Com os outros no banco, o consenso ainda pergunta a eles")
    func benched() async throws {
        let pool = ProviderPool(Self.providers(["a", "b"]))
        let b = Self.providers(["b"])[0]
        for _ in 0..<3 { await pool.reportFailure(b) }
        #expect(await pool.available().map(\.name) == ["a"])
        #expect(try await pool.agreeing { _ in 42 } == 42)
        struct Down: Error {}
        await #expect(throws: ConsensusFailure.self) {
            try await pool.agreeing { provider -> Int in
                if provider.name == "b" { throw Down() }
                return 42
            }
        }
    }
}

/// O banco pelo motivo da recusa (contingencia de Litecoin e Dogecoin, 04/10/2026).
@Suite("Banco pelo motivo")
struct ProviderPoolReasonTests {
    @Test("429 tira por 5 min, 430 e 403 por 15, timeout por 2; outro erro segue a regra das tres")
    func benchByReason() async {
        let names = ["a", "b", "c", "d", "e"]
        let providers = names.map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test")!) }
        let pool = ProviderPool(providers)
        let now = Date(timeIntervalSince1970: 1_000_000)
        await pool.reportFailure(providers[0], error: HTTPClient.Failure.status(429), now: now)
        await pool.reportFailure(providers[1], error: HTTPClient.Failure.status(430), now: now)
        await pool.reportFailure(providers[2], error: HTTPClient.Failure.timeout, now: now)
        await pool.reportFailure(providers[3], error: HTTPClient.Failure.status(403), now: now)
        await pool.reportFailure(providers[4], error: HTTPClient.Failure.status(500), now: now)
        #expect(await pool.benched(providers[0]) == now.addingTimeInterval(300))
        #expect(await pool.benched(providers[1]) == now.addingTimeInterval(900))
        #expect(await pool.benched(providers[2]) == now.addingTimeInterval(120))
        #expect(await pool.benched(providers[3]) == now.addingTimeInterval(900))
        #expect(await pool.benched(providers[4]) == nil)
        #expect(await pool.available(now: now.addingTimeInterval(1)).map(\.name) == ["e"])
        #expect(await pool.available(now: now.addingTimeInterval(301)).map(\.name) == ["a", "c", "e"])
        // Uma recusa curta nao encurta um banco mais longo ja marcado.
        await pool.reportFailure(providers[1], error: HTTPClient.Failure.status(429), now: now)
        #expect(await pool.benched(providers[1]) == now.addingTimeInterval(900))
    }
}
