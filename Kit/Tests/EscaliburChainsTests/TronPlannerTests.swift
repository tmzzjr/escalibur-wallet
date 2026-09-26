import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// Planejamento de TRX e USDT: regras de custo, recusas e assinatura de ponta a ponta.
///
/// Numeros de referencia, todos da mainnet em 25/09/2026 (Fixtures/tron):
/// - Parametros de `getchainparameters`: getEnergyFee 100, getTransactionFee 1.000,
///   getCreateNewAccountFeeInSystemContract 1.000.000, getCreateAccountFee 100.000,
///   getMemoFee 1.000.000.
/// - Recibos: TRX consome 265 de bandwidth; USDT 345 (365 com memo de 18 bytes); USDT
///   para quem nao tem USDT consome 130.285 de energy (13,0285 TRX queimados).
/// - Bloco 86.571.746 (000000000528fae2...), base do TaPoS dos planos.
@Suite("Tron: planejamento")
struct TronPlannerTests {
    static let walletID = UUID(uuidString: "00000000-0000-0000-0000-000000000195")!
    static let destination = "TU6UKxqHCG743kdKURsXK37ZhvND9SBgTv"
    static let now = Date(timeIntervalSince1970: 1_790_387_633.5)

    static let parameters = TronChainParameters(
        energyPrice: 100, bandwidthPrice: 1_000, createAccountFee: 1_000_000,
        createAccountBandwidthFee: 100_000, memoFee: 1_000_000
    )

    /// Chave privada 1: a chave de teste classica. O endereco Ethereum dela e
    /// 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf; na Tron, o mesmo com 0x41.
    static func testKey() -> SecureBytes {
        let key = SecureBytes(capacity: 32)
        key.replaceAll(with: [UInt8](repeating: 0, count: 31) + [1])
        return key
    }

    static func owner() throws -> TronOwner {
        try TronOwner(path: DefaultPaths.path(for: .tron), publicKey: Secp256k1.publicKey(of: testKey()))
    }

    static func block() throws -> TronBlockReference {
        try TronBlockReference(
            number: 86_571_746, idHex: "000000000528fae24243cce895cda63da5325f0c07a646f939af56fd201cac99",
            timestamp: 1_790_387_631_000
        )
    }

