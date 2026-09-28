import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra a Polkadot Asset Hub real, so com ESCALIBUR_REDE=1. Le uma conta com DOT nos
/// quatro provedores, pede a taxa de uma transferencia montada pelo planejador e monta o
/// plano (nunca assina nem transmite: a chave privada nem existe aqui). A chave publica e
/// a da transferencia real dessa conta no bloco 21.172.670.
@Suite("Leitor Polkadot ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct PolkadotReaderLiveTests {
    static let owner = PolkadotRecorded.address(PolkadotRecorded.owner)
    static let ownerKey = [UInt8](hex: "de01f487837eae7557b87b856c1750bc21effbf60042a79cd87cb54b0a11bb3e")!

    @Test("Estado e taxa em dois provedores, e plano de 0,01 DOT montado")
    func stateFeeAndPlan() async throws {
        let reader = PolkadotReader()
        let destination = PolkadotRecorded.address(PolkadotRecorded.empty)
        let reading = try await reader.accountState(owner: Self.owner, destination: destination)
        try PolkadotPlanner.checkRuntime(reading.runtime)
        #expect(reading.sender.nonce > 0)
        let ownerKey = PolkadotOwner(path: DerivationPath("m/44'/354'/0'/0'/0'")!, publicKey: Self.ownerKey)
        let estimation = try PolkadotPlanner.feeEstimationExtrinsic(
            owner: ownerKey, to: destination.ss58, amount: PolkadotRuntime.existentialDeposit, sender: reading.sender,
            checkpoint: reading.checkpoint, runtime: reading.runtime
        )
        let fee = try await reader.fee(for: estimation, at: reading.checkpoint)
        #expect(fee > 0 && fee < PolkadotRuntime.feeCeiling)
        let state = PolkadotChainState(checkpoint: reading.checkpoint, runtime: reading.runtime, sender: reading.sender, destination: reading.destination, fee: fee)
        if PolkadotPlanner.maximumSendable(state) >= PolkadotRuntime.existentialDeposit {
            let plan = try PolkadotPlanner.planSend(walletID: UUID(), owner: ownerKey, to: destination.ss58, amount: PolkadotRuntime.existentialDeposit, state: state)
            #expect(plan.review.recipient == destination.ss58)
        }
    }

    @Test("Saldo da tela e historico do indexador da Nova")
    func balanceAndHistory() async throws {
        let reader = PolkadotReader()
        let balance = try await reader.displayBalance(owner: PolkadotRecorded.owner)
        #expect(balance.chainID == "polkadot")
        let page = try await reader.history(owner: PolkadotRecorded.owner)
        #expect(!page.items.isEmpty)
    }

    @Test("Sidecar da Parity: a transferencia real do bloco 21.172.670 deu certo")
    func sidecar() async throws {
        let reader = PolkadotReader()
        await reader.track(PolkadotRecorded.signedID, birth: PolkadotRecorded.transferBlock - 1, death: PolkadotRecorded.transferBlock + 10)
        #expect(try await reader.status(of: PolkadotRecorded.signedID) == .confirmed(block: PolkadotRecorded.transferBlock, confirmations: nil))
    }
}
