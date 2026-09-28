import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// O motor contra a rede real, so com ESCALIBUR_REDE=1: maximo e plano de 0,01 DOT, lidos
/// em dois provedores concordando. Nada e assinado nem transmitido.
@Suite("Motor Polkadot ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct PolkadotEngineLiveTests {
    @Test("Maximo e plano de envio montados com os provedores concordando")
    func planLive() async throws {
        let engine = PolkadotSendEngine()
        let amount = PolkadotRuntime.existentialDeposit
        let spendable = try await engine.spendable(PolkadotEngineRecorded.request(amount: amount))
        guard spendable.amount >= amount else { return }
        let plan = try await engine.plan(PolkadotEngineRecorded.request(amount: amount))
        #expect(plan.review.recipient == PolkadotEngineRecorded.destination)
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: Asset.native(.polkadot).id, amount: amount))
    }

    @Test("Atividade lida do indexador da Nova")
    func activityLive() async throws {
        let entries = try await PolkadotActivitySource().history(chain: .polkadot, account: PolkadotEngineRecorded.account(), usage: nil)
        #expect(!entries.isEmpty)
    }
}
