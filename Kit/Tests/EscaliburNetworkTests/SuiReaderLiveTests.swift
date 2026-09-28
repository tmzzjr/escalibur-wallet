import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra os nos reais, so com ESCALIBUR_REDE=1. Nada e assinado nem transmitido.
@Suite("Leitor Sui ao vivo", .enabled(if: Live.enabled), .serialized)
struct SuiReaderLiveTests {
    @Test("Os tres provedores sem chave estao na rede principal, cada um sozinho")
    func providersOnMainnet() async throws {
        for provider in Endpoints.sui {
            let reader = SuiReader(providers: [provider])
            let epoch = try await reader.currentEpochFromSingle()
            Live.note("\(provider.name): epoca \(epoch)")
            #expect(epoch > 1_000)
        }
    }

    @Test("Estado da Binance 1 em dois provedores concordando, e a simulacao do envio")
    func accountAndSimulation() async throws {
        let reader = SuiReader()
        let state = try await reader.accountState(owner: SuiRecorded.owner)
        Live.note("moedas \(state.coins.count), preco \(state.referenceGasPrice), epoca \(state.epoch)")
        #expect(!state.coins.isEmpty)
        #expect(state.referenceGasPrice > 0 && state.referenceGasPrice <= SuiPlanner.gasPriceCeiling)
        let owner = SuiOwner(path: DerivationPath("m/44'/784'/0'/0'/0'")!, publicKey: SuiRecorded.ownerKey)
        let probe = try SuiPlanner.estimationTransaction(owner: owner, to: SuiRecorded.destination, state: state)
        let estimate = try await reader.estimateGas(probe)
        Live.note("gas \(estimate.computationCost) + \(estimate.storageCost) - \(estimate.storageRebate)")
        #expect(try SuiPlanner.budget(for: estimate, price: state.referenceGasPrice) <= SuiPlanner.budgetCeiling)
    }

    @Test("Saldo da tela e historico pelo GraphQL")
    func balanceAndHistory() async throws {
        let reader = SuiReader()
        let balance = try await reader.displayBalance(owner: SuiRecorded.owner.hex)
        #expect(balance.holdings.first?.amount.isZero == false)
        let page = try await reader.history(owner: SuiRecorded.owner)
        Live.note("historico: \(page.items.count) itens, completo \(page.isComplete)")
        #expect(page.isComplete)
        #expect(!page.items.isEmpty)
    }
}

extension SuiReader {
    /// A epoca lida de um provedor so (o `currentEpoch` exige dois).
    func currentEpochFromSingle() async throws -> UInt64 {
        guard let provider = providers.first else { throw ReaderError.notEnoughProviders(needed: 1, got: 0) }
        try await ensureMainnet(provider)
        return try await epochReading(provider).epoch
    }
}
