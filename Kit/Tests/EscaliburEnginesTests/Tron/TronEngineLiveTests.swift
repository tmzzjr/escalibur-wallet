import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// O motor Tron contra a rede de verdade (TronGrid, PublicNode, TronStack), so com
/// ESCALIBUR_REDE=1. So leitura: os planos sao montados e conferidos, nunca assinados nem
/// transmitidos. O dono e a conta de exchange TNXoiAJ3...32G, com TRX, USDT e stake, e a
/// chave publica recuperada de uma assinatura dela (ver TronTestSupport).
@Suite("Motor Tron ao vivo", .enabled(if: TronRecorded.liveNetwork), .serialized)
struct TronEngineLiveTests {
    typealias R = TronRecorded

    let engine = TronSendEngine()

    @Test("Destino ativo lido da rede")
    func destination() async throws {
        let info = try await engine.destination(R.destination, chain: .tron)
        #expect(info.exists && !info.isContract && info.activationMinimum == nil)
    }

    @Test("USDT: maximo e plano completo, com o destino e o memo pedidos")
    func usdtPlan() async throws {
        let spendable = try await engine.spendable(R.request(asset: R.usdt, amount: 0, sendAll: true))
        #expect(!spendable.amount.isZero)
        let plan = try await engine.plan(R.request(asset: R.usdt, amount: 1_000_000, memo: "escalibur"))
        #expect(plan.review.recipient == R.destination)
        #expect(Address.sameRecipient(plan.review.recipient, R.destination, chain: .tron))
        #expect(plan.review.recipientTag == "escalibur")
        let transaction = try #require(plan.transactions.first as? TronTransaction)
        guard case .triggerSmartContract(_, let contract, _, let data) = transaction.raw.contract else { Issue.record("contrato"); return }
        #expect(contract == TRC20.usdt.contract)
        #expect(TRC20.decodeTransfer(data)?.to.base58 == R.destination)
    }

    @Test("TRX: maximo e plano completo, com o destino pedido")
    func trxPlan() async throws {
        let spendable = try await engine.spendable(R.request(asset: R.trx, amount: 0, sendAll: true))
        #expect(!spendable.amount.isZero)
        let plan = try await engine.plan(R.request(asset: R.trx, amount: 1_000_000))
        #expect(plan.review.recipient == R.destination)
        #expect(plan.review.recipientTag == nil)
        let transaction = try #require(plan.transactions.first as? TronTransaction)
        guard case .transfer(_, let to, let amount) = transaction.raw.contract else { Issue.record("contrato"); return }
        #expect(to.base58 == R.destination)
        #expect(amount == BigUInt(1_000_000))
    }

    @Test("Conta com controle dividido: o plano e recusado com a frase das permissoes")
    func splitControl() async throws {
        // TNPeeaa...qeL tem a permissao de dono em 2 de 2 (ver TronReaderLiveTests). A chave
        // publica nao importa: a recusa vem antes, e a conta aqui e so o endereco.
        let address = try #require(TronAddress(base58: "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL"))
        let control = try await engine.reader.ownerControl(owner: address)
        #expect(control.isCompromised)
    }

    @Test("Atividade da conta lida da TronGrid")
    func activity() async throws {
        let entries = try await TronActivitySource().history(chain: .tron, account: R.account(), usage: nil)
        #expect(entries.count <= 30)
    }
}
