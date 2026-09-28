import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// O planejador do envio de NEAR: o que ele monta, a conta da taxa contra transferencias
/// reais, o que a revisao diz e cada recusa.
@Suite("NEAR: planejador de envio")
struct NEARPlannerTests {
    static let near = NEARRules.oneNEAR
    static let checkpoint = NEARCheckpoint(height: 217_581_805, hash: Base58.bitcoin.decode("B8bnYvsCzJmnrQdEMWuMAN1m6VRtVChFie1fTAxm2b8S")!)
    static let named = "madturk.near"
    static let implicitDestination = "b8d5df25047841365008f30fb6b30dd820e9a84d869f05623d114e96831f2fbf"

    /// As regras da rede principal no bloco 217.581.805 (protocolo 86), gravadas em
    /// EscaliburNetworkTests/Fixtures/leitores/near/protocol_config.json.
    static let rules = NEARProtocolRules(
        chainID: "mainnet", gasPrice: 100_000_000, minGasPurchasePrice: 1_000_000_000,
        accountCreationCharge: BigUInt(7) * BigUInt.power(of: 10, 21), storageAmountPerByte: BigUInt.power(of: 10, 19),
        actionReceipt: NEARActionFee(sendNotSir: 108_059_500_000, execution: 108_059_500_000),
        transfer: NEARActionFee(sendNotSir: 115_123_062_500, execution: 115_123_062_500),
        createAccount: NEARActionFee(sendNotSir: 500_000_000_000, execution: 7_200_000_000_000),
        addFullAccessKey: NEARActionFee(sendNotSir: 101_765_125_000, execution: 101_765_125_000)
    )

    static func owner() throws -> NEAROwner {
        let seed = SecureBytes(capacity: 32)
        defer { seed.wipe() }
        seed.replaceAll(with: [UInt8](repeating: 0x46, count: 32))
        return NEAROwner(path: DefaultPaths.path(for: .near), publicKey: try Ed25519.publicKey(of: seed))
    }

    static func state(
        sender: NEARAccountState = NEARAccountState(amount: near * 10, storageUsage: 182),
        accessKey: NEARAccessKeyState = NEARAccessKeyState(nonce: 217_540_425_000_008, fullAccess: true),
        destination: NEARAccountState? = NEARAccountState(amount: near, storageUsage: 182),
        rules: NEARProtocolRules = rules, checkpoint: NEARCheckpoint = checkpoint
    ) -> NEARChainState {
        NEARChainState(checkpoint: checkpoint, sender: sender, accessKey: accessKey, destination: destination, rules: rules)
    }

    static func plan(_ amount: BigUInt, to destination: String = named, state: NEARChainState = state(), owner: NEAROwner? = nil) throws -> SigningPlan {
        try NEARPlanner.planSend(walletID: UUID(), owner: owner ?? (try Self.owner()), to: destination, amount: amount, state: state)
    }

    static func account(_ text: String) -> NEARAccountID {
        guard case .success(let account) = NEARAccountID.parse(text) else { fatalError("conta do teste") }
        return account
    }

    @Test("Envio de 1 NEAR: transacao, revisao e movimento conferidos")
    func sendOne() throws {
        let owner = try Self.owner()
        let plan = try Self.plan(Self.near)
        let transfer = try #require(plan.transactions.first as? NEARTransfer)
        #expect(plan.transactions.count == 1 && plan.chain == .near)
        #expect(transfer.fields.nonce == 217_540_425_000_009 && transfer.fields.deposit == Self.near)
        #expect(transfer.fields.blockHash == Self.checkpoint.hash)
        #expect(transfer.fields.receiver.text == Self.named)
        #expect(transfer.fields.signer.text == Hex.encode(owner.publicKey) && transfer.fields.publicKey == owner.publicKey)
        #expect(transfer.signingRequests.first?.payload == (try transfer.fields.hash()))

        let review = plan.review
        #expect(review.title == "Enviar 1 NEAR")
        #expect(review.recipient == Self.named && review.recipientTag == nil)
        #expect(review.outgoing == PlanReview.Movement(assetID: Asset.native(.near).id, amount: Self.near))
        #expect(review.lines.contains(PlanReview.Line("Para", Self.named, verbatim: true)))
        #expect(review.lines.contains(PlanReview.Line("Taxa estimada", "0,0000446365125 NEAR")))
        #expect(review.lines.contains { $0.label == "Reservado para a taxa" && $0.value.hasPrefix("0,00024996447 NEAR. ") })
        #expect(review.warnings.isEmpty)
        #expect(!review.lines.contains { $0.value.contains("—") || $0.value.contains("–") || $0.label.contains("—") })
        try PlanIntentCheck.send(review, asset: .native(.near), amount: Self.near, ceiling: Self.near * 10, chain: .near)
    }

