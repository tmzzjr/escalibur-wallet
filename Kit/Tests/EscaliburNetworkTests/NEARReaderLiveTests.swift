import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra a rede principal da NEAR, so com ESCALIBUR_REDE=1: o estado da conta das
/// respostas gravadas em dois provedores concordando, cada provedor da lista respondendo
/// da rede principal, o plano montado (nunca assinado nem transmitido: a chave privada
/// nem existe aqui), o saldo da tela e o historico.
@Suite("Leitor NEAR ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct NEARReaderLiveTests {
    typealias R = NEARRecorded

    @Test("Estado em dois provedores e plano de 0,001 NEAR montado")
    func stateAndPlan() async throws {
        let reader = NEARReader()
        let reading = try await reader.state(owner: R.account(R.owner), publicKey: R.ownerKey, destination: R.account(R.destination))
        #expect(reading.checkpoint.height > R.checkpointHeight)
        #expect(reading.rules.chainID == NEARRules.chainID && !reading.rules.gasPrice.isZero)
        let sender = try #require(reading.sender)
        let key = try #require(reading.accessKey)
        #expect(key.fullAccess && key.nonce >= 217_540_425_000_008)
        #expect(reading.destination != nil)
        Live.note("NEAR: bloco \(reading.checkpoint.height), saldo \(sender.amount), nonce \(key.nonce), gas \(reading.rules.gasPrice)")
        let state = NEARChainState(checkpoint: reading.checkpoint, sender: sender, accessKey: key, destination: reading.destination, rules: reading.rules)
        let amount = NEARRules.oneNEAR / BigUInt(1000)
        guard NEARPlanner.maximumSendable(to: R.account(R.destination), state: state) >= amount else { return }
        let plan = try NEARPlanner.planSend(
            walletID: UUID(), owner: NEAROwner(path: DerivationPath("m/44'/397'/0'")!, publicKey: R.ownerKey),
            to: R.destination, amount: amount, state: state
        )
        let transfer = try #require(plan.transactions.first as? NEARTransfer)
        #expect(transfer.fields.nonce == key.nonce + 1 && transfer.fields.blockHash == reading.checkpoint.hash)
    }

    @Test("Cada provedor da lista responde da rede principal, no mesmo bloco")
    func everyProvider() async throws {
        let reference = try await NEARReader().checkpoint()
        for provider in Endpoints.near {
            let reader = NEARReader(providers: [provider, provider])
            let answer = try await reader.destination(R.account(R.destination))
            #expect(answer != nil, "\(provider.name)")
            let header = try NEARReader.header(try await reader.call(provider, "block", .object(["block_id": .int(reference.height)])))
            #expect(header.hash == reference.hash, "\(provider.name)")
        }
    }

    @Test("Conta com nome que nao existe, saldo da tela e historico")
    func missingBalanceHistory() async throws {
        let reader = NEARReader()
        #expect(try await reader.destination(R.account(R.missing)) == nil)
        let balance = try await reader.displayBalance(owner: R.owner)
        #expect(balance.accountExists)
        let page = try await reader.history(owner: R.owner)
        #expect(!page.items.isEmpty && page.items.count <= NEARReader.historyDetails * 2)
    }
}
