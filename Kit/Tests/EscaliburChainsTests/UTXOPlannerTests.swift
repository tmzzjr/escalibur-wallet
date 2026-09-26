import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Uma conta de teste: chave privada conhecida, xpub, e moedas com transacao
/// anterior de verdade (serializada aqui), para o planejamento conferir como
/// conferiria a de um provedor.
struct UTXOTestAccount {
    let chain: Chain
    let purpose: UInt32
    let account: UInt32
    let privateKey: [UInt8]
    let accountKey: ExtendedPublicKey

    init(_ chain: Chain, purpose: UInt32, account: UInt32 = 0, seed: String = "escalibur utxo") throws {
        self.chain = chain
        self.purpose = purpose
        self.account = account
        privateKey = Hash.sha256(Array("\(seed) \(chain.id) \(purpose) \(account)".utf8))
        let secret = UTXOFixtures.key(privateKey.hex)
        accountKey = try ExtendedPublicKey(
            publicKey: Secp256k1.publicKey(of: secret),
            chainCode: Hash.sha256(Array("cadeia \(seed)".utf8))
        )
    }

    var kind: UTXOInputKind { UTXOInputKind(purpose: purpose)! }

    func path(_ branch: UInt32, _ index: UInt32) -> DerivationPath {
        UTXOFixtures.path(purpose, chain.coinType, account, branch, index)
    }

    func publicKey(_ branch: UInt32, _ index: UInt32) throws -> [UInt8] {
        try accountKey.derive([branch, index]).publicKey
    }

    /// Derivacao privada nao endurecida (BIP-32), so para assinar no teste.
    func privateKey(_ branch: UInt32, _ index: UInt32) throws -> SecureBytes {
        let key = UTXOFixtures.key(privateKey.hex)
        var parentPub = accountKey.publicKey
        var chainCode = accountKey.chainCode
        for i in [branch, index] {
            let mac = Hash.hmacSHA512(key: chainCode, data: parentPub + i.bigEndianByteArray)
            try Array(mac.prefix(32)).withUnsafeBytes { try Secp256k1.tweakAdd(privateKey: key, tweak: $0) }
            chainCode = Array(mac.suffix(32))
            parentPub = try Secp256k1.publicKey(of: key)
        }
        return key
    }

    func address(_ branch: UInt32, _ index: UInt32) throws -> String {
        let script = kind.scriptPubKey(publicKey: try publicKey(branch, index))
        return try #require(UTXOScript.address(for: script, chain: chain))
    }

    func change(_ index: UInt32 = 0) throws -> UTXOChangeAddress {
        UTXOChangeAddress(address: try address(1, index), path: path(1, index), publicKey: try publicKey(1, index), accountKey: accountKey)
    }

    /// Uma moeda de `value` no endereco (branch, index), dentro de uma transacao de
    /// financiamento serializada de verdade. `salt` muda o txid.
    func coin(_ value: UInt64, branch: UInt32 = 0, index: UInt32 = 0, confirmations: UInt32 = 6, salt: UInt8 = 0, vout: UInt32 = 0) throws -> UTXOCoin {
        let script = kind.scriptPubKey(publicKey: try publicKey(branch, index))
        var outputs = [UTXOTxOut]()
        for _ in 0..<vout { outputs.append(UTXOTxOut(value: 12_345, scriptPubKey: UTXOScript.p2pkh([UInt8](repeating: 9, count: 20)))) }
        outputs.append(UTXOTxOut(value: value, scriptPubKey: script))
        let funding = UTXOTransaction(
            version: 2,
            inputs: [UTXOTxIn(
                outpoint: UTXOOutpoint(txid: UTXOTxID(bytes: Hash.sha256([salt, UInt8(index), UInt8(branch)] + value.littleEndianByteArray))!, vout: 0),
                scriptSig: [0x51], sequence: 0xFFFF_FFFF
            )],
            outputs: outputs, lockTime: 0
        )
        return UTXOCoin(
            outpoint: UTXOOutpoint(txid: funding.txid, vout: vout), previousTransaction: funding.serialized(),
            confirmations: confirmations, path: path(branch, index), publicKey: try publicKey(branch, index)
        )
    }

    /// Assina o plano como o assinador faria: chave pelo caminho, confere a chave
    /// publica esperada, assina e deixa a transacao montar.
    func sign(_ plan: SigningPlan) throws -> (SignedTransaction, UTXOSignableTransaction) {
        let tx = try #require(plan.transactions.first as? UTXOSignableTransaction)
        var signatures = [ProducedSignature]()
        for request in tx.signingRequests {
            let c = request.path.components
            let key = try privateKey(c[3], c[4])
            #expect(try Secp256k1.publicKey(of: key) == request.expectedPublicKey)
            signatures.append(try UTXOFixtures.sign(request.payload, with: key))
        }
        return (try tx.assemble(with: signatures), tx)
    }
}

