import EscaliburCore
import Foundation

/// O plano faz o que a tela pediu? Conferido pelo app antes de mostrar a revisao e de
/// novo antes de assinar (auditoria 2, M1).
///
/// A revisao e montada pelo planejador da rede a partir das transacoes; esta conferencia
/// amarra essa revisao ao pedido do dono: o ativo e o valor que saem, o minimo e o ativo
/// que entram, e quem recebe. Falha fechada: movimento ausente e recusado.
public enum PlanIntentCheck {
    public enum Mismatch: Error, Equatable, Sendable {
        case missingMovement
        case wrongAsset
        /// Sai mais (ou, num envio de valor exato, outro valor) do que o pedido.
        case wrongAmount
        case wrongBuyAsset
        case belowMinimum
        case wrongBeneficiary
    }

    /// Envio. Valor exato: sai exatamente `amount`. Enviar tudo (`amount` nil): sai no
    /// maximo `ceiling`, o saldo que a tela mostrou.
    public static func send(_ review: PlanReview, asset: Asset, amount: BigUInt?, ceiling: BigUInt, chain: Chain) throws {
        guard let outgoing = review.outgoing else { throw Mismatch.missingMovement }
        guard sameAsset(outgoing.assetID, asset, chain: chain) else { throw Mismatch.wrongAsset }
        if let amount {
            guard outgoing.amount == amount else { throw Mismatch.wrongAmount }
        } else {
            guard outgoing.amount <= ceiling else { throw Mismatch.wrongAmount }
        }
    }

    /// Troca ou ordem limite: vende `sell`, nunca mais que `amountIn`; garante pelo
    /// menos `minimumOut` de `buy`; e o que entra vai para `owner`.
    public static func trade(
        _ review: PlanReview, sell: Asset, amountIn: BigUInt, buy: Asset, minimumOut: BigUInt, owner: String, chain: Chain
    ) throws {
        guard let outgoing = review.outgoing, let incoming = review.incomingMinimum else { throw Mismatch.missingMovement }
        guard sameAsset(outgoing.assetID, sell, chain: chain) else { throw Mismatch.wrongAsset }
        guard outgoing.amount <= amountIn else { throw Mismatch.wrongAmount }
        guard sameAsset(incoming.assetID, buy, chain: chain) else { throw Mismatch.wrongBuyAsset }
        guard incoming.amount >= minimumOut else { throw Mismatch.belowMinimum }
        guard Address.sameRecipient(review.beneficiary, owner, chain: chain) else { throw Mismatch.wrongBeneficiary }
    }

    /// A tag, o memo ou o comentario do plano contra o digitado (auditoria 2, B7). A tag
    /// do XRP Ledger e um numero: "0123" e 123 sao a mesma. Memo da Stellar, comentario
    /// da TON e memo da Tron sao comparados exatamente: o motor da Stellar so escolhe
    /// memo ID para digitos sem zero a esquerda, e "0123" de texto nunca vale o ID 123.
    public static func sameTag(_ planned: String?, _ typed: String?, chain: Chain) -> Bool {
        let a = planned.flatMap { $0.isEmpty ? nil : $0 }
        let b = typed.flatMap { $0.isEmpty ? nil : $0 }
        guard let a, let b else { return a == nil && b == nil }
        if chain.destinationTag == .xrplTag {
            guard let x = UInt32(a), let y = UInt32(b) else { return false }
            return x == y
        }
        return a == b
    }

    /// O id do `TokenRegistry`. Na EVM o contrato pode vir em outra caixa (EIP-55), e
    /// so la a comparacao ignora caixa: nas outras redes a caixa faz parte do endereco.
    static func sameAsset(_ id: String, _ asset: Asset, chain: Chain) -> Bool {
        chain.family == .evm ? id.lowercased() == asset.id.lowercased() : id == asset.id
    }
}