    @Test("A taxa esperada e a que a rede cobrou em transferencias reais")
    func costMatchesRealTransfers() {
        // 8VhtMYxX... para neartokenbot.near: 22318256250000000000 na conversao e o mesmo
        // no recibo.
        let named = NEARTransferCost.transfer(to: Self.account("neartokenbot.near"), destinationExists: true, rules: Self.rules)
        #expect(named.burntGas == 223_182_562_500 && named.receiptGas == 223_182_562_500)
        #expect(named.expected == BigUInt(decimal: "44636512500000000000")!)
        // Reserva: a conversao a 1,2x o preco e o recibo comprado a 1 Ggas de yocto.
        #expect(named.reserved == BigUInt(decimal: "249964470000000000000")!)
        #expect(!named.createsAccount)

        // HRVqJKLb... para uma conta implicita nova: 82494768750000000000 na conversao e
        // 7032494768750000000000 no recibo, com a cobranca de 0,007 NEAR pela conta.
        let created = NEARTransferCost.transfer(to: Self.account(Self.implicitDestination), destinationExists: false, rules: Self.rules)
        #expect(created.burntGas == 824_947_687_500 && created.receiptGas == 7_524_947_687_500)
        #expect(created.expected == BigUInt(decimal: "7114989537500000000000")!)
        #expect(created.createsAccount && created.reserved >= created.expected)

        // Implicita que ja existe: a mesma taxa de gas, sem a cobranca.
        let existing = NEARTransferCost.transfer(to: Self.account(Self.implicitDestination), destinationExists: true, rules: Self.rules)
        #expect(existing.expected == BigUInt(decimal: "834989537500000000000")! && !existing.createsAccount)
    }

    @Test("Conta implicita nova: a revisao diz que o envio cria a conta")
    func newImplicit() throws {
        let plan = try Self.plan(Self.near / BigUInt(1000), to: Self.implicitDestination, state: Self.state(destination: nil))
        #expect(plan.review.lines.contains { $0.label == "Destino" && $0.value.contains("cria") })
        #expect(plan.review.lines.contains(PlanReview.Line("Taxa estimada", "0,0071149895375 NEAR")))
        // 0,001 NEAR com taxa de 0,007: taxa acima de 10% do valor.
        #expect(plan.review.warnings.contains { if case .highFee = $0 { return true } else { return false } })
    }

    @Test("Maximo: o saldo menos a reserva da taxa; acima de 770 bytes, menos o armazenamento")
    func maximum() throws {
        let state = Self.state()
        let max = NEARPlanner.maximumSendable(to: Self.account(Self.named), state: state)
        #expect(max == Self.near * 10 - BigUInt(decimal: "249964470000000000000")!)
        _ = try Self.plan(max, state: state)
        #expect(throws: NEARPlanError.insufficientBalance(needed: max + 1 + BigUInt(decimal: "249964470000000000000")!, available: Self.near * 10)) {
            try Self.plan(max + 1, state: state)
        }

