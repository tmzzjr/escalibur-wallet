import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburCore

@Suite("Cardano: planejador de envio")
struct CardanoPlannerTests {
    static let walletID = UUID()
    static let path = DerivationPath("m/1852'/1815'/0'/0/0")!
    static let parameters = CardanoRealTransactions.parameters
    /// Uma conta de carteira qualquer, para destino (vetor do wallet-core).
    static let destination = "addr1q94zzrtl32tjp8j96auatnhxd2y35fnk6wuxqvqm9364vp9spdkjdsmyfhvfagjzh4uzp9zs6p5djw89jac2g0ujs2eqsuy7pu"

    /// O relogio que corresponde a um slot da rede principal.
    static func date(slot: UInt64) -> Date { Date(timeIntervalSince1970: TimeInterval(Int64(slot) + CardanoPlanner.shelleySlotOffset)) }

    static func source(_ vector: CardanoRealTransactions.Vector) throws -> CardanoSource {
        let parsed = try CardanoSignedTransaction.parse(Hex.decode(vector.cbor)!)
        return CardanoSource(path: path, publicKey: parsed.witnesses[0].publicKey, address: vector.inputAddress)
    }

    static func utxo(_ id: String, _ index: UInt32, _ lovelace: UInt64, tokens: Bool = false) -> CardanoUTXO {
        CardanoUTXO(transactionID: id, index: index, lovelace: lovelace, hasTokens: tokens, hasReferenceScript: false)
    }

    static func state(_ utxos: [CardanoUTXO], slot: UInt64 = 199_000_000) -> CardanoSpendState {
        CardanoSpendState(utxos: utxos, parameters: parameters, tipSlot: slot)
    }

    static let ownSource: CardanoSource = try! source(CardanoRealTransactions.withChange)  // swiftlint:disable:this force_try

    static func plan(_ amount: BigUInt?, utxos: [CardanoUTXO], to destination: String = destination, source: CardanoSource = ownSource) throws -> SigningPlan {
        try CardanoPlanner.planSend(
            walletID: walletID, source: source, to: destination, amount: amount, state: state(utxos), now: date(slot: 199_000_000)
        )
    }

    static func body(_ plan: SigningPlan) throws -> CardanoTransactionBody {
        try #require(plan.transactions.first as? CardanoTransfer).body
    }

    // MARK: Transacoes reais

