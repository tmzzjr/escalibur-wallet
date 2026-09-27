import Testing
@testable import EscaliburEngines

@Suite("Fila local de nonces (auditoria 2, M1 dos motores)")
struct PendingNonceQueueTests {
    @Test("Consecutivos em qualquer ordem: proximo e o maior mais um, hashes em ordem de nonce")
    func consecutive() throws {
        let queue = try #require(PendingNonceQueue.trailingRun([(7, "c"), (5, "a"), (6, "b")]))
        #expect(queue.nextNonce == 8)
        #expect(queue.pendingHashes == ["a", "b", "c"])
    }

    @Test("Com buraco, so a sequencia que termina no maior")
    func gap() throws {
        let queue = try #require(PendingNonceQueue.trailingRun([(3, "x"), (5, "a"), (6, "b")]))
        #expect(queue.nextNonce == 7)
        #expect(queue.pendingHashes == ["a", "b"])
    }

    @Test("Vazia e nil; uma so vale")
    func edges() throws {
        #expect(PendingNonceQueue.trailingRun([]) == nil)
        let single = try #require(PendingNonceQueue.trailingRun([(0, "z")]))
        #expect(single.nextNonce == 1 && single.pendingHashes == ["z"])
    }
}
