import EscaliburChains
import EscaliburNetwork
import Foundation

/// A varredura de uma conta UTXO vale um minuto, para o envio e para a Atividade.
///
/// Varrer e perguntar endereco por endereco (a xpub nunca sai do aparelho), dezenas de
/// consultas por rede. Abrir a Atividade, ver o maximo e revisar o envio usam a mesma
/// varredura em vez de repetir tudo e bater no limite dos provedores publicos. Guarda
/// so enderecos e indices; moedas, taxa e historico sao lidos de novo a cada vez.
/// Transmitir esquece tudo, porque o troco novo passa a ter uso.
enum UTXODiscoveryCache {
    struct Key: Hashable, Sendable {
        let account: UTXOAccount
        let usage: UTXOUsage?
    }

    static let memory = ShortLivedMemory<Key, UTXODiscovery>(lifetime: 60, capacity: 8)

    static func discover(_ account: UTXOAccount, usage: UTXOUsage?, reader: UTXOReader) async throws -> UTXODiscovery {
        let key = Key(account: account, usage: usage)
        if let cached = memory.recall(key) { return cached }
        let fresh = try await reader.discover(
            account, gapLimit: UTXOEngineSupport.gapLimit, knownUsed: UTXOEngineSupport.knownUsed(usage, account: account)
        )
        memory.remember(fresh, for: key)
        return fresh
    }

    static func forgetAll() {
        memory.forgetAll()
    }
}