    @Test("Enviar tudo reproduz byte a byte uma transacao real aceita pela rede")
    func reproducesSweep() throws {
        let vector = CardanoRealTransactions.sweep
        // As duas moedas da transacao 1497077d..., e a ponta a 900 slots do TTL dela.
        let utxos = [
            Self.utxo("a797b2caa21ca44328b5edc2d81f3de51ed4e260fa6aa224134f5eb1dbd7e713", 0, 10_500_000_000),
            Self.utxo("fbf2df72ca415eb34ba2d5296653a2edc266e25cbe86c6087c7a1849d3c7cec8", 0, 6_998_000_000),
        ]
        let tip: UInt64 = 0x7FFF_FFFF - 900
        let plan = try CardanoPlanner.planSend(
            walletID: Self.walletID, source: try Self.source(vector),
            to: "addr1q8pzlgqaf9r2aev8k7jaen2f089lm3yhvk7mumxeh38nm9kz97sp6j2x4mjc0da9mnx5j7wtlhzfwedahekdn0z08ktq972pyf",
            amount: nil, state: Self.state(utxos, slot: tip), now: Self.date(slot: tip)
        )
        let real = try CardanoSignedTransaction.parse(Hex.decode(vector.cbor)!)
        let body = try Self.body(plan)
        #expect(body.bytes == real.body.bytes)
        #expect(Hex.encode(body.hash) == vector.id)
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: Asset.native(.cardano).id, amount: 17_497_832_695))
    }

    @Test("Com troco: a mesma transacao real, com a taxa minima e o troco para o dono")
    func matchesRealWithChange() throws {
        let vector = CardanoRealTransactions.withChange
        let real = try CardanoSignedTransaction.parse(Hex.decode(vector.cbor)!)
        let utxos = [Self.utxo("167d2716707f45cc00d4ba7086bcd8fba87798f6c240df667eb8be4f46462d77", 0, 999_822_399)]
        let tip = real.body.ttl - 900
        let recipient = "addr1qy5v4llgps32xyfedt38dmx6zhalyh4ayj8yzmdy5lglr6kk79udnsmyh3ms3h42qygxr7rs2d69f8crkrl4d2kej87qf5uqsa"
        let plan = try CardanoPlanner.planSend(
            walletID: Self.walletID, source: try Self.source(vector), to: recipient, amount: 475_000_000,
            state: Self.state(utxos, slot: tip), now: Self.date(slot: tip)
        )
        let body = try Self.body(plan)
        // A carteira real pagou 168.581 e mandou o troco (a saida 1) para outro endereco
        // seu; aqui a taxa e a minima do tamanho, e o troco volta para o endereco que gastou.
        let fee = CardanoPlanner.minimumFee(size: 296, Self.parameters)
        let owner = try #require(try? CardanoAddress.parse(vector.inputAddress).get())
        let expected = CardanoTransactionBody(
            inputs: real.body.inputs,
            outputs: [real.body.outputs[0], CardanoOutput(address: owner.bytes, lovelace: 999_822_399 - 475_000_000 - fee)],
            fee: fee, ttl: real.body.ttl
        )
        #expect(body == expected)
        #expect(CardanoPlanner.signedSize(body) == 296)
        #expect(body.fee == 168_405)
    }

    // MARK: Revisao

    @Test("Revisao: destino, valor, taxa, troco e o movimento que o app confere")
    func review() throws {
        let plan = try Self.plan(2_000_000, utxos: [Self.utxo(String(repeating: "11", count: 32), 0, 10_000_000)])
        let review = plan.review
        #expect(review.kind == .send)
        #expect(review.title == "Enviar 2 ADA")
        #expect(review.recipient == Self.destination)
        #expect(review.recipientTag == nil)
        #expect(review.lines.first == PlanReview.Line("Para", Self.destination, verbatim: true))
        #expect(review.lines.contains { $0.label == "Troco" })
        #expect(review.lines.contains { $0.label == "Rede" && $0.value == "Cardano" })
        try PlanIntentCheck.send(review, asset: .native(.cardano), amount: 2_000_000, ceiling: 10_000_000, chain: .cardano)
        #expect(throws: PlanIntentCheck.Mismatch.wrongAmount) {
            try PlanIntentCheck.send(review, asset: .native(.cardano), amount: 2_000_001, ceiling: 10_000_000, chain: .cardano)
        }
        let body = try Self.body(plan)
        #expect(body.outputs[0].lovelace == 2_000_000)
        #expect(body.inputs.count == 1)
        #expect(body.ttl == 199_000_900)
        // Entradas = saidas + taxa, exatamente.
        #expect(body.outputs.reduce(0) { $0 + $1.lovelace } + body.fee == 10_000_000)
        #expect(body.fee == CardanoPlanner.minimumFee(size: CardanoPlanner.signedSize(body), Self.parameters))
        #expect(body.outputs[1].address == (try CardanoAddress.parse(Self.ownSource.address).get()).bytes)
    }

    @Test("Maximo: todas as moedas so de ADA, menos a taxa, sem troco")
    func maximum() throws {
        let utxos = [
            Self.utxo(String(repeating: "11", count: 32), 0, 5_000_000),
            Self.utxo(String(repeating: "22", count: 32), 1, 3_000_000),
            Self.utxo(String(repeating: "33", count: 32), 0, 1_500_000, tokens: true),
        ]
        let maximum = try CardanoPlanner.maximumSendable(
            source: Self.ownSource, to: Self.destination, state: Self.state(utxos), now: Self.date(slot: 199_000_000)
        )
        let plan = try Self.plan(nil, utxos: utxos)
        let body = try Self.body(plan)
        #expect(body.inputs.count == 2)  // a moeda com token fica de fora
        #expect(body.outputs.count == 1)
        #expect(BigUInt(body.outputs[0].lovelace) == maximum)
        #expect(body.outputs[0].lovelace + body.fee == 8_000_000)
        // Pedir exatamente o maximo fecha sem troco.
        let exact = try Self.body(Self.plan(maximum, utxos: utxos))
        #expect(exact == body)
    }

    @Test("Escolhe as maiores moedas primeiro, so as necessarias")
    func selection() throws {
        let utxos = [
            Self.utxo(String(repeating: "11", count: 32), 0, 2_000_000),
            Self.utxo(String(repeating: "22", count: 32), 0, 50_000_000),
            Self.utxo(String(repeating: "33", count: 32), 0, 30_000_000),
        ]
        let body = try Self.body(Self.plan(60_000_000, utxos: utxos))
        #expect(Set(body.inputs.map { Hex.encode($0.transactionID) }) == [String(repeating: "22", count: 32), String(repeating: "33", count: 32)])
        #expect(body.inputs == body.inputs.sorted())
    }

    // MARK: Recusas

    @Test("Recusas: valor, saldo, minimo por saida e troco abaixo do minimo")
    func amountRefusals() throws {
        let utxos = [Self.utxo(String(repeating: "11", count: 32), 0, 5_000_000)]
        #expect(throws: CardanoPlanError.zeroAmount) { try Self.plan(0, utxos: utxos) }
        #expect(throws: CardanoPlanError.amountTooLarge) { try Self.plan(BigUInt(UInt64.max) + 1, utxos: utxos) }
        #expect {
            try Self.plan(500_000, utxos: utxos)
        } throws: { error in
            guard case CardanoPlanError.belowMinimumOutput(let minimum) = error else { return false }
            // (160 + 65 bytes da saida base com 0,5 ADA) x 4.310.
            return minimum == 969_750
        }
        #expect {
            try Self.plan(6_000_000, utxos: utxos)
        } throws: { error in
            if case CardanoPlanError.insufficientBalance = error { return true }
            return false
        }
        // 4,5 ADA de 5: sobram ~0,33 ADA, abaixo do minimo de ~0,97 para o troco.
        #expect {
            try Self.plan(4_500_000, utxos: utxos)
        } throws: { error in
            guard case CardanoPlanError.changeBelowMinimum(let leftover, let minimum, let maximum) = error else { return false }
            return leftover < minimum && maximum > 0 && maximum < 4_500_000
        }
        // So moedas com tokens: nada a gastar.
        #expect {
            try Self.plan(2_000_000, utxos: [Self.utxo(String(repeating: "11", count: 32), 0, 50_000_000, tokens: true)])
        } throws: { error in
            if case CardanoPlanError.insufficientBalance = error { return true }
            return false
        }
        #expect(throws: CardanoPlanError.duplicateUTXO) { try Self.plan(2_000_000, utxos: utxos + utxos) }
    }

    @Test("Recusas: destino de outra rede, de script, a propria conta")
    func destinationRefusals() throws {
        let utxos = [Self.utxo(String(repeating: "11", count: 32), 0, 50_000_000)]
        #expect(throws: CardanoPlanError.invalidDestination(.otherNetwork(.ethereum))) {
            try Self.plan(2_000_000, utxos: utxos, to: "0x52908400098527886E0F7030069857D2E4169EE7")
        }
        // CIP-19 tipo 1: pagamento por script.
        #expect(throws: CardanoPlanError.invalidDestination(.unsupportedType)) {
            try Self.plan(2_000_000, utxos: utxos, to: "addr1z8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gten0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgs9yc0hh")
        }
        #expect(throws: CardanoPlanError.destinationIsSelf) {
            try Self.plan(2_000_000, utxos: utxos, to: Self.ownSource.address)
        }
    }

    @Test("Recusas: chave de outra conta, caminho fora da CIP-1852, parametros e ponta fora da faixa")
    func stateRefusals() throws {
        let utxos = [Self.utxo(String(repeating: "11", count: 32), 0, 50_000_000)]
        let other = try Self.source(CardanoRealTransactions.untagged)
        #expect(throws: CardanoPlanError.keyMismatch) {
            try Self.plan(2_000_000, utxos: utxos, source: CardanoSource(path: Self.path, publicKey: other.publicKey, address: Self.ownSource.address))
        }
        #expect(throws: CardanoPlanError.invalidPath) {
            try Self.plan(2_000_000, utxos: utxos, source: CardanoSource(
                path: DerivationPath("m/44'/1815'/0'/0/0")!, publicKey: Self.ownSource.publicKey, address: Self.ownSource.address
            ))
        }
        let absurd = CardanoSpendState(
            utxos: utxos, parameters: CardanoProtocolParameters(minFeeA: 4_400, minFeeB: 155_381, coinsPerUTxOByte: 4_310, maxTxSize: 16_384),
            tipSlot: 199_000_000
        )
        #expect(throws: CardanoPlanError.parametersOutOfRange) {
            try CardanoPlanner.planSend(walletID: Self.walletID, source: Self.ownSource, to: Self.destination, amount: 2_000_000,
                                        state: absurd, now: Self.date(slot: 199_000_000))
        }
        // Ponta uma hora atras do relogio: provedor parado.
        #expect(throws: CardanoPlanError.staleTip) {
            try CardanoPlanner.planSend(walletID: Self.walletID, source: Self.ownSource, to: Self.destination, amount: 2_000_000,
                                        state: Self.state(utxos, slot: 199_000_000), now: Self.date(slot: 199_003_600))
        }
    }

    @Test("Aviso de taxa alta quando ela passa de 10% do valor")
    func highFee() throws {
        let plan = try Self.plan(1_500_000, utxos: [Self.utxo(String(repeating: "11", count: 32), 0, 3_000_000)])
        #expect(plan.review.warnings.contains { if case .highFee = $0 { return true } else { return false } })
    }
}
