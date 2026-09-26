import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

@Suite("Stellar planejamento")
struct StellarPlannerTests {
    static let xlm = BigUInt(10_000_000)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    /// USDC da Circle na rede principal (codigo e emissor exatos).
    static let usdc = try! StellarAsset(code: "USDC", issuer: "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN")
    /// Mesmo codigo, outro emissor: o golpe do ativo falso.
    static let fakeUSDC = try! StellarAsset(code: "USDC", issuer: StellarTestKeys.sep5Account2)
    static let network = StellarNetworkState(baseReserve: 5_000_000, baseFee: 100, feeChargedP90: 100)

    /// A conta 0 do SEP-0005: 100 XLM, uma subentrada (a trustline de 50 USDC).
    func context(
        balance: BigUInt = 100 * Self.xlm, subentries: UInt32 = 1, sellingLiabilities: BigUInt = 0,
        trustlines: [StellarTrustline]? = nil, network: StellarNetworkState = Self.network,
        account: String = StellarTestKeys.sep5Account0, now: Date = Self.now
    ) throws -> StellarPlanContext {
        let key = try #require(StellarKey.publicKey(of: StellarTestKeys.sep5Account0))
        let source = try StellarSource(path: DefaultPaths.path(for: .stellar), publicKey: key)
        let state = StellarAccountState(
            account: try StellarTestKeys.account(account), sequence: 1_000, balance: balance, subentryCount: subentries,
            sellingLiabilities: sellingLiabilities,
            trustlines: trustlines ?? [StellarTrustline(asset: Self.usdc, balance: 50 * Self.xlm, limit: BigUInt(UInt64(Int64.max)))]
        )
        return StellarPlanContext(
            walletID: UUID(), source: source, account: state, network: network, allowedAssets: [Self.usdc], now: now
        )
    }

    static let existing = StellarDestinationState(exists: true)

    func transaction(_ plan: SigningPlan) throws -> StellarTransaction {
        #expect(plan.transactions.count == 1)
        return try #require(plan.transactions.first as? StellarTransaction)
    }

    // MARK: Enviar XLM

