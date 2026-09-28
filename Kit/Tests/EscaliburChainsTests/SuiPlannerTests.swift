import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

@Suite("Sui endereco e planejador")
struct SuiPlannerTests {
    // A chave do sign_direct_transfer do wallet-core (SuiTransactionTests).
    static let ownerKey = try! SuiTransactionTests.publicKey("3823dce5288ab55dd1c00d97e91933c613417fdb282a0b8b01a7f5f5a533b266")
    static let owner = SuiOwner(path: DerivationPath("m/44'/784'/0'/0'/0'")!, publicKey: ownerKey)
    static let sender = try! SuiAddress(ed25519PublicKey: ownerKey)
    static let destination = "0x259ff8074ab425cbb489f236e18e08f03f1a7856bdf7c7a2877bd64f738b5015"
    /// Custo medido numa simulacao real de 27/09/2026 (tres moedas, preco 100).
    static let estimate = SuiGasCost(computationCost: 100_000, storageCost: 1_976_000, storageRebate: 978_120)

    static func coin(_ byte: UInt8, _ balance: UInt64, version: UInt64 = 7) -> SuiCoin {
        let id = SuiAddress(bytes: [UInt8](repeating: 0, count: 31) + [byte])!
        return SuiCoin(ref: try! SuiObjectRef(objectID: id, version: version, digest: [UInt8](repeating: byte, count: 32)), balance: balance)
    }

    static let state = SuiAccountState(
        coins: [coin(1, 1_000_000_000), coin(2, 3_000_000_000), coin(3, 500_000)], referenceGasPrice: 100, epoch: 1_263
    )

    static func plan(
        to destination: String = destination, amount: BigUInt = 1_500_000_000, state: SuiAccountState = state,
        estimate: SuiGasCost = estimate, owner: SuiOwner = owner
    ) throws -> SigningPlan {
        try SuiPlanner.planSend(walletID: UUID(), owner: owner, to: destination, amount: amount, state: state, estimate: estimate)
    }

    // MARK: Endereco

    @Test("Endereco: 0x e 64 hex, minusculas; forma curta, sem prefixo e EVM recusados")
    func addressValidation() {
        let upper = "0x259FF8074AB425CBB489F236E18E08F03F1A7856BDF7C7A2877BD64F738B5015"
        #expect(Address.validate(upper, for: .sui) == .success(.init(address: Self.destination, tag: nil)))
        #expect(Address.validate("0x2", for: .sui) == .failure(.malformed))
        #expect(Address.validate(String(Self.destination.dropFirst(2)), for: .sui) == .failure(.malformed))
        #expect(Address.validate(Self.destination + "0", for: .sui) == .failure(.malformed))
        #expect(Address.validate("0xZ59ff8074ab425cbb489f236e18e08f03f1a7856bdf7c7a2877bd64f738b5015", for: .sui) == .failure(.malformed))
        // wallet-core, sui_address.rs: endereco de 20 bytes nao vale na Sui; e da Ethereum.
        #expect(Address.validate("0xb1dc06bd64d4e179a482b97bb68243f6c02c1b92", for: .sui) == .failure(.otherNetwork(.ethereum)))
        #expect(Address.validate("HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk", for: .sui) == .failure(.otherNetwork(.solana)))
        // O formato e o mesmo da Aptos: nenhum palpite de rede para ele.
        #expect(Address.guessChain(Self.destination) == nil)
        #expect(Address.validate(Self.destination, for: .ethereum) == .failure(.malformed))
        #expect(Address.sameRecipient(upper, Self.destination, chain: .sui))
        #expect(AddressPoisoning.body(Self.destination, chain: .sui) == String(Self.destination.dropFirst(2)))
        #expect(SuiAddress.parse("0x" + String(repeating: "0", count: 62) + "02").map(\.isSystem) == .success(true))
    }

    // MARK: Plano