        // 1.000 bytes prendem 0,01 NEAR; o que esta em stake paga primeiro.
        let heavy = Self.state(sender: NEARAccountState(amount: Self.near, storageUsage: 1_000))
        let storage = BigUInt(1_000) * BigUInt.power(of: 10, 19)
        #expect(NEARPlanner.maximumSendable(to: Self.account(Self.named), state: heavy) == Self.near - storage - BigUInt(decimal: "249964470000000000000")!)
        let staked = Self.state(sender: NEARAccountState(amount: Self.near, locked: Self.near, storageUsage: 1_000))
        #expect(NEARPlanner.maximumSendable(to: Self.account(Self.named), state: staked) == Self.near - BigUInt(decimal: "249964470000000000000")!)
    }

    @Test("Recusas: destino, conta com nome inexistente, chave, nonce, rede, taxa e valor")
    func refusals() throws {
        let owner = try Self.owner()
        #expect(throws: NEARPlanError.invalidDestination(.otherNetwork(.ethereum))) { try Self.plan(Self.near, to: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94") }
        #expect(throws: NEARPlanError.invalidDestination(.malformed)) { try Self.plan(Self.near, to: "Alice.near") }
        #expect(throws: NEARPlanError.invalidDestination(.unsupportedType)) { try Self.plan(Self.near, to: "0s9858effd232b4033e47d90003d41ec34ecaeda94") }
        #expect(throws: NEARPlanError.destinationIsSelf) { try Self.plan(Self.near, to: Hex.encode(owner.publicKey)) }
        #expect(throws: NEARPlanError.destinationMissing) { try Self.plan(Self.near, state: Self.state(destination: nil)) }
        #expect(throws: NEARPlanError.zeroAmount) { try Self.plan(0) }
        #expect(throws: NEARPlanError.keyNotFullAccess) {
            try Self.plan(Self.near, state: Self.state(accessKey: NEARAccessKeyState(nonce: 5, fullAccess: false)))
        }
        // Chave criada no proprio bloco de referencia: o nonce seguinte passa do limite.
        #expect(throws: NEARPlanError.nonceNotReady) {
            try Self.plan(Self.near, state: Self.state(accessKey: NEARAccessKeyState(nonce: 217_581_805 * 1_000_000, fullAccess: true)))
        }
        let testnet = NEARProtocolRules(
            chainID: "testnet", gasPrice: Self.rules.gasPrice, minGasPurchasePrice: Self.rules.minGasPurchasePrice,
            accountCreationCharge: Self.rules.accountCreationCharge, storageAmountPerByte: Self.rules.storageAmountPerByte,
            actionReceipt: Self.rules.actionReceipt, transfer: Self.rules.transfer, createAccount: Self.rules.createAccount,
            addFullAccessKey: Self.rules.addFullAccessKey
        )
        #expect(throws: NEARPlanError.wrongNetwork) { try Self.plan(Self.near, state: Self.state(rules: testnet)) }
        #expect(throws: NEARPlanError.wrongNetwork) {
            try Self.plan(Self.near, state: Self.state(checkpoint: NEARCheckpoint(height: 1, hash: [1, 2, 3])))
        }
        let expensive = NEARProtocolRules(
            chainID: "mainnet", gasPrice: BigUInt.power(of: 10, 13), minGasPurchasePrice: Self.rules.minGasPurchasePrice,
            accountCreationCharge: Self.rules.accountCreationCharge, storageAmountPerByte: Self.rules.storageAmountPerByte,
            actionReceipt: Self.rules.actionReceipt, transfer: Self.rules.transfer, createAccount: Self.rules.createAccount,
            addFullAccessKey: Self.rules.addFullAccessKey
        )
        #expect(throws: NEARPlanError.self) { try Self.plan(Self.near, state: Self.state(rules: expensive)) }
        #expect(throws: NEARPlanError.amountTooLarge) { try Self.plan(BigUInt.power(of: 2, 128)) }
        #expect(throws: NEARPlanError.invalidPath) {
            try Self.plan(Self.near, owner: NEAROwner(path: DerivationPath("m/44'/397'/0")!, publicKey: owner.publicKey))
        }
        #expect(throws: NEARPlanError.keyMismatch) {
            try Self.plan(Self.near, owner: NEAROwner(path: DefaultPaths.path(for: .near), publicKey: [1, 2, 3]))
        }
    }

    @Test("Destino com contrato ganha o aviso")
    func contractDestination() throws {
        let contract = NEARAccountState(amount: Self.near, storageUsage: 200_000, codeHash: [UInt8](repeating: 9, count: 32))
        let plan = try Self.plan(Self.near, state: Self.state(destination: contract))
        #expect(plan.review.warnings.contains(.destinationIsContract))
        let global = NEARAccountState(amount: Self.near, storageUsage: 300, globalContract: true)
        #expect(try Self.plan(Self.near, state: Self.state(destination: global)).review.warnings.contains(.destinationIsContract))
    }
}
