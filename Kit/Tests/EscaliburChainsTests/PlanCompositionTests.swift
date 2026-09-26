import Foundation
import Testing
@testable import EscaliburChains

@Suite("Composicao de planos")
struct PlanCompositionTests {
    struct Dummy: SignableTransaction {
        let chain: Chain = .ethereum
        let signingRequests: [SigningRequest] = []
        func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction { throw SigningError.wrongSignatureCount }
    }

    func plan(wallet: UUID, chain: Chain = .ethereum, recipient: String? = "0xabc", warnings: [PlanReview.Warning] = [], lines: [PlanReview.Line] = []) -> SigningPlan {
        SigningPlan(
            walletID: wallet, chain: chain,
            review: PlanReview(kind: .send, title: "Enviar", lines: lines, warnings: warnings, recipient: recipient, recipientTag: "7"),
            transactions: [Dummy()]
        )
    }

    @Test("Somar avisos nao mexe em transacao, destino, identidade nem prazo")
    func addingWarnings() {
        let original = plan(wallet: UUID(), warnings: [.destinationIsContract])
        let updated = original.addingWarnings([.firstSendToAddress, .destinationIsContract, .firstSendToAddress])
        #expect(updated.id == original.id)
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.review.recipient == "0xabc" && updated.review.recipientTag == "7")
        #expect(updated.review.warnings == [.destinationIsContract, .firstSendToAddress])
        #expect(updated.transactions.count == 1)
        #expect(original.addingWarnings([.destinationIsContract]).review.warnings == [.destinationIsContract])
    }

    func trade(wallet: UUID, kind: PlanReview.Kind = .swap, lines: [PlanReview.Line] = []) -> SigningPlan {
        SigningPlan(walletID: wallet, chain: .ethereum, review: PlanReview(kind: kind, title: "Trocar", lines: lines), transactions: [Dummy()])
    }

    func sequence(_ plans: [SigningPlan], kind: PlanReview.Kind = .swap, lead: [PlanReview.Line] = [], stepPrefix: Bool = false,
                  omitting: Set<String> = []) throws -> SigningPlan {
        try SigningPlan.sequence(plans, kind: kind, title: "Trocar", lead: lead, stepPrefix: stepPrefix, omitting: omitting,
                                 outgoing: .init(assetID: "ethereum:native", amount: 3), incomingMinimum: nil, beneficiary: "0xdono")
    }

    @Test("Encadear so planos da mesma carteira e da mesma rede, com os movimentos do compositor")
    func sequence() throws {
        let wallet = UUID()
        let a = trade(wallet: wallet, lines: [.init("Rede", "Ethereum"), .init("Valor", "1")])
        let b = trade(wallet: wallet, lines: [.init("Valor", "2")])
        let joined = try sequence([a.addingWarnings([.unlimitedApproval]), b.addingWarnings([.unlimitedApproval])],
                                  lead: [.init("Sai", "3")], stepPrefix: true, omitting: ["Rede"])
        #expect(joined.transactions.count == 2)
        #expect(joined.review.transactionCount == 2)
        #expect(joined.review.lines.map(\.label) == ["Sai", "Etapa 1 · Valor", "Etapa 2 · Valor"])
        #expect(joined.review.warnings == [.unlimitedApproval])
        #expect(joined.review.recipient == nil)
        #expect(joined.review.outgoing == .init(assetID: "ethereum:native", amount: 3) && joined.review.beneficiary == "0xdono")
        #expect(throws: SigningPlan.CompositionError.mixedPlans) { try sequence([a, trade(wallet: UUID())]) }
        #expect(throws: SigningPlan.CompositionError.mixedPlans) {
            try sequence([a, SigningPlan(walletID: wallet, chain: .base, review: PlanReview(kind: .swap, title: "x", lines: []), transactions: [Dummy()])])
        }
        #expect(throws: SigningPlan.CompositionError.empty) { try sequence([]) }
    }

    @Test("Regressao A1: envio dentro de troca ou ordem e recusado, e linha de conferir nunca some")
    func tradeGuards() throws {
        let wallet = UUID()
        // Um envio para outra pessoa, embrulhado como etapa de troca.
        let send = plan(wallet: wallet)
        #expect(throws: SigningPlan.CompositionError.sendInsideTrade) { try sequence([trade(wallet: wallet), send]) }
        #expect(throws: SigningPlan.CompositionError.sendInsideTrade) { try sequence([trade(wallet: wallet), send], kind: .limitOrder) }
        // Mesmo um plano de outro tipo com destinatario conta como envio.
        let disguised = SigningPlan(
            walletID: wallet, chain: .ethereum,
            review: PlanReview(kind: .approve, title: "x", lines: [], recipient: "0xoutro"), transactions: [Dummy()]
        )
        #expect(throws: SigningPlan.CompositionError.sendInsideTrade) { try sequence([trade(wallet: wallet), disguised]) }

        // "Contrato" na lista de omitir nao tira a linha que se confere caractere a caractere.
        let verbatim = trade(wallet: wallet, lines: [.init("Contrato", "0xabc", verbatim: true), .init("Contrato", "texto")])
        let joined = try sequence([verbatim, trade(wallet: wallet)], omitting: ["Contrato"])
        #expect(joined.review.lines == [.init("Contrato", "0xabc", verbatim: true)])
    }
}