@Suite("UTXO planejamento")
struct UTXOPlannerTests {
    static let wallet = UUID()
    static let destination = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
    static let height: UInt32 = 968_620

    static func rate(_ satPerVByte: UInt64) -> UTXOFeeRate { UTXOFeeRate(satPerVByte: satPerVByte) }

    static func intent(
        _ amount: UTXOSendIntent.Amount, to address: String = destination, rate: UInt64 = 5,
        change: UTXOChangeAddress?, coinControl: [UTXOOutpoint]? = nil, known: [String]? = nil
    ) -> UTXOSendIntent {
        UTXOSendIntent(
            destination: Address.Destination(address: address, tag: nil), amount: amount,
            feeRate: Self.rate(rate), change: change, coinControl: coinControl, knownAddresses: known
        )
    }

    static func state(_ coins: [UTXOCoin], estimates: [UInt64] = [8, 6]) -> UTXONetworkState {
        UTXONetworkState(coins: coins, feeEstimates: estimates.map { UTXOFeeRate(satPerVByte: $0) }, tipHeight: height)
    }

    /// Confere a transacao assinada de ponta a ponta: parse, taxa, peso e troco.
    static func checkSigned(_ signed: SignedTransaction, _ tx: UTXOSignableTransaction, rate: UTXOFeeRate) throws -> UTXOTransaction {
        let parsed = try UTXOTransaction(parsing: signed.raw)
        #expect(parsed.txid.hex == signed.id)
        let summary = try #require(tx.summary)
        let totalIn = tx.spends.reduce(UInt64(0)) { $0 + $1.value }
        let totalOut = parsed.outputs.reduce(UInt64(0)) { $0 + $1.value }
        #expect(BigUInt(totalIn - totalOut) == summary.fee)
        // O peso real nunca passa do estimado, e a taxa efetiva nunca fica abaixo da escolhida.
        #expect(parsed.virtualSize <= summary.virtualSize)
        #expect(totalIn - totalOut >= rate.fee(virtualSize: parsed.virtualSize))
        #expect(parsed.inputs.allSatisfy { $0.sequence == 0xFFFF_FFFD })
        #expect(parsed.lockTime == height)
        return parsed
    }

    @Test("Envio com troco: selecao, taxa, RBF, locktime, troco nosso e assinatura de ponta a ponta")
    func sendWithChange() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        let coins = [try account.coin(100_000, index: 0), try account.coin(50_000, index: 1), try account.coin(20_000, index: 2)]
        let plan = try UTXOPlanner.planSend(
            walletID: Self.wallet, chain: .bitcoin,
            intent: Self.intent(.exact(60_000), change: account.change()), network: Self.state(coins)
        )
        #expect(plan.chain == .bitcoin)
        #expect(plan.review.kind == .send)
        #expect(plan.review.title == "Enviar 0,0006 BTC")
        #expect(plan.review.lines.map(\.label) == ["Para", "Valor", "Rede", "Taxa", "Troco"])
        #expect(plan.review.lines[0].value == Self.destination && plan.review.lines[0].verbatim)
        #expect(plan.review.lines[3].value == "0,00000705 BTC (5 sat/vB)")
        #expect(plan.review.lines[4].value == "0,00039295 BTC, volta para a sua carteira")
        #expect(plan.review.warnings.isEmpty)

