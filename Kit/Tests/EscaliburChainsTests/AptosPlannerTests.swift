import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// O planejador da Aptos com o estado gravado da rede principal em 28/09/2026
/// (EscaliburNetworkTests/Fixtures/leitores/aptos/gravacao.json): conta 0x966e...6c41, preco
/// 100, gas usado 63 para destino com APT e 5.415 para destino novo.
@Suite("Aptos planejador")
struct AptosPlannerTests {
    static let ownerKey = [UInt8](hex: "466ca5a1cb600f73a5edc1dc36f38d12c4514a9131ee6ec9619504778bf27280")!
    static let path = DerivationPath("m/44'/637'/0'/0'/0'")!
    static let owner = AptosOwner(path: path, publicKey: ownerKey)
    static let sender = try! AptosAddress(ed25519PublicKey: ownerKey)
    static let existing = "0xa816db9fa6e242878969f54c5e8ae5081f01ffc9442c0c055ef62a9b02459cc6"
    static let fresh = "0xe5d350bdd25ec33a5c1acb3a8018d61184d7769cc3c91d7a046f919d35493539"
    static let ledgerTime: UInt64 = 1_790_570_883
    static let now = Date(timeIntervalSince1970: TimeInterval(ledgerTime))

    static func state(
        balance: UInt64 = 3_376_623_591, price: UInt64 = 100, chainID: UInt8 = 1, key: [UInt8]? = nil,
        destinationExists: Bool = true
    ) -> AptosAccountState {
        AptosAccountState(
            sequenceNumber: 1_554_045, authenticationKey: key ?? sender.bytes, balance: balance, gasUnitPrice: price,
            chainID: chainID, ledgerVersion: 7_391_711_772, ledgerTimestamp: ledgerTime, destinationExists: destinationExists
        )
    }

    static func plan(
        to destination: String = existing, amount: BigUInt = 100_000_000, state: AptosAccountState = state(),
        gasUsed: UInt64 = 63, owner: AptosOwner = owner, now: Date = now
    ) throws -> SigningPlan {
        try AptosPlanner.planSend(walletID: UUID(), owner: owner, to: destination, amount: amount, state: state, gasUsed: gasUsed, now: now)
    }

    static func transfer(_ plan: SigningPlan) throws -> AptosTransfer {
        try #require(plan.transactions.first as? AptosTransfer)
    }

