import EscaliburChains
import EscaliburNetwork
import Foundation
import os

/// A varredura de uma conta UTXO, guardada para o envio e para a Atividade.
///
/// Varrer e perguntar endereco por endereco (a xpub nunca sai do aparelho), dezenas de
/// consultas por rede, e Blockcypher e Blockchair cortam por IP depois de poucas
/// dezenas. Por isso:
/// - a Atividade aceita uma varredura de ate cinco minutos; o envio, de ate um (moeda
///   que acabou de chegar num endereco novo aparece no minuto seguinte);
/// - duas telas que pedem a mesma varredura ao mesmo tempo esperam a mesma leitura;
/// - endereco que alguma varredura viu usado nao e perguntado de novo ate o app fechar:
///   historico nao some.
/// Guarda so enderecos e indices; moedas, taxa e historico sao lidos de novo a cada vez.
/// Transmitir esquece as varreduras, porque o troco novo passa a ter uso.
enum UTXODiscoveryCache {
    struct Key: Hashable, Sendable {
        let account: UTXOAccount
        let usage: UTXOUsage?
    }

    struct Stamped: Sendable {
        let discovery: UTXODiscovery
        let at: Date
    }

    /// Quanto uma varredura vale para a Atividade e para o envio.
    static let displayLifetime: TimeInterval = 300
    static let sendLifetime: TimeInterval = 60

    static let memory = ShortLivedMemory<Key, Stamped>(lifetime: displayLifetime, capacity: 8)
    private static let usedPaths = OSAllocatedUnfairLock<[UTXOAccount: Set<DerivationPath>]>(initialState: [:])
    private static let running = OSAllocatedUnfairLock<[Key: Task<UTXODiscovery, Error>]>(initialState: [:])

    static func discover(
        _ account: UTXOAccount, usage: UTXOUsage?, reader: UTXOReader, maxAge: TimeInterval = sendLifetime
    ) async throws -> UTXODiscovery {
        let key = Key(account: account, usage: usage)
        if let cached = memory.recall(key), Date().timeIntervalSince(cached.at) < maxAge { return cached.discovery }
        let known = UTXOEngineSupport.knownUsed(usage, account: account).union(usedPaths.withLock { $0[account] ?? [] })
        let task = running.withLock { tasks in
            if let existing = tasks[key] { return existing }
            let created = Task { try await reader.discover(account, gapLimit: UTXOEngineSupport.gapLimit, knownUsed: known) }
            tasks[key] = created
            return created
        }
        defer { running.withLock { tasks in if tasks[key] == task { tasks[key] = nil } } }
        let fresh = try await task.value
        let paths = Set(fresh.used.map(\.path))
        usedPaths.withLock { $0[account, default: []].formUnion(paths) }
        memory.remember(Stamped(discovery: fresh, at: .now), for: key)
        return fresh
    }

    /// Os caminhos ja vistos usados nesta conta (para os testes).
    static func knownUsed(_ account: UTXOAccount) -> Set<DerivationPath> {
        usedPaths.withLock { $0[account] ?? [] }
    }

    static func forgetAll() {
        memory.forgetAll()
    }
}