        let (signed, tx) = try account.sign(plan)
        let summary = try #require(tx.summary)
        // Uma moeda (a de 100.000) paga tudo com troco: 1 entrada e 2 saidas P2WPKH,
        // 141 vB a 5 sat/vB.
        #expect(summary.inputCount == 1)
        #expect(summary.fee == 705)
        #expect(summary.change == 39_295)
        #expect(summary.absorbedIntoFee == 0)
        let parsed = try Self.checkSigned(signed, tx, rate: Self.rate(5))
        #expect(parsed.version == 2)
        let changeScript = UTXOInputKind.p2wpkh.scriptPubKey(publicKey: try account.publicKey(1, 0))
        #expect(parsed.outputs.contains(UTXOTxOut(value: 39_295, scriptPubKey: changeScript)))
        #expect(parsed.outputs.contains(UTXOTxOut(value: 60_000, scriptPubKey: try UTXOScript.scriptPubKey(for: Self.destination, chain: .bitcoin))))
        // BIP-69: saidas por valor crescente.
        #expect(parsed.outputs.map(\.value) == [39_295, 60_000])
    }

    @Test("Branch and Bound acha a moeda que paga sem troco, sem sobra")
    func exactMatch() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        // Alvo: 60.000 + 42 vB de parte fixa a 5 sat/vB (210) = 60.210 de valor efetivo.
        // A moeda de 60.550 vale 60.550 - 340 = 60.210.
        let coins = [try account.coin(100_000, index: 0), try account.coin(60_550, index: 1), try account.coin(30_000, index: 2)]
        let plan = try UTXOPlanner.planSend(
            walletID: Self.wallet, chain: .bitcoin,
            intent: Self.intent(.exact(60_000), change: account.change()), network: Self.state(coins)
        )
        let (signed, tx) = try account.sign(plan)
        let summary = try #require(tx.summary)
        #expect(summary.change == nil)
        #expect(summary.fee == 550)
        #expect(summary.absorbedIntoFee == 0)
        #expect(tx.spends.map(\.value) == [60_550])
        #expect(plan.review.lines.last?.value == "Nenhum")
        _ = try Self.checkSigned(signed, tx, rate: Self.rate(5))
    }

    @Test("Troco abaixo do dust vira taxa, e a revisao diz quanto")
    func dustChangeBecomesFee() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        // A 1 sat/vB: alvo 60.042; a moeda de 60.410 sobra 300 alem do alvo. Troco de
        // 300 - 31 = 269 fica abaixo do dust de 294: nao ha troco, e os 300 viram taxa.
        let coins = [try account.coin(60_410)]
        let plan = try UTXOPlanner.planSend(
            walletID: Self.wallet, chain: .bitcoin,
            intent: Self.intent(.exact(60_000), rate: 1, change: account.change()), network: Self.state(coins, estimates: [1, 2])
        )
        let (signed, tx) = try account.sign(plan)
        let summary = try #require(tx.summary)
        #expect(summary.change == nil)
        #expect(summary.fee == 410)
        #expect(summary.absorbedIntoFee == 300)
        #expect(plan.review.lines.last?.label == "Troco")
        #expect(plan.review.lines.last?.value == "Nenhum: 0,000003 BTC que sobraria fica abaixo do mínimo que vale guardar e vai para a taxa")
        let parsed = try Self.checkSigned(signed, tx, rate: Self.rate(1))
        #expect(parsed.outputs.count == 1)
    }

    @Test("Moedas de ate 1.000 sats e recebimentos sem confirmacao ficam de fora da selecao automatica")
    func protectedCoins() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        let small = [try account.coin(546, index: 0), try account.coin(1_000, index: 1), try account.coin(330, index: 2)]
        let pending = try account.coin(80_000, index: 3, confirmations: 0)
        // So pequenas e uma pendente de recebimento: nao ha o que gastar.
        // Sem candidata segwit, a parte fixa nao tem marker e flag: 41 vB, 205 sats.
        #expect(throws: UTXOPlanError.insufficientFunds(available: 0, required: 20_205)) {
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: Self.intent(.exact(20_000), change: account.change()), network: Self.state(small + [pending])
            )
        }
        // Troco nosso sem confirmacao (cadeia 1) pode ser gasto: so nos o substituimos.
        let ownChange = try account.coin(80_000, branch: 1, index: 5, confirmations: 0)
        let plan = try UTXOPlanner.planSend(
            walletID: Self.wallet, chain: .bitcoin,
            intent: Self.intent(.exact(20_000), change: account.change()), network: Self.state(small + [pending, ownChange])
        )
        let (_, tx) = try account.sign(plan)
        #expect(tx.spends.map(\.path) == [account.path(1, 5)])

        // Escolhidas a mao, as pequenas entram.
        let manual = try UTXOPlanner.planSend(
            walletID: Self.wallet, chain: .bitcoin,
            intent: Self.intent(.all, change: nil, coinControl: [small[1].outpoint, pending.outpoint]),
            network: Self.state(small + [pending])
        )
        let (_, manualTx) = try account.sign(manual)
        #expect(Set(manualTx.spends.map(\.value)) == [1_000, 80_000])
    }

    @Test("Enviar tudo: sem troco, taxa sobre todas as entradas, e o que fica aparece na revisao")
    func sendAll() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        let coins = [try account.coin(40_000, index: 0), try account.coin(25_000, index: 1), try account.coin(800, index: 2)]
        let plan = try UTXOPlanner.planSend(
            walletID: Self.wallet, chain: .bitcoin,
            intent: Self.intent(.all, change: nil), network: Self.state(coins)
        )
        let (signed, tx) = try account.sign(plan)
        let summary = try #require(tx.summary)
        // 2 entradas P2WPKH e 1 saida: (10 + 82 + 31) * 4 + 2 + 216 = 710 WU = 178 vB.
        #expect(summary.fee == 890)
        #expect(summary.amount == BigUInt(64_110))
        #expect(summary.change == nil)
        #expect(summary.sendsAll)
        #expect(plan.review.lines.first { $0.label == "Troco" }?.value == "Nenhum: enviar tudo")
        #expect(plan.review.lines.last?.label == "Fica na carteira")
        #expect(plan.review.lines.last?.value.hasPrefix("1 moeda, 0,000008 BTC") == true)
        let parsed = try Self.checkSigned(signed, tx, rate: Self.rate(5))
        #expect(parsed.outputs.count == 1)
    }

    @Test("Taxa: piso, teto de 2x a maior estimativa, duas fontes, teto absoluto e aviso acima de 3%")
    func feeLimits() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        let coins = [try account.coin(2_000_000, index: 0), try account.coin(100_000_000, index: 1)]
        let change = try account.change()
        let plan = { (rate: UInt64, estimates: [UInt64], amount: BigUInt) in
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: Self.intent(.exact(amount), rate: rate, change: change), network: Self.state(coins, estimates: estimates)
            )
        }
        #expect(throws: UTXOPlanError.feeRateAboveCeiling(ceiling: Self.rate(16))) { try plan(17, [8, 6], 100_000) }
        _ = try plan(16, [8, 6], 100_000)
        #expect(throws: UTXOPlanError.needTwoFeeEstimates) { try plan(5, [8], 100_000) }
        #expect(throws: UTXOPlanError.needTwoFeeEstimates) { try plan(5, [8, 0], 100_000) }
        #expect(throws: UTXOPlanError.feeRateBelowMinimum(minimum: Self.rate(1))) {
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: UTXOSendIntent(destination: .init(address: Self.destination, tag: nil), amount: .exact(100_000),
                                       feeRate: UTXOFeeRate(satPerKvB: 500), change: change),
                network: Self.state(coins)
            )
        }
        // Mempool vazia: 2x a maior estimativa (0,6 sat/vB) fica abaixo do piso de 1
        // sat/vB, e o piso continua valendo.
        let quiet = UTXONetworkState(coins: coins, feeEstimates: [UTXOFeeRate(satPerKvB: 300), UTXOFeeRate(satPerKvB: 250)], tipHeight: Self.height)
        _ = try UTXOPlanner.planSend(walletID: Self.wallet, chain: .bitcoin, intent: Self.intent(.exact(100_000), rate: 1, change: change), network: quiet)
        #expect(throws: UTXOPlanError.feeRateAboveCeiling(ceiling: Self.rate(1))) {
            try UTXOPlanner.planSend(walletID: Self.wallet, chain: .bitcoin, intent: Self.intent(.exact(100_000), rate: 2, change: change), network: quiet)
        }
        // Estimativas gigantes nao estouram inteiro: a taxa cai no teto absoluto.
        let huge = UTXOFeeRate(satPerKvB: UInt64.max / 2)
        #expect(throws: UTXOPlanError.feeAboveAbsoluteCap(cap: 10_000_000)) {
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: UTXOSendIntent(destination: .init(address: Self.destination, tag: nil), amount: .exact(100_000), feeRate: huge, change: change),
                network: UTXONetworkState(coins: coins, feeEstimates: [huge, huge], tipHeight: Self.height)
            )
        }
        // Estimativas absurdas das duas fontes nao liberam taxa absurda: teto de 0,1 BTC.
        #expect(throws: UTXOPlanError.feeAboveAbsoluteCap(cap: 10_000_000)) { try plan(80_000, [50_000, 50_000], 100_000) }

        // 141 vB a 16 sat/vB = 2.256 sats sobre 50.000: 4,5%, acima de 3%.
        let high = try plan(16, [8, 6], 50_000)
        guard case .highFee(let percent)? = high.review.warnings.first else {
            Issue.record("sem aviso de taxa alta"); return
        }
        #expect(abs(percent - 4.512) < 0.001)
        #expect(try plan(5, [8, 6], 100_000).review.warnings.isEmpty)
    }

    @Test("Transacao anterior adulterada, moeda de outra chave, caminho errado, moeda repetida")
    func coinVerification() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        let good = try account.coin(100_000)
        let change = try account.change()
        let plan = { (coins: [UTXOCoin]) in
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: Self.intent(.exact(10_000), change: change), network: Self.state(coins)
            )
        }
        // O provedor diz que a moeda vale 10x mais e entrega a transacao "corrigida".
        var inflated = try UTXOTransaction(parsing: good.previousTransaction)
        inflated.outputs[0].value = 1_000_000
        let lie = UTXOCoin(outpoint: good.outpoint, previousTransaction: inflated.serialized(), confirmations: 6, path: good.path, publicKey: good.publicKey)
        #expect(throws: UTXOPlanError.previousTransactionMismatch(good.outpoint)) { try plan([lie]) }

        // Chave que nao e a do script.
        let wrongKey = UTXOCoin(outpoint: good.outpoint, previousTransaction: good.previousTransaction, confirmations: 6,
                                path: good.path, publicKey: try account.publicKey(0, 7))
        #expect(throws: UTXOPlanError.coinNotOurs(good.outpoint)) { try plan([wrongKey]) }

        // Caminho de BIP-44 para um script P2WPKH, e caminho de outra moeda (coin type).
        let legacyPath = UTXOCoin(outpoint: good.outpoint, previousTransaction: good.previousTransaction, confirmations: 6,
                                  path: UTXOFixtures.path(44, 0, 0, 0, 0), publicKey: good.publicKey)
        #expect(throws: UTXOPlanError.badDerivationPath(UTXOFixtures.path(44, 0, 0, 0, 0))) { try plan([legacyPath]) }
        let otherCoinType = UTXOCoin(outpoint: good.outpoint, previousTransaction: good.previousTransaction, confirmations: 6,
                                     path: UTXOFixtures.path(84, 2, 0, 0, 0), publicKey: good.publicKey)
        #expect(throws: UTXOPlanError.badDerivationPath(UTXOFixtures.path(84, 2, 0, 0, 0))) { try plan([otherCoinType]) }

        #expect(throws: UTXOPlanError.duplicateCoin(good.outpoint)) { try plan([good, good]) }

        // Saida P2TR: a carteira nao assina ainda.
        var taproot = try UTXOTransaction(parsing: good.previousTransaction)
        taproot.outputs[0].scriptPubKey = UTXOScript.p2tr([UInt8](repeating: 7, count: 32))
        let trOutpoint = UTXOOutpoint(txid: taproot.txid, vout: 0)
        let tr = UTXOCoin(outpoint: trOutpoint, previousTransaction: taproot.serialized(), confirmations: 6, path: good.path, publicKey: good.publicKey)
        #expect(throws: UTXOPlanError.unsupportedCoinType(trOutpoint)) { try plan([tr]) }

        // Moedas inventadas: cada uma dentro do MAX_MONEY, a soma nao.
        let maxMoney = UInt64(21_000_000) * 100_000_000
        let fake = try (0..<3).map { try account.coin(maxMoney, index: UInt32($0)) }
        #expect(throws: UTXOPlanError.balanceOutOfRange) { try plan(fake) }
        #expect(throws: UTXOPlanError.coinValueOutOfRange(try account.coin(maxMoney + 1).outpoint)) { try plan([try account.coin(maxMoney + 1)]) }

        // Moedas de duas contas no mesmo envio.
        let other = try UTXOTestAccount(.bitcoin, purpose: 84, account: 1)
        #expect(throws: UTXOPlanError.mixedAccounts) { try plan([good, try other.coin(50_000)]) }

        // Moeda escolhida a mao que nao esta no estado.
        let ghost = UTXOOutpoint(txid: UTXOTxID(bytes: [UInt8](repeating: 1, count: 32))!, vout: 0)
        #expect(throws: UTXOPlanError.coinControlUnknown(ghost)) {
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: Self.intent(.all, change: nil, coinControl: [ghost]), network: Self.state([good])
            )
        }
    }

    @Test("Troco: caminho, chave, xpub e endereco tem de fechar")
    func changeVerification() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        let coins = [try account.coin(100_000)]
        let plan = { (change: UTXOChangeAddress?) in
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: Self.intent(.exact(10_000), change: change), network: Self.state(coins)
            )
        }
        let good = try account.change(3)
        _ = try plan(good)
        #expect(throws: UTXOPlanError.changeRequired) { try plan(nil) }

        // Endereco de outra chave com o caminho e a chave certos.
        let otherAddress = UTXOChangeAddress(address: Self.destination, path: good.path, publicKey: good.publicKey, accountKey: good.accountKey)
        #expect(throws: UTXOPlanError.changeNotOurs) { try plan(otherAddress) }
        // Chave que nao sai da xpub no caminho dito.
        let wrongIndex = UTXOChangeAddress(address: try account.address(1, 4), path: good.path, publicKey: try account.publicKey(1, 4), accountKey: good.accountKey)
        #expect(throws: UTXOPlanError.changeNotOurs) { try plan(wrongIndex) }
        // Cadeia 0: troco tem de ir para a cadeia interna.
        let external = UTXOChangeAddress(address: try account.address(0, 3), path: account.path(0, 3), publicKey: try account.publicKey(0, 3), accountKey: good.accountKey)
        #expect(throws: UTXOPlanError.changeNotOurs) { try plan(external) }
        // Uma xpub qualquer, coerente com o proprio troco, mas que nao gera as moedas
        // gastas: o troco iria para uma carteira que o assinador nunca viu.
        let stranger = try UTXOTestAccount(.bitcoin, purpose: 84, seed: "outra carteira")
        #expect(throws: UTXOPlanError.changeNotOurs) { try plan(try stranger.change(0)) }
        // Troco numa conta sem moedas conferidas.
        let otherAccount = try UTXOTestAccount(.bitcoin, purpose: 84, account: 1)
        #expect(throws: UTXOPlanError.changeAccountNotSpent) { try plan(try otherAccount.change(0)) }
    }

    @Test("Valor: zero, abaixo do dust, acima do saldo, destino invalido ou de outra rede")
    func amountAndDestination() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        let coins = [try account.coin(100_000)]
        let change = try account.change()
        let plan = { (amount: BigUInt, address: String) in
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: Self.intent(.exact(amount), to: address, change: change), network: Self.state(coins)
            )
        }
        #expect(throws: UTXOPlanError.amountZero) { try plan(0, Self.destination) }
        #expect(throws: UTXOPlanError.amountBelowDust(minimum: 294)) { try plan(293, Self.destination) }
        // P2PKH tem dust maior.
        #expect(throws: UTXOPlanError.amountBelowDust(minimum: 546)) { try plan(545, "1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo") }
        _ = try plan(294, Self.destination)
        #expect(throws: UTXOPlanError.insufficientFunds(available: 99_660, required: 100_210)) { try plan(100_000, Self.destination) }
        #expect(throws: UTXOPlanError.amountAboveMaximum) { try plan(BigUInt(21_000_001) * 100_000_000, Self.destination) }
        #expect(throws: UTXOPlanError.invalidDestination(.badChecksum)) { try plan(10_000, "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5") }
        #expect(throws: UTXOPlanError.invalidDestination(.otherNetwork(.litecoin))) { try plan(10_000, "ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh") }
        #expect(throws: UTXOPlanError.invalidDestination(.unsupportedType)) { try plan(10_000, "bc1zw508d6qejxtdg4y5r3zarvaryvaxxpcs") }
        // Taproot e P2WSH sao destinos validos.
        _ = try plan(10_000, "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0")
        _ = try plan(10_000, "bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3")
        // Altura invalida.
        #expect(throws: UTXOPlanError.invalidTipHeight) {
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin, intent: Self.intent(.exact(10_000), change: change),
                network: UTXONetworkState(coins: coins, feeEstimates: [Self.rate(8), Self.rate(6)], tipHeight: 500_000_000)
            )
        }
        #expect(throws: UTXOPlanError.wrongFamily) {
            try UTXOPlanner.planSend(walletID: Self.wallet, chain: .ethereum, intent: Self.intent(.exact(10_000), change: change), network: Self.state(coins))
        }
    }

    @Test("Avisos de primeiro envio e de endereco parecido")
    func addressWarnings() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        let coins = [try account.coin(100_000)]
        let change = try account.change()
        let plan = { (known: [String]?) in
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: Self.intent(.exact(50_000), change: change, known: known), network: Self.state(coins)
            )
        }
        #expect(try plan(nil).review.warnings.isEmpty)
        #expect(try plan([Self.destination]).review.warnings.isEmpty)
        #expect(try plan([]).review.warnings == [.firstSendToAddress])
        // Mesmos 4 primeiros e 4 ultimos depois de "bc1q", meio diferente.
        let lookalike = "bc1qw508zzzzzzzzzzzzzzzzzzzzzzzzzzzzv8f3t4"
        #expect(try plan([lookalike]).review.warnings == [.firstSendToAddress, .lookalikeAddress(known: lookalike)])
    }

    @Test("Litecoin P2WPKH: envio assinado de ponta a ponta")
    func litecoin() throws {
        let account = try UTXOTestAccount(.litecoin, purpose: 84)
        let destination = try UTXOTestAccount(.litecoin, purpose: 84, seed: "destino").address(0, 0)
        #expect(destination.hasPrefix("ltc1q"))
        let coins = [try account.coin(5_000_000, index: 0), try account.coin(3_000_000, index: 1)]
        let plan = try UTXOPlanner.planSend(
            walletID: Self.wallet, chain: .litecoin,
            intent: Self.intent(.exact(6_000_000), to: destination, rate: 2, change: account.change()),
            network: Self.state(coins, estimates: [2, 3])
        )
        #expect(plan.review.title == "Enviar 0,06 LTC")
        #expect(plan.review.lines.first { $0.label == "Rede" }?.value == "Litecoin")
        let (signed, tx) = try account.sign(plan)
        #expect(signed.chainID == "litecoin")
        let parsed = try Self.checkSigned(signed, tx, rate: Self.rate(2))
        #expect(parsed.inputs.count == 2)
        #expect(parsed.inputs.allSatisfy { $0.witness.count == 2 && $0.scriptSig.isEmpty })
    }

    @Test("Dogecoin P2PKH: versao 1, sighash legado, taxa em DOGE/kB, dust de 0,01 DOGE")
    func dogecoin() throws {
        let account = try UTXOTestAccount(.dogecoin, purpose: 44)
        let destination = try UTXOTestAccount(.dogecoin, purpose: 44, seed: "destino").address(0, 0)
        #expect(destination.hasPrefix("D"))
        let coins = [try account.coin(50 * 100_000_000, index: 0), try account.coin(900_000, index: 1), try account.coin(20 * 100_000_000, index: 2)]
        let dogeRate = UTXOFeeRate(satPerKvB: 1_000_000)  // 0,01 DOGE/kB
        let intent = UTXOSendIntent(
            destination: .init(address: destination, tag: nil), amount: .exact(BigUInt(60) * 100_000_000),
            feeRate: dogeRate, change: try account.change()
        )
        let network = UTXONetworkState(coins: coins, feeEstimates: [dogeRate, UTXOFeeRate(satPerKvB: 2_000_000)], tipHeight: 6_389_697)
        let plan = try UTXOPlanner.planSend(walletID: Self.wallet, chain: .dogecoin, intent: intent, network: network)
        #expect(plan.review.title == "Enviar 60 DOGE")
        #expect(plan.review.lines.first { $0.label == "Taxa" }?.value.hasSuffix("(0,01 DOGE/kB)") == true)
        let (signed, tx) = try account.sign(plan)
        let parsed = try UTXOTransaction(parsing: signed.raw)
        #expect(parsed.version == 1)
        #expect(!parsed.hasWitness)
        #expect(parsed.lockTime == 6_389_697)
        // A moeda de 0,009 DOGE esta abaixo do dust de 0,01 e fica de fora.
        #expect(!tx.spends.contains { $0.value == 900_000 })
        #expect(tx.spends.allSatisfy { $0.kind == .p2pkh })
        // 2 entradas P2PKH e 2 saidas P2PKH: 374 bytes a 1.000 koinu/B.
        #expect(tx.summary?.fee == 374_000)
        for (index, input) in parsed.inputs.enumerated() {
            let pushes = try UTXOSighashTests.pushes(input.scriptSig)
            let digest = UTXOSighash.legacy(transaction: parsed, inputIndex: index, scriptCode: UTXOScript.p2pkh(Hash.hash160(pushes[1])), hashType: 1)
            #expect(Secp256k1.verifyDER(signature: Array(pushes[0].dropLast()), digest: digest, publicKey: pushes[1]))
        }
        // Dogecoin nao aceita piso de Bitcoin: 1 sat/vB e 0,00001 DOGE/kB.
        #expect(throws: UTXOPlanError.feeRateBelowMinimum(minimum: dogeRate)) {
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .dogecoin,
                intent: UTXOSendIntent(destination: .init(address: destination, tag: nil), amount: .exact(100_000_000), feeRate: Self.rate(1), change: try account.change()),
                network: network
            )
        }
    }

    @Test("Mesma entrada, mesma transacao: o plano e deterministico")
    func deterministic() throws {
        let account = try UTXOTestAccount(.bitcoin, purpose: 84)
        let coins = (0..<8).map { try! account.coin(UInt64(10_000 + $0 * 7_919), index: UInt32($0)) }
        let make = {
            try UTXOPlanner.planSend(
                walletID: Self.wallet, chain: .bitcoin,
                intent: Self.intent(.exact(45_000), change: account.change()), network: Self.state(coins.reversed())
            )
        }
        let a = try #require(try make().transactions.first as? UTXOSignableTransaction)
        let b = try #require(try make().transactions.first as? UTXOSignableTransaction)
        #expect(a.unsigned == b.unsigned)
        #expect(a.signingRequests == b.signingRequests)
        // BIP-69: entradas em ordem de txid.
        let ids = a.unsigned.inputs.map(\.outpoint.txid.hex)
        #expect(ids == ids.sorted())
    }
}

