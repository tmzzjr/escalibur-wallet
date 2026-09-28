import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A Atividade da Sui: o historico do `SuiReader`, com cada recebimento julgado contra
/// envenenamento de endereco antes de chegar a tela (docs/seguranca.md §4.10).
///
/// O leitor ja deixa de fora o recebimento de valor zero, o po e a moeda fora da lista.
/// Aqui entra a comparacao com o que o atacante nao controla: a propria conta e os
/// destinos que ela ja pagou. Na Sui o envio so sai com a assinatura do dono, entao o que
/// saiu aparece sempre.
struct SuiActivitySource: ActivitySource {
    let reader: SuiReader

    init(reader: SuiReader = .shared) {
        self.reader = reader
    }

    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        guard chain.id == Chain.sui.id else { throw SendEngineError.unsupported(chain) }
        guard account.chainID == Chain.sui.id, case .success(let owner) = SuiAddress.parse(account.address) else {
            throw SendEngineError.message(SuiEngineText.keyMismatch)
        }
        let page: ActivityPage
        do {
            page = try await reader.history(owner: owner)
        } catch {
            throw SendEngineError.message(SuiEngineText.historyFailure)
        }
        return Self.entries(page.items, owner: owner)
    }

    static func entries(_ items: [ActivityItem], owner: SuiAddress) -> [ActivityEntry] {
        let paid = items.filter { $0.direction == .sent && !$0.amount.isZero }.compactMap(\.counterparty)
        let known = [owner.hex] + paid
        return items.map { item in
            let incoming = item.direction == .received
            let suspicious = incoming && ActivityScreening.imitatesKnown(item.counterparty, known: known, chain: .sui)
                && !known.contains(where: { Address.sameRecipient($0, item.counterparty ?? "", chain: .sui) })
            return ActivityEntry(
                id: item.id, chainID: item.chainID, direction: direction(item.direction), asset: item.asset,
                amount: item.amount, counterparty: item.counterparty, date: item.date, status: status(item.status),
                fee: item.fee, hash: item.hash, suspicious: suspicious
            )
        }
    }

    static func direction(_ direction: ActivityItem.Direction) -> ActivityEntry.Direction {
        switch direction {
        case .sent: return .sent
        case .received: return .received
        case .swap: return .swap
        case .other: return .other
        }
    }

    static func status(_ status: ActivityItem.Status) -> ActivityEntry.Status {
        switch status {
        case .pending: return .pending(nil)
        case .confirmed: return .confirmed
        case .failed: return .failed(nil)
        }
    }
}
