import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// O motor contra a rede real, so com ESCALIBUR_REDE=1: maximo e plano completo de 1 SUI
/// da Binance 1 para a OKX 1, com as duas simulacoes. Nada e assinado nem transmitido
/// (a chave privada nem existe aqui).
@Suite("Motor Sui ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct SuiEngineLiveTests {
    @Test("Maximo e plano de envio montados e simulados em dois provedores")
    func planLive() async throws {
        let engine = SuiSendEngine()
        let spendable = try await engine.spendable(SuiRecorded.request())
        #expect(spendable.amount > BigUInt(1_000_000_000))
        let plan = try await engine.plan(SuiRecorded.request())
        #expect(plan.review.recipient == SuiRecorded.destination)
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: "sui:native", amount: 1_000_000_000))
        let transfer = try #require(plan.transactions.first as? SuiTransfer)
        #expect(transfer.data.gas.budget <= SuiPlanner.budgetCeiling)
    }

    @Test("Atividade lida do GraphQL")
    func activityLive() async throws {
        let entries = try await SuiActivitySource().history(chain: .sui, account: SuiRecorded.account(), usage: nil)
        #expect(!entries.isEmpty)
    }
}
