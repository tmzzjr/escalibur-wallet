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
