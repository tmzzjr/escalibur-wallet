import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines

/// O motor de envio da Tron contra as respostas gravadas (Fixtures/tron), sem rede.
@Suite("Motor Tron: destino, maximo e plano")
struct TronSendEngineTests {
    typealias R = TronRecorded

    @Test("Registro: envio e historico na Tron, troca fora da v1")
    func registry() {
        #expect(SendEngines.engine(for: .tron) is TronSendEngine)
        #expect(ActivitySources.source(for: .tron) is TronActivitySource)
        #expect(TradeEngines.engine(for: .tron) == nil)
        #expect(!TradeEngines.chains.contains(.tron))
    }

    // MARK: Destino

    @Test("Destino ativo e comum: existe, sem minimo de ativacao, sem nota")
    func activeDestination() async throws {
        let info = try await R.engine(try R.Transport()).destination(R.destination, chain: .tron)
        #expect(info.exists)
        #expect(!info.isContract)
        #expect(!info.requiresTag)
        #expect(info.activationMinimum == nil)
        #expect(info.note == nil)
    }

    @Test("Destino que a rede nao conhece: a ativacao, pelos parametros lidos da rede")
    func unfundedDestination() async throws {
        let info = try await R.engine(try R.Transport()).destination(R.unfunded, chain: .tron)
        #expect(!info.exists)
        // getCreateNewAccountFeeInSystemContract (1 TRX) mais getCreateAccountFee (0,1 TRX).
        #expect(info.activationMinimum == BigUInt(1_100_000))
        #expect(info.note?.contains("1,1 TRX") == true)
    }

    /// Resposta montada no teste: o getaccount de um contrato traz o proprio endereco e
    /// `type: Contract`. O getcontract e o gravado do USDT.
    @Test("Destino contrato: marcado, com a nota de que TRX nao entra")
    func contractDestination() async throws {
        let contractAccount = R.encode(["address": R.usdtContract, "type": "Contract"])
        let transport = try R.Transport { _, path, body in
            path == "/wallet/getaccount" && body["address"] as? String == R.usdtContract ? contractAccount : nil
        }
        let info = try await R.engine(transport).destination(R.usdtContract, chain: .tron)
        #expect(info.exists)
        #expect(info.isContract)
        #expect(info.note?.contains("contrato") == true)
    }

