import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// As regras de planejamento do XRP Ledger (docs/blockchain.md §2.4 e §3.5,
/// docs/seguranca.md §4.1, §4.5 e §4.8), cada uma com o caso que passa e o que bloqueia.
@Suite("XRPL planejamento")
struct XRPLPlannerTests {
    static let wallet = UUID()
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let destination = "rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe"
    static let xrp: BigUInt = 1_000_000
    static let bitstamp = "rvYAfWj5gh67oV6fW32ZzP3Aw4Eubs59B"
    static let impostor = "rMaa8VLBTjwTJWA2kSme4Sqgphhr6Lr6FH"

    static func ledger(fee: BigUInt = 10, index: UInt32 = 100_000_000) -> XRPLLedgerState {
        // Reserva de hoje (1 XRP + 0,2 por objeto), passada como dado, como a rede passa.
        XRPLLedgerState(validatedLedgerIndex: index, reserveBase: 1_000_000, reserveIncrement: 200_000, openLedgerFee: fee)
    }

    static func account(
        _ signer: XRPLSigner, balance: BigUInt = 250 * xrp, owners: UInt32 = 3, sequences: [UInt32] = [77, 77], flags: UInt32 = 0
    ) -> XRPLAccountState {
        XRPLAccountState(address: signer.address, sequenceReadings: sequences, balance: balance, ownerCount: owners, flags: flags)
    }

    static func found(_ flags: UInt32 = 0, address: String = destination, preauthorized: Bool = false) -> XRPLDestinationState {
        XRPLDestinationState(address: address, readings: [.found(flags: flags), .found(flags: flags)], depositPreauthorized: preauthorized)
    }

    static func send(
        _ intent: XRPLSendIntent, account: XRPLAccountState? = nil, ledger: XRPLLedgerState = ledger(),
        destination: XRPLDestinationState = found()
    ) throws -> SigningPlan {
        let signer = try XRPLTestKeys.signer()
        return try XRPLPlanner.planSend(
            intent, signer: signer, account: account ?? Self.account(signer), ledger: ledger,
            destination: destination, walletID: wallet, now: now
        )
    }

    static func transaction(_ plan: SigningPlan) throws -> XRPLTransaction {
        #expect(plan.transactions.count == 1)
        return try #require(plan.transactions.first as? XRPLTransaction)
    }

    static func line(_ plan: SigningPlan, _ label: String) -> PlanReview.Line? {
        plan.review.lines.first { $0.label == label }
    }

    static func curated() throws -> [XRPLCuratedAsset] {
        [try XRPLCuratedAsset(currency: XRPLCurrency(code: "USD"), issuer: bitstamp, issuerName: "Bitstamp", decimals: 6)]
    }

    // MARK: Enviar XRP

