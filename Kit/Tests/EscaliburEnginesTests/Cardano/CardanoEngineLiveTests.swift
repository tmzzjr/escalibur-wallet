import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// O motor contra a rede real, so com ESCALIBUR_REDE=1: maximo e plano de 2 ADA, lidos
/// nas duas fontes. Nada e assinado nem transmitido.
@Suite("Motor Cardano ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct CardanoEngineLiveTests {
    @Test("Maximo e plano de envio montados com as duas fontes concordando")
    func planLive() async throws {
        let engine = CardanoSendEngine()
        let spendable = try await engine.spendable(CardanoEngineRecorded.request(amount: 2_000_000))
        #expect(spendable.amount > BigUInt(2_000_000))
        let plan = try await engine.plan(CardanoEngineRecorded.request(amount: 2_000_000))
        #expect(plan.review.recipient == CardanoEngineRecorded.destination)
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: Asset.native(.cardano).id, amount: 2_000_000))
    }

    @Test("Atividade lida da Koios")
    func activityLive() async throws {
        let entries = try await CardanoActivitySource().history(chain: .cardano, account: CardanoEngineRecorded.account(), usage: nil)
        #expect(!entries.isEmpty)
    }
}
