import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra os nos reais, so com ESCALIBUR_REDE=1. Nada e assinado nem transmitido.
@Suite("Leitor Aptos ao vivo", .enabled(if: Live.enabled), .serialized)
struct AptosReaderLiveTests {
    typealias R = AptosRecorded

    @Test("Os tres provedores sem chave estao na rede principal, cada um sozinho")
    func providersOnMainnet() async throws {
        for provider in Endpoints.aptos {
            let ledger = try await AptosReader(providers: [provider]).ledger(provider)
            Live.note("\(provider.name): versao \(ledger.version)")
            #expect(ledger.chainID == 1 && ledger.version > 7_000_000_000)
        }
    }

    @Test("Estado da conta gravada em dois provedores e a simulacao da estimativa")
    func accountAndSimulation() async throws {
        let reader = AptosReader()
        let destination = R.address(R.recording.existente)
        let state = try await reader.accountState(owner: R.owner, destination: destination)
        Live.note("sequencia \(state.sequenceNumber), saldo \(state.balance), preco \(state.gasUnitPrice), versao \(state.ledgerVersion)")
        #expect(state.chainID == 1 && state.authenticationKey == R.owner.bytes && state.destinationExists)
        let owner = AptosOwner(path: DefaultPaths.path(for: .aptos), publicKey: R.ownerKey)
        let estimation = try AptosPlanner.estimationTransaction(owner: owner, to: destination.hex, state: state, now: Date())
        let gasUsed = try await reader.estimateGasUsed(estimation, publicKey: R.ownerKey)
        Live.note("gas usado \(gasUsed)")
        #expect(gasUsed > 0 && gasUsed < 1_000)
    }

    @Test("Historico pelo indexador da Aptos Labs")
    func history() async throws {
        let page = try await AptosReader().history(owner: R.owner)
        Live.note("\(page.items.count) itens")
        #expect(!page.items.isEmpty)
    }
}
