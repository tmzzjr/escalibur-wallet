import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A regra de envenenamento da Atividade que depende de comparar enderecos
/// (docs/seguranca.md §4.10).
///
/// So recebimentos sao julgados. O que a propria conta fez aparece sempre: foi o dono
/// que assinou, e esconder um envio esconderia justamente o rastro de um golpe que deu
/// certo. "Conhecido" e o que o atacante nao controla: os enderecos da propria carteira
/// e os destinos que ela ja pagou. Remetentes nao entram, porque o golpe manda poeira de
/// um endereco parecido com o de um remetente real, e comparar os dois marcaria o real.
enum ActivityScreening {
    static func imitatesKnown(_ counterparty: String?, known: [String], chain: Chain) -> Bool {
        guard let counterparty else { return false }
        return AddressPoisoning.lookalike(counterparty, among: known, chain: chain) != nil
    }
}

/// `ChainActivity` (leitores de Bitcoin, Litecoin, Dogecoin e Stellar) para o
/// `ActivityEntry` da Atividade.
enum ChainActivityEntries {
    /// `own`: os enderecos da carteira nesta rede. `resolve`: o ativo da lista curada
    /// para uma referencia do historico, ou nil quando ele esta fora da lista.
    static func entries(
        _ items: [ChainActivity], chain: Chain, own: [String],
        resolve: (ChainActivity.AssetRef) -> Asset?, fetchedAt: Date = .now
    ) -> [ActivityEntry] {
        let paid = items.filter { direction(of: $0) == .sent }.compactMap(\.counterparty)
        let known = own + paid
        return items.compactMap { item in
            // Trade da Stellar executado contra oferta da conta: acontece na transacao de
            // outra pessoa e a Horizon nao diz qual. Sem hash nao ha o que abrir no
            // explorador, e o `ActivityEntry` exige um.
            guard let hash = item.transactionHash else { return nil }
            let direction = direction(of: item)
            let movement = item.movements.first { !$0.incoming } ?? item.movements.first
            let asset = movement.flatMap { resolve($0.asset) }
            let incoming = direction == .received
            let suspicious = item.suspicious
                || (incoming && movement?.amount.isZero == true)
                || (incoming && movement != nil && asset == nil)
                || (incoming && ActivityScreening.imitatesKnown(item.counterparty, known: known, chain: chain))
            return ActivityEntry(
                id: "\(chain.id):\(item.id)", chainID: chain.id, direction: direction, asset: asset,
                amount: movement?.amount ?? BigUInt(), counterparty: item.counterparty,
                // Pendente sem data e o que acabou de chegar a mempool; confirmado sem data
                // so vem de provedor que nao informou, e fica na hora da leitura.
                date: item.date ?? fetchedAt, status: status(item.status), fee: item.fee, hash: hash,
                suspicious: suspicious
            )
        }
    }

    static func direction(of item: ChainActivity) -> ActivityEntry.Direction {
        switch item.kind {
        case .send: return .sent
        case .receive: return .received
        case .swap, .trade: return .swap
        case .offer: return .order
        case .createAccount, .claimableBalance:
            guard let movement = item.movements.first else { return .other }
            return movement.incoming ? .received : .sent
        case .selfTransfer, .trustline, .accountMerge, .other: return .other
        }
    }

    static func status(_ status: ChainActivity.Status) -> ActivityEntry.Status {
        switch status {
        case .pending: return .pending(nil)
        case .confirmed: return .confirmed
        case .failed: return .failed(nil)
        }
    }
}

/// Onde uma transferencia esta, dito para a tela, a partir da leitura dos dois
/// provedores (`ChainTransactionStatus.combine`).
enum ChainTransferStatus {
    static func transfer(_ status: ChainTransactionStatus, finalLedger: Bool) -> TransferStatus {
        switch status {
        case .notFound, .pending:
            return .pending
        case .confirmed(let height, let confirmations):
            if finalLedger { return .confirmed(detail: "Incluída no ledger \(EngineFormat.grouped(height)), que já é final.") }
            guard let count = confirmations else { return .confirmed(detail: "Confirmada no bloco \(EngineFormat.grouped(height)).") }
            let noun = count == 1 ? "confirmação" : "confirmações"
            return .confirmed(detail: "\(EngineFormat.grouped(count)) \(noun), no bloco \(EngineFormat.grouped(height)).")
        case .failed:
            return .failed(reason: "A transação entrou na rede e falhou. Só a taxa foi cobrada.")
        }
    }
}
