import EscaliburChains
import EscaliburCore
import Foundation
import Testing

@Suite("TON transferencia")
struct TONTransferTests {
    // MARK: Vetores da rede principal

    /// Cada vetor e uma transacao que o wallet-core assinou e a rede aceitou. O teste
    /// monta a mesma transferencia, confere que a assinatura publicada verifica sobre
    /// o hash que a Escalibur calcula (a mensagem assinada e byte a byte a mesma), e
    /// que a mensagem externa montada com ela tem o mesmo hash publicado.
    @Test("Transacoes transmitidas pelo wallet-core: V4R2, V5R1, deploy, comentario, jetton")
    func trustWalletVectors() throws {
        let vectors = try TrustWalletVectors.load()
        #expect(vectors.count == 13)
        for vector in vectors {
            let publicKey = try TONTestSupport.publicKey(seed: vector.privateKey)
            let version = try #require(TONWalletVersion(rawValue: vector.version))
            let wallet = try TONWallet(publicKey: publicKey, version: version)
            let expected = try TONTestSupport.boc(base64: vector.boc)
            #expect(expected.hash.hex == vector.hash)

            // O destino da mensagem externa e o endereco que a Escalibur deriva.
            var root = expected.beginParse()
            #expect(try root.loadUInt(bits: 2) == 0b10)
            #expect(try root.loadAddress() == nil)
            #expect(try root.loadAddress() == wallet.address, "\(vector.source)")

            let messages = try vector.messages.map { message -> TONOutgoingMessage in
                var body: TONCell?
                if let comment = message.comment { body = try TONComment.cell(comment) }
                if let jetton = message.jetton {
                    body = try TONJetton.transferBody(
                        queryID: #require(UInt64(jetton.queryId)),
                        amount: #require(BigUInt(decimal: jetton.amount)),
                        destination: TONTestSupport.address(jetton.destination),
                        responseDestination: TONTestSupport.address(jetton.responseDestination),
                        forwardTON: #require(BigUInt(decimal: jetton.forwardTon)),
                        comment: nil
                    )
                }
                return TONOutgoingMessage(
                    destination: try TONTestSupport.address(message.to),
                    amount: try #require(BigUInt(decimal: message.amount)),
                    bounce: message.bounce,
                    body: body
                )
            }
            let transfer = try TONTransfer(
                wallet: wallet, path: DefaultPaths.path(for: .ton), seqno: vector.seqno,
                validUntil: vector.validUntil, messages: messages, mode: vector.mode, deploy: vector.deploy
            )

            let signature = try Self.signature(in: expected, version: version)
            #expect(Ed25519.verify(signature: signature, message: transfer.signingHash, publicKey: publicKey), "\(vector.source)")

            let signed = try transfer.assemble(with: [ProducedSignature(bytes: signature)])
            #expect(signed.id == vector.hash, "\(vector.source)")
            #expect(signed.chainID == "ton")
            #expect(try TONBOC.parseRoot(signed.raw).hash.hex == vector.hash)
            #expect(try TONBOC.parseRoot(base64: signed.encoded).hash.hex == vector.hash)

            let request = try #require(transfer.signingRequests.first)
            #expect(request.curve == .ed25519)
            #expect(request.scheme == .ed25519)
            #expect(request.payload.count == 32)
            #expect(request.expectedPublicKey == publicKey)
        }
    }

    /// A assinatura publicada: nos primeiros 512 bits do corpo (V4R2) ou nos ultimos
    /// (V5R1).
    static func signature(in message: TONCell, version: TONWalletVersion) throws -> [UInt8] {
        let body = try #require(message.refs.last)
        var slice = body.beginParse()
        switch version {
        case .v4r2:
            return try slice.loadBytes(64)
        case .v5r1:
            _ = try slice.loadBigUInt(bits: body.bitCount - 512)
            return try slice.loadBytes(64)
        }
    }

