import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// O planejador do envio de DOT: o que ele monta, o que a revisao diz e cada recusa
/// (deposito existencial dos dois lados, prefixo de outra rede, runtime diferente, taxa).
@Suite("Polkadot: planejador de envio")
struct PolkadotPlannerTests {
    static let dot = BigUInt(10_000_000_000)
    static let fee = BigUInt(8_808_355)
    static let checkpoint = PolkadotCheckpoint(
        number: 21_173_079, hash: [UInt8](hex: "dbe81ae3b8fc1fdfad4a503d791799bc594c1fb76aadaf65038406b956ddc524")!
    )
    static let runtime = PolkadotRuntimeState(specName: "statemint", specVersion: 2_005_000, transactionVersion: 15, genesisHash: PolkadotRuntime.genesisHash)
    static let alice = PolkadotAddressTests.alicePolkadot

    static func owner() throws -> PolkadotOwner {
        let seed = SecureBytes(capacity: 32)
        defer { seed.wipe() }
        seed.replaceAll(with: [UInt8](repeating: 0x46, count: 32))
        return PolkadotOwner(path: DefaultPaths.path(for: .polkadot), publicKey: try Ed25519.publicKey(of: seed))
    }

    static func state(
        sender: PolkadotAccountInfo = PolkadotAccountInfo(nonce: 485, free: dot * 10),
        destination: PolkadotAccountInfo = PolkadotAccountInfo(nonce: 0, providers: 1, free: dot),
        runtime: PolkadotRuntimeState = runtime, fee: BigUInt = fee
    ) -> PolkadotChainState {
        PolkadotChainState(checkpoint: checkpoint, runtime: runtime, sender: sender, destination: destination, fee: fee)
    }

    static func plan(_ amount: BigUInt, to destination: String = alice, state: PolkadotChainState = state(), owner: PolkadotOwner? = nil) throws -> SigningPlan {
        try PolkadotPlanner.planSend(walletID: UUID(), owner: owner ?? (try Self.owner()), to: destination, amount: amount, state: state)
    }

    @Test("Envio de 1 DOT: transacao, revisao e movimento conferidos")
    func sendOne() throws {
        let plan = try Self.plan(Self.dot)
        let transfer = try #require(plan.transactions.first as? PolkadotTransfer)
        #expect(plan.transactions.count == 1 && plan.chain == .polkadot)
        #expect(transfer.fields.nonce == 485 && transfer.fields.amount == Self.dot)
        #expect(transfer.fields.blockNumber == Self.checkpoint.number && transfer.fields.blockHash == Self.checkpoint.hash)
        #expect(transfer.fields.era.period == 256 && transfer.fields.specVersion == 2_005_000)
        #expect(transfer.fields.destination.ss58 == Self.alice)
        #expect(transfer.fields.sender.ss58 == "16PpFrXrC6Ko3pYcyMAx6gPMp3mFFaxgyYMt4G5brkgNcSz8")
        #expect(transfer.signingRequests.first?.payload == transfer.fields.payload)

        let review = plan.review
        #expect(review.title == "Enviar 1 DOT")
        #expect(review.recipient == Self.alice && review.recipientTag == nil)
        #expect(review.outgoing == PlanReview.Movement(assetID: Asset.native(.polkadot).id, amount: Self.dot))
        #expect(review.lines.contains(PlanReview.Line("Para", Self.alice, verbatim: true)))
        #expect(review.lines.contains(PlanReview.Line("Taxa estimada", "0,0008808355 DOT")))
        #expect(review.warnings.isEmpty)
        #expect(!review.lines.contains { $0.value.contains("—") || $0.value.contains("–") || $0.label.contains("—") })
        try PlanIntentCheck.send(review, asset: .native(.polkadot), amount: Self.dot, ceiling: Self.dot * 10, chain: .polkadot)
    }

