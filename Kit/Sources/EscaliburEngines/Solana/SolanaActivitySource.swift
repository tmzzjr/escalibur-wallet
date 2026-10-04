import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O historico da Solana na forma comum da Atividade.
///
/// O `SolanaHistoryReader` le as ultimas transacoes da carteira e dos ATAs dos
/// tokens da lista e tira de cada uma o efeito liquido sobre o dono (saldos antes e
/// depois, nunca o texto das instrucoes). Aqui cada linha vira `ActivityEntry` e
/// ganha a marca de suspeita (docs/seguranca.md §4.10), que esconde a linha por
/// padrao:
///   - token fora da lista, poeira de desconhecido e saida que o dono nao assinou,
///     que o leitor ja marca;
///   - transferencia de valor zero;
///   - recebimento de endereco parecido com um que o dono conhece: o proprio ou um
///     para quem ele ja enviou (`AddressPoisoning.lookalike`).
/// Envio assinado pelo dono nunca e escondido, mesmo para endereco parecido: seria
/// esconder dinheiro que saiu de verdade.
struct SolanaActivitySource: ActivitySource {
    static let shared = SolanaActivitySource(network: SolanaLiveNetwork())

    /// Transacoes lidas por consulta, o padrao do leitor.
    static let limit = 30

    let network: any SolanaEngineNetwork

    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        do {
            try SolanaEngineGuard.chain(chain)
            let owner = try SolanaEngineGuard.owner(account)
            let activities = try await network.recentActivity(owner: owner.publicKey, limit: Self.limit)
            return Self.entries(activities, owner: owner.publicKey)
        } catch {
            throw SolanaEngineMessages.map(error, .history)
        }
    }

    static func entries(_ activities: [SolanaActivity], owner: SolanaPublicKey, now: Date = .now) -> [ActivityEntry] {
        // O contrato nao traz os contatos do dono; conhecidos sao a propria conta e
        // quem recebeu dele um envio que nao e suspeito, a mesma regra do leitor.
        let paid = activities.filter { $0.direction == .outgoing && !$0.isSuspicious }.compactMap(\.counterparty)
        let known = [owner.base58] + paid
        return activities.map { entry($0, known: known, now: now) }
    }

    static func entry(_ activity: SolanaActivity, known: [String], now: Date) -> ActivityEntry {
        let direction: ActivityEntry.Direction
        switch activity.direction {
        case .incoming: direction = .received
        case .outgoing: direction = .sent
        case .swap: direction = .swap
        case .other: direction = .other
        }
        let status: ActivityEntry.Status
        switch activity.status {
        case .confirmed, .finalized: status = .confirmed
        // O erro do no nao vai para a tela; ela diz "Falhou".
        case .failed: status = .failed(nil)
        }
        return ActivityEntry(
            id: activity.id, chainID: Chain.solana.id, direction: direction,
            // Sem movimento de ativo (so a taxa), nao ha valor a mostrar.
            asset: direction == .other ? nil : asset(activity.asset), amount: activity.amount, counterparty: activity.counterparty,
            // Sem `blockTime` (o no ainda nao tem a hora do bloco), a transacao e recente.
            date: activity.date ?? now, status: status, fee: activity.fee.isZero ? nil : activity.fee, hash: activity.id,
            suspicious: suspicious(activity, known: known)
        )
    }

    static func suspicious(_ activity: SolanaActivity, known: [String]) -> Bool {
        if activity.isSuspicious { return true }
        switch activity.direction {
        case .incoming:
            if activity.amount.isZero { return true }
            if let counterparty = activity.counterparty, AddressPoisoning.lookalike(counterparty, among: known, chain: .solana) != nil {
                return true
            }
            return false
        case .outgoing:
            return activity.amount.isZero
        case .swap, .other:
            return false
        }
    }

    /// O ativo da linha: SOL ou token da lista. Token fora da lista fica sem ativo,
    /// nunca com o nome ou o simbolo que a rede diz (sao exatamente o que o golpista
    /// escolhe); a linha ja vem marcada como suspeita e escondida.
    static func asset(_ asset: SolanaActivity.ActivityAsset) -> Asset? {
        switch asset {
        case .listed(let listed): return listed
        case .unlisted: return nil
        }
    }
}
