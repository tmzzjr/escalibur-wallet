import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// O motor contra a rede real, so com ESCALIBUR_REDE=1: destino, maximo e plano de 0,001
/// NEAR, lidos em dois provedores concordando. Nada e assinado nem transmitido.
@Suite("Motor NEAR ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct NEAREngineLiveTests {
    typealias R = NEAREngineRecorded

    @Test("Destino, maximo e plano montados com os provedores concordando")
    func planLive() async throws {
        let engine = NEARSendEngine()
        #expect(try await engine.destination(R.destination, chain: .near).exists)
        await #expect(throws: SendEngineError.message(NEAREngineText.namedMissing)) { _ = try await engine.destination(R.missing, chain: .near) }
        let amount = NEARRules.oneNEAR / BigUInt(1000)
        let spendable = try await engine.spendable(R.request(amount: amount))
        guard spendable.amount >= amount else { return }
        let plan = try await engine.plan(R.request(amount: amount))
        #expect(plan.review.recipient == R.destination)
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: Asset.native(.near).id, amount: amount))
    }

    @Test("Atividade lida da FastNEAR")
    func activityLive() async throws {
        let entries = try await NEARActivitySource().history(chain: .near, account: R.account(), usage: nil)
        #expect(!entries.isEmpty)
    }
}