    @Test("Assinatura errada nao e embrulhada")
    func rejectsForeignSignature() throws {
        let seed = "c38f49de2fb13223a9e7d37d5d0ffbdd89a5eb7c8b0ee4d1c299f2cefe7dc4a0"
        let wallet = try TONWallet(publicKey: TONTestSupport.publicKey(seed: seed))
        let message = TONOutgoingMessage(destination: try TONTestSupport.address(TONAddressTests.raw), amount: 10, bounce: false, body: nil)
        let transfer = try TONTransfer(wallet: wallet, path: DefaultPaths.path(for: .ton), seqno: 1, validUntil: 2_000_000_000, messages: [message], deploy: false)
        let other = try TONTestSupport.sign(transfer.signingHash + [0], seed: seed)
        #expect(throws: SigningError.malformedSignature) { try transfer.assemble(with: [ProducedSignature(bytes: other)]) }
        #expect(throws: SigningError.malformedSignature) { try transfer.assemble(with: [ProducedSignature(bytes: [1, 2, 3])]) }
        #expect(throws: SigningError.wrongSignatureCount) { try transfer.assemble(with: []) }
        // W5 sem o +2 no modo: o contrato recusaria (erro 137), entao nem monta.
        let w5 = try TONWallet(publicKey: wallet.publicKey, version: .v5r1)
        #expect(throws: TONCellError.self) {
            try TONTransfer(wallet: w5, path: DefaultPaths.path(for: .ton), seqno: 1, validUntil: 2_000_000_000, messages: [message], mode: 1, deploy: false)
        }
        #expect(throws: TONCellError.self) {
            try TONTransfer(wallet: wallet, path: DefaultPaths.path(for: .ton), seqno: 1, validUntil: 2_000_000_000, messages: [], deploy: false)
        }
    }

    // MARK: Jetton

    @Test("Corpo transfer do USDT com comentario, igual ao ton-core no layout do Tonkeeper")
    func jettonBodyWithComment() throws {
        let vector = try TONCoreVectors.load().jettonTransferWithComment
        let body = try TONJetton.transferBody(
            queryID: #require(UInt64(vector.queryId)),
            amount: #require(BigUInt(decimal: vector.amount)),
            destination: TONTestSupport.address(vector.destination),
            responseDestination: TONTestSupport.address(vector.responseDestination),
            forwardTON: #require(BigUInt(decimal: vector.forwardTon)),
            comment: vector.comment
        )
        #expect(body.hash.hex == vector.hash)
        #expect(TONBOC.serialize(body).hex == vector.boc)
    }

    @Test("Carteira jetton do USDT calculada aqui bate com a da rede")
    func usdtJettonWallet() throws {
        // get_wallet_address no mestre do USDT (toncenter runGetMethod, 25/09/2026).
        #expect(try TONJetton.usdtWallet(owner: TONTestSupport.address("UQDYW_1eScJVxtitoBRksvoV9cCYo4uKGWLVNIHB1JqRRyQx")).raw
            == "0:b9383436299888f2d5e88b91ff4129a49fed2df19546e08d0bd99b4ef66a626a")
        #expect(try TONJetton.usdtWallet(owner: TONTestSupport.address("EQBkQP48aUEDg5Y5RRc8SxFHm_C5tNcJDlh3e9pYHC-ZmG2M")).raw
            == "0:ecefd888957a88992f5699bb19274f29d20adb539e49f31901d91e27da43605f")
        // wallet-core ton_sign_wallet_v5r1.rs, test_ton_sign_wallet_v5r1_transfer_jettons: envio
        // real de 0,12 USDT da carteira W5 UQCh41... pela carteira jetton EQDg4Ajf...
        #expect(try TONJetton.usdtWallet(owner: TONTestSupport.address("UQCh41gQP1A4I0lnAn6yAfitDAIYpXG6UFIXqeSz1TVxNOJ_"))
            == TONTestSupport.address("EQDg4AjfaxQBVsUFueenkKlHLhhYWrcBvCEzbEgfrT0nxuGC"))
        #expect(TONJetton.usdtMaster.friendly(bounceable: true) == "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs")
    }

    // MARK: Planejamento, de ponta a ponta

    static let seed = "3d935b7a8c24e7dc55ef7c0c890806cee3af1174a62165d4d2fb64ccf2e2260b"
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let path = DefaultPaths.path(for: .ton)

    static func state(
        _ status: TONAccountStatus = .active, seqno: UInt32 = 7, balance: BigUInt = 2_000_000_000,
        destination: TONAccountStatus = .active, fee: BigUInt = 5_000_000, codeHash: [UInt8]? = nil
    ) -> TONChainState {
        TONChainState(accountStatus: status, seqno: seqno, balance: balance, codeHash: codeHash, destinationStatus: destination, estimatedFee: fee)
    }

    /// Assina o plano com a chave de teste, monta e le de volta o que iria para a rede.
    static func signAndDecode(_ plan: SigningPlan) throws -> (signed: SignedTransaction, body: TONCell, message: TONCell, hasInit: Bool) {
        let transfer = try #require(plan.transactions.first as? TONTransfer)
        let request = try #require(transfer.signingRequests.first)
        #expect(request.path == path)
        let signature = try TONTestSupport.sign(request.payload, seed: seed)
        let signed = try transfer.assemble(with: [ProducedSignature(bytes: signature)])
        let external = try TONBOC.parseRoot(base64: signed.encoded)
        #expect(external.hash.hex == signed.id)
        var s = external.beginParse()
        _ = try s.loadUInt(bits: 2)
        _ = try s.loadAddress()
        #expect(try s.loadAddress() == transfer.wallet.address)
        #expect(try s.loadCoins() == 0)
        let hasInit = try s.loadBit()
        if hasInit {
            #expect(try s.loadBit())
            #expect(try s.loadRef() == transfer.wallet.stateInit)
        }
        #expect(try s.loadBit())
        let body = try s.loadRef()
        // A assinatura verifica sobre o hash do corpo sem ela.
        var b = body.beginParse()
        let signatureInBody: [UInt8]
        switch transfer.wallet.version {
        case .v4r2:
            signatureInBody = try b.loadBytes(64)
        case .v5r1:
            _ = try b.loadBigUInt(bits: body.bitCount - 512)
            signatureInBody = try b.loadBytes(64)
        }
        #expect(Ed25519.verify(signature: signatureInBody, message: request.payload, publicKey: transfer.wallet.publicKey))
        // A mensagem interna lida do que vai para a rede: na V4R2 e a referencia do
        // corpo; no W5, a segunda referencia do primeiro no da OutList.
        let internalMessage: TONCell
        switch transfer.wallet.version {
        case .v4r2: internalMessage = try #require(body.refs.first)
        case .v5r1: internalMessage = try #require(body.refs.first?.refs.last)
        }
        return (signed, body, internalMessage, hasInit)
    }

    static func decodeInternal(_ cell: TONCell) throws -> (bounce: Bool, to: TONAddress?, amount: BigUInt, body: TONCell) {
        var s = cell.beginParse()
        #expect(try !s.loadBit())
        #expect(try s.loadBit())                       // ihr_disabled
        let bounce = try s.loadBit()
        #expect(try !s.loadBit())
        #expect(try s.loadAddress() == nil)
        let to = try s.loadAddress()
        let amount = try s.loadCoins()
        return (bounce, to, amount, try #require(cell.refs.first))
    }

    @Test("Enviar TON (V4R2): assina com a chave de teste e confere cada campo")
    func planSendTONEndToEnd() throws {
        let wallet = try TONWallet(publicKey: TONTestSupport.publicKey(seed: Self.seed))
        let plan = try TONPlanner.planSendTON(
            walletID: UUID(), wallet: wallet, path: Self.path,
            to: TONAddressTests.bounceable, amount: 1_500_000_000, comment: "pedido 42",
            state: Self.state(), now: Self.now
        )
        #expect(plan.chain == .ton)
        #expect(plan.review.title == "Enviar 1,5 TON")
        #expect(plan.review.lines.contains(PlanReview.Line("Para", TONAddressTests.bounceable, verbatim: true)))
        #expect(plan.review.lines.contains(PlanReview.Line("Comentário", "pedido 42", verbatim: true)))
        #expect(plan.review.lines.contains(PlanReview.Line("Taxa estimada", "0,005 TON")))
        #expect(plan.review.warnings.isEmpty)

        let decoded = try Self.signAndDecode(plan)
        #expect(!decoded.hasInit)
        var body = decoded.body.beginParse()
        _ = try body.loadBytes(64)
        #expect(try body.loadUInt(bits: 32) == 698_983_191)
        #expect(try body.loadUInt(bits: 32) == UInt64(Self.now.timeIntervalSince1970) + 120)
        #expect(try body.loadUInt(bits: 32) == 7)
        #expect(try body.loadUInt(bits: 8) == 0)
        #expect(try body.loadUInt(bits: 8) == 3)
        let internalMessage = try body.loadRef()
        let message = try Self.decodeInternal(internalMessage)
        #expect(message.bounce)                        // EQ... e destino ativo
        #expect(message.to == (try TONTestSupport.address(TONAddressTests.raw)))
        #expect(message.amount == 1_500_000_000)
        #expect(try TONComment.text(of: message.body) == "pedido 42")
    }

    @Test("Enviar TON (W5) de carteira nova: leva o state init e sai sem bounce para UQ")
    func planSendTONV5Deploy() throws {
        let wallet = try TONWallet(publicKey: TONTestSupport.publicKey(seed: Self.seed), version: .v5r1)
        let plan = try TONPlanner.planSendTON(
            walletID: UUID(), wallet: wallet, path: Self.path,
            to: TONAddressTests.nonBounceable, amount: 100_000_000,
            state: Self.state(.uninitialized, seqno: 0, balance: 500_000_000), now: Self.now
        )
        #expect(plan.review.lines.contains { $0.label == "Ativação" })
        #expect(plan.review.lines.contains(PlanReview.Line("Carteira", "W5 (V5R1)")))
        let decoded = try Self.signAndDecode(plan)
        #expect(decoded.hasInit)
        var body = decoded.body.beginParse()
        #expect(try body.loadUInt(bits: 32) == 0x7369_676E)
        #expect(try body.loadUInt(bits: 32) == 2_147_483_409)
        _ = try body.loadUInt(bits: 32)
        #expect(try body.loadUInt(bits: 32) == 0)
        let outList = try #require(try body.loadMaybeRef())
        #expect(try !body.loadBit())
        var action = outList.beginParse()
        #expect(try action.loadRef() == .empty)
        #expect(try action.loadUInt(bits: 32) == 0x0EC3_C86D)
        #expect(try action.loadUInt(bits: 8) == 3)
        let message = try Self.decodeInternal(try action.loadRef())
        #expect(!message.bounce)
        #expect(message.amount == 100_000_000)
    }

    @Test("Bounce: UQ nunca; EQ e raw so com destino ativo (regra do Tonkeeper)")
    func bounceRule() throws {
        let wallet = try TONWallet(publicKey: TONTestSupport.publicKey(seed: Self.seed))
        let cases: [(String, TONAccountStatus, Bool)] = [
            (TONAddressTests.nonBounceable, .active, false),
            (TONAddressTests.nonBounceable, .uninitialized, false),
            (TONAddressTests.bounceable, .active, true),
            (TONAddressTests.bounceable, .uninitialized, false),
            (TONAddressTests.raw, .active, true),
            (TONAddressTests.raw, .uninitialized, false),
        ]
        for (to, status, expected) in cases {
            let plan = try TONPlanner.planSendTON(
                walletID: UUID(), wallet: wallet, path: Self.path, to: to, amount: 1_000_000,
                state: Self.state(destination: status, fee: 100_000), now: Self.now
            )
            let transfer = try #require(plan.transactions.first as? TONTransfer)
            #expect(transfer.messages.first?.bounce == expected, "\(to) \(status)")
            #expect(plan.review.lines.contains { $0.label == "Se o destino recusar" } == !expected)
        }
    }

    @Test("Enviar USDT: corpo transfer para a propria carteira jetton, com 0,05 TON")
    func planSendUSDTEndToEnd() throws {
        let wallet = try TONWallet(publicKey: TONTestSupport.publicKey(seed: Self.seed))
        let jettonWallet = try TONJetton.usdtWallet(owner: wallet.address)
        let plan = try TONPlanner.planSendUSDT(
            walletID: UUID(), wallet: wallet, path: Self.path,
            to: TONAddressTests.nonBounceable, amount: 12_500_000, comment: "123456",
            state: Self.state(), jetton: TONJettonState(ownerJettonWallet: jettonWallet.friendly(bounceable: true), balance: 20_000_000),
            now: Self.now
        )
        #expect(plan.review.title == "Enviar 12,5 USDT")
        #expect(plan.review.lines.contains(PlanReview.Line("Contrato do token", "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs", verbatim: true)))
        let decoded = try Self.signAndDecode(plan)
        let message = try Self.decodeInternal(decoded.message)
        #expect(message.bounce)
        #expect(message.to == jettonWallet)
        #expect(message.amount == 50_000_000)
        var jetton = message.body.beginParse()
        #expect(try jetton.loadUInt(bits: 32) == 0x0F8A_7EA5)
        _ = try jetton.loadUInt(bits: 64)
        #expect(try jetton.loadCoins() == 12_500_000)
        #expect(try jetton.loadAddress() == (try TONTestSupport.address(TONAddressTests.raw)))
        #expect(try jetton.loadAddress() == wallet.address)
        #expect(try jetton.loadMaybeRef() == nil)
        #expect(try jetton.loadCoins() == 1)
        let forward = try #require(try jetton.loadMaybeRef())
        #expect(try TONComment.text(of: forward) == "123456")
        #expect(jetton.remainingBits == 0 && jetton.remainingRefs == 0)
    }

    @Test("Recusas do envio de TON")
    func refusalsTON() throws {
        let wallet = try TONWallet(publicKey: TONTestSupport.publicKey(seed: Self.seed))
        func plan(_ to: String = TONAddressTests.bounceable, amount: BigUInt = 1_000_000, comment: String? = nil,
                  state: TONChainState = TONTransferTests.state(), path: DerivationPath = TONTransferTests.path) throws {
            _ = try TONPlanner.planSendTON(walletID: UUID(), wallet: wallet, path: path, to: to, amount: amount,
                                           comment: comment, state: state, now: TONTransferTests.now)
        }
        #expect(throws: TONPlanError.invalidDestination(.unsupportedType)) { try plan(TONAddressTests.bounceableTestnet) }
        #expect(throws: TONPlanError.invalidDestination(.badChecksum)) { try plan(String(TONAddressTests.bounceable.dropLast()) + "m") }
        #expect(throws: TONPlanError.destinationIsSelf) { try plan(wallet.address.friendly(bounceable: false)) }
        #expect(throws: TONPlanError.destinationIsTokenContract) { try plan(TONJetton.usdtMaster.raw) }
        #expect(throws: TONPlanError.zeroAmount) { try plan(amount: 0) }
        #expect(throws: TONPlanError.insufficientBalance(needed: 2_000_000_001, available: 2_000_000_000)) {
            try plan(amount: 1_995_000_001)
        }
        #expect(throws: TONPlanError.missingFee) { try plan(state: Self.state(fee: 0)) }
        #expect(throws: TONPlanError.feeAboveCeiling(fee: 100_000_001, ceiling: 100_000_000)) { try plan(state: Self.state(fee: 100_000_001)) }
        #expect(throws: TONPlanError.accountFrozen) { try plan(state: Self.state(.frozen)) }
        #expect(throws: TONPlanError.destinationFrozen) { try plan(state: Self.state(destination: .frozen)) }
        #expect(throws: TONPlanError.inconsistentState) { try plan(state: Self.state(.uninitialized, seqno: 3)) }
        #expect(throws: TONPlanError.walletVersionMismatch) { try plan(state: Self.state(codeHash: TONWalletVersion.v5r1.codeHash)) }
        #expect(throws: TONPlanError.invalidPath) { try plan(path: DerivationPath("m/44'/607'/0'/0")!) }
        #expect(throws: TONPlanError.commentHasControlCharacters) { try plan(comment: "memo\u{202E}oditep") }
        #expect(throws: TONPlanError.commentHasControlCharacters) { try plan(comment: "linha\nquebrada") }
        #expect(throws: TONPlanError.commentHasControlCharacters) { try plan(comment: "123\u{200B}456") }
        #expect(throws: TONPlanError.commentHasSurroundingSpaces) { try plan(comment: "123456 ") }
        #expect(throws: TONPlanError.commentHasSurroundingSpaces) { try plan(comment: "\u{00A0}123456") }
        // Destino que e carteira jetton do USDT (code_hash da biblioteca, como a rede informa).
        let jettonWalletCode = try TONCell.library(codeHash: #require([UInt8](hex: "8f452d7a4dfd74066b682365177259ed05734435be76b5fd4bd5d8af2b7c3d68"))).hash
        var toJettonWallet = Self.state()
        toJettonWallet.destinationCodeHash = jettonWalletCode
        #expect(throws: TONPlanError.destinationIsTokenContract) { try plan(state: toJettonWallet) }
        toJettonWallet.destinationCodeHash = TONWalletVersion.v4r2.codeHash
        try plan(state: toJettonWallet)
        #expect(throws: TONPlanError.commentTooLong(maxBytes: 1024)) { try plan(comment: String(repeating: "é", count: 513)) }
        // Hash de codigo igual ao esperado passa; comentario vazio vira nenhum.
        try plan(comment: "", state: Self.state(codeHash: TONWalletVersion.v4r2.codeHash))
        // Taxa alta perto do valor gera aviso, nao recusa.
        let cheap = try TONPlanner.planSendTON(walletID: UUID(), wallet: wallet, path: Self.path, to: TONAddressTests.bounceable,
                                               amount: 10_000_000, state: Self.state(), now: Self.now)
        #expect(cheap.review.warnings == [.highFee(percentOfAmount: 50)])
    }

    @Test("Recusas do envio de USDT")
    func refusalsUSDT() throws {
        let wallet = try TONWallet(publicKey: TONTestSupport.publicKey(seed: Self.seed))
        let ownJettonWallet = try TONJetton.usdtWallet(owner: wallet.address)
        let good = TONJettonState(ownerJettonWallet: ownJettonWallet.raw, balance: 10_000_000)
        func plan(_ to: String = TONAddressTests.nonBounceable, amount: BigUInt = 1_000_000,
                  state: TONChainState = TONTransferTests.state(), jetton: TONJettonState) throws {
            _ = try TONPlanner.planSendUSDT(walletID: UUID(), wallet: wallet, path: TONTransferTests.path, to: to, amount: amount,
                                            state: state, jetton: jetton, now: TONTransferTests.now)
        }
        try plan(jetton: good)
        // A rede informa a carteira jetton de outro dono: recusado.
        let foreign = try TONJetton.usdtWallet(owner: TONTestSupport.address(TONAddressTests.raw))
        #expect(throws: TONPlanError.jettonWalletMismatch) {
            try plan(jetton: TONJettonState(ownerJettonWallet: foreign.raw, balance: 10_000_000))
        }
        #expect(throws: TONPlanError.jettonWalletMismatch) { try plan(jetton: TONJettonState(ownerJettonWallet: "lixo", balance: 1)) }
        #expect(throws: TONPlanError.destinationIsTokenContract) { try plan(ownJettonWallet.friendly(bounceable: true), jetton: good) }
        #expect(throws: TONPlanError.destinationIsTokenContract) { try plan(TONJetton.usdtMaster.raw, jetton: good) }
        #expect(throws: TONPlanError.destinationIsSelf) { try plan(wallet.address.raw, jetton: good) }
        #expect(throws: TONPlanError.insufficientTokenBalance(needed: 10_000_001, available: 10_000_000)) {
            try plan(amount: 10_000_001, jetton: good)
        }
        #expect(throws: TONPlanError.insufficientBalance(needed: 55_000_000, available: 54_999_999)) {
            try plan(state: Self.state(balance: 54_999_999), jetton: good)
        }
        #expect(throws: TONPlanError.zeroAmount) { try plan(amount: 0, jetton: good) }
        // Destino e uma carteira jetton de outra pessoa (reconhecida pelo codigo).
        var toJettonWallet = Self.state()
        toJettonWallet.destinationCodeHash = try TONCell.library(codeHash: #require([UInt8](hex: "8f452d7a4dfd74066b682365177259ed05734435be76b5fd4bd5d8af2b7c3d68"))).hash
        #expect(throws: TONPlanError.destinationIsTokenContract) { try plan(state: toJettonWallet, jetton: good) }
    }

    @Test("Formato dos valores na revisao: exato, pt_BR")
    func reviewAmounts() throws {
        let wallet = try TONWallet(publicKey: TONTestSupport.publicKey(seed: Self.seed))
        let titles: [(BigUInt, String)] = [
            (1, "Enviar 0,000000001 TON"),
            (1_000_000_000, "Enviar 1 TON"),
            (1_234_567_000_000_000, "Enviar 1.234.567 TON"),
            (12_345_678_901, "Enviar 12,345678901 TON"),
        ]
        for (amount, title) in titles {
            let plan = try TONPlanner.planSendTON(
                walletID: UUID(), wallet: wallet, path: Self.path, to: TONAddressTests.raw, amount: amount,
                state: Self.state(balance: 2_000_000_000_000_000, fee: 1), now: Self.now
            )
            #expect(plan.review.title == title)
        }
    }
}