    @Test("Envio para conta com APT: transacao, revisao e movimento")
    func planExisting() throws {
        let plan = try Self.plan()
        let raw = try Self.transfer(plan).raw
        #expect(raw.sender == Self.sender && raw.recipient.hex == Self.existing)
        #expect(raw.amount == 100_000_000 && raw.sequenceNumber == 1_554_045 && raw.chainID == 1)
        #expect(raw.maxGasAmount == 200 && raw.gasUnitPrice == 100)
        #expect(raw.expirationTimestampSecs == Self.ledgerTime + 120)
        #expect(plan.review.recipient == Self.existing && plan.review.recipientTag == nil)
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: Asset.native(.aptos).id, amount: 100_000_000))
        #expect(plan.review.title == "Enviar 1 APT")
        #expect(plan.review.lines.contains(PlanReview.Line("Taxa estimada", "0,000063 APT")))
        #expect(plan.review.lines.contains(PlanReview.Line("Taxa máxima", "0,0002 APT, o que não for usado não é cobrado")))
        #expect(!plan.review.lines.contains { $0.label == "Conta de destino" })
        #expect(plan.review.warnings.isEmpty)
        try PlanIntentCheck.send(plan.review, asset: .native(.aptos), amount: 100_000_000, ceiling: 0, chain: .aptos)
    }

    @Test("Destino novo: a revisao diz que o envio cria a conta, e o gas cobre o armazenamento")
    func planFreshDestination() throws {
        let plan = try Self.plan(to: Self.fresh, amount: 1_000_000, state: Self.state(destinationExists: false), gasUsed: 5_415)
        let raw = try Self.transfer(plan).raw
        #expect(raw.maxGasAmount == 6_498)
        #expect(plan.review.lines.contains { $0.label == "Conta de destino" && $0.value.contains("cria a conta") })
        // 0,005415 APT de taxa para 0,01 APT: mais de 10%.
        #expect(plan.review.warnings.contains { if case .highFee = $0 { return true }; return false })
    }

    @Test("Gas maximo, maximo enviavel e transacao de estimativa")
    func gasAndMaximum() throws {
        #expect(try AptosPlanner.maxGas(forGasUsed: 63, price: 100) == 200)
        #expect(try AptosPlanner.maxGas(forGasUsed: 5_415, price: 100) == 6_498)
        #expect(throws: AptosPlanError.invalidEstimate) { try AptosPlanner.maxGas(forGasUsed: 0, price: 100) }
        #expect(throws: AptosPlanError.self) { try AptosPlanner.maxGas(forGasUsed: 17_000, price: 100) }
        #expect(throws: AptosPlanError.self) { try AptosPlanner.maxGas(forGasUsed: 5_415, price: 1_000) }
        #expect(try AptosPlanner.maximumSendable(Self.state(), gasUsed: 63) == BigUInt(3_376_623_591 - 20_000))

        let estimation = try AptosPlanner.estimationTransaction(owner: Self.owner, to: Self.existing, state: Self.state(), now: Self.now)
        #expect(estimation.amount == 1 && estimation.maxGasAmount == 20_000 && estimation.expirationTimestampSecs == Self.ledgerTime + 120)
        let poor = try AptosPlanner.estimationTransaction(owner: Self.owner, to: Self.existing, state: Self.state(balance: 500_001), now: Self.now)
        #expect(poor.maxGasAmount == 5_000)
        #expect(throws: AptosPlanError.self) {
            try AptosPlanner.estimationTransaction(owner: Self.owner, to: Self.existing, state: Self.state(balance: 10_000), now: Self.now)
        }
    }

    @Test("Recusas do planejador")
    func refusals() throws {
        #expect(throws: AptosPlanError.destinationIsSelf) { try Self.plan(to: Self.sender.hex) }
        #expect(throws: AptosPlanError.destinationIsSystem) { try Self.plan(to: "0x1") }
        #expect(throws: AptosPlanError.destinationIsSystem) { try Self.plan(to: "0x" + String(repeating: "0", count: 63) + "a") }
        #expect(throws: AptosPlanError.invalidDestination(.otherNetwork(.ethereum))) {
            try Self.plan(to: "0x52908400098527886E0F7030069857D2E4169EE7")
        }
        #expect(throws: AptosPlanError.invalidDestination(.malformed)) { try Self.plan(to: String(Self.existing.dropFirst(2))) }
        #expect(throws: AptosPlanError.zeroAmount) { try Self.plan(amount: 0) }
        #expect(throws: AptosPlanError.amountTooLarge) { try Self.plan(amount: BigUInt(UInt64.max) + BigUInt(1)) }
        #expect(throws: AptosPlanError.insufficientBalance(needed: BigUInt(3_376_623_591 - 19_999 + 20_000), available: 3_376_623_591)) {
            try Self.plan(amount: BigUInt(3_376_623_591 - 19_999))
        }
        #expect(throws: AptosPlanError.authenticationKeyRotated) { try Self.plan(state: Self.state(key: [UInt8](repeating: 7, count: 32))) }
        #expect(throws: AptosPlanError.wrongNetwork) { try Self.plan(state: Self.state(chainID: 2)) }
        #expect(throws: AptosPlanError.gasPriceOutOfRange(99)) { try Self.plan(state: Self.state(price: 99)) }
        #expect(throws: AptosPlanError.gasPriceOutOfRange(10_001)) { try Self.plan(state: Self.state(price: 10_001)) }
        #expect(throws: AptosPlanError.clockSkew) { try Self.plan(now: Self.now.addingTimeInterval(121)) }
        #expect(throws: AptosPlanError.clockSkew) { try Self.plan(now: Self.now.addingTimeInterval(-121)) }
        #expect(throws: AptosPlanError.invalidEstimate) { try Self.plan(gasUsed: 0) }
        #expect(throws: AptosPlanError.invalidPath) {
            try Self.plan(owner: AptosOwner(path: DerivationPath("m/44'/637'/0'/0/0")!, publicKey: Self.ownerKey))
        }
        #expect(throws: AptosPlanError.keyMismatch) {
            try Self.plan(owner: AptosOwner(path: Self.path, publicKey: [1, 2, 3]))
        }
    }

    // MARK: Simulacao

    static func goodSimulation(_ plan: SigningPlan) throws -> AptosSimulation {
        let transfer = try transfer(plan)
        let raw = transfer.raw
        return AptosSimulation(
            success: true, gasUsed: 63,
            hash: AptosSignedTransaction.hash(of: AptosSignedTransaction.simulationBytes(raw, publicKey: transfer.publicKey)),
            events: [
                .withdraw(store: raw.sender.primaryAPTStore, amount: raw.amount),
                .deposit(store: raw.recipient.primaryAPTStore, amount: raw.amount),
                .fee(totalGasUnits: 63),
            ]
        )
    }

    @Test("Simulacao da transacao exata: so o valor da loja do dono para a do destino, e a taxa")
    func simulationCheck() throws {
        let plan = try Self.plan()
        let good = try Self.goodSimulation(plan)
        try AptosPlanner.verifySimulation(plan, results: [good, good])

        #expect(throws: AptosPlanError.simulationMissing) { try AptosPlanner.verifySimulation(plan, results: [good]) }
        let failed = AptosSimulation(success: false, gasUsed: 63, hash: good.hash, events: good.events)
        #expect(throws: AptosPlanError.simulationFailed) { try AptosPlanner.verifySimulation(plan, results: [good, failed]) }

        let raw = try Self.transfer(plan).raw
        let variants: [AptosSimulation] = [
            AptosSimulation(success: true, gasUsed: 63, hash: "0x" + String(repeating: "1", count: 64), events: good.events),
            AptosSimulation(success: true, gasUsed: 201, hash: good.hash, events: [good.events[0], good.events[1], .fee(totalGasUnits: 201)]),
            AptosSimulation(success: true, gasUsed: 63, hash: good.hash, events: [
                .withdraw(store: raw.sender.primaryAPTStore, amount: raw.amount + 1), good.events[1], good.events[2],
            ]),
            AptosSimulation(success: true, gasUsed: 63, hash: good.hash, events: [
                good.events[0], .deposit(store: Self.sender.primaryAPTStore, amount: raw.amount), good.events[2],
            ]),
            AptosSimulation(success: true, gasUsed: 63, hash: good.hash, events: good.events + [.other("0x1::coin::CoinWithdraw")]),
            AptosSimulation(success: true, gasUsed: 63, hash: good.hash, events: [good.events[0], good.events[1], .fee(totalGasUnits: 62)]),
        ]
        for variant in variants {
            #expect(throws: AptosPlanError.simulationMismatch) { try AptosPlanner.verifySimulation(plan, results: [good, variant]) }
        }
    }
}