@Suite("UTXO selecao de moedas")
struct UTXOCoinSelectionTests {
    static func coin(_ id: Int, _ value: UInt64, fee: UInt64 = 68, longTerm: UInt64 = 68) -> UTXOSelectionCoin {
        UTXOSelectionCoin(id: id, value: value, fee: fee, longTermFee: longTerm)
    }

    @Test("Branch and Bound acha a combinacao exata entre muitas")
    func bnbExact() {
        // Alvo 60.000 de valor efetivo: so 10.068 + 50.068 fecha dentro de custo de troco 100.
        let coins = [Self.coin(0, 30_068), Self.coin(1, 10_068), Self.coin(2, 50_068), Self.coin(3, 25_068), Self.coin(4, 70_068)]
        let p = UTXOSelectionParameters(target: 60_000, changeOutputFee: 31, costOfChange: 100, minViableChange: 294)
        let result = UTXOCoinSelection.branchAndBound(coins, p)
        #expect(result?.ids == [1, 2])
        #expect(result?.withChange == false)
        #expect(UTXOCoinSelection.select(coins, p)?.ids == [1, 2])
    }

    @Test("Sem combinacao exata, prefere menos desperdicio; com taxa alta, menos entradas")
    func wastePrefersFewerInputsAtHighFee() {
        // Taxa atual 10x a de longo prazo: cada entrada a mais pesa no desperdicio.
        let coins = [Self.coin(0, 120_000, fee: 680, longTerm: 68), Self.coin(1, 40_000, fee: 680, longTerm: 68), Self.coin(2, 45_000, fee: 680, longTerm: 68)]
        let p = UTXOSelectionParameters(target: 70_000, changeOutputFee: 310, costOfChange: 990, minViableChange: 681)
        let result = UTXOCoinSelection.select(coins, p)
        #expect(result?.ids == [0])
        #expect(result?.withChange == true)
    }

