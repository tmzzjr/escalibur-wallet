import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A Atividade da NEAR: as transferencias de NEAR do `NEARReader`, com cada recebimento
/// julgado contra envenenamento de conta antes de chegar a tela (docs/seguranca.md §4.10).
///
/// O leitor ja deixa de fora o recebimento de valor zero e o po. Aqui entra a comparacao
/// com o que o atacante nao controla: a propria conta e os destinos que ela ja pagou.
struct NEARActivitySource: ActivitySource {
    let reader: NEARReader

    init(reader: NEARReader = .shared) {
        self.reader = reader
    }

    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        guard chain.id == Chain.near.id else { throw SendEngineError.unsupported(chain) }
        guard account.chainID == Chain.near.id, case .success = NEARAccountID.parse(account.address) else {
            throw SendEngineError.message(NEAREngineText.keyMismatch)
        }
        let page: ActivityPage
        do {
            page = try await reader.history(owner: account.address)
        } catch {
            throw SendEngineError.message(NEAREngineText.historyFailure)
        }
        return Self.entries(page.items, owner: account.address)
    }

    static func entries(_ items: [ActivityItem], owner: String) -> [ActivityEntry] {
        let paid = items.filter { $0.direction == .sent && !$0.amount.isZero }.compactMap(\.counterparty)
        let known = [owner] + paid
        return items.map { item in
            let incoming = item.direction == .received
            let suspicious = incoming && ActivityScreening.imitatesKnown(item.counterparty, known: known, chain: .near)
                && !known.contains(where: { Address.sameRecipient($0, item.counterparty ?? "", chain: .near) })
            return ActivityEntry(
                id: item.id, chainID: item.chainID, direction: SuiActivitySource.direction(item.direction), asset: item.asset,
                amount: item.amount, counterparty: item.counterparty, date: item.date, status: SuiActivitySource.status(item.status),
                fee: item.fee, hash: item.hash, suspicious: suspicious
            )
        }
    }
}
