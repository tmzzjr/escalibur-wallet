import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// O motor contra a rede real, so com ESCALIBUR_REDE=1: maximo e plano completo de 1 APT da
/// conta gravada para o destino gravado, com as quatro simulacoes. Nada e assinado nem
/// transmitido (a chave privada nem existe aqui).
@Suite("Motor Aptos ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct AptosEngineLiveTests {
    @Test("Maximo e plano de envio montados e simulados em dois provedores")
    func planLive() async throws {
        let engine = AptosSendEngine()
        let spendable = try await engine.spendable(AptosRecorded.request(sendAll: true))
        #expect(spendable.amount > BigUInt(AptosRecorded.recording.valor))
        let plan = try await engine.plan(AptosRecorded.request())
        #expect(plan.review.recipient == AptosRecorded.recording.existente)
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: Asset.native(.aptos).id, amount: BigUInt(AptosRecorded.recording.valor)))
        let transfer = try #require(plan.transactions.first as? AptosTransfer)
        #expect(transfer.raw.maxGasAmount <= AptosPlanner.maxGasCeiling && transfer.raw.chainID == 1)
    }

    @Test("Destino novo e Atividade pelo indexador")
    func destinationAndActivity() async throws {
        let fresh = try await AptosSendEngine().destination(AptosRecorded.recording.nova, chain: .aptos)
        #expect(!fresh.exists)
        let entries = try await AptosActivitySource().history(chain: .aptos, account: AptosRecorded.account(), usage: nil)
        #expect(!entries.isEmpty)
    }
}
