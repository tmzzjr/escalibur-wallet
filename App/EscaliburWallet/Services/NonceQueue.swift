import EscaliburChains
import EscaliburEngines
import Foundation

/// Uma transacao EVM transmitida deste aparelho e ainda sem confirmacao.
struct PendingEVMTransaction: Codable, Equatable {
    let nonce: UInt64
    let hash: String
    let sentAt: Date
}

/// A fila local de nonces EVM, por carteira, rede e conta (auditoria 2, M1 dos motores).
///
/// Sem ela, o planejador exige que as duas fontes da rede concordem no nonce, e um
/// segundo envio logo depois do primeiro pode esbarrar num provedor que ainda nao viu
/// a transacao. Com ela, o planejador sabe o que este aparelho ja transmitiu. O perigo
/// e o contrario, uma entrada velha: a transacao que a rede descartou faria o proximo
/// plano usar um nonce que nunca executa. Por isso a fila e podada antes de cada plano
/// e esquecida quando o motor diz que ela esta a frente da rede.
@MainActor
enum NonceQueue {
    /// Pendente ha mais que isto sem confirmar: a rede provavelmente descartou.
    static let staleAfter: TimeInterval = 30 * 60

    nonisolated static func key(wallet: UUID, chain: Chain, address: String) -> String {
        "\(wallet.uuidString)|\(chain.id)|\(address.lowercased())"
    }

    /// A fila para um pedido: nil fora da EVM ou sem transacao em transito. Os nonces
    /// vao consecutivos, terminando em `nextNonce - 1`, como o contrato pede.
    static func queue(_ session: AppSession, wallet: UUID, chain: Chain, address: String) -> PendingNonceQueue? {
        guard chain.family == .evm,
              let entries = session.metadata.pendingEVM?[key(wallet: wallet, chain: chain, address: address)], !entries.isEmpty
        else { return nil }
        return PendingNonceQueue.trailingRun(entries.map { ($0.nonce, $0.hash) })
    }

    /// Anota as transacoes EVM de um plano que acabou de ser transmitido.
    static func record(_ session: AppSession, wallet: UUID, chain: Chain, address: String, plan: SigningPlan, signed: [SignedTransaction]) {
        guard chain.family == .evm, plan.transactions.count == signed.count else { return }
        let now = Date()
        let fresh = zip(plan.transactions, signed).compactMap { transaction, signature -> PendingEVMTransaction? in
            guard let evm = transaction as? EVMTransaction else { return nil }
            return PendingEVMTransaction(nonce: evm.nonce, hash: signature.id, sentAt: now)
        }
        guard !fresh.isEmpty else { return }
        let key = key(wallet: wallet, chain: chain, address: address)
        var all = session.metadata.pendingEVM ?? [:]
        let kept = (all[key] ?? []).filter { old in !fresh.contains { $0.nonce == old.nonce } }
        all[key] = kept + fresh
        session.metadata.pendingEVM = all
        try? session.persist()
    }

    /// Tira da fila o que a rede ja confirmou ou recusou, e o que esta pendente ha tempo
    /// demais. Leitura de status falha: a entrada fica, a nao ser que esteja velha.
    static func prune(_ session: AppSession, wallet: UUID, chain: Chain, address: String) async {
        let key = key(wallet: wallet, chain: chain, address: address)
        guard chain.family == .evm, let entries = session.metadata.pendingEVM?[key], !entries.isEmpty,
              let engine = SendEngines.engine(for: chain) else { return }
        var kept = [PendingEVMTransaction]()
        for entry in entries {
            if Date().timeIntervalSince(entry.sentAt) > staleAfter { continue }
            if case .pending = await engine.status(entry.hash, chain: chain) { kept.append(entry) }
        }
        guard kept != entries else { return }
        session.metadata.pendingEVM?[key] = kept.isEmpty ? nil : kept
        try? session.persist()
    }

    static func clear(_ session: AppSession, wallet: UUID, chain: Chain, address: String) {
        session.metadata.pendingEVM?[key(wallet: wallet, chain: chain, address: address)] = nil
        try? session.persist()
    }
}