    @Test("Destino invalido ou de outra rede: frase sem endereco, sem ler a rede")
    func invalidDestination() async throws {
        let transport = try R.Transport()
        let engine = try R.engine(transport)
        await #expect(throws: SendEngineError.message(TronEngineText.address(.otherNetwork(.ethereum)))) {
            _ = try await engine.destination("0x52908400098527886E0F7030069857D2E4169EE7", chain: .tron)
        }
        let broken = String(R.destination.dropLast()) + "c"
        await #expect(throws: SendEngineError.message(TronEngineText.address(.badChecksum))) {
            _ = try await engine.destination(broken, chain: .tron)
        }
        await #expect(throws: SendEngineError.unsupported(.ton)) { _ = try await engine.destination(R.destination, chain: .ton) }
        #expect(transport.requests.isEmpty)
    }

    /// Resposta alterada no teste: um provedor ve o destino, o outro responde `{}`. Sem
    /// terceiro provedor para desempatar, o motor para, em vez de ficar com uma resposta.
    @Test("Provedores discordando do destino: erro, nunca uma resposta so")
    func destinationDisagreement() async throws {
        let empty = try R.data("getaccount-inexistente")
        let transport = try R.Transport { host, path, body in
            host == "trongrid.test" && path == "/wallet/getaccount" && body["address"] as? String == R.destination ? empty : nil
        }
        await #expect(throws: SendEngineError.message(TronEngineText.reader(.providersDisagree(field: "getaccount")))) {
            _ = try await R.engine(transport).destination(R.destination, chain: .tron)
        }
    }

    // MARK: Plano

    @Test("USDT: o plano sai com o destino e o memo pedidos, e a calldata para o destino")
    func usdtPlan() async throws {
        let request = R.request(asset: R.usdt, amount: 1_000_000, memo: "pedido 42")
        let plan = try await R.engine(try R.Transport()).plan(request)
        #expect(plan.review.recipient == R.destination)
        #expect(plan.review.recipientTag == "pedido 42")
        #expect(plan.walletID == request.walletID)
        #expect(plan.review.warnings.contains(.firstSendToAddress))
        let transaction = try #require(plan.transactions.first as? TronTransaction)
        guard case .triggerSmartContract(let owner, let contract, let callValue, let data) = transaction.raw.contract else {
            Issue.record("contrato"); return
        }
        #expect(owner.base58 == R.owner)
        #expect(contract == TRC20.usdt.contract)
        #expect(callValue.isZero)
        let decoded = try #require(TRC20.decodeTransfer(data))
        #expect(decoded.to.base58 == R.destination)
        #expect(decoded.amount == BigUInt(1_000_000))
        #expect(transaction.raw.memo == Array("pedido 42".utf8))
    }

    @Test("TRX: o plano sai com o destino pedido; destino conhecido nao gera aviso de primeiro envio")
    func trxPlan() async throws {
        let request = R.request(asset: R.trx, amount: 2_000_000, known: [R.destination])
        let plan = try await R.engine(try R.Transport()).plan(request)
        #expect(plan.review.recipient == R.destination)
        #expect(plan.review.recipientTag == nil)
        #expect(plan.review.warnings.isEmpty)
        let transaction = try #require(plan.transactions.first as? TronTransaction)
        guard case .transfer(_, let to, let amount) = transaction.raw.contract else { Issue.record("contrato"); return }
        #expect(to.base58 == R.destination)
        #expect(amount == BigUInt(2_000_000))
        #expect(transaction.raw.memo.isEmpty)
    }

    /// Endereco conhecido montado no teste: as mesmas cinco primeiras e cinco ultimas
    /// letras do destino, com o meio trocado. A deteccao compara o texto.
    @Test("Destino parecido com um endereco para onde o dono ja enviou: aviso no plano")
    func lookalikeWarning() async throws {
        let lookalike = String(R.destination.prefix(5)) + String(repeating: "Q", count: 24) + String(R.destination.suffix(5))
        let plan = try await R.engine(try R.Transport()).plan(R.request(asset: R.trx, amount: 2_000_000, known: [lookalike]))
        #expect(plan.review.warnings.contains(.lookalikeAddress(known: lookalike)))
        #expect(plan.review.warnings.contains(.firstSendToAddress))
    }

    /// Resposta alterada no teste: a permissao de dono passa a exigir duas chaves, a
    /// derivada e uma estranha (ver `TronRecorded.splitControlAccount`).
    @Test("Conta com controle dividido: recusa com a frase das permissoes, antes de ler saldo ou energia")
    func splitControlRefused() async throws {
        let split = try R.splitControlAccount()
        let transport = try R.Transport { _, path, body in
            path == "/wallet/getaccount" && body["address"] as? String == R.owner ? split : nil
        }
        let engine = try R.engine(transport)
        for asset in [R.usdt, R.trx] {
            await #expect(throws: SendEngineError.message(TronEngineText.compromised)) {
                _ = try await engine.plan(R.request(asset: asset, amount: 1_000_000))
            }
        }
        #expect(transport.paths(containing: "getnowblock").isEmpty)
        #expect(transport.paths(containing: "triggerconstantcontract").isEmpty)
    }

    /// Resposta alterada no teste: o getaccount do dono volta `{}`, a conta que so recebeu USDT.
    @Test("Conta que a rede nao conhece: USDT pede TRX, TRX diz que a conta nao existe")
    func unactivatedOwner() async throws {
        let empty = try R.data("getaccount-inexistente")
        let transport = try R.Transport { _, path, body in
            path == "/wallet/getaccount" && body["address"] as? String == R.owner ? empty : nil
        }
        let engine = try R.engine(transport)
        await #expect(throws: SendEngineError.message(TronEngineText.usdtWithoutAccount)) {
            _ = try await engine.plan(R.request(asset: R.usdt, amount: 1_000_000))
        }
        await #expect(throws: SendEngineError.message(TronEngineText.ownerNotActivated)) {
            _ = try await engine.plan(R.request(asset: R.trx, amount: 1_000_000))
        }
    }

    @Test("Conta cuja chave nao da o endereco guardado: nada e lido nem montado")
    func keyMismatch() async throws {
        let transport = try R.Transport()
        let request = SendRequest(
            walletID: UUID(), chain: .tron, asset: R.trx, account: R.account(address: R.destination), destination: R.unfunded,
            tag: nil, amount: 1_000_000, sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
        await #expect(throws: SendEngineError.message(TronEngineText.keyMismatch)) { _ = try await R.engine(transport).plan(request) }
        #expect(transport.requests.isEmpty)
    }

    @Test("Token fora da lista: recusado antes de ler a rede")
    func unsupportedToken() async throws {
        let fake = Asset(chainID: "tron", kind: .token(contract: "TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj"), symbol: "USDT", name: "Tether",
                         decimals: 6, coingeckoID: nil, isStablecoin: true)
        let transport = try R.Transport()
        await #expect(throws: SendEngineError.message(TronEngineText.unsupportedAsset)) {
            _ = try await R.engine(transport).plan(R.request(asset: fake, amount: 1))
        }
        #expect(transport.requests.isEmpty)
    }

    /// Resposta alterada no teste: a simulacao do `transfer` volta a reversao gravada.
    @Test("Simulacao do USDT revertida: recusa antes de montar, sem queimar energia a toa")
    func revertedSimulation() async throws {
        let reverted = try R.data("transfer-revert")
        let transport = try R.Transport { _, path, body in
            path == "/wallet/triggerconstantcontract" && body["function_selector"] as? String == "transfer(address,uint256)" ? reverted : nil
        }
        await #expect(throws: SendEngineError.message(TronEngineText.reader(.executionReverted))) {
            _ = try await R.engine(transport).plan(R.request(asset: R.usdt, amount: 1_000_000))
        }
    }

    @Test("Saldo curto: a frase nao traz valor")
    func insufficient() async throws {
        await #expect(throws: SendEngineError.message(TronEngineText.insufficientTRX)) {
            _ = try await R.engine(try R.Transport()).plan(R.request(asset: R.trx, amount: BigUInt(9_000_000_000_000_000)))
        }
    }

    // MARK: Maximo

    @Test("TRX com stake e destino ativo: nada queimado, o maximo e o saldo")
    func trxSpendableCovered() async throws {
        let spendable = try await R.engine(try R.Transport()).spendable(R.request(asset: R.trx, amount: 0, sendAll: true))
        #expect(spendable.amount == BigUInt(5_178_080_212_471))
        #expect(spendable.feeNote == TronEngineText.trxFee(burn: 0, activates: false, memo: false))
    }

    /// Resposta alterada no teste: `getaccountresource` volta `{}` (sem stake, cota gasta).
    @Test("TRX para conta nova, sem recursos: o maximo e exatamente o limite do planejador")
    func trxSpendableMatchesPlanner() async throws {
        let transport = try R.Transport { _, path, _ in path == "/wallet/getaccountresource" ? R.noResources : nil }
        let engine = try R.engine(transport)
        let spendable = try await engine.spendable(R.request(asset: R.trx, to: R.unfunded, amount: 0, sendAll: true))
        // Ativacao: 1 TRX da conta nova mais 0,1 TRX de banda sem stake.
        #expect(spendable.amount == BigUInt(5_178_080_212_471 - 1_100_000))
        #expect(spendable.feeNote?.contains("ativação da conta de destino") == true)

        let all = try await engine.plan(R.request(asset: R.trx, to: R.unfunded, amount: spendable.amount, sendAll: true))
        guard case .transfer(_, _, let sent) = try #require(all.transactions.first as? TronTransaction).raw.contract else {
            Issue.record("contrato"); return
        }
        #expect(sent == spendable.amount)
        await #expect(throws: SendEngineError.message(TronEngineText.insufficientTRX)) {
            _ = try await engine.plan(R.request(asset: R.trx, to: R.unfunded, amount: spendable.amount + 1))
        }
    }

    @Test("Maximo: o plano nunca manda mais do que o valor que o dono viu")
    func sendAllNeverAboveRequest() async throws {
        let engine = try R.engine(try R.Transport())
        let plan = try await engine.plan(R.request(asset: R.trx, amount: 3_000_000, sendAll: true))
        guard case .transfer(_, _, let sent) = try #require(plan.transactions.first as? TronTransaction).raw.contract else {
            Issue.record("contrato"); return
        }
        #expect(sent == BigUInt(3_000_000))
    }

    @Test("USDT com stake: o maximo e o saldo de USDT, e a nota diz que o stake cobre")
    func usdtSpendableCovered() async throws {
        let spendable = try await R.engine(try R.Transport()).spendable(R.request(asset: R.usdt, amount: 0, sendAll: true))
        #expect(spendable.amount == BigUInt(37_409_884_001_115))
        #expect(spendable.feeNote == TronEngineText.usdtFee(burn: 0, trxBalance: 1, memo: false))
    }

    /// Resposta alterada no teste: `getaccountresource` volta `{}`.
    @Test("Queima do USDT perguntada ao planejador: com esse TRX ele aceita, com um sun a menos recusa")
    func usdtBurnIsThePlanners() async throws {
        let transport = try R.Transport { _, path, _ in path == "/wallet/getaccountresource" ? R.noResources : nil }
        let reader = TronReader(transport: transport, providers: R.providers)
        let now = try R.blockTime()
        let request = R.request(asset: R.usdt, amount: 1_000_000, memo: "abc")
        let order = try TronSendEngine.Order(request)
        let state = try await reader.networkState(owner: order.owner.address, intent: .usdt(to: order.to, amount: 1_000_000), now: now)
        let burn = try TronSendEngine.burn(order, amount: 1_000_000, state: state, now: now)
        // 64.285 de energia a 100 sun, o memo de 1 TRX e a banda da transacao.
        #expect(burn > BigUInt(6_428_500 + 1_000_000))

        func withTRX(_ trx: BigUInt) -> TronNetworkState {
            TronNetworkState(
                block: state.block, trxBalance: trx, usdtBalance: state.usdtBalance, resources: state.resources,
                parameters: state.parameters, destinationActivated: state.destinationActivated,
                destinationIsContract: state.destinationIsContract, usdtEnergyEstimate: state.usdtEnergyEstimate,
                destinationHoldsUSDT: state.destinationHoldsUSDT, ownerControl: state.ownerControl
            )
        }
        _ = try TronPlanner.planSendUSDT(walletID: order.walletID, owner: order.owner, to: order.to, amount: 1_000_000, memo: "abc", state: withTRX(burn), now: now)
        #expect(throws: TronPlanError.insufficientTRXForFees(needed: burn, available: burn - 1)) {
            _ = try TronPlanner.planSendUSDT(
                walletID: order.walletID, owner: order.owner, to: order.to, amount: 1_000_000, memo: "abc", state: withTRX(burn - 1), now: now
            )
        }
        let spendable = try await R.engine(transport).spendable(request)
        #expect(spendable.feeNote == TronEngineText.usdtFee(burn: burn, trxBalance: state.trxBalance, memo: true))
    }

    // MARK: Frases

    @Test("Nenhuma frase de erro traz numero, endereco ou travessao")
    func messagesCarryNoData() {
        let planner: [TronPlanError] = [
            .invalidOwnerKey, .ownerKeyMismatch, .invalidBlockReference, .parameterOutOfRange("energyPrice"), .controlForOtherAccount,
            .accountCompromised([]), .ownerNotActivated, .invalidDestination(.badChecksum), .invalidDestination(.otherNetwork(.bitcoin)),
            .destinationIsOwner, .destinationIsTokenContract, .destinationIsBurnAddress, .destinationIsContract, .zeroAmount,
            .amountTooLarge, .memoTooLong(maxBytes: 256), .insufficientTRX(needed: 123_456_789, available: 987),
            .insufficientUSDT(needed: 5_000_000, available: 1), .noTRXForFees(needed: 13_000_000),
            .insufficientTRXForFees(needed: 7_000_000, available: 2), .missingEnergyEstimate, .energyEstimateOutOfRange(999_999),
            .feeLimitAboveCeiling(101_000_000),
        ]
        let reader: [ReaderError] = [
            .malformed(field: "x"), .providerError(code: "SIGERROR"), .notEnoughProviders(needed: 2, got: 1),
            .providersDisagree(field: "x"), .wrongNetwork, .implausibleValue(field: "x"), .responseMismatch(field: "x"),
            .accountNotFound, .executionReverted, .unsupported("x"), .broadcastMismatch, .invalidInput("destino"),
            .broadcastRejected(.insufficientFunds, code: "BANDWITH_ERROR"),
        ]
        var texts = planner.map(TronEngineText.planner) + reader.map(TronEngineText.reader)
        texts += [BroadcastRejection.expired, .invalidSignature, .other].map(TronEngineText.rejected)
        texts += [
            TronEngineText.compromised, TronEngineText.usdtWithoutAccount, TronEngineText.keyMismatch, TronEngineText.planMismatch,
            TronEngineText.notOurTransaction, TronEngineText.broadcastUnconfirmed, TronEngineText.historyFailure,
            TronEngineText.failure("expired"), TronEngineText.failure("OUT_OF_ENERGY"), TronEngineText.failure("REVERT"),
        ]
        for text in texts {
            #expect(!text.contains { $0.isNumber }, "\(text)")
            #expect(!text.contains("—") && !text.contains("–"), "\(text)")
            #expect(!text.contains(R.owner) && !text.contains("SIGERROR"), "\(text)")
        }
    }

    @Test("Valores das notas no padrao da carteira")
    func numbers() {
        #expect(TronEngineText.trx(1_100_000) == "1,1 TRX")
        #expect(TronEngineText.trx(5_178_080_212_471) == "5.178.080,212471 TRX")
        #expect(TronEngineText.trx(0) == "0 TRX")
        #expect(TronEngineText.trx(7) == "0,000007 TRX")
        #expect(TronEngineText.units(1_000_000, decimals: 0) == "1.000.000")
    }
}
