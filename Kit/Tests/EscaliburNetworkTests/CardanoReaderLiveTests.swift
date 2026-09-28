import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra a Koios e o backend da Yoroi reais, so com ESCALIBUR_REDE=1. Le uma conta com
/// ADA e monta o plano de envio (nunca assina nem transmite: a chave privada nem existe
/// aqui). A chave publica e a testemunha das transacoes dessa conta na rede.
@Suite("Leitor Cardano ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct CardanoReaderLiveTests {
    static let owner = "addr1q8ph5dwx5hzrygtwfdpk2nxp2y4p0rr35tds049rz3dee4kr0g6udfwyxgskuj6rv4xvz5f2z7x8rgkmql22x9zmnntqar3scw"
    static let ownerKey = [UInt8](hex: "23807a7cac8e98ac43b4f329dabb9e56a748dc27610604b5509f2da1bec894fd")!

    @Test("Estado nas duas fontes e plano de 2 ADA montado")
    func spendStateAndPlan() async throws {
        let state = try await CardanoReader().spendState(owner: Self.owner)
        #expect(!state.utxos.isEmpty)
        #expect(state.parameters.minFeeA > 0 && state.parameters.coinsPerUTxOByte > 0)
        let plan = try CardanoPlanner.planSend(
            walletID: UUID(),
            source: CardanoSource(path: DerivationPath("m/1852'/1815'/0'/0/0")!, publicKey: Self.ownerKey, address: Self.owner),
            to: "addr1q94zzrtl32tjp8j96auatnhxd2y35fnk6wuxqvqm9364vp9spdkjdsmyfhvfagjzh4uzp9zs6p5djw89jac2g0ujs2eqsuy7pu",
            amount: 2_000_000, state: state
        )
        let body = try #require(plan.transactions.first as? CardanoTransfer).body
        #expect(body.fee < 300_000)
        #expect(plan.review.outgoing?.amount == 2_000_000)
    }

    @Test("Saldo, historico e uma transacao confirmada nas duas fontes")
    func readsLive() async throws {
        let reader = CardanoReader()
        let balance = try await reader.displayBalance(owner: Self.owner)
        #expect(balance.holdings.first?.amount ?? 0 > 0)
        let page = try await reader.history(owner: Self.owner, limit: 5)
        #expect(!page.items.isEmpty)
        let status = try await reader.status(of: "d8da3593663c88b2aa46dc27f7bcb8cef20bc86f7e456b43e467674fe6889c3a")
        guard case .confirmed = status else { Issue.record("esperava confirmada: \(status)"); return }
    }
}
