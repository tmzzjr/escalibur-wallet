import Foundation
import os

/// O pouco que um motor precisa lembrar entre duas chamadas do app e que o contrato
/// ainda nao carrega: o indice de troco de um plano UTXO ate o envio, o
/// LastLedgerSequence de uma transacao do XRP Ledger ate o acompanhamento.
///
/// So memoria do processo: nada vai para disco, cada item vence sozinho e o total tem
/// teto. Guarda indices e numeros de ledger, nunca endereco, valor ou chave.
final class ShortLivedMemory<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let value: Value
        let expires: Date
    }

    private let lifetime: TimeInterval
    private let capacity: Int
    private let entries = OSAllocatedUnfairLock<[Key: Entry]>(initialState: [:])

    init(lifetime: TimeInterval, capacity: Int = 64) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    func remember(_ value: Value, for key: Key, now: Date = .now) {
        let entry = Entry(value: value, expires: now.addingTimeInterval(lifetime))
        let capacity = self.capacity
        entries.withLock { stored in
            stored = stored.filter { $0.value.expires > now }
            if stored.count >= capacity, let oldest = stored.min(by: { $0.value.expires < $1.value.expires })?.key {
                stored[oldest] = nil
            }
            stored[key] = entry
        }
    }

    func recall(_ key: Key, now: Date = .now) -> Value? {
        entries.withLock { stored in
            guard let entry = stored[key], entry.expires > now else { return nil }
            return entry.value
        }
    }
}