    @Test("Envio simples: campos, janela de 20 ledgers, taxa x1,2 e assinatura de ponta a ponta")
    func sendHappyPath() throws {
        let plan = try Self.send(XRPLSendIntent(destination: Self.destination, destinationTag: 7, drops: 50 * Self.xrp, memo: "aluguel"))
        let tx = try Self.transaction(plan)
        #expect(plan.chain == .xrpl && plan.walletID == Self.wallet && plan.createdAt == Self.now)
        #expect(tx.unsigned[.sequence] == .uint32(77))
        #expect(tx.unsigned[.lastLedgerSequence] == .uint32(100_000_020))
        #expect(tx.unsigned[.fee] == .amount(.xrp(drops: 12)))
        #expect(tx.unsigned[.flags] == .uint32(XRPLTransactionFlags.fullyCanonicalSig))
        #expect(tx.unsigned[.destinationTag] == .uint32(7))
        #expect(tx.unsigned[.amount] == .amount(.xrp(drops: 50 * Self.xrp)))
        // O que sai e o Amount gravado.
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: "xrpl:native", amount: 50 * Self.xrp))
        #expect(tx.unsigned[.networkID] == nil)
        #expect(tx.unsigned[.sendMax] == nil && tx.unsigned[.deliverMin] == nil)
        #expect(tx.memos == [try XRPLMemo.text("aluguel")])

        #expect(plan.review.kind == .send)
        #expect(plan.review.title == "Enviar 50 XRP")
        expectRecipient(plan)
        #expect(Self.line(plan, "Para") == PlanReview.Line("Para", Self.destination, verbatim: true))
        #expect(Self.line(plan, "Tag de destino") == PlanReview.Line("Tag de destino", "7", verbatim: true))
        #expect(Self.line(plan, "Taxa da rede")?.value == "0,000012 XRP")
        #expect(Self.line(plan, "Memo")?.value == "aluguel")
        #expect(plan.review.warnings.isEmpty)

        let signed = try XRPLTestKeys.sign(tx)
        #expect(signed.id == XRPLFixtures.hex(Hash.sha512Half([0x54, 0x58, 0x4E, 0x00] + signed.raw)))
        #expect(signed.encoded == XRPLFixtures.hex(signed.raw))
    }

    @Test("Tag obrigatoria (lsfRequireDestTag): sem tag bloqueia, com tag passa")
    func requireDestTag() throws {
        let flagged = Self.found(XRPLAccountFlags.requireDestTag)
        #expect(throws: XRPLPlanError.destinationTagRequired) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), destination: flagged)
        }
        let plan = try Self.send(XRPLSendIntent(destination: Self.destination, destinationTag: 0, drops: Self.xrp), destination: flagged)
        #expect(try Self.transaction(plan).unsigned[.destinationTag] == .uint32(0))
    }

    @Test("X-address: a tag embutida vale; outra tag digitada e recusa")
    func xAddress() throws {
        let x = try #require(XRPLAddress.xAddress(classic: Self.destination, tag: 12_345))
        let plan = try Self.send(XRPLSendIntent(destination: x, drops: Self.xrp))
        #expect(try Self.transaction(plan).unsigned[.destinationTag] == .uint32(12_345))
        #expect(Self.line(plan, "Para")?.value == Self.destination)

        // A mesma tag digitada de novo e aceita; outra, nao.
        _ = try Self.send(XRPLSendIntent(destination: x, destinationTag: 12_345, drops: Self.xrp))
        #expect(throws: XRPLPlanError.conflictingDestinationTag(inAddress: 12_345, typed: 999)) {
            try Self.send(XRPLSendIntent(destination: x, destinationTag: 999, drops: Self.xrp))
        }
        // X-address sem tag, com tag digitada: vale a digitada.
        let bare = try #require(XRPLAddress.xAddress(classic: Self.destination, tag: nil))
        let typed = try Self.send(XRPLSendIntent(destination: bare, destinationTag: 5, drops: Self.xrp))
        #expect(try Self.transaction(typed).unsigned[.destinationTag] == .uint32(5))
    }

    @Test("Destino inexistente: abaixo da reserva base bloqueia, a partir dela avisa que ativa a conta")
    func activation() throws {
        let missing = XRPLDestinationState(address: Self.destination, readings: [.notFound, .notFound])
        #expect(throws: XRPLPlanError.belowActivationReserve(minimum: 1_000_000)) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: 999_999), destination: missing)
        }
        let plan = try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), destination: missing)
        #expect(plan.review.warnings == [.activatesAccount(minimum: "1 XRP")])

        // A reserva vem do server_info: se os validadores baixarem para 0,5 XRP, o
        // plano segue o dado, nao uma constante.
        var cheaper = Self.ledger()
        cheaper.reserveBase = 500_000
        let lower = try Self.send(XRPLSendIntent(destination: Self.destination, drops: 500_000), ledger: cheaper, destination: missing)
        #expect(lower.review.warnings == [.activatesAccount(minimum: "0,5 XRP")])
    }

    @Test("Saldo gastavel = saldo - (reserva base + owner count x por objeto), com a taxa")
    func spendable() throws {
        let signer = try XRPLTestKeys.signer()
        let account = Self.account(signer, balance: 25 * Self.xrp, owners: 3)
        #expect(XRPLPlanner.spendable(account: account, ledger: Self.ledger()) == 23_400_000)
        _ = try Self.send(XRPLSendIntent(destination: Self.destination, drops: 23_399_988), account: account)
        #expect(throws: XRPLPlanError.insufficientFunds(spendable: 23_400_000, required: 23_400_001)) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: 23_399_989), account: account)
        }
        let poor = Self.account(signer, balance: 1_500_000, owners: 3)
        #expect(XRPLPlanner.spendable(account: poor, ledger: Self.ledger()) == 0)
        #expect(throws: XRPLPlanError.insufficientFunds(spendable: 0, required: 1_000_012)) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), account: poor)
        }
    }

    @Test("Sequence de um servidor so, ou divergente, bloqueia")
    func sequenceConsensus() throws {
        let signer = try XRPLTestKeys.signer()
        #expect(throws: XRPLPlanError.sequenceUnconfirmed(readings: 1)) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), account: Self.account(signer, sequences: [77]))
        }
        #expect(throws: XRPLPlanError.sequenceMismatch([77, 78])) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), account: Self.account(signer, sequences: [77, 78]))
        }
        let three = try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), account: Self.account(signer, sequences: [9, 9, 9]))
        #expect(try Self.transaction(three).sequence == 9)
    }

    @Test("Taxa: max(open_ledger_fee, 10) x 1,2 para cima, com teto de 1.000 drops")
    func feeCap() throws {
        #expect(XRPLPlanner.fee(openLedgerFee: 0) == 12)
        #expect(XRPLPlanner.fee(openLedgerFee: 10) == 12)
        #expect(XRPLPlanner.fee(openLedgerFee: 11) == 14)
        #expect(XRPLPlanner.fee(openLedgerFee: 833) == 1_000)
        let atCap = try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), ledger: Self.ledger(fee: 833))
        #expect(try Self.transaction(atCap).fee == 1_000)
        #expect(throws: XRPLPlanError.feeAboveCap(fee: 1_001, cap: 1_000)) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), ledger: Self.ledger(fee: 834))
        }
    }

    @Test("Estado do destino: dois servidores, concordando, do mesmo endereco")
    func destinationConsensus() throws {
        let intent = XRPLSendIntent(destination: Self.destination, drops: Self.xrp)
        #expect(throws: XRPLPlanError.destinationUnconfirmed(readings: 1)) {
            try Self.send(intent, destination: XRPLDestinationState(address: Self.destination, readings: [.found(flags: 0)]))
        }
        #expect(throws: XRPLPlanError.destinationReadingsDisagree) {
            try Self.send(intent, destination: XRPLDestinationState(
                address: Self.destination, readings: [.found(flags: 0), .found(flags: XRPLAccountFlags.requireDestTag)]
            ))
        }
        #expect(throws: XRPLPlanError.destinationReadingsDisagree) {
            try Self.send(intent, destination: XRPLDestinationState(address: Self.destination, readings: [.found(flags: 0), .notFound]))
        }
        #expect(throws: XRPLPlanError.destinationStateMismatch) {
            try Self.send(intent, destination: Self.found(address: Self.impostor))
        }
    }

    @Test("lsfDisallowXRP pede confirmacao; lsfDepositAuth sem pre-autorizacao bloqueia")
    func destinationFlags() throws {
        let disallow = Self.found(XRPLAccountFlags.disallowXRP)
        #expect(throws: XRPLPlanError.destinationDisallowsXRP) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), destination: disallow)
        }
        let confirmed = try Self.send(
            XRPLSendIntent(destination: Self.destination, drops: Self.xrp, acknowledgesDisallowXRP: true), destination: disallow
        )
        #expect(Self.line(confirmed, "Aviso do destino")?.value == "Esta conta pediu para não receber XRP")

        let auth = XRPLAccountFlags.depositAuth
        #expect(throws: XRPLPlanError.depositNotAuthorized) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), destination: Self.found(auth))
        }
        _ = try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), destination: Self.found(auth, preauthorized: true))
    }

    @Test("Recusas da conta e do valor: si mesmo, outra conta, chave mestra desligada, zero, endereco de outra rede")
    func refusals() throws {
        let signer = try XRPLTestKeys.signer()
        #expect(throws: XRPLPlanError.sendToSelf) {
            try Self.send(XRPLSendIntent(destination: signer.address, drops: Self.xrp), destination: Self.found(address: signer.address))
        }
        var other = Self.account(signer)
        other.address = Self.impostor
        #expect(throws: XRPLPlanError.stateForOtherAccount) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), account: other)
        }
        #expect(throws: XRPLPlanError.masterKeyDisabled) {
            try Self.send(
                XRPLSendIntent(destination: Self.destination, drops: Self.xrp),
                account: Self.account(signer, flags: XRPLAccountFlags.disableMaster)
            )
        }
        #expect(throws: XRPLPlanError.zeroAmount) { try Self.send(XRPLSendIntent(destination: Self.destination, drops: 0)) }
        #expect(throws: XRPLPlanError.invalidDestination(.otherNetwork(.ethereum))) {
            try Self.send(XRPLSendIntent(destination: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", drops: Self.xrp))
        }
        #expect(throws: XRPLPlanError.implausibleReserve) {
            var broken = Self.ledger()
            broken.reserveBase = 0
            return try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), ledger: broken)
        }
        #expect(throws: XRPLPlanError.invalidLedgerIndex) {
            try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), ledger: Self.ledger(index: UInt32.max - 5))
        }
    }

    // MARK: Linha de confianca

    @Test("Trustline: so da lista curada, com tfSetNoRipple e reserva de mais um objeto")
    func trustline() throws {
        let signer = try XRPLTestKeys.signer()
        let usd = try XRPLCurrency(code: "USD")
        let plan = try XRPLPlanner.planTrustline(
            XRPLTrustlineIntent(currency: usd, issuer: Self.bitstamp, limit: "1000000"), signer: signer,
            account: Self.account(signer), ledger: Self.ledger(), curated: try Self.curated(), walletID: Self.wallet, now: Self.now
        )
        let tx = try Self.transaction(plan)
        #expect(tx.body.type == .trustSet)
        #expect(tx.flags == XRPLTransactionFlags.fullyCanonicalSig | XRPLTransactionFlags.setNoRipple)
        #expect(tx.unsigned[.limitAmount] == .amount(.issued(try XRPLIssuedAmount(value: XRPLDecimal("1000000"), currency: usd, issuer: Self.bitstamp))))
        #expect(plan.review.kind == .trustline && plan.review.title == "Aceitar USD de Bitstamp")
        #expect(Self.line(plan, "Endereço do emissor") == PlanReview.Line("Endereço do emissor", Self.bitstamp, verbatim: true))
        #expect(Self.line(plan, "Reserva")?.value == "0,2 XRP ficam presos enquanto a linha existir")
        _ = try XRPLTestKeys.sign(tx)

        // O mesmo "USD" de outro emissor e o golpe do emissor falso.
        #expect(throws: XRPLPlanError.assetNotCurated(currency: "USD", issuer: Self.impostor)) {
            try XRPLPlanner.planTrustline(
                XRPLTrustlineIntent(currency: usd, issuer: Self.impostor, limit: "1000000"), signer: signer,
                account: Self.account(signer), ledger: Self.ledger(), curated: try Self.curated(), walletID: Self.wallet, now: Self.now
            )
        }
        for limit in ["0", "-5", "abc"] {
            #expect(throws: XRPLPlanError.invalidValue(limit)) {
                try XRPLPlanner.planTrustline(
                    XRPLTrustlineIntent(currency: usd, issuer: Self.bitstamp, limit: limit), signer: signer,
                    account: Self.account(signer), ledger: Self.ledger(), curated: try Self.curated(), walletID: Self.wallet, now: Self.now
                )
            }
        }
        // Saldo que cobre a reserva de hoje mas nao a do objeto novo.
        #expect(throws: XRPLPlanError.insufficientFunds(spendable: 100_000, required: 200_012)) {
            try XRPLPlanner.planTrustline(
                XRPLTrustlineIntent(currency: usd, issuer: Self.bitstamp, limit: "10"), signer: signer,
                account: Self.account(signer, balance: 1_700_000, owners: 3), ledger: Self.ledger(),
                curated: try Self.curated(), walletID: Self.wallet, now: Self.now
            )
        }
    }

    // MARK: Oferta

    static func offer(_ intent: XRPLOfferIntent, balance: BigUInt = 250 * xrp) throws -> SigningPlan {
        let signer = try XRPLTestKeys.signer()
        return try XRPLPlanner.planOffer(
            intent, signer: signer, account: account(signer, balance: balance), ledger: ledger(),
            curated: try curated(), walletID: wallet, now: now
        )
    }

    @Test("Oferta: entrega X, recebe no minimo Y, expiracao na epoca de 2000, flags permitidas")
    func offer() throws {
        let usd = try XRPLCurrency(code: "USD")
        let expiration = Self.now.addingTimeInterval(7 * 86_400)
        let plan = try Self.offer(XRPLOfferIntent(
            give: .xrp(drops: 100 * Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "50.5"),
            expiration: expiration
        ))
        let tx = try Self.transaction(plan)
        guard case .offerCreate(let offer) = tx.body else { Issue.record("corpo errado"); return }
        #expect(offer.takerGets == .xrp(drops: 100 * Self.xrp))
        #expect(offer.takerPays == .issued(try XRPLIssuedAmount(value: XRPLDecimal("50.5"), currency: usd, issuer: Self.bitstamp)))
        // 1.790.604.800 (Unix) - 946.684.800 = 843.920.000 segundos desde 01/01/2000.
        #expect(offer.expiration == 843_920_000)
        #expect(tx.unsigned[.expiration] == .uint32(843_920_000))
        #expect(tx.flags == XRPLTransactionFlags.fullyCanonicalSig | XRPLTransactionFlags.sell)
        #expect(plan.review.kind == .limitOrder)
        #expect(plan.review.title == "Ordem limite: 100 XRP por 50,5 USD")
        #expect(Self.line(plan, "Você entrega")?.value == "100 XRP")
        #expect(Self.line(plan, "Você recebe no mínimo")?.value == "50,5 USD")
        #expect(Self.line(plan, "Endereço do emissor de USD") == PlanReview.Line("Endereço do emissor de USD", Self.bitstamp, verbatim: true))
        #expect(Self.line(plan, "Expira em")?.value == "28/09/2026 14:13 UTC")
        _ = try XRPLTestKeys.sign(tx)

        let ioc = try Self.offer(XRPLOfferIntent(
            give: .issued(currency: usd, issuer: Self.bitstamp, value: "10"), receiveAtLeast: .xrp(drops: 20 * Self.xrp),
            expiration: expiration, sell: false, passive: true, timeInForce: .immediateOrCancel
        ))
        #expect(try Self.transaction(ioc).flags == XRPLTransactionFlags.fullyCanonicalSig | XRPLTransactionFlags.passive | XRPLTransactionFlags.immediateOrCancel)
        #expect(Self.line(ioc, "Você entrega")?.value == "até 10 USD")
        let fok = try Self.offer(XRPLOfferIntent(
            give: .issued(currency: usd, issuer: Self.bitstamp, value: "10"), receiveAtLeast: .xrp(drops: 20 * Self.xrp),
            expiration: expiration, timeInForce: .fillOrKill
        ))
        #expect(try Self.transaction(fok).flags == XRPLTransactionFlags.fullyCanonicalSig | XRPLTransactionFlags.sell | XRPLTransactionFlags.fillOrKill)
    }

    @Test("Oferta: o que sai, o minimo que entra e quem recebe vem dos valores gravados; tudo ou nada e troca")
    func offerMovements() throws {
        let usd = try XRPLCurrency(code: "USD")
        let signer = try XRPLTestKeys.signer()
        let later = Self.now.addingTimeInterval(86_400)
        let order = try Self.offer(XRPLOfferIntent(
            give: .xrp(drops: 100 * Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "50.5"), expiration: later
        ))
        #expect(order.review.kind == .limitOrder)
        #expect(order.review.outgoing == PlanReview.Movement(assetID: "xrpl:native", amount: 100 * Self.xrp))
        #expect(order.review.incomingMinimum == PlanReview.Movement(assetID: "xrpl:USD:\(Self.bitstamp)", amount: 50_500_000))
        #expect(order.review.beneficiary == signer.address)

        // Vender o token: sai o TakerGets em unidades de 6 casas, entra o minimo em drops.
        let swap = try Self.offer(XRPLOfferIntent(
            give: .issued(currency: usd, issuer: Self.bitstamp, value: "10.25"), receiveAtLeast: .xrp(drops: 20 * Self.xrp),
            expiration: later, timeInForce: .fillOrKill
        ))
        #expect(swap.review.kind == .swap && swap.review.title == "Trocar 10,25 USD por XRP")
        #expect(swap.review.outgoing == PlanReview.Movement(assetID: "xrpl:USD:\(Self.bitstamp)", amount: 10_250_000))
        #expect(swap.review.incomingMinimum == PlanReview.Movement(assetID: "xrpl:native", amount: 20 * Self.xrp))

        // Token curado sem as casas da carteira: sem como dizer o valor, sem plano.
        let noDecimals = [try XRPLCuratedAsset(currency: usd, issuer: Self.bitstamp, issuerName: "Bitstamp")]
        #expect(throws: XRPLPlanError.assetNotCurated(currency: "USD", issuer: Self.bitstamp)) {
            try XRPLPlanner.planOffer(
                XRPLOfferIntent(give: .xrp(drops: Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "1"), expiration: later),
                signer: signer, account: Self.account(signer), ledger: Self.ledger(), curated: noDecimals, walletID: Self.wallet, now: Self.now
            )
        }
    }

    @Test("Oferta sem prazo: sem Expiration, dita 'nao expira'; tudo ou nada sem prazo e recusado")
    func offerWithoutExpiry() throws {
        let usd = try XRPLCurrency(code: "USD")
        let plan = try Self.offer(XRPLOfferIntent(
            give: .xrp(drops: 100 * Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "50"), expiration: nil
        ))
        guard case .offerCreate(let offer) = try Self.transaction(plan).body else { Issue.record("corpo errado"); return }
        #expect(offer.expiration == nil)
        #expect(try Self.transaction(plan).unsigned[.expiration] == nil)
        #expect(Self.line(plan, "Validade")?.value == "Não expira: fica no livro até executar ou você cancelar")
        #expect(Self.line(plan, "Expira em") == nil)
        #expect(throws: XRPLPlanError.expirationInPast) {
            try Self.offer(XRPLOfferIntent(
                give: .xrp(drops: Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "1"), expiration: nil,
                timeInForce: .fillOrKill
            ))
        }
    }

    @Test("Regressao A1: linha de confianca e oferta so se juntam na mesma conta, em sequencia, para o token comprado")
    func trustlineAndOffer() throws {
        let usd = try XRPLCurrency(code: "USD")
        let eur = try XRPLCurrency(code: "EUR")
        let signer = try XRPLTestKeys.signer()
        let curated = try Self.curated() + [try XRPLCuratedAsset(currency: eur, issuer: Self.bitstamp, issuerName: "Bitstamp", decimals: 6)]
        func trust(_ currency: XRPLCurrency, sequence: UInt32 = 77) throws -> SigningPlan {
            try XRPLPlanner.planTrustline(
                XRPLTrustlineIntent(currency: currency, issuer: Self.bitstamp, limit: "1000"), signer: signer,
                account: Self.account(signer, sequences: [sequence, sequence]), ledger: Self.ledger(), curated: curated,
                walletID: Self.wallet, now: Self.now
            )
        }
        func offer(sequence: UInt32 = 78) throws -> SigningPlan {
            try XRPLPlanner.planOffer(
                XRPLOfferIntent(give: .xrp(drops: 10 * Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "5"),
                                expiration: Self.now.addingTimeInterval(300), timeInForce: .fillOrKill),
                signer: signer, account: Self.account(signer, sequences: [sequence, sequence]), ledger: Self.ledger(), curated: curated,
                walletID: Self.wallet, now: Self.now
            )
        }
        let joined = try XRPLPlanner.combineTrustlineAndOffer(trust: try trust(usd), offer: try offer())
        #expect(joined.review.kind == .swap && joined.review.title == "Trocar 10 XRP por USD")
        #expect(joined.review.transactionCount == 2 && joined.transactions.count == 2)
        #expect(joined.review.lines.first == PlanReview.Line("Transações", "2: primeiro aceitar USD, depois a troca"))
        #expect(joined.review.lines.contains(PlanReview.Line("Endereço do emissor", Self.bitstamp, verbatim: true)))
        #expect(joined.review.outgoing == PlanReview.Movement(assetID: "xrpl:native", amount: 10 * Self.xrp))
        #expect(joined.review.incomingMinimum == PlanReview.Movement(assetID: "xrpl:USD:\(Self.bitstamp)", amount: 5_000_000))

        // A linha e de outro token, fora de sequencia, ou as duas partes trocadas.
        #expect(throws: SigningPlan.CompositionError.partsDoNotMatch) {
            try XRPLPlanner.combineTrustlineAndOffer(trust: try trust(eur), offer: try offer())
        }
        #expect(throws: SigningPlan.CompositionError.partsDoNotMatch) {
            try XRPLPlanner.combineTrustlineAndOffer(trust: try trust(usd), offer: try offer(sequence: 79))
        }
        #expect(throws: SigningPlan.CompositionError.partsDoNotMatch) {
            try XRPLPlanner.combineTrustlineAndOffer(trust: try offer(), offer: try trust(usd))
        }
        // Um envio no lugar da oferta nao vira "troca".
        let send = try Self.send(XRPLSendIntent(destination: Self.destination, drops: Self.xrp), account: Self.account(signer, sequences: [78, 78]))
        #expect(throws: SigningPlan.CompositionError.partsDoNotMatch) {
            try XRPLPlanner.combineTrustlineAndOffer(trust: try trust(usd), offer: send)
        }
    }

    @Test("Oferta: emissor fora da lista, mesmo ativo, XRP dos dois lados, expiracao e saldo")
    func offerRefusals() throws {
        let usd = try XRPLCurrency(code: "USD")
        let later = Self.now.addingTimeInterval(86_400)
        #expect(throws: XRPLPlanError.assetNotCurated(currency: "USD", issuer: Self.impostor)) {
            try Self.offer(XRPLOfferIntent(give: .xrp(drops: Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.impostor, value: "1"), expiration: later))
        }
        #expect(throws: XRPLPlanError.xrpBothSides) {
            try Self.offer(XRPLOfferIntent(give: .xrp(drops: Self.xrp), receiveAtLeast: .xrp(drops: 2), expiration: later))
        }
        #expect(throws: XRPLPlanError.sameAssetBothSides) {
            try Self.offer(XRPLOfferIntent(
                give: .issued(currency: usd, issuer: Self.bitstamp, value: "1"),
                receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "2"), expiration: later
            ))
        }
        #expect(throws: XRPLPlanError.expirationInPast) {
            try Self.offer(XRPLOfferIntent(give: .xrp(drops: Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "1"), expiration: Self.now.addingTimeInterval(30)))
        }
        #expect(throws: XRPLPlanError.expirationTooFar(maxDays: 30)) {
            try Self.offer(XRPLOfferIntent(give: .xrp(drops: Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "1"), expiration: Self.now.addingTimeInterval(31 * 86_400)))
        }
        #expect(throws: XRPLPlanError.zeroAmount) {
            try Self.offer(XRPLOfferIntent(give: .xrp(drops: Self.xrp), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "0"), expiration: later))
        }
        // 25 XRP, 3 objetos: gastavel 23,4; a oferta nova prende mais 0,2.
        #expect(throws: XRPLPlanError.insufficientFunds(spendable: 23_400_000, required: 23_400_012)) {
            try Self.offer(
                XRPLOfferIntent(give: .xrp(drops: 23_200_000), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "1"), expiration: later),
                balance: 25 * Self.xrp
            )
        }
        _ = try Self.offer(
            XRPLOfferIntent(give: .xrp(drops: 23_199_988), receiveAtLeast: .issued(currency: usd, issuer: Self.bitstamp, value: "1"), expiration: later),
            balance: 25 * Self.xrp
        )
    }

    @Test("Cancelar oferta: so oferta ja criada (OfferSequence < Sequence)")
    func cancelOffer() throws {
        let signer = try XRPLTestKeys.signer()
        func plan(_ sequence: UInt32) throws -> SigningPlan {
            try XRPLPlanner.planCancelOffer(
                XRPLCancelOfferIntent(offerSequence: sequence), signer: signer, account: Self.account(signer),
                ledger: Self.ledger(), walletID: Self.wallet, now: Self.now
            )
        }
        let ok = try plan(76)
        #expect(try Self.transaction(ok).unsigned[.offerSequence] == .uint32(76))
        #expect(ok.review.kind == .cancelOrder && ok.review.title == "Cancelar a oferta 76")
        _ = try XRPLTestKeys.sign(try Self.transaction(ok))
        #expect(throws: XRPLPlanError.invalidOfferSequence) { try plan(77) }
        #expect(throws: XRPLPlanError.invalidOfferSequence) { try plan(0) }
    }

    @Test("Texto de valor: virgula decimal, sem arredondar")
    func format() throws {
        #expect(XRPLFormat.xrp(0) == "0 XRP")
        #expect(XRPLFormat.xrp(12) == "0,000012 XRP")
        #expect(XRPLFormat.xrp(1_500_000) == "1,5 XRP")
        #expect(XRPLFormat.xrp(100_000_000_000_000_000) == "100000000000 XRP")
        #expect(XRPLFormat.decimal(try XRPLDecimal("0.1248548562296331")) == "0,1248548562296331")
        #expect(XRPLPlanner.rippleTime(Date(timeIntervalSince1970: 946_684_800)) == 0)
        #expect(XRPLPlanner.rippleTime(Date(timeIntervalSince1970: 946_684_799)) == nil)
    }
}