    static func soleControl(_ owner: TronOwner) throws -> TronAccountControl {
        try TronPermissions.check(getAccountJSON: Data(#"{"address":"\#(owner.address.hex)"}"#.utf8), derived: owner.address)
    }

    static func state(
        trx: BigUInt = 50_000_000, usdt: BigUInt = 0,
        resources: TronAccountResources = TronAccountResources(freeBandwidth: 600, stakedBandwidth: 0, energy: 0),
        parameters: TronChainParameters = parameters,
        destinationActivated: Bool = true, destinationIsContract: Bool = false,
        energy: UInt64? = nil, holdsUSDT: Bool? = nil, control: TronAccountControl? = nil
    ) throws -> TronNetworkState {
        let owner = try owner()
        return TronNetworkState(
            block: try block(), trxBalance: trx, usdtBalance: usdt, resources: resources, parameters: parameters,
            destinationActivated: destinationActivated, destinationIsContract: destinationIsContract,
            usdtEnergyEstimate: energy, destinationHoldsUSDT: holdsUSDT, ownerControl: try control ?? soleControl(owner)
        )
    }

    static func tron(_ plan: SigningPlan) throws -> TronTransaction {
        #expect(plan.transactions.count == 1)
        return try #require(plan.transactions.first as? TronTransaction)
    }

    static func line(_ plan: SigningPlan, _ label: String) -> String? {
        plan.review.lines.first { $0.label == label }?.value
    }

    static func sendTRX(_ amount: BigUInt, to: String = destination, memo: String? = nil, state: TronNetworkState) throws -> SigningPlan {
        try TronPlanner.planSendTRX(walletID: walletID, owner: owner(), to: to, amount: amount, memo: memo, state: state, now: now)
    }

    static func sendUSDT(_ amount: BigUInt, to: String = destination, memo: String? = nil, state: TronNetworkState) throws -> SigningPlan {
        try TronPlanner.planSendUSDT(walletID: walletID, owner: owner(), to: to, amount: amount, memo: memo, state: state, now: now)
    }

    // MARK: Chave de teste

    @Test("Chave privada 1 -> TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC (0x7E5F4552... com 0x41)")
    func testKeyAddress() throws {
        let owner = try Self.owner()
        #expect(Hex.encode(owner.address.account20) == "7e5f4552091a69125d5dfcb7b8c2659029395bdf")
        #expect(owner.address.base58 == "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC")
        #expect(owner.address.base58 == (try Address.from(publicKey: owner.publicKey, chain: .tron)))
    }

    // MARK: TRX

    @Test("TRX para conta ativa, cota gratis cobre: custo zero, TaPoS e expiracao de 60 s")
    func trxToActiveAccount() throws {
        let plan = try Self.sendTRX(12_500_000, state: Self.state())
        let tx = try Self.tron(plan)
        #expect(plan.chain == .tron)
        #expect(plan.walletID == Self.walletID)
        #expect(plan.review.kind == .send)
        #expect(plan.review.title == "Enviar 12,5 TRX")
        #expect(plan.review.warnings.isEmpty)
        #expect(Self.line(plan, "Para") == Self.destination)
        // 268 = 265 do recibo das txs de 1 sun mais 3 bytes do varint de 12,5 TRX.
        #expect(Self.line(plan, "Banda") == "268 bytes, coberta pela cota da conta")
        #expect(Self.line(plan, "Custo estimado") == "0 TRX queimados")
        #expect(Self.line(plan, "Sai da conta") == "12,5 TRX")

        #expect(tx.raw.refBlockBytes == [0xFA, 0xE2])
        #expect(Hex.encode(tx.raw.refBlockHash) == "4243cce895cda63d")
        // O relogio (2,5 s depois do bloco) e o mais tardio: expira 60 s depois dele.
        #expect(tx.raw.expiration == 1_790_387_633_500 + 60_000)
        #expect(tx.raw.timestamp == 1_790_387_633_500)
        #expect(tx.raw.feeLimit.isZero)
        #expect(tx.raw.memo.isEmpty)
        #expect(tx.raw.contract == .transfer(owner: try Self.owner().address, to: TronAddress(base58: Self.destination)!, amount: 12_500_000))
        #expect(TronTransaction.bandwidthBytes(of: tx.raw) == 268)
        #expect(tx.txID == Hash.sha256(tx.raw.serialized()))
    }

    @Test("TRX sem cota: queima bytes x getTransactionFee")
    func trxBurnsBandwidth() throws {
        let resources = TronAccountResources(freeBandwidth: 200, stakedBandwidth: 100, energy: 0)
        let plan = try Self.sendTRX(10_000_000, state: Self.state(resources: resources))
        #expect(Self.line(plan, "Banda") == "268 bytes, 0,268 TRX queimados")
        #expect(Self.line(plan, "Custo estimado") == "0,268 TRX queimados")
        // Saldo exato para valor mais taxa passa; um sun a menos, nao.
        let exact = try Self.state(trx: 10_268_000, resources: resources)
        _ = try Self.sendTRX(10_000_000, state: exact)
        #expect(throws: TronPlanError.insufficientTRX(needed: 10_268_000, available: 10_267_999)) {
            try Self.sendTRX(10_000_000, state: Self.state(trx: 10_267_999, resources: resources))
        }
    }

    @Test("TRX para conta nova: aviso activatesAccount, 1 TRX mais 0,1 sem stake de bandwidth")
    func trxActivatesAccount() throws {
        let plan = try Self.sendTRX(20_000_000, state: Self.state(destinationActivated: false))
        #expect(plan.review.warnings == [.activatesAccount(minimum: "1,1 TRX")])
        #expect(Self.line(plan, "Ativação da conta de destino") == "1,1 TRX")
        #expect(Self.line(plan, "Banda") == "268 bytes, incluída na ativação")
        #expect(Self.line(plan, "Custo estimado") == "1,1 TRX queimados")
        #expect(Self.line(plan, "Sai da conta") == "21,1 TRX")

        // Com bandwidth em stake, a criacao usa o stake e so a taxa de 1 TRX fica.
        let staked = TronAccountResources(freeBandwidth: 0, stakedBandwidth: 1_000, energy: 0)
        let withStake = try Self.sendTRX(20_000_000, state: Self.state(resources: staked, destinationActivated: false))
        #expect(withStake.review.warnings == [.activatesAccount(minimum: "1 TRX")])
        #expect(Self.line(withStake, "Custo estimado") == "1 TRX queimados")

        // 1 TRX para conta nova: a taxa passa de 100% do valor.
        let small = try Self.sendTRX(1_000_000, state: Self.state(destinationActivated: false))
        #expect(small.review.warnings.contains(.highFee(percentOfAmount: 110)))
    }

    @Test("TRX com memo: 1 TRX de getMemoFee e o memo no campo data do raw")
    func trxMemo() throws {
        let plan = try Self.sendTRX(5_000_000, memo: "pedido 4812", state: Self.state())
        let tx = try Self.tron(plan)
        #expect(tx.raw.memo == Array("pedido 4812".utf8))
        #expect(Self.line(plan, "Memo") == "pedido 4812")
        #expect(Self.line(plan, "Taxa do memo") == "1 TRX")
        #expect(Self.line(plan, "Custo estimado") == "1 TRX queimados")
        // 5 TRX: varint de 4 bytes (268), mais tag, tamanho e 11 bytes de memo.
        #expect(TronTransaction.bandwidthBytes(of: tx.raw) == 268 + 2 + 11)
        #expect(throws: TronPlanError.memoTooLong(maxBytes: 256)) {
            try Self.sendTRX(5_000_000, memo: String(repeating: "a", count: 257), state: Self.state())
        }
    }