    @Test("Com taxa baixa, consolidar pode desperdicar menos")
    func wasteAtLowFee() {
        // Taxa atual abaixo da de longo prazo: gastar entradas agora e economia, e a
        // selecao aceita a exata de duas moedas.
        let coins = [Self.coin(0, 200_000, fee: 68, longTerm: 680), Self.coin(1, 30_068, fee: 68, longTerm: 680), Self.coin(2, 40_068, fee: 68, longTerm: 680)]
        let p = UTXOSelectionParameters(target: 70_000, changeOutputFee: 31, costOfChange: 99, minViableChange: 294)
        let result = UTXOCoinSelection.select(coins, p)
        #expect(result?.ids == [1, 2])
        #expect(result?.withChange == false)
    }

    @Test("Moeda que nao paga a propria entrada nunca e escolhida; saldo insuficiente devolve nil")
    func uneconomicAndInsufficient() {
        let coins = [Self.coin(0, 60, fee: 68), Self.coin(1, 50_000)]
        let p = UTXOSelectionParameters(target: 49_000, changeOutputFee: 31, costOfChange: 100, minViableChange: 294)
        #expect(UTXOCoinSelection.select(coins, p)?.ids == [1])
        let big = UTXOSelectionParameters(target: 60_000, changeOutputFee: 31, costOfChange: 100, minViableChange: 294)
        #expect(UTXOCoinSelection.select(coins, big) == nil)
    }

    @Test("Paga mas o troco nao sairia viavel: sem troco, sobra vira taxa")
    func fallbackWithoutChange() {
        let coins = [Self.coin(0, 49_268)]
        // Efetivo 49.200: passa do alvo em 200, acima do custo de troco (100), mas o
        // troco viavel pediria 49.000 + 31 + 294.
        let p = UTXOSelectionParameters(target: 49_000, changeOutputFee: 31, costOfChange: 100, minViableChange: 294)
        let result = UTXOCoinSelection.select(coins, p)
        #expect(result?.ids == [0])
        #expect(result?.withChange == false)
    }
}