    @Test("Envio: transacao do SplitCoins na moeda de gas, orcamento, validade e revisao")
    func planSend() throws {
        let plan = try Self.plan()
        let transfer = try #require(plan.transactions.first as? SuiTransfer)
        let data = transfer.data
        // Orcamento: (100.000 + 1.976.000) * 1,2.
        #expect(data.gas.budget == 2_491_200)
        #expect(data.gas.price == 100)
        #expect(data.gas.owner == Self.sender && data.sender == Self.sender)
        // Todas as moedas como gas, da maior para a menor.
        #expect(data.gas.payment.map(\.objectID) == [Self.coin(2, 0).ref.objectID, Self.coin(1, 0).ref.objectID, Self.coin(3, 0).ref.objectID])
        #expect(data.expiration == .epoch(1_264))
        let expected = SuiTransactionData.payFromGas(
            sender: Self.sender, recipient: try SuiTransactionTests.address(Self.destination), amount: 1_500_000_000,
            gas: data.gas, expiration: .epoch(1_264)
        )
        #expect(data == expected)
        #expect(transfer.signingRequests.first?.payload == data.signingDigest)
        #expect(transfer.signingRequests.first?.path == Self.owner.path)

        let review = plan.review
        #expect(review.kind == .send)
        #expect(review.title == "Enviar 1,5 SUI")
        #expect(review.recipient == Self.destination)
        #expect(review.recipientTag == nil)
        #expect(review.outgoing == PlanReview.Movement(assetID: "sui:native", amount: 1_500_000_000))
        #expect(review.lines.contains(PlanReview.Line("Para", Self.destination, verbatim: true)))
        #expect(review.lines.contains(PlanReview.Line("Taxa máxima", "0,0024912 SUI, o que não for usado volta")))
        #expect(review.lines.contains(PlanReview.Line("Taxa estimada", "0,00109788 SUI")))
        #expect(review.warnings.isEmpty)
        #expect(!review.lines.contains { $0.value.contains("—") || $0.value.contains("–") || $0.label.contains("—") })
        try PlanIntentCheck.send(review, asset: .native(.sui), amount: 1_500_000_000, ceiling: 4_000_500_000, chain: .sui)
        #expect(throws: PlanIntentCheck.Mismatch.wrongAmount) {
            try PlanIntentCheck.send(review, asset: .native(.sui), amount: 1_500_000_001, ceiling: 4_000_500_000, chain: .sui)
        }
    }

    @Test("Maximo e transacao de estimativa: moedas menos o orcamento; 1 MIST com o orcamento que cabe")
    func maximumAndEstimation() throws {
        #expect(try SuiPlanner.maximumSendable(Self.state, estimate: Self.estimate) == BigUInt(4_000_500_000 - 2_491_200))
        let probe = try SuiPlanner.estimationTransaction(owner: Self.owner, to: Self.destination, state: Self.state)
        #expect(SuiPlanner.sendParameters(probe)?.1 == 1)
        #expect(probe.gas.budget == SuiPlanner.budgetCeiling)
        #expect(probe.expiration == .epoch(1_264))
        let small = SuiAccountState(coins: [Self.coin(1, 2_000_000)], referenceGasPrice: 100, epoch: 9)
        #expect(try SuiPlanner.estimationTransaction(owner: Self.owner, to: Self.destination, state: small).gas.budget == 1_999_999)
        // Menos que o orcamento minimo (1.000 unidades ao preco 100) nao simula.
        let dust = SuiAccountState(coins: [Self.coin(1, 90_000)], referenceGasPrice: 100, epoch: 9)
        #expect(throws: SuiPlanError.insufficientBalance(needed: 100_001, available: 90_000)) {
            try SuiPlanner.estimationTransaction(owner: Self.owner, to: Self.destination, state: dust)
        }
        // Orcamento nunca abaixo do minimo do protocolo.
        #expect(try SuiPlanner.budget(for: SuiGasCost(computationCost: 1_000, storageCost: 0, storageRebate: 0), price: 100) == 100_000)
    }

    @Test("Recusas do planejador")
    func refusals() throws {
        #expect(throws: SuiPlanError.zeroAmount) { try Self.plan(amount: 0) }
        #expect(throws: SuiPlanError.destinationIsSelf) { try Self.plan(to: Self.sender.hex) }
        #expect(throws: SuiPlanError.destinationIsSystem) { try Self.plan(to: "0x" + String(repeating: "0", count: 63) + "2") }
        #expect(throws: SuiPlanError.invalidDestination(.otherNetwork(.ethereum))) {
            try Self.plan(to: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        }
        #expect(throws: SuiPlanError.invalidDestination(.malformed)) { try Self.plan(to: "0x2") }
        // Valor mais orcamento acima das moedas.
        #expect(throws: SuiPlanError.insufficientBalance(needed: BigUInt(4_000_000_000 + 2_491_200), available: 4_000_500_000)) {
            try Self.plan(amount: 4_000_000_000)
        }
        #expect(throws: SuiPlanError.amountTooLarge) { try Self.plan(amount: BigUInt(UInt64.max) + 1) }
        #expect(throws: SuiPlanError.noCoins) { try Self.plan(state: SuiAccountState(coins: [], referenceGasPrice: 100, epoch: 1)) }
        #expect(throws: SuiPlanError.duplicateCoin) {
            try Self.plan(state: SuiAccountState(coins: [Self.coin(1, 5_000_000_000), Self.coin(1, 5_000_000_000, version: 8)], referenceGasPrice: 100, epoch: 1))
        }
        for price: UInt64 in [0, 10_001] {
            #expect(throws: SuiPlanError.gasPriceOutOfRange(price)) {
                try Self.plan(state: SuiAccountState(coins: Self.state.coins, referenceGasPrice: price, epoch: 1))
            }
        }
        #expect(throws: SuiPlanError.feeAboveCeiling(budget: 60_000_000, ceiling: SuiPlanner.budgetCeiling)) {
            try Self.plan(estimate: SuiGasCost(computationCost: 25_000_000, storageCost: 25_000_000, storageRebate: 0))
        }
        #expect(throws: SuiPlanError.invalidEstimate) { try Self.plan(estimate: SuiGasCost(computationCost: 0, storageCost: 5, storageRebate: 0)) }
        #expect(throws: SuiPlanError.invalidPath) {
            try Self.plan(owner: SuiOwner(path: DerivationPath("m/44'/784'/0'/0/0")!, publicKey: Self.ownerKey))
        }
        #expect(throws: SuiPlanError.keyMismatch) {
            try Self.plan(owner: SuiOwner(path: Self.owner.path, publicKey: Array(Self.ownerKey.prefix(31))))
        }
    }

    @Test("Taxa acima de 10% do valor avisa")
    func highFee() throws {
        let plan = try Self.plan(amount: 10_000_000)
        #expect(plan.review.warnings.contains { if case .highFee = $0 { return true }; return false })
    }

    // MARK: Simulacao

    static func simulation(recipient: BigUInt = 1_500_000_000, ownerDelta: (Bool, BigUInt)? = nil, success: Bool = true,
                           gas: SuiGasCost = estimate, extra: [SuiBalanceChange] = []) -> SuiSimulation {
        let dest = try! SuiTransactionTests.address(destination)
        // Dono: -(1,5 SUI + 2.076.000 - 978.120).
        let owner = ownerDelta ?? (true, BigUInt(1_500_000_000 + 2_076_000 - 978_120))
        return SuiSimulation(success: success, gas: gas, balanceChanges: [
            SuiBalanceChange(address: dest, coinType: SuiPlanner.suiCoinType, negative: false, magnitude: recipient),
            SuiBalanceChange(address: sender, coinType: SuiPlanner.suiCoinType, negative: owner.0, magnitude: owner.1),
        ] + extra)
    }

    @Test("Simulacao da transacao exata: dois provedores, valor ao destino, valor e gas do dono, nada mais")
    func verifySimulation() throws {
        let plan = try Self.plan()
        try SuiPlanner.verifySimulation(plan, results: [Self.simulation(), Self.simulation()])
        #expect(throws: SuiPlanError.simulationMissing) { try SuiPlanner.verifySimulation(plan, results: [Self.simulation()]) }
        #expect(throws: SuiPlanError.simulationFailed) {
            try SuiPlanner.verifySimulation(plan, results: [Self.simulation(), Self.simulation(success: false)])
        }
        #expect(throws: SuiPlanError.simulationMismatch) {
            try SuiPlanner.verifySimulation(plan, results: [Self.simulation(), Self.simulation(recipient: 1_499_999_999)])
        }
        #expect(throws: SuiPlanError.simulationMismatch) {
            try SuiPlanner.verifySimulation(plan, results: [Self.simulation(ownerDelta: (true, 1_600_000_000)), Self.simulation()])
        }
        let token = SuiBalanceChange(address: Self.sender, coinType: "0x" + String(repeating: "a", count: 64) + "::usdc::USDC", negative: true, magnitude: 5)
        #expect(throws: SuiPlanError.simulationMismatch) {
            try SuiPlanner.verifySimulation(plan, results: [Self.simulation(), Self.simulation(extra: [token])])
        }
        // Gas acima do orcamento assinado.
        let heavy = SuiGasCost(computationCost: 2_000_000, storageCost: 1_000_000, storageRebate: 0)
        #expect(throws: SuiPlanError.simulationMismatch) {
            try SuiPlanner.verifySimulation(plan, results: [Self.simulation(), Self.simulation(ownerDelta: (true, 1_503_000_000), gas: heavy)])
        }
        // Juntar moedas pode devolver mais do que custa: o dono ainda perde o valor.
        let rebate = SuiGasCost(computationCost: 100_000, storageCost: 1_976_000, storageRebate: 2_934_360)
        let small = try Self.plan(amount: 1_000)
        let dest = try SuiTransactionTests.address(Self.destination)
        let gained = SuiSimulation(success: true, gas: rebate, balanceChanges: [
            SuiBalanceChange(address: dest, coinType: SuiPlanner.suiCoinType, negative: false, magnitude: 1_000),
            SuiBalanceChange(address: Self.sender, coinType: SuiPlanner.suiCoinType, negative: false, magnitude: 857_360),
        ])
        try SuiPlanner.verifySimulation(small, results: [gained, gained])
    }
}
