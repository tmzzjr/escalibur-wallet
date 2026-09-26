import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A Atividade do XRP Ledger, pelo `XRPLReader.history`.
///
/// O leitor ja mostra o recebido pelo `delivered_amount`, nunca pelo `Amount`, e ja
/// deixa de fora valor zero, poeira e token fora da lista (a pagina so traz a contagem
/// deles). Aqui se soma a regra do endereco parecido com o da conta ou com um destino ja
/// pago.
struct XRPLActivitySource: ActivitySource {
    let reader: XRPLReader

    init(reader: XRPLReader = .shared) {
        self.reader = reader
    }

    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        guard chain == .xrpl, account.chainID == Chain.xrpl.id else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
        do {
            let page = try await reader.history(address: account.address)
            return Self.entries(page, owner: account.address)
        } catch {
            throw XRPLEngineSupport.translate(error)
        }
    }

    static func entries(_ page: ActivityPage, owner: String) -> [ActivityEntry] {
        let known = [owner] + page.items.filter { $0.direction == .sent }.compactMap(\.counterparty)
        return page.items.map { item in
            let direction: ActivityEntry.Direction
            switch item.direction {
            case .sent: direction = .sent
            case .received: direction = .received
            case .swap: direction = .swap
            case .other: direction = .other
            }
            let status: ActivityEntry.Status
            switch item.status {
            case .pending: status = .pending(nil)
            case .confirmed: status = .confirmed
            case .failed: status = .failed(nil)
            }
            let suspicious = direction == .received
                && (item.amount.isZero || ActivityScreening.imitatesKnown(item.counterparty, known: known, chain: .xrpl))
            return ActivityEntry(
                id: item.id, chainID: Chain.xrpl.id, direction: direction, asset: item.asset, amount: item.amount,
                counterparty: item.counterparty, date: item.date, status: status, fee: item.fee, hash: item.hash,
                suspicious: suspicious
            )
        }
    }
}
