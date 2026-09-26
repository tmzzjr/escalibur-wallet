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

    @Test("Encadear so planos da mesma carteira e da mesma rede")
    func sequence() throws {
        let wallet = UUID()
        let a = plan(wallet: wallet, warnings: [.unlimitedApproval], lines: [.init("Rede", "Ethereum"), .init("Valor", "1")])
        let b = plan(wallet: wallet, warnings: [.unlimitedApproval], lines: [.init("Valor", "2")])
        let joined = try SigningPlan.sequence([a, b], kind: .swap, title: "Trocar", lead: [.init("Sai", "3")], stepPrefix: true, omitting: ["Rede"])
        #expect(joined.transactions.count == 2)
        #expect(joined.review.transactionCount == 2)
        #expect(joined.review.lines.map(\.label) == ["Sai", "Etapa 1 · Valor", "Etapa 2 · Valor"])
        #expect(joined.review.warnings == [.unlimitedApproval])
        #expect(joined.review.recipient == nil)
        #expect(throws: SigningPlan.CompositionError.mixedPlans) {
            try SigningPlan.sequence([a, plan(wallet: UUID())], kind: .swap, title: "x", lead: [])
        }
        #expect(throws: SigningPlan.CompositionError.mixedPlans) {
            try SigningPlan.sequence([a, plan(wallet: wallet, chain: .base)], kind: .swap, title: "x", lead: [])
        }
        #expect(throws: SigningPlan.CompositionError.empty) { try SigningPlan.sequence([], kind: .swap, title: "x", lead: []) }
    }
}
