import EscaliburChains
import EscaliburCore
import EscaliburEngines
import Foundation

/// O ultimo historico lido de cada carteira, para a Atividade abrir com ele na hora e
/// trocar rede por rede conforme cada uma responde. Fica nos metadados cifrados, como o
/// cache de saldo: so o que a rede ja mostra publicamente, nada de chave.
struct CachedActivity: Codable, Equatable {
    let id: String
    let chainID: String
    let direction: String
    let asset: Asset?
    let amount: BigUInt
    let counterparty: String?
    let date: Date
    /// "pendente", "confirmada" ou "falhou", e o motivo quando ha.
    let status: String
    let statusNote: String?
    let fee: BigUInt?
    let hash: String
    let suspicious: Bool
    let receivedAsset: Asset?
    let receivedAmount: BigUInt?

    /// Quantas guardar por carteira: as mais recentes.
    static let limit = 300

    init(_ entry: ActivityEntry) {
        id = entry.id
        chainID = entry.chainID
        direction = entry.direction.rawValue
        asset = entry.asset
        amount = entry.amount
        counterparty = entry.counterparty
        date = entry.date
        switch entry.status {
        case .pending(let note): (status, statusNote) = ("pendente", note)
        case .confirmed: (status, statusNote) = ("confirmada", nil)
        case .failed(let note): (status, statusNote) = ("falhou", note)
        }
        fee = entry.fee
        hash = entry.hash
        suspicious = entry.suspicious
        receivedAsset = entry.receivedAsset
        receivedAmount = entry.receivedAmount
    }

    var entry: ActivityEntry? {
        guard let direction = ActivityEntry.Direction(rawValue: direction) else { return nil }
        let state: ActivityEntry.Status
        switch status {
        case "pendente": state = .pending(statusNote)
        case "confirmada": state = .confirmed
        case "falhou": state = .failed(statusNote)
        default: return nil
        }
        return ActivityEntry(
            id: id, chainID: chainID, direction: direction, asset: asset, amount: amount, counterparty: counterparty, date: date,
            status: state, fee: fee, hash: hash, suspicious: suspicious, receivedAsset: receivedAsset, receivedAmount: receivedAmount
        )
    }
}
