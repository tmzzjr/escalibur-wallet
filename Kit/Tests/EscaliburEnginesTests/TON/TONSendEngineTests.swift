import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines

/// O motor de envio da TON contra as respostas gravadas (Fixtures/ton), sem rede.
@Suite("Motor TON: destino, maximo e plano")
struct TONSendEngineTests {
    typealias R = TONRecorded

    @Test("Registro: envio e historico na TON, troca fora da v1")
    func registry() {
        #expect(SendEngines.engine(for: .ton) is TONSendEngine)
        #expect(ActivitySources.source(for: .ton) is TONActivitySource)
        #expect(TradeEngines.engine(for: .ton) == nil)
    }

    // MARK: Destino

    @Test("Destino: ativo, nao inicializado e contrato do token")
    func destinations() async throws {
        let engine = R.engine(try R.Transport())
        let active = try await engine.destination(R.activeDestination.friendly(bounceable: true), chain: .ton)
        #expect(active.exists && !active.isContract && active.note == nil && active.activationMinimum == nil)

        let fresh = try await engine.destination(R.uninitializedDestination.friendly(bounceable: false), chain: .ton)
        #expect(!fresh.exists && !fresh.isContract)
        #expect(fresh.note == TONEngineText.destinationNote(status: .uninitialized, tokenContract: false))

        let master = try await engine.destination("EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs", chain: .ton)
        #expect(master.isContract)
        #expect(master.note == TONEngineText.tokenContract)
    }

