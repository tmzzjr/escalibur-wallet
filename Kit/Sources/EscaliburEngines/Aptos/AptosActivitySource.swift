import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A Atividade da Aptos: o historico do `AptosReader` (indexador da Aptos Labs), com cada
/// recebimento julgado contra envenenamento de endereco antes de chegar a tela
/// (docs/seguranca.md §4.10).
///
/// O leitor ja deixa de fora o recebimento de valor zero, o po e o ativo fora da lista.
/// Aqui entra a comparacao com o que o atacante nao controla: a propria conta e os
/// destinos que ela ja pagou. Na Aptos o envio so sai com a assinatura do dono, entao o
/// que saiu aparece sempre.
struct AptosActivitySource: ActivitySource {
    let reader: AptosReader

    init(reader: AptosReader = .shared) {
        self.reader = reader
    }

    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        guard chain.id == Chain.aptos.id else { throw SendEngineError.unsupported(chain) }
        guard account.chainID == Chain.aptos.id, case .success(let owner) = AptosAddress.parse(account.address) else {
            throw SendEngineError.message(AptosEngineText.keyMismatch)
        }
        let page: ActivityPage
        do {
            page = try await reader.history(owner: owner)
        } catch {
            throw SendEngineError.message(AptosEngineText.historyFailure)
        }
        return Self.entries(page.items, owner: owner)
    }

    static func entries(_ items: [ActivityItem], owner: AptosAddress) -> [ActivityEntry] {
        let paid = items.filter { $0.direction == .sent && !$0.amount.isZero }.compactMap(\.counterparty)
        let known = [owner.hex] + paid
        return items.map { item in
            let incoming = item.direction == .received
            let suspicious = incoming && ActivityScreening.imitatesKnown(item.counterparty, known: known, chain: .aptos)
                && !known.contains(where: { Address.sameRecipient($0, item.counterparty ?? "", chain: .aptos) })
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