    @Test("Maximo: livre menos o deposito existencial e a taxa com 20% de folga")
    func maximum() throws {
        let state = Self.state()
        let expected = Self.dot * 10 - PolkadotRuntime.existentialDeposit - BigUInt(10_570_026)
        #expect(PolkadotPlanner.feeWithMargin(Self.fee) == BigUInt(10_570_026))
        #expect(PolkadotPlanner.maximumSendable(state) == expected)
        _ = try Self.plan(expected)
        #expect(throws: PolkadotPlanError.insufficientBalance(needed: expected + 1 + BigUInt(10_570_026), available: Self.dot * 10 - PolkadotRuntime.existentialDeposit)) {
            try Self.plan(expected + 1)
        }
        // Tudo o que a conta tem nunca sai: o deposito existencial fica.
        #expect(throws: PolkadotPlanError.self) { try Self.plan(Self.dot * 10) }
    }

    @Test("Saldo congelado alem do reservado fica fora do que pode sair")
    func frozen() {
        let info = PolkadotAccountInfo(nonce: 1, free: Self.dot * 10, reserved: Self.dot * 20, frozen: Self.dot * 25)
        #expect(info.reducible(existentialDeposit: PolkadotRuntime.existentialDeposit) == Self.dot * 5)
        let small = PolkadotAccountInfo(nonce: 1, free: Self.dot, reserved: Self.dot * 20, frozen: Self.dot * 3)
        #expect(small.reducible(existentialDeposit: PolkadotRuntime.existentialDeposit) == Self.dot - PolkadotRuntime.existentialDeposit)
        #expect(PolkadotAccountInfo.empty.reducible(existentialDeposit: PolkadotRuntime.existentialDeposit) == 0)
        #expect(PolkadotPlanner.maximumSendable(Self.state(sender: info)) == Self.dot * 5 - BigUInt(10_570_026))
    }

    @Test("Destino vazio: so com o deposito existencial, e a revisao avisa")
    func existentialDepositForDestination() throws {
        let ed = PolkadotRuntime.existentialDeposit
        let empty = Self.state(destination: .empty)
        #expect(throws: PolkadotPlanError.belowExistentialDeposit(minimum: ed)) { try Self.plan(ed - 1, state: empty) }
        let plan = try Self.plan(ed, state: empty)
        #expect(plan.review.warnings.contains(.activatesAccount(minimum: "0,01 DOT")))
        #expect(plan.review.lines.contains { $0.label == "Destino" })
        // O que conta e o livre do destino depois do envio.
        let half = ed / 2
        let dusty = Self.state(destination: PolkadotAccountInfo(nonce: 0, free: 0, reserved: Self.dot))
        #expect(throws: PolkadotPlanError.belowExistentialDeposit(minimum: ed)) { try Self.plan(half, state: dusty) }
        _ = try Self.plan(half, state: Self.state(destination: PolkadotAccountInfo(nonce: 0, free: half)))
    }

    @Test("Destino: outra rede, a propria conta, valor zero")
    func destinationRefusals() throws {
        #expect(throws: PolkadotPlanError.invalidDestination(.malformed)) { try Self.plan(Self.dot, to: PolkadotAddressTests.aliceKusama) }
        #expect(throws: PolkadotPlanError.invalidDestination(.malformed)) { try Self.plan(Self.dot, to: PolkadotAddressTests.aliceGeneric) }
        #expect(throws: PolkadotPlanError.invalidDestination(.otherNetwork(.bitcoin))) { try Self.plan(Self.dot, to: "1ES14c7qLb5CYhLMUekctxLgc1FV2Ti9DA") }
        #expect(throws: PolkadotPlanError.destinationIsSelf) { try Self.plan(Self.dot, to: "16PpFrXrC6Ko3pYcyMAx6gPMp3mFFaxgyYMt4G5brkgNcSz8") }
        #expect(throws: PolkadotPlanError.zeroAmount) { try Self.plan(0) }
    }

    @Test("Runtime: outra rede e outra versao de transacao sao recusadas")
    func runtimeRefusals() {
        let relay = PolkadotRuntimeState(specName: "polkadot", specVersion: 2_005_000, transactionVersion: 26, genesisHash: PolkadotRuntime.genesisHash)
        #expect(throws: PolkadotPlanError.wrongNetwork) { try Self.plan(Self.dot, state: Self.state(runtime: relay)) }
        let kusama = PolkadotRuntimeState(
            specName: "statemint", specVersion: 2_005_000, transactionVersion: 15,
            genesisHash: [UInt8](hex: "48239ef607d7928874027a43a67689209727dfb3d3dc5e5b03a39bdc2eda771a")!
        )
        #expect(throws: PolkadotPlanError.wrongNetwork) { try Self.plan(Self.dot, state: Self.state(runtime: kusama)) }
        let upgraded = PolkadotRuntimeState(specName: "statemint", specVersion: 2_006_000, transactionVersion: 16, genesisHash: PolkadotRuntime.genesisHash)
        #expect(throws: PolkadotPlanError.runtimeChanged(transactionVersion: 16)) { try Self.plan(Self.dot, state: Self.state(runtime: upgraded)) }
        // So a spec subindo, com a mesma codificacao: segue.
        let spec = PolkadotRuntimeState(specName: "statemint", specVersion: 2_006_000, transactionVersion: 15, genesisHash: PolkadotRuntime.genesisHash)
        #expect((try? Self.plan(Self.dot, state: Self.state(runtime: spec))) != nil)
    }

    @Test("Taxa ausente ou acima do teto, e taxa alta avisada")
    func fees() throws {
        #expect(throws: PolkadotPlanError.missingFee) { try Self.plan(Self.dot, state: Self.state(fee: 0)) }
        let high = PolkadotRuntime.feeCeiling + 1
        #expect(throws: PolkadotPlanError.feeAboveCeiling(fee: high, ceiling: PolkadotRuntime.feeCeiling)) {
            try Self.plan(Self.dot, state: Self.state(fee: high))
        }
        let plan = try Self.plan(BigUInt(50_000_000))
        #expect(plan.review.warnings.contains { if case .highFee = $0 { return true } else { return false } })
    }

    @Test("Chave e caminho: nao endurecido e chave de outro tamanho sao recusados")
    func keyAndPath() throws {
        let owner = try Self.owner()
        let loose = PolkadotOwner(path: DerivationPath("m/44'/354'/0'/0/0")!, publicKey: owner.publicKey)
        #expect(throws: PolkadotPlanError.invalidPath) { try Self.plan(Self.dot, owner: loose) }
        let short = PolkadotOwner(path: owner.path, publicKey: Array(owner.publicKey.dropLast()))
        #expect(throws: PolkadotPlanError.keyMismatch) { try Self.plan(Self.dot, owner: short) }
    }

    @Test("A transacao da estimativa tem o formato e o tamanho maximo do envio")
    func estimation() throws {
        let state = Self.state()
        let raw = try PolkadotPlanner.feeEstimationExtrinsic(
            owner: try Self.owner(), to: Self.alice, amount: Self.dot, sender: state.sender, checkpoint: Self.checkpoint, runtime: Self.runtime
        )
        let decoded = try PolkadotSignedExtrinsic.decode(raw)
        #expect(decoded.signature == [UInt8](repeating: 0, count: 64))
        #expect(decoded.amount == Self.dot * 10 && decoded.nonce == 485 && decoded.destination.ss58 == Self.alice)
        let plan = try Self.plan(Self.dot)
        let transfer = try #require(plan.transactions.first as? PolkadotTransfer)
        #expect(transfer.fields.extrinsic(signature: [UInt8](repeating: 0, count: 64)).count <= raw.count)
    }

    @Test("System.Account gravado da rede: 80 bytes, e outro tamanho recusado")
    func accountInfo() throws {
        // state_getStorage de 1626DFYA... no bloco 21.173.079 (Fixtures/leitores/polkadot).
        let raw = [UInt8](hex: "e50100000200000001000000000000008dd3f46b02000000000000000000000080ea5da92e00000000000000000000000000000000000000000000000000000000000000000000000000000000000080")!
        let info = try PolkadotAccountInfo.decode(raw)
        #expect(info.nonce == 485 && info.consumers == 2 && info.providers == 1 && info.sufficients == 0)
        #expect(info.free == BigUInt(10_401_141_645) && info.reserved == BigUInt(200_410_000_000) && info.frozen == 0)
        #expect(throws: PolkadotSCALE.Failure.nonCanonical) { try PolkadotAccountInfo.decode(Array(raw.dropLast())) }
    }
}
