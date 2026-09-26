import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra a TronGrid e a PublicNode, so com ESCALIBUR_REDE=1.
///
/// O dono e TNXoiAJ3dct8Fjg4M9fkLFh9S2v9TXc32G, conta de exchange com TRX e USDT e
/// permissoes de dono unico. A chave publica foi recuperada da assinatura da transacao
/// f5e12244e2d27d3e40a3e3207accec8d8959c67909d78847bad61fd3002dbdcb (txID assinado
/// direto, v - 27 como id de recuperacao), em 25/09/2026; o teste confere que ela da o
/// endereco. Nada e assinado nem transmitido.
@Suite("Leitor Tron ao vivo", .enabled(if: Live.enabled), .serialized)
struct TronReaderLiveTests {
    static let ownerKey = [UInt8](hex: "026a2745758b2ece1844db054201c56698b1942f390ac4e2ab44f3ec711dc8322a")!
    static let ownerPath = DerivationPath("m/44'/195'/0'/0/0")!
    /// Conta ativada que ja tem USDT.
    static let destination = "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
    /// Conta com a permissao de dono dividida com outra chave (multi-assinatura 2 de 2).
    static let sharedControl = "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL"

    let reader = TronReader()

    func owner() throws -> TronOwner {
        let owner = try TronOwner(path: Self.ownerPath, publicKey: Self.ownerKey)
        #expect(owner.address.base58 == "TNXoiAJ3dct8Fjg4M9fkLFh9S2v9TXc32G")
        return owner
    }

    @Test("USDT: estado real ate o SigningPlan")
    func usdtPlan() async throws {
        let owner = try owner()
        let amount = BigUInt(1_000_000)
        let state = try await reader.networkState(owner: owner.address, intent: .usdt(to: Self.destination, amount: amount))
        #expect(state.ownerControl.verdict == .soleOwner)
        #expect(state.destinationActivated)
        #expect(state.destinationIsContract == false)
        #expect(state.destinationHoldsUSDT == true)
        #expect(!state.usdtBalance.isZero)
        let energy = try #require(state.usdtEnergyEstimate)
        #expect(TronPlanner.usdtEnergyRange.contains(energy))
        let plan = try TronPlanner.planSendUSDT(walletID: UUID(), owner: owner, to: Self.destination, amount: amount, state: state)
        #expect(plan.transactions.count == 1)
        Live.note("tron: bloco \(state.block.number), energy \(energy), trx \(state.trxBalance), precos \(state.parameters.energyPrice)/\(state.parameters.bandwidthPrice)")
    }

    @Test("TRX: estado real ate o SigningPlan")
    func trxPlan() async throws {
        let owner = try owner()
        let state = try await reader.networkState(owner: owner.address, intent: .trx(to: Self.destination, amount: 1_000_000))
        #expect(state.usdtEnergyEstimate == nil)
        let plan = try TronPlanner.planSendTRX(walletID: UUID(), owner: owner, to: Self.destination, amount: 1_000_000, state: state)
        #expect(plan.transactions.count == 1)
    }

    @Test("Conta com controle dividido e marcada como comprometida")
    func sharedControlIsCompromised() async throws {
        let address = try #require(TronAddress(base58: Self.sharedControl))
        let control = try await reader.ownerControl(owner: address)
        #expect(control.isCompromised)
    }

    @Test("Transacao conhecida confirmada no no solidificado dos dois provedores")
    func knownTransaction() async throws {
        let status = try await reader.status(of: "6484590d488c8c312525f491137e5f95f5d3a9cd05235474a058c2fe29824982")
        #expect(status == .confirmed(block: 85_577_993, confirmations: nil))
    }

    @Test("Historico da TronGrid")
    func history() async throws {
        let page = try await reader.history(address: try owner().address)
        #expect(page.items.count <= ActivityRules.pageSize)
        Live.note("tron: \(page.items.count) itens, \(page.suspiciousCount) suspeitos (\(page.suspicious))")
    }
}