    @Test("Enviar XLM: Payment, sequence + 1, validade de 180 s, assinatura de ponta a ponta com a chave SEP-0005")
    func sendNativeEndToEnd() throws {
        // Relogio real: a montagem recusa transacao cuja validade ja passou.
        let now = Date.now
        let plan = try StellarPlanner.planSendNative(
            amount: 12 * Self.xlm + 5_000_000, to: StellarTestKeys.sep5Account1, memo: try StellarMemo.fromText("pedido 42"),
            destination: Self.existing, context: try context(now: now)
        )
        #expect(plan.chain == .stellar)
        #expect(plan.review.kind == .send)
        #expect(plan.review.title == "Enviar 12,5 XLM")
        #expect(plan.review.lines.contains(PlanReview.Line("Para", StellarTestKeys.sep5Account1, verbatim: true)))
        #expect(plan.review.lines.contains(PlanReview.Line("Memo (texto)", "pedido 42", verbatim: true)))
        #expect(plan.review.lines.contains(PlanReview.Line("Taxa máxima", "0,00001 XLM")))
        #expect(plan.review.warnings.isEmpty)

        let transaction = try transaction(plan)
        let tx = transaction.tx
        #expect(tx.sequence == 1_001)
        #expect(tx.fee == 100)
        #expect(tx.timeBounds == StellarTimeBounds(minTime: 0, maxTime: UInt64(now.timeIntervalSince1970) + 180))
        #expect(tx.source.address == StellarTestKeys.sep5Account0)
        #expect(tx.operations == [StellarOperation(.payment(
            destination: try StellarTestKeys.muxed(StellarTestKeys.sep5Account1), asset: .native, amount: 125_000_000))])

        // O que vai para o assinador: o hash de 32 bytes, recalculado aqui por fora.
        let request = try #require(transaction.signingRequests.first)
        let payload = StellarNetwork.networkID + [0, 0, 0, 2] + tx.xdr
        #expect(request.payload == Hash.sha256(payload))
        #expect(request.path.description == "m/44'/148'/0'")
        #expect(request.curve == .ed25519)
        #expect(request.expectedPublicKey == StellarKey.publicKey(of: StellarTestKeys.sep5Account0))

        // Assina com a semente do vetor SEP-0005 (Ed25519 do Core, so no teste).
        let seed = try StellarTestKeys.seed(StellarTestKeys.sep5Secret0)
        let signature = try Ed25519.sign(request.payload, seed: seed)
        let signed = try transaction.assemble(with: [ProducedSignature(bytes: signature)])
        #expect(signed.chainID == "stellar")
        #expect(signed.id == Hex.encode(Hash.sha256(payload)))

        let envelope = try StellarEnvelope.decode(base64: signed.encoded)
        #expect(envelope.xdr == signed.raw)
        #expect(envelope.tx == tx)
        #expect(!envelope.isLegacyV0)
        #expect(envelope.signatures.count == 1)
        let decorated = envelope.signatures[0]
        #expect(decorated.hint == Array(try #require(StellarKey.publicKey(of: StellarTestKeys.sep5Account0)).suffix(4)))
        #expect(Ed25519.verify(signature: decorated.signature, message: envelope.hash,
                               publicKey: try #require(StellarKey.publicKey(of: StellarTestKeys.sep5Account0))))
        #expect(Hex.encode(envelope.hash) == signed.id)
    }

    @Test("Enviar XLM para conta inexistente: CreateAccount, minimo de 1 XLM, aviso de ativacao")
    func sendNativeCreatesAccount() throws {
        let plan = try StellarPlanner.planSendNative(
            amount: 2 * Self.xlm, to: StellarTestKeys.sep5Account1, destination: .missing, context: try context()
        )
        #expect(plan.review.warnings == [.activatesAccount(minimum: "1 XLM")])
        #expect(try transaction(plan).tx.operations == [StellarOperation(.createAccount(
            destination: try StellarTestKeys.account(StellarTestKeys.sep5Account1), startingBalance: 20_000_000))])

        #expect(throws: StellarPlanError.belowAccountMinimum(minimum: Self.xlm)) {
            try StellarPlanner.planSendNative(amount: Self.xlm / 2, to: StellarTestKeys.sep5Account1, destination: .missing, context: try context())
        }
        // Conta muxed inexistente: criar a base perderia o id.
        let muxed = StellarKey.muxedAddress(publicKey: try #require(StellarKey.publicKey(of: StellarTestKeys.sep5Account1)), id: 7)
        #expect(throws: StellarPlanError.muxedDestinationMissing) {
            try StellarPlanner.planSendNative(amount: 2 * Self.xlm, to: muxed, destination: .missing, context: try context())
        }
    }

    @Test("Saldo gastavel: saldo - (2 + subentradas) x reserva - liabilities - taxa")
    func spendable() throws {
        // 100 XLM - 3 x 0,5 = 98,5 XLM gastaveis; a taxa (100 stroops) sai daqui tambem.
        let ctx = try context()
        #expect(ctx.account.spendable(baseReserve: 5_000_000) == 985_000_000)
        _ = try StellarPlanner.planSendNative(amount: 985_000_000 - 100, to: StellarTestKeys.sep5Account1, destination: Self.existing, context: ctx)
        #expect(throws: StellarPlanError.insufficientBalance(available: 985_000_000, required: 985_000_001, asset: .native)) {
            try StellarPlanner.planSendNative(amount: 985_000_000 - 99, to: StellarTestKeys.sep5Account1, destination: Self.existing, context: ctx)
        }
        // Ofertas abertas vendendo 10 XLM travam esses 10.
        let locked = try context(sellingLiabilities: 10 * Self.xlm)
        #expect(locked.account.spendable(baseReserve: 5_000_000) == 885_000_000)
        #expect(throws: StellarPlanError.insufficientBalance(available: 885_000_000, required: 900_000_100, asset: .native)) {
            try StellarPlanner.planSendNative(amount: 90 * Self.xlm, to: StellarTestKeys.sep5Account1, destination: Self.existing, context: locked)
        }
        // Patrocinios (CAP-33) entram na conta das subentradas.
        let sponsoring = StellarAccountState(
            account: ctx.account.account, sequence: 1, balance: 100 * Self.xlm, subentryCount: 1, numSponsoring: 2, numSponsored: 1
        )
        #expect(sponsoring.spendable(baseReserve: 5_000_000) == 980_000_000)
    }

    // MARK: Memo e destino

    @Test("SEP-29: destino que exige memo bloqueia envio sem memo")
    func memoRequired() throws {
        let requires = StellarDestinationState(exists: true, memoRequired: true)
        #expect(throws: StellarPlanError.memoRequired) {
            try StellarPlanner.planSendNative(amount: Self.xlm, to: StellarTestKeys.sep5Account1, destination: requires, context: try context())
        }
        #expect(throws: StellarPlanError.memoRequired) {
            try StellarPlanner.planSendAsset(
                Self.usdc, amount: Self.xlm, to: StellarTestKeys.sep5Account1,
                destination: StellarDestinationState(exists: true, trustlines: [Self.usdcLine()], memoRequired: true),
                context: try context()
            )
        }
        let plan = try StellarPlanner.planSendNative(
            amount: Self.xlm, to: StellarTestKeys.sep5Account1, memo: .id(1_234_567), destination: requires, context: try context()
        )
        #expect(try transaction(plan).tx.memo == .id(1_234_567))
        #expect(plan.review.lines.contains(PlanReview.Line("Memo (ID)", "1234567", verbatim: true)))

        // O Horizon devolve os dados em base64.
        #expect(StellarDestinationState.memoRequired(dataEntries: ["config.memo_required": "MQ=="]))
        #expect(!StellarDestinationState.memoRequired(dataEntries: ["config.memo_required": "MA=="]))
        #expect(!StellarDestinationState.memoRequired(dataEntries: ["outra.chave": "MQ=="]))
        #expect(!StellarDestinationState.memoRequired(dataEntries: [:]))
    }

    @Test("Conta M: carrega o id; memo ID junto e recusado; SEP-29 nao se aplica")
    func muxedDestination() throws {
        let key = try #require(StellarKey.publicKey(of: StellarTestKeys.sep5Account1))
        let muxed = StellarKey.muxedAddress(publicKey: key, id: 15_266_350_798)
        let requires = StellarDestinationState(exists: true, memoRequired: true)

        #expect(throws: StellarPlanError.memoIDWithMuxedDestination) {
            try StellarPlanner.planSendNative(amount: Self.xlm, to: muxed, memo: .id(9), destination: requires, context: try context())
        }
        let plan = try StellarPlanner.planSendNative(amount: Self.xlm, to: muxed, destination: requires, context: try context())
        let operation = try #require(try transaction(plan).tx.operations.first)
        #expect(operation.body == .payment(
            destination: StellarMuxedAccount(account: try StellarAccountID(publicKey: key), id: 15_266_350_798),
            asset: .native, amount: 10_000_000))
        #expect(plan.review.lines.contains(PlanReview.Line("ID no endereço M", "15266350798", verbatim: true)))
        #expect(plan.review.lines.contains(PlanReview.Line("Conta base", StellarTestKeys.sep5Account1, verbatim: true)))
    }

    @Test("Destino invalido, de outra rede, a propria conta")
    func badDestinations() throws {
        #expect(throws: StellarPlanError.invalidDestination(.otherNetwork(.ethereum))) {
            try StellarPlanner.planSendNative(
                amount: Self.xlm, to: "0x52908400098527886E0F7030069857D2E4169EE7", destination: Self.existing, context: try context()
            )
        }
        #expect(throws: StellarPlanError.invalidDestination(.badChecksum)) {
            try StellarPlanner.planSendNative(
                amount: Self.xlm, to: "GBAW5XGWORWVFE2XTJYDTLDHXTY2Q2MO73HYCGB3XMFMQ562Q2W2GJQY", destination: Self.existing, context: try context()
            )
        }
        #expect(throws: StellarPlanError.destinationIsSelf) {
            try StellarPlanner.planSendNative(amount: Self.xlm, to: StellarTestKeys.sep5Account0, destination: Self.existing, context: try context())
        }
        #expect(throws: StellarPlanError.amountZero) {
            try StellarPlanner.planSendNative(amount: 0, to: StellarTestKeys.sep5Account1, destination: Self.existing, context: try context())
        }
        #expect(throws: StellarPlanError.amountTooLarge) {
            try StellarPlanner.planSendNative(
                amount: BigUInt(UInt64(Int64.max)) + 1, to: StellarTestKeys.sep5Account1, destination: Self.existing, context: try context()
            )
        }
    }

    // MARK: Enviar ativo

    static func usdcLine(balance: BigUInt = 0, limit: BigUInt = 1_000_000 * Self.xlm, authorized: Bool = true) -> StellarTrustline {
        StellarTrustline(asset: usdc, balance: balance, limit: limit, isAuthorized: authorized)
    }

    @Test("Enviar ativo: destino precisa de trustline autorizada e com espaco")
    func sendAsset() throws {
        let ok = StellarDestinationState(exists: true, trustlines: [Self.usdcLine()])
        let plan = try StellarPlanner.planSendAsset(
            Self.usdc, amount: 20 * Self.xlm, to: StellarTestKeys.sep5Account1, destination: ok, context: try context()
        )
        #expect(plan.review.title == "Enviar 20 USDC")
        #expect(plan.review.lines.contains(PlanReview.Line("Emissor", "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN", verbatim: true)))
        #expect(try transaction(plan).tx.operations == [StellarOperation(.payment(
            destination: try StellarTestKeys.muxed(StellarTestKeys.sep5Account1), asset: Self.usdc, amount: 200_000_000))])

        let to = StellarTestKeys.sep5Account1
        let ctx = try context()
        #expect(throws: StellarPlanError.destinationLacksTrustline(Self.usdc)) {
            try StellarPlanner.planSendAsset(Self.usdc, amount: Self.xlm, to: to, destination: Self.existing, context: ctx)
        }
        #expect(throws: StellarPlanError.destinationTrustlineNotAuthorized(Self.usdc)) {
            try StellarPlanner.planSendAsset(Self.usdc, amount: Self.xlm, to: to,
                                             destination: StellarDestinationState(exists: true, trustlines: [Self.usdcLine(authorized: false)]), context: ctx)
        }
        #expect(throws: StellarPlanError.destinationTrustlineFull(Self.usdc)) {
            try StellarPlanner.planSendAsset(Self.usdc, amount: 2 * Self.xlm, to: to,
                                             destination: StellarDestinationState(exists: true, trustlines: [Self.usdcLine(balance: 9 * Self.xlm, limit: 10 * Self.xlm)]), context: ctx)
        }
        #expect(throws: StellarPlanError.destinationMissing) {
            try StellarPlanner.planSendAsset(Self.usdc, amount: Self.xlm, to: to, destination: .missing, context: ctx)
        }
        // Ativo falso: mesmo codigo, emissor fora da lista.
        #expect(throws: StellarPlanError.assetNotAllowed(Self.fakeUSDC)) {
            try StellarPlanner.planSendAsset(Self.fakeUSDC, amount: Self.xlm, to: to, destination: ok, context: ctx)
        }
        // Pagar ao emissor destroi o ativo.
        #expect(throws: StellarPlanError.destinationIsIssuer) {
            try StellarPlanner.planSendAsset(Self.usdc, amount: Self.xlm, to: "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN",
                                             destination: ok, context: ctx)
        }
        // Saldo do ativo: 50 USDC.
        #expect(throws: StellarPlanError.insufficientBalance(available: 50 * Self.xlm, required: 51 * Self.xlm, asset: Self.usdc)) {
            try StellarPlanner.planSendAsset(Self.usdc, amount: 51 * Self.xlm, to: to, destination: ok, context: ctx)
        }
        // XLM pelo caminho de ativo cai no envio nativo.
        let native = try StellarPlanner.planSendAsset(.native, amount: Self.xlm, to: to, destination: Self.existing, context: ctx)
        #expect(native.review.title == "Enviar 1 XLM")
    }

    // MARK: Aceitar ativo

    @Test("Aceitar ativo: ChangeTrust sem teto, reserva de 0,5 XLM na tela")
    func addTrustline() throws {
        let plan = try StellarPlanner.planAddTrustline(Self.usdc, context: try context(subentries: 0, trustlines: []))
        #expect(plan.review.kind == .trustline)
        #expect(plan.review.title == "Aceitar USDC")
        #expect(plan.review.lines.contains(PlanReview.Line("Reserva", "0,5 XLM ficam presos enquanto a conta aceitar USDC")))
        #expect(try transaction(plan).tx.operations == [StellarOperation(.changeTrust(asset: Self.usdc, limit: Int64.max))])

        #expect(throws: StellarPlanError.trustlineExists(Self.usdc)) { try StellarPlanner.planAddTrustline(Self.usdc, context: try context()) }
        #expect(throws: StellarPlanError.assetNotAllowed(Self.fakeUSDC)) { try StellarPlanner.planAddTrustline(Self.fakeUSDC, context: try context()) }
        #expect(throws: StellarPlanError.nativeAssetHasNoTrustline) { try StellarPlanner.planAddTrustline(.native, context: try context()) }
        // Com saldo so para a reserva atual, nao ha como pagar a nova.
        #expect(throws: StellarPlanError.insufficientBalance(available: 0, required: 5_000_100, asset: .native)) {
            try StellarPlanner.planAddTrustline(Self.usdc, context: try context(balance: Self.xlm, subentries: 0, trustlines: []))
        }
    }

    // MARK: Trocar

    @Test("Troca: PathPaymentStrictSend para si mesmo, destMin calculado da tolerancia")
    func swap() throws {
        // 10 XLM por USDC, cotacao 2,5 USDC, tolerancia 1%: minimo 2,475 USDC.
        let plan = try StellarPlanner.planSwap(
            send: .native, amount: 10 * Self.xlm, receive: Self.usdc, quotedReceive: 25_000_000,
            slippageBasisPoints: 100, context: try context()
        )
        #expect(plan.review.kind == .swap)
        #expect(plan.review.title == "Trocar 10 XLM por USDC")
        #expect(plan.review.lines.contains(PlanReview.Line("Você entrega", "10 XLM")))
        #expect(plan.review.lines.contains(PlanReview.Line("Recebe no mínimo", "2,475 USDC")))
        #expect(plan.review.lines.contains(PlanReview.Line("Tolerância", "1%")))
        let me = StellarMuxedAccount(account: try StellarTestKeys.account(StellarTestKeys.sep5Account0))
        #expect(try transaction(plan).tx.operations == [StellarOperation(.pathPaymentStrictSend(
            sendAsset: .native, sendAmount: 100_000_000, destination: me, destAsset: Self.usdc, destMin: 24_750_000, path: []))])

        // Sem trustline do ativo comprado: ChangeTrust no mesmo tx, uma assinatura.
        let opening = try StellarPlanner.planSwap(
            send: .native, amount: 10 * Self.xlm, receive: Self.usdc, quotedReceive: 25_000_000,
            slippageBasisPoints: 50, path: [Self.fakeUSDC], context: try context(subentries: 0, trustlines: [])
        )
        let tx = try transaction(opening).tx
        #expect(tx.fee == 200)
        #expect(tx.operations.count == 2)
        #expect(tx.operations[0] == StellarOperation(.changeTrust(asset: Self.usdc, limit: Int64.max)))
        #expect(opening.review.lines.contains(PlanReview.Line("Tolerância", "0,5%")))
        #expect(opening.review.lines.contains(PlanReview.Line("Rota", "XLM > USDC > USDC")))

        let ctx = try context()
        #expect(throws: StellarPlanError.slippageTooHigh(maxBasisPoints: 500)) {
            try StellarPlanner.planSwap(send: .native, amount: Self.xlm, receive: Self.usdc, quotedReceive: 1_000, slippageBasisPoints: 501, context: ctx)
        }
        #expect(throws: StellarPlanError.minimumReceiveZero) {
            try StellarPlanner.planSwap(send: .native, amount: Self.xlm, receive: Self.usdc, quotedReceive: 1, slippageBasisPoints: 100, context: ctx)
        }
        #expect(throws: StellarPlanError.sameAsset) {
            try StellarPlanner.planSwap(send: Self.usdc, amount: Self.xlm, receive: Self.usdc, quotedReceive: Self.xlm, slippageBasisPoints: 100, context: ctx)
        }
        #expect(throws: StellarPlanError.assetNotAllowed(Self.fakeUSDC)) {
            try StellarPlanner.planSwap(send: .native, amount: Self.xlm, receive: Self.fakeUSDC, quotedReceive: Self.xlm, slippageBasisPoints: 100, context: ctx)
        }
        #expect(throws: StellarPlanError.tooManyPathHops) {
            try StellarPlanner.planSwap(send: .native, amount: Self.xlm, receive: Self.usdc, quotedReceive: Self.xlm,
                                        slippageBasisPoints: 100, path: Array(repeating: Self.fakeUSDC, count: 6), context: ctx)
        }
        // Vendendo USDC: sai do saldo da trustline (50), a taxa sai do XLM.
        #expect(throws: StellarPlanError.insufficientBalance(available: 50 * Self.xlm, required: 60 * Self.xlm, asset: Self.usdc)) {
            try StellarPlanner.planSwap(send: Self.usdc, amount: 60 * Self.xlm, receive: .native, quotedReceive: Self.xlm, slippageBasisPoints: 100, context: ctx)
        }
    }

    // MARK: Ordem limite

    @Test("Ordem limite: ManageSellOffer, preco n/d local, voce entrega X recebe no minimo Y")
    func limitOrder() throws {
        // Vende 90 XLM por no minimo 27 USDC: preco 3/10 USDC por XLM.
        let plan = try StellarPlanner.planLimitOrder(
            sell: .native, amount: 90 * Self.xlm, buy: Self.usdc, minimumReceive: 270_000_000, context: try context()
        )
        #expect(plan.review.kind == .limitOrder)
        #expect(plan.review.title == "Vender 90 XLM por USDC")
        #expect(plan.review.lines.contains(PlanReview.Line("Você entrega", "90 XLM")))
        #expect(plan.review.lines.contains(PlanReview.Line("Recebe no mínimo", "27 USDC")))
        #expect(plan.review.lines.contains(PlanReview.Line("Preço limite", "3/10 USDC por XLM")))
        #expect(plan.review.lines.contains(PlanReview.Line("Validade", "Até você cancelar. A Stellar não expira ofertas.")))
        #expect(try transaction(plan).tx.operations == [StellarOperation(.manageSellOffer(
            selling: .native, buying: Self.usdc, amount: 900_000_000, price: StellarPrice(n: 3, d: 10), offerID: 0))])

        // A oferta e uma subentrada nova: 100 - (2 + 1 + 1) x 0,5 = 98 XLM gastaveis,
        // e a taxa ainda precisa caber.
        let tight = try context()
        #expect(throws: StellarPlanError.insufficientBalance(available: 980_000_000, required: 980_000_100, asset: .native)) {
            try StellarPlanner.planLimitOrder(sell: .native, amount: 98 * Self.xlm, buy: Self.usdc, minimumReceive: Self.xlm, context: tight)
        }

        // Preco que nao reduz: arredonda para cima, nunca entrega menos que o minimo.
        let odd = try StellarPlanner.planLimitOrder(
            sell: .native, amount: 3_333_333_333, buy: Self.usdc, minimumReceive: 1_000_000_007, context: try context(balance: 1_000 * Self.xlm)
        )
        guard case let .manageSellOffer(_, _, amount, price, _) = try transaction(odd).tx.operations[0].body else {
            Issue.record("esperava ManageSellOffer")
            return
        }
        #expect(BigUInt(UInt64(amount)) * BigUInt(UInt64(price.n)) >= BigUInt(1_000_000_007) * BigUInt(UInt64(price.d)))

        #expect(throws: StellarPlanError.priceNotRepresentable) {
            try StellarPlanner.planLimitOrder(sell: .native, amount: 30_000_000_000, buy: Self.usdc, minimumReceive: 1, context: try context(balance: 10_000 * Self.xlm))
        }
        #expect(throws: StellarPlanError.assetNotAllowed(Self.fakeUSDC)) {
            try StellarPlanner.planLimitOrder(sell: .native, amount: Self.xlm, buy: Self.fakeUSDC, minimumReceive: Self.xlm, context: try context())
        }
    }

    @Test("Cancelar oferta: amount 0 com o offerID")
    func cancelOrder() throws {
        let plan = try StellarPlanner.planCancelOrder(offerID: 2_921_622, selling: .native, buying: Self.usdc, context: try context())
        #expect(plan.review.kind == .cancelOrder)
        #expect(plan.review.lines.contains(PlanReview.Line("Oferta", "2921622", verbatim: true)))
        #expect(try transaction(plan).tx.operations == [StellarOperation(.manageSellOffer(
            selling: .native, buying: Self.usdc, amount: 0, price: StellarPrice(n: 1, d: 1), offerID: 2_921_622))])
        // Cancelar vale mesmo para ativo fora da lista: so libera saldo.
        _ = try StellarPlanner.planCancelOrder(offerID: 1, selling: Self.fakeUSDC, buying: .native, context: try context())
        #expect(throws: StellarPlanError.invalidOfferID) {
            try StellarPlanner.planCancelOrder(offerID: 0, selling: .native, buying: Self.usdc, context: try context())
        }
    }

    // MARK: Estado de rede

    @Test("Estado recebido: conta errada, reserva implausivel, taxa com teto")
    func networkState() throws {
        #expect(throws: StellarPlanError.stateForAnotherAccount) {
            try StellarPlanner.planSendNative(amount: Self.xlm, to: StellarTestKeys.sep5Account1, destination: Self.existing,
                                              context: try context(account: StellarTestKeys.sep5Account2))
        }
        #expect(throws: StellarPlanError.suspiciousNetworkState) {
            try StellarPlanner.planSendNative(amount: Self.xlm, to: StellarTestKeys.sep5Account1, destination: Self.existing,
                                              context: try context(network: StellarNetworkState(baseReserve: 0, baseFee: 100, feeChargedP90: 100)))
        }
        #expect(throws: StellarPlanError.feeAboveCeiling) {
            try StellarPlanner.planSendNative(amount: Self.xlm, to: StellarTestKeys.sep5Account1, destination: Self.existing,
                                              context: try context(network: StellarNetworkState(baseReserve: 5_000_000, baseFee: 200_000, feeChargedP90: 100)))
        }
        // p90 inflado pelo provedor: o lance para no teto de 0,01 XLM por operacao.
        let inflated = try StellarPlanner.planSendNative(
            amount: Self.xlm, to: StellarTestKeys.sep5Account1, destination: Self.existing,
            context: try context(network: StellarNetworkState(baseReserve: 5_000_000, baseFee: 100, feeChargedP90: 90_000_000))
        )
        #expect(try transaction(inflated).tx.fee == 100_000)
        // Surto normal: acompanha o p90.
        let surge = try StellarPlanner.planSendNative(
            amount: Self.xlm, to: StellarTestKeys.sep5Account1, destination: Self.existing,
            context: try context(network: StellarNetworkState(baseReserve: 5_000_000, baseFee: 100, feeChargedP90: 5_000))
        )
        #expect(try transaction(surge).tx.fee == 5_000)
        // Taxa zero de um provedor mentiroso vira o minimo do protocolo.
        let zero = try StellarPlanner.planSendNative(
            amount: Self.xlm, to: StellarTestKeys.sep5Account1, destination: Self.existing,
            context: try context(network: StellarNetworkState(baseReserve: 5_000_000, baseFee: 0, feeChargedP90: 0))
        )
        #expect(try transaction(zero).tx.fee == 100)
    }

    @Test("Origem: so caminho SEP-0005 m/44'/148'/i'")
    func sourcePath() throws {
        let key = try #require(StellarKey.publicKey(of: StellarTestKeys.sep5Account0))
        _ = try StellarSource(path: try #require(DerivationPath("m/44'/148'/3'")), publicKey: key)
        for path in ["m/44'/501'/0'", "m/44'/148'/0'/0'", "m/44'/148'/0", "m/44'/148'"] {
            #expect(throws: StellarSource.Problem.notAStellarPath) {
                try StellarSource(path: try #require(DerivationPath(path)), publicKey: key)
            }
        }
        #expect(throws: StellarSource.Problem.invalidPublicKey) {
            try StellarSource(path: DefaultPaths.path(for: .stellar), publicKey: [1, 2, 3])
        }
    }

    @Test("Valores na tela: stroops com 7 casas e virgula")
    func amountFormat() {
        #expect(StellarAmount.format(0) == "0")
        #expect(StellarAmount.format(1) == "0,0000001")
        #expect(StellarAmount.format(5_000_000) == "0,5")
        #expect(StellarAmount.format(10_000_000) == "1")
        #expect(StellarAmount.format(123_456_789) == "12,3456789")
        #expect(StellarAmount.format(BigUInt(UInt64(Int64.max)), .native) == "922337203685,4775807 XLM")
    }

    @Test("Nenhum texto da tela usa travessao")
    func noDashes() throws {
        let plans = [
            try StellarPlanner.planSendNative(amount: 2 * Self.xlm, to: StellarTestKeys.sep5Account1, destination: .missing, context: try context()),
            try StellarPlanner.planAddTrustline(Self.usdc, context: try context(subentries: 0, trustlines: [])),
            try StellarPlanner.planSwap(send: .native, amount: Self.xlm, receive: Self.usdc, quotedReceive: Self.xlm, slippageBasisPoints: 100,
                                        context: try context(subentries: 0, trustlines: [])),
            try StellarPlanner.planLimitOrder(sell: .native, amount: Self.xlm, buy: Self.usdc, minimumReceive: Self.xlm,
                                              context: try context(subentries: 0, trustlines: [])),
            try StellarPlanner.planCancelOrder(offerID: 1, selling: .native, buying: Self.usdc, context: try context()),
        ]
        var texts = plans.flatMap { [$0.review.title] + $0.review.lines.flatMap { [$0.label, $0.value] } }
        texts += [
            StellarPlanError.memoRequired, .memoIDWithMuxedDestination, .destinationIsIssuer, .priceNotRepresentable,
            .belowAccountMinimum(minimum: Self.xlm), .destinationLacksTrustline(Self.usdc), .suspiciousNetworkState,
            .slippageTooHigh(maxBasisPoints: 500),
        ].map(\.reason)
        #expect(StellarPlanError.slippageTooHigh(maxBasisPoints: 500).reason == "A tolerância passa do máximo de 5%.")
        for text in texts {
            #expect(!text.contains("—") && !text.contains("–"), "\(text)")
        }
    }
}