    @Test("Destino invalido ou de rede de teste: frase sem endereco, sem ler a rede")
    func invalidDestination() async throws {
        let transport = try R.Transport()
        let engine = R.engine(transport)
        let testnet = R.activeDestination.friendly(bounceable: false, testnet: true)
        await #expect(throws: SendEngineError.message(TONEngineText.address(.unsupportedType))) {
            _ = try await engine.destination(testnet, chain: .ton)
        }
        await #expect(throws: SendEngineError.message(TONEngineText.address(.otherNetwork(.tron)))) {
            _ = try await engine.destination("TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb", chain: .ton)
        }
        #expect(transport.requests.isEmpty)
    }

    // MARK: Plano

    static func transfer(_ plan: SigningPlan) throws -> TONTransfer {
        try #require(plan.transactions.first as? TONTransfer)
    }

    @Test("TON: destino e comentario do plano sao os pedidos; o bounce segue a grafia e o estado do destino")
    func tonPlanBounce() async throws {
        let engine = R.engine(try R.Transport())
        let cases: [(String, Bool)] = [
            (R.activeDestination.friendly(bounceable: false), false),
            (R.activeDestination.friendly(bounceable: true), true),
            (R.activeDestination.raw, true),
            (R.uninitializedDestination.friendly(bounceable: true), false),
        ]
        for (typed, bounce) in cases {
            let plan = try await engine.plan(R.request(asset: R.ton, to: typed, amount: 1_000_000_000, comment: "fatura 7"))
            #expect(Address.sameRecipient(plan.review.recipient, typed, chain: .ton))
            #expect(plan.review.recipientTag == "fatura 7")
            let transfer = try Self.transfer(plan)
            #expect(transfer.messages.count == 1)
            #expect(transfer.messages[0].bounce == bounce, "\(typed)")
            #expect(transfer.messages[0].amount == BigUInt(1_000_000_000))
            #expect(try TONComment.text(of: try #require(transfer.messages[0].body)) == "fatura 7")
            #expect(transfer.seqno == 63_846)
            #expect(transfer.validUntil == UInt32(R.now.timeIntervalSince1970 + TONPlanner.validitySeconds))
        }
    }

    @Test("USDT: a mensagem vai para a carteira jetton do dono, com o corpo transfer para o destino pedido")
    func usdtPlan() async throws {
        let typed = R.activeDestination.friendly(bounceable: false)
        let plan = try await R.engine(try R.Transport()).plan(R.request(asset: R.usdt, to: typed, amount: 2_500_000, comment: "pedido 9"))
        #expect(Address.sameRecipient(plan.review.recipient, typed, chain: .ton))
        #expect(plan.review.recipientTag == "pedido 9")
        #expect(plan.review.warnings.contains(.firstSendToAddress))
        let message = try Self.transfer(plan).messages[0]
        #expect(message.destination.raw == R.ownerJettonWallet)
        #expect(message.amount == TONJetton.attachedTON)
        #expect(message.bounce)
        let expected = try TONJetton.transferBody(
            queryID: UInt64(R.now.timeIntervalSince1970), amount: 2_500_000, destination: R.activeDestination,
            responseDestination: R.wallet.address, forwardTON: TONJetton.forwardTON, comment: "pedido 9"
        )
        #expect(message.body == expected)
    }

    /// Endereco conhecido montado no teste: a grafia raw do destino com o meio trocado.
    @Test("Destino parecido com um conhecido: aviso; destino conhecido: sem aviso de primeiro envio")
    func warnings() async throws {
        let engine = R.engine(try R.Transport())
        let raw = R.activeDestination.raw
        let lookalike = String(raw.prefix(8)) + String(repeating: "0", count: raw.count - 14) + String(raw.suffix(6))
        let flagged = try await engine.plan(R.request(asset: R.ton, to: raw, amount: 1_000, known: [lookalike]))
        #expect(flagged.review.warnings.contains(.lookalikeAddress(known: lookalike)))
        let known = try await engine.plan(R.request(asset: R.ton, to: raw, amount: 1_000, known: [R.activeDestination.friendly(bounceable: true)]))
        #expect(!known.review.warnings.contains(.firstSendToAddress))
    }

    @Test("Comentario com espaco na ponta ou caractere invisivel: recusado com a frase do planejador")
    func badComments() async throws {
        let engine = R.engine(try R.Transport())
        await #expect(throws: SendEngineError.message(TONEngineText.planner(.commentHasSurroundingSpaces, coin: .ton))) {
            _ = try await engine.plan(R.request(asset: R.ton, amount: 1_000, comment: "memo "))
        }
        await #expect(throws: SendEngineError.message(TONEngineText.planner(.commentHasControlCharacters, coin: .ton))) {
            _ = try await engine.plan(R.request(asset: R.ton, amount: 1_000, comment: "me\u{200B}mo"))
        }
    }

    @Test("Carteira: a versao e a que da o endereco guardado; chave de outro endereco e recusada sem ler a rede")
    func walletVersion() async throws {
        let w5 = try TONWallet(publicKey: R.ownerKey, version: .v5r1)
        #expect(try TONSendEngine.wallet(of: R.account(address: w5.address.friendly(bounceable: false))).version == .v5r1)
        #expect(try TONSendEngine.wallet(of: R.account()).version == .v4r2)

        let transport = try R.Transport()
        let stranger = SendRequest(
            walletID: UUID(), chain: .ton, asset: R.ton, account: R.account(address: R.activeDestination.friendly(bounceable: false)),
            destination: R.uninitializedDestination.raw, tag: nil, amount: 1_000, sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
        await #expect(throws: SendEngineError.message(TONEngineText.keyMismatch)) { _ = try await R.engine(transport).plan(stranger) }
        #expect(transport.requests.isEmpty)
    }

    @Test("Saldo curto: TON para o valor, TON para a taxa do USDT e USDT, cada um com a sua frase")
    func insufficient() async throws {
        let engine = R.engine(try R.Transport())
        await #expect(throws: SendEngineError.message(TONEngineText.insufficientTON)) {
            _ = try await engine.plan(R.request(asset: R.ton, amount: R.ownerBalance))
        }
        await #expect(throws: SendEngineError.message(TONEngineText.planner(.insufficientTokenBalance(needed: 1, available: 0), coin: .usdt))) {
            _ = try await engine.plan(R.request(asset: R.usdt, amount: R.jettonBalance + 1))
        }
        // Resposta alterada no teste: a carteira do dono com 0,01 TON, menos que os 0,05
        // anexados ao envio de USDT.
        let poor = Data("""
        {"ok":true,"result":{"@type":"raw.fullAccountState","balance":"10000000","code":"\(try Self.recordedCode())","data":"","frozen_hash":"","state":"active"}}
        """.utf8)
        let transport = try R.Transport { _, _, method, params in
            method == "getAddressInformation" && params["address"] as? String == R.wallet.address.raw ? poor : nil
        }
        await #expect(throws: SendEngineError.message(TONEngineText.usdtNeedsTON)) {
            _ = try await R.engine(transport).plan(R.request(asset: R.usdt, amount: 1_000_000))
        }
    }

    static func recordedCode() throws -> String {
        let object = try JSONSerialization.jsonObject(with: try R.data("getAddressInformation-dono")) as? [String: Any]
        return try #require((object?["result"] as? [String: Any])?["code"] as? String)
    }

    // MARK: Maximo

    @Test("TON: o maximo deixa uma taxa de folga, e o plano do maximo passa")
    func tonSpendable() async throws {
        let engine = R.engine(try R.Transport())
        let spendable = try await engine.spendable(R.request(asset: R.ton, amount: R.ownerBalance, sendAll: true))
        #expect(spendable.amount == R.ownerBalance - R.estimatedFee - R.estimatedFee)
        #expect(spendable.feeNote == TONEngineText.tonFee(R.estimatedFee, activatesWallet: false))
        #expect(spendable.reserveNote == TONEngineText.margin(R.estimatedFee))
        let plan = try await engine.plan(R.request(asset: R.ton, amount: spendable.amount, sendAll: true))
        #expect(try Self.transfer(plan).messages[0].amount == spendable.amount)
        // Pedido acima do maximo, com "enviar tudo": sai o maximo, nunca mais.
        let capped = try await engine.plan(R.request(asset: R.ton, amount: R.ownerBalance, sendAll: true))
        #expect(try Self.transfer(capped).messages[0].amount == spendable.amount)
    }

    @Test("USDT: o maximo e o saldo da carteira jetton; a nota diz quanto TON vai junto")
    func usdtSpendable() async throws {
        let spendable = try await R.engine(try R.Transport()).spendable(R.request(asset: R.usdt, amount: 0, sendAll: true))
        #expect(spendable.amount == R.jettonBalance)
        #expect(spendable.feeNote == TONEngineText.usdtFee(attached: TONJetton.attachedTON, fee: R.estimatedFee, balance: R.ownerBalance))
        #expect(spendable.feeNote?.contains("0,05 TON") == true)
    }

    // MARK: Frases

    @Test("Nenhuma frase de erro traz numero, endereco ou travessao")
    func messagesCarryNoData() {
        let planner: [TONPlanError] = [
            .invalidDestination(.badChecksum), .invalidDestination(.otherNetwork(.ethereum)), .destinationIsSelf,
            .destinationIsTokenContract, .destinationFrozen, .zeroAmount, .insufficientBalance(needed: 123_456, available: 7),
            .insufficientTokenBalance(needed: 9, available: 8), .missingFee, .feeAboveCeiling(fee: 200_000_000, ceiling: 100_000_000),
            .accountFrozen, .inconsistentState, .walletVersionMismatch, .jettonWalletMismatch, .commentTooLong(maxBytes: 1_024),
            .commentHasControlCharacters, .commentHasSurroundingSpaces, .invalidPath,
        ]
        let reader: [ReaderError] = [
            .malformed(field: "x"), .providerError(code: "-13"), .notEnoughProviders(needed: 2, got: 1), .providersDisagree(field: "seqno"),
            .wrongNetwork, .implausibleValue(field: "estimateFee"), .responseMismatch(field: "x"), .accountNotFound,
            .executionReverted, .unsupported("x"), .broadcastMismatch, .invalidInput("comentario"),
            .broadcastRejected(.expired, code: "x"),
        ]
        var texts = planner.map { TONEngineText.planner($0, coin: .ton) } + planner.map { TONEngineText.planner($0, coin: .usdt) }
        texts += reader.map(TONEngineText.reader)
        texts += [BroadcastRejection.insufficientFunds, .invalidSignature, .other].map(TONEngineText.rejected)
        texts += [
            TONEngineText.keyMismatch, TONEngineText.unsupportedAsset, TONEngineText.planMismatch, TONEngineText.notOurTransaction,
            TONEngineText.broadcastUnconfirmed, TONEngineText.historyFailure, TONEngineText.failure("expired"),
            TONEngineText.failure("aborted"),
        ]
        for text in texts {
            #expect(!text.contains { $0.isNumber }, "\(text)")
            #expect(!text.contains("—") && !text.contains("–"), "\(text)")
        }
    }

    @Test("Valores das notas no padrao da carteira")
    func numbers() {
        #expect(TONEngineText.ton(50_000_000) == "0,05 TON")
        #expect(TONEngineText.ton(66_727) == "0,000066727 TON")
        #expect(TONEngineText.ton(96_633_095_889_328) == "96.633,095889328 TON")
    }
}
