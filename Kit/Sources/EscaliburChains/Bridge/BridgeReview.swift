import EscaliburCore
import Foundation

// A revisao da ponte, em portugues: de onde sai, para onde vai, quanto chega no minimo,
// quem recebe (a propria conta, caractere a caractere), a taxa da ponte, o tempo e o que
// acontece se nao chegar. O que sai, o minimo que chega e quem recebe vem da transferencia
// que o app montou e reconferiu (`BridgePlanner.reencode`), nunca da API.

enum BridgeReview {
    static func review(
        quote: ValidatedBridgeQuote, approvalValues: [BigUInt], approveQuote: EVMFeeQuote?, depositQuote: EVMFeeQuote,
        firstNonce: UInt64
    ) -> PlanReview {
        let intent = quote.intent
        let from = intent.from.chain
        let to = intent.to.chain
        let sell = intent.sell
        let receive = intent.receive
        let native = TradeAsset.native(from)
        let count = approvalValues.count + 1

        var lines: [PlanReview.Line] = [
            .init("De", from.name),
            .init("Para", to.name),
            .init("Sai", TradeText.amount(intent.amount, sell)),
            .init("Chega, no mínimo", TradeText.amount(quote.minimumReceived, receive)),
            .init("Recebe", "A sua conta na \(to.name)"),
            .init("Endereço que recebe", intent.owner.checksummed, verbatim: true),
        ]

        switch quote.call {
        case .cctp(let transfer):
            lines.append(.init("Ponte", "CCTP da Circle: o USDC é queimado na \(from.name) e a própria Circle cunha o mesmo USDC na \(to.name)"))
            lines.append(.init("Taxa da ponte (máxima)", TradeText.amount(transfer.maxFee, sell)))
            lines.append(.init("Entrega", "A Circle entrega na \(to.name) e cobra o gás de lá dentro da taxa acima. Você não precisa ter \(to.nativeSymbol) na \(to.name)"))
            lines.append(.init("Tempo estimado", quote.route == .cctpFast ? "Menos de 1 minuto" : "Uns 20 minutos, o tempo da finalidade da \(from.name)"))
            lines.append(.init("Se não chegar", "O USDC queimado só pode ser cunhado para a sua conta. Se a entrega da Circle falhar, a carteira resgata com a sua assinatura"))
            lines.append(.init("Contrato da Circle", BridgeAllowlist.tokenMessenger.checksummed, verbatim: true))
        case .across(let transfer):
            lines.append(.init("Ponte", "Across: um relayer entrega na \(to.name) do próprio bolso, e o Across devolve a ele o seu depósito depois"))
            lines.append(.init("Taxa da ponte", TradeText.amount(quote.bridgeFee, sell)))
            lines.append(.init("Tempo estimado", quote.estimatedSeconds < 120 ? "Segundos" : "Uns \(quote.estimatedSeconds / 60) minutos"))
            let hours = (transfer.fillDeadline - transfer.quoteTimestamp) / 3_600
            lines.append(.init("Se não chegar", "Sem entrega em \(hours) horas, o depósito volta para esta conta na \(from.name), algumas horas depois do prazo"))
            lines.append(.init("Contrato do Across", quote.to.checksummed, verbatim: true))
        }

        if sell.isNative {
            lines.append(.init("Autorização", "Não precisa: moeda nativa"))
        } else if approvalValues.isEmpty {
            lines.append(.init("Autorização", "Já existe e cobre o valor"))
        } else if let spender = quote.spender {
            lines.append(.init("Autorização", "Exata: \(TradeText.amount(intent.amount, sell)), nunca ilimitada"))
            lines.append(.init("Autorizado a gastar", spender.checksummed, verbatim: true))
            if approvalValues.count == 2 {
                lines.append(.init("Antes", "Zerar a autorização atual (exigência do \(sell.symbol))"))
            }
        }

        let approveCount = BigUInt(approvalValues.count)
        let expectedFee = depositQuote.expectedCost + (approveQuote?.expectedCost ?? 0) * approveCount
        let maxFee = depositQuote.maxCost + (approveQuote?.maxCost ?? 0) * approveCount
        lines.append(.init("Taxa da rede (estimada)", TradeText.amount(expectedFee, native)))
        lines.append(.init("Taxa da rede (máxima)", TradeText.amount(maxFee, native)))
        let l1 = depositQuote.l1DataFee + (approveQuote?.l1DataFee ?? 0) * approveCount
        if !l1.isZero { lines.append(.init("Parte da taxa paga à L1", TradeText.amount(l1, native))) }
        lines.append(.init("Taxa da Escalibur", "Sem taxa da Escalibur"))
        lines.append(.init("Etapas", approvalValues.isEmpty ? "1 transação: o depósito na ponte" : "\(count) transações: autorizar e depositar, nesta ordem"))
        lines.append(.init("Nonce", count == 1 ? "\(firstNonce)" : "\(firstNonce) a \(firstNonce + UInt64(count - 1))"))

        var warnings: [PlanReview.Warning] = []
        if quote.feePercent >= 1 { warnings.append(.highFee(percentOfAmount: quote.feePercent)) }
        return PlanReview(
            kind: .bridge, title: "Levar \(TradeText.amount(intent.amount, sell)) para a \(to.name)", lines: lines, warnings: warnings,
            transactionCount: count, outgoing: sell.movement(intent.amount), incomingMinimum: receive.movement(quote.minimumReceived),
            beneficiary: intent.owner.checksummed
        )
    }
}