    @Test("Destinos recusados: a propria conta, contrato do USDT, queima, contrato, outra rede, checksum")
    func destinations() throws {
        let state = try Self.state()
        let owner = try Self.owner()
        #expect(throws: TronPlanError.destinationIsOwner) { try Self.sendTRX(1_000_000, to: owner.address.base58, state: state) }
        #expect(throws: TronPlanError.destinationIsTokenContract) {
            try Self.sendTRX(1_000_000, to: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", state: state)
        }
        #expect(throws: TronPlanError.destinationIsTokenContract) {
            try Self.sendUSDT(1, to: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", state: Self.state(usdt: 10, energy: 64_285))
        }
        #expect(TronAddress(account20: [UInt8](repeating: 0, count: 20))!.base58 == "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb")
        #expect(throws: TronPlanError.destinationIsBurnAddress) {
            try Self.sendTRX(1_000_000, to: "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb", state: state)
        }
        #expect(throws: TronPlanError.destinationIsContract) {
            try Self.sendTRX(1_000_000, state: Self.state(destinationIsContract: true))
        }
        #expect(throws: TronPlanError.invalidDestination(.otherNetwork(.ethereum))) {
            try Self.sendTRX(1_000_000, to: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf", state: state)
        }
        #expect(throws: TronPlanError.invalidDestination(.badChecksum)) {
            try Self.sendTRX(1_000_000, to: "TU6UKxqHCG743kdKURsXK37ZhvND9SBgTw", state: state)
        }
        #expect(throws: TronPlanError.zeroAmount) { try Self.sendTRX(0, state: state) }
        #expect(throws: TronPlanError.amountTooLarge) {
            try Self.sendTRX(BigUInt(UInt64(Int64.max)) + 1, state: Self.state(trx: BigUInt.uint256Max))
        }
    }

    // MARK: USDT

    @Test("USDT para quem ja tem USDT: ~6,4 TRX de energy, fee_limit com margem, calldata certa")
    func usdtToHolder() throws {
        let plan = try Self.sendUSDT(50_000_000, state: Self.state(trx: 20_000_000, usdt: 100_000_000, energy: 64_285, holdsUSDT: true))
        let tx = try Self.tron(plan)
        #expect(plan.review.title == "Enviar 50 USDT")
        #expect(Self.line(plan, "Rede") == "Tron (TRC-20)")
        #expect(Self.line(plan, "Contrato do USDT") == "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")
        #expect(Self.line(plan, "Energia") == "64.285 de energia, 6,4285 TRX queimados")
        #expect(Self.line(plan, "Banda") == "345 bytes, coberta pela cota da conta")
        #expect(Self.line(plan, "Custo estimado") == "6,4285 TRX queimados")
        // 64.285 x 100 x 1,25 = 8,04 TRX, arredondado para 9.
        #expect(Self.line(plan, "Taxa máxima (fee_limit)") == "9 TRX")
        #expect(Self.line(plan, "Destino sem USDT") == nil)
        #expect(tx.raw.feeLimit == 9_000_000)
        let to = TronAddress(base58: Self.destination)!
        #expect(tx.raw.contract == .triggerSmartContract(
            owner: try Self.owner().address, contract: TRC20.usdt.contract, callValue: 0,
            data: try TRC20.transferCalldata(to: to, amount: 50_000_000)
        ))
        #expect(TronTransaction.bandwidthBytes(of: tx.raw) == 345)
    }

    @Test("USDT para quem nao tem USDT: os ~13 TRX aparecem, com o motivo")
    func usdtToNewHolder() throws {
        let plan = try Self.sendUSDT(
            1_032_980_000,
            state: Self.state(trx: 30_000_000, usdt: 2_000_000_000, destinationActivated: false, energy: 130_285, holdsUSDT: false)
        )
        // O mesmo que o recibo da 8f0df00f... cobrou em energy_fee: 13.028.500 sun.
        #expect(Self.line(plan, "Energia") == "130.285 de energia, 13,0285 TRX queimados")
        #expect(Self.line(plan, "Custo estimado") == "13,0285 TRX queimados")
        #expect(Self.line(plan, "Taxa máxima (fee_limit)") == "17 TRX")
        #expect(Self.line(plan, "Destino sem USDT") != nil)
        #expect(Self.line(plan, "Destino sem conta ativa") != nil)
        // USDT nao ativa conta: sem aviso nem taxa de ativacao.
        #expect(plan.review.warnings.isEmpty)
    }

    @Test("USDT com memo: 1 TRX a mais e bandwidth do memo")
    func usdtMemo() throws {
        let plan = try Self.sendUSDT(
            1_032_980_000, memo: "202609260939444993",
            state: Self.state(trx: 30_000_000, usdt: 2_000_000_000, energy: 130_285, holdsUSDT: false)
        )
        let tx = try Self.tron(plan)
        // Recibo da 8f0df00f...: net_usage 365 e fee = energy_fee + 1 TRX.
        #expect(TronTransaction.bandwidthBytes(of: tx.raw) == 365)
        #expect(Self.line(plan, "Custo estimado") == "14,0285 TRX queimados")
    }

    @Test("Dono com USDT e 0 TRX: recusa, e o motivo diz que a Escalibur nao paga a energia")
    func usdtWithoutTRX() throws {
        let error = #expect(throws: TronPlanError.self) {
            try Self.sendUSDT(10_000_000, state: Self.state(trx: 0, usdt: 10_000_000, energy: 130_285))
        }
        #expect(error == .noTRXForFees(needed: 13_028_500))
        #expect(error?.message.contains("A Escalibur não paga essa taxa por você") == true)
        #expect(error?.message.contains("13,0285 TRX") == true)

        // Conta que so recebeu USDT (nao existe na rede): mesma recusa.
        let owner = try Self.owner()
        let notActivated = try TronPermissions.check(getAccountJSON: Data("{}".utf8), derived: owner.address)
        #expect(throws: TronPlanError.noTRXForFees(needed: 13_028_500)) {
            try Self.sendUSDT(10_000_000, state: Self.state(trx: 0, usdt: 10_000_000, energy: 130_285, control: notActivated))
        }
        #expect(throws: TronPlanError.ownerNotActivated) {
            try Self.sendTRX(1, state: Self.state(trx: 0, control: notActivated))
        }

        // Algum TRX, mas nao o bastante.
        #expect(throws: TronPlanError.insufficientTRXForFees(needed: 13_028_500, available: 5_000_000)) {
            try Self.sendUSDT(10_000_000, state: Self.state(trx: 5_000_000, usdt: 10_000_000, energy: 130_285))
        }
    }

    @Test("Energy em stake cobre: 0 TRX livre basta, mas o fee_limit continua cobrindo a estimativa inteira")
    func usdtWithStakedEnergy() throws {
        let resources = TronAccountResources(freeBandwidth: 600, stakedBandwidth: 0, energy: 200_000)
        let plan = try Self.sendUSDT(10_000_000, state: Self.state(trx: 0, usdt: 10_000_000, resources: resources, energy: 130_285))
        #expect(Self.line(plan, "Energia") == "130.285 de energia, coberta pelo stake")
        #expect(Self.line(plan, "Custo estimado") == "0 TRX queimados")
        #expect(try Self.tron(plan).raw.feeLimit == 17_000_000)

        // Stake cobre parte: queima so o resto.
        let partial = TronAccountResources(freeBandwidth: 600, stakedBandwidth: 0, energy: 100_000)
        let rest = try Self.sendUSDT(10_000_000, state: Self.state(trx: 10_000_000, usdt: 10_000_000, resources: partial, energy: 130_285))
        #expect(Self.line(rest, "Energia") == "130.285 de energia, 3,0285 TRX queimados")
    }

    @Test("Estimativa de energy e fee_limit: ausente, fora da faixa, acima do teto")
    func usdtEnergyGuards() throws {
        #expect(throws: TronPlanError.missingEnergyEstimate) {
            try Self.sendUSDT(1, state: Self.state(usdt: 10))
        }
        #expect(throws: TronPlanError.energyEstimateOutOfRange(5_000)) {
            try Self.sendUSDT(1, state: Self.state(usdt: 10, energy: 5_000))
        }
        #expect(throws: TronPlanError.energyEstimateOutOfRange(250_000)) {
            try Self.sendUSDT(1, state: Self.state(usdt: 10, energy: 250_000))
        }
        // Preco de energy de 1.000 sun (o maximo aceito): 130.285 x 1.000 x 1,25 = 162,9 TRX.
        let expensive = TronChainParameters(
            energyPrice: 1_000, bandwidthPrice: 1_000, createAccountFee: 1_000_000,
            createAccountBandwidthFee: 100_000, memoFee: 1_000_000
        )
        #expect(throws: TronPlanError.feeLimitAboveCeiling(163_000_000)) {
            try Self.sendUSDT(1, state: Self.state(trx: 1_000_000_000, usdt: 10, parameters: expensive, energy: 130_285))
        }
        // Parametro absurdo do provedor.
        let free = TronChainParameters(
            energyPrice: 0, bandwidthPrice: 1_000, createAccountFee: 1_000_000,
            createAccountBandwidthFee: 100_000, memoFee: 1_000_000
        )
        #expect(throws: TronPlanError.parameterOutOfRange("energyPrice")) {
            try Self.sendUSDT(1, state: Self.state(usdt: 10, parameters: free, energy: 64_285))
        }
    }

    @Test("Saldo de USDT e valor")
    func usdtAmounts() throws {
        #expect(throws: TronPlanError.insufficientUSDT(needed: 10_000_001, available: 10_000_000)) {
            try Self.sendUSDT(10_000_001, state: Self.state(usdt: 10_000_000, energy: 64_285))
        }
        #expect(throws: TronPlanError.zeroAmount) {
            try Self.sendUSDT(0, state: Self.state(usdt: 10_000_000, energy: 64_285))
        }
        // Contrato no destino de USDT: avisa, nao bloqueia.
        let plan = try Self.sendUSDT(1, state: Self.state(usdt: 10, destinationIsContract: true, energy: 64_285))
        #expect(plan.review.warnings == [.destinationIsContract])
    }

    @Test("Conta comprometida ou checagem de outra conta: nenhum plano")
    func compromisedAccount() throws {
        let owner = try Self.owner()
        let attacker = "41b785fc63372bced2b345e8edc1913260465c6e0b"
        let json = #"{"address":"\#(owner.address.hex)","owner_permission":{"threshold":1,"keys":[{"address":"\#(attacker)","weight":1}]}}"#
        let compromised = try TronPermissions.check(getAccountJSON: Data(json.utf8), derived: owner.address)
        #expect(compromised.isCompromised)
        let error = #expect(throws: TronPlanError.self) {
            try Self.sendUSDT(1, state: Self.state(usdt: 10, energy: 64_285, control: compromised))
        }
        if case .accountCompromised = error {} else { Issue.record("esperava accountCompromised, veio \(String(describing: error))") }
        #expect(error?.message.contains("golpe") == true)
        #expect(throws: TronPlanError.self) {
            try Self.sendTRX(1_000_000, state: Self.state(control: compromised))
        }

        let other = TronAddress(base58: Self.destination)!
        let otherControl = try TronPermissions.check(getAccountJSON: Data(#"{"address":"\#(other.hex)"}"#.utf8), derived: other)
        #expect(throws: TronPlanError.controlForOtherAccount) {
            try Self.sendTRX(1_000_000, state: Self.state(control: otherControl))
        }
    }

    // MARK: Ponta a ponta

    @Test("Ponta a ponta: planejar, assinar com a chave de teste, montar, recuperar o dono")
    func endToEnd() throws {
        let key = Self.testKey()
        defer { key.wipe() }
        let owner = try Self.owner()
        let plans = [
            try Self.sendUSDT(50_000_000, memo: "fatura 77", state: Self.state(trx: 20_000_000, usdt: 100_000_000, energy: 64_285, holdsUSDT: true)),
            try Self.sendTRX(12_500_000, state: Self.state(destinationActivated: false)),
        ]
        for plan in plans {
            #expect(!plan.isExpired(now: Self.now))
            let tx = try Self.tron(plan)
            // Nunca AccountPermissionUpdateContract: so TransferContract e TriggerSmartContract.
            #expect([TronContract.transferType, TronContract.triggerSmartContractType].contains(tx.raw.contract.typeNumber))
            let request = try #require(tx.signingRequests.first)
            #expect(request.path == DefaultPaths.path(for: .tron))
            #expect(request.curve == .secp256k1)
            #expect(request.scheme == .ecdsaRecoverable)
            #expect(request.expectedPublicKey == owner.publicKey)
            #expect(request.payload == Hash.sha256(tx.raw.serialized()))

            // O papel do assinador (EscaliburKeys), feito aqui com a chave de teste.
            let signature = try Secp256k1.signRecoverable(digest: request.payload, privateKey: key)
            let signed = try tx.assemble(with: [ProducedSignature(bytes: signature.compact, recoveryID: signature.recoveryID)])

            #expect(signed.id == Hex.encode(tx.txID))
            #expect(signed.encoded == Hex.encode(signed.raw))
            let decoded = try TronProtobuf.decodeSignedTransaction(Hex.decode(signed.encoded)!)
            #expect(decoded.raw == tx.raw)
            #expect(Hex.encode(decoded.raw.txID) == signed.id)
            let full = try #require(decoded.signatures.first)
            #expect(decoded.signatures.count == 1)
            #expect(full.count == 65)
            #expect(full[64] == signature.recoveryID + 27)
            let recovered = try Secp256k1.recover(digest: decoded.raw.txID, compact: Array(full.prefix(64)), recoveryID: full[64] - 27)
            #expect(try TronAddress(publicKey: recovered) == owner.address)
            #expect(try TronAddress(publicKey: recovered).base58 == "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC")
        }
    }
}
