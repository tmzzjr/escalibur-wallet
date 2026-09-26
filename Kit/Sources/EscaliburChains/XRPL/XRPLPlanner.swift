import EscaliburCore
import Foundation

/// Por que um plano do XRP Ledger foi recusado. Cada caso e uma frase que a tela
/// consegue dizer ao dono; nenhum e "erro desconhecido".
public enum XRPLPlanError: Error, Equatable, Sendable {
    // Conta e estado da rede
    /// O estado lido e de outra conta, nao da chave que assina.
    case stateForOtherAccount
    /// A conta desativou a chave mestra: a carteira nao tem a chave que assina por ela.
    case masterKeyDisabled
    /// Menos de dois servidores confirmaram o Sequence.
    case sequenceUnconfirmed(readings: Int)
    /// Os servidores discordam do Sequence.
    case sequenceMismatch([UInt32])
    /// Reserva zero nao existe no XRP Ledger; o dado de `server_info` esta errado.
    case implausibleReserve
    /// A taxa passou do teto: rede congestionada, ou um servidor inflando a taxa.
    case feeAboveCap(fee: BigUInt, cap: BigUInt)
    /// Ledger validado zero ou tao alto que o +20 da a volta: dado de servidor errado.
    case invalidLedgerIndex
    /// Saldo gastavel (saldo menos reserva) menor que o necessario.
    case insufficientFunds(spendable: BigUInt, required: BigUInt)

    // Destino
    case invalidDestination(Address.Problem)
    case sendToSelf
    /// O X-address traz uma tag e o dono digitou outra.
    case conflictingDestinationTag(inAddress: UInt32, typed: UInt32)
    /// O destino exige tag (lsfRequireDestTag) e nao ha tag.
    case destinationTagRequired
    /// O estado do destino e de outro endereco.
    case destinationStateMismatch
    case destinationUnconfirmed(readings: Int)
    case destinationReadingsDisagree
    /// O destino pediu para nao receber XRP (lsfDisallowXRP). Seguir exige que o dono
    /// confirme (`XRPLSendIntent.acknowledgesDisallowXRP`).
    case destinationDisallowsXRP
    /// O destino so aceita deposito pre-autorizado (lsfDepositAuth).
    case depositNotAuthorized
    /// Conta nova so nasce com pelo menos a reserva base.
    case belowActivationReserve(minimum: BigUInt)

    // Valores
    case zeroAmount
    case amountTooLarge
    case invalidValue(String)
    case invalidMemo

    // Tokens e ofertas
    /// Moeda e emissor fora da lista curada.
    case assetNotCurated(currency: String, issuer: String)
    case sameAssetBothSides
    case xrpBothSides
    case expirationInPast
    case expirationTooFar(maxDays: Int)
    /// A oferta a cancelar nao pode ter sido criada ainda (Sequence >= o atual).
    case invalidOfferSequence

    /// O que o rippled recusaria na montagem (ver XRPLTransactionError).
    case transaction(XRPLTransactionError)
}

/// O planejamento do XRP Ledger: da intencao do dono e do estado publico ao
/// `SigningPlan`, validando antes de montar (docs/blockchain.md §2.4 e §3.5,
/// docs/seguranca.md §4.5 e §4.8).
///
/// So existem quatro planos: enviar XRP, criar linha de confianca, criar oferta e
/// cancelar oferta. SetRegularKey, SignerListSet, AccountSet e AccountDelete nao tem
/// plano nem tipo de transacao (ver `XRPLTransactionType`).
public enum XRPLPlanner {
    /// Teto da taxa, em drops (0,001 XRP). Hoje a taxa e 10 a 12 drops; acima disso a
    /// rede esta congestionada ou alguem esta mentindo, e nos dois casos esperar e melhor.
    public static let maxFeeDrops: BigUInt = 1_000
    /// Piso da taxa: a taxa de referencia do protocolo.
    public static let minimumFeeDrops: BigUInt = 10
    /// LastLedgerSequence = ultimo validado + 20 (uns 80 segundos). Sem isso uma
    /// transacao presa pode entrar horas depois, com outro preco e outro contexto.
    public static let ledgerWindow: UInt32 = 20
    /// Rede principal. NetworkID so entra na transacao acima de 1024.
    public static let mainnetNetworkID: UInt32 = 0
    /// Oferta vale no maximo 30 dias, como a ordem limite das outras redes (§4.5).
    public static let maxOfferLifetime: TimeInterval = 30 * 86_400
    /// Uma oferta que expira em menos de um minuto expira antes de validar.
    public static let minOfferLifetime: TimeInterval = 60
    /// 01/01/2000 00:00 UTC em segundos Unix: a epoca do XRP Ledger.
    public static let rippleEpoch: TimeInterval = 946_684_800

    // MARK: Enviar XRP

    public static func planSend(
        _ intent: XRPLSendIntent, signer: XRPLSigner, account: XRPLAccountState, ledger: XRPLLedgerState,
        destination: XRPLDestinationState, walletID: UUID, now: Date = .now
    ) throws -> SigningPlan {
        let base = try common(signer: signer, account: account, ledger: ledger)

        let resolved: Address.Destination
        switch Address.validate(intent.destination, for: .xrpl) {
        case .success(let value): resolved = value
        case .failure(let problem): throw XRPLPlanError.invalidDestination(problem)
        }
        guard resolved.address != signer.address else { throw XRPLPlanError.sendToSelf }

        // X-address: a tag vem dentro do endereco. Se o dono digitou outra, alguem
        // (ele, a area de transferencia, um golpe) trocou uma das duas.
        let embeddedTag = resolved.tag.flatMap { UInt32(exactly: $0) }
        if let inAddress = embeddedTag, let typed = intent.destinationTag, inAddress != typed {
            throw XRPLPlanError.conflictingDestinationTag(inAddress: inAddress, typed: typed)
        }
        let tag = embeddedTag ?? intent.destinationTag

        guard destination.address == resolved.address else { throw XRPLPlanError.destinationStateMismatch }
        guard destination.readings.count >= 2 else {
            throw XRPLPlanError.destinationUnconfirmed(readings: destination.readings.count)
        }
        guard Set(destination.readings).count == 1 else { throw XRPLPlanError.destinationReadingsDisagree }

        guard !intent.drops.isZero else { throw XRPLPlanError.zeroAmount }
        guard intent.drops <= XRPLAmount.maxDrops else { throw XRPLPlanError.amountTooLarge }

        var warnings = [PlanReview.Warning]()
        var notices = [PlanReview.Line]()
        switch destination.readings[0] {
        case .notFound:
            guard intent.drops >= ledger.reserveBase else {
                throw XRPLPlanError.belowActivationReserve(minimum: ledger.reserveBase)
            }
            warnings.append(.activatesAccount(minimum: XRPLFormat.xrp(ledger.reserveBase)))
        case .found(let flags):
            if flags & XRPLAccountFlags.requireDestTag != 0, tag == nil {
                throw XRPLPlanError.destinationTagRequired
            }
            if flags & XRPLAccountFlags.depositAuth != 0, !destination.depositPreauthorized {
                throw XRPLPlanError.depositNotAuthorized
            }
            if flags & XRPLAccountFlags.disallowXRP != 0 {
                guard intent.acknowledgesDisallowXRP else { throw XRPLPlanError.destinationDisallowsXRP }
                notices.append(PlanReview.Line("Aviso do destino", "Esta conta pediu para não receber XRP"))
            }
        }

        try requireFunds(base, objectsAdded: 0, xrpOut: intent.drops, ledger: ledger)

        var memos = [XRPLMemo]()
        if let text = intent.memo, !text.isEmpty {
            do { memos = [try XRPLMemo.text(text)] } catch { throw XRPLPlanError.invalidMemo }
        }

        let transaction = try build {
            let payment = try XRPLPayment(destination: resolved.address, amount: .xrp(drops: intent.drops), destinationTag: tag)
            return try XRPLTransaction(
                signer: signer, body: .payment(payment), fee: base.fee, sequence: base.sequence,
                lastLedgerSequence: base.lastLedgerSequence, memos: memos, networkID: mainnetNetworkID
            )
        }

        var lines = [PlanReview.Line("Para", resolved.address, verbatim: true)]
        if let tag { lines.append(PlanReview.Line("Tag de destino", String(tag), verbatim: true)) }
        lines.append(PlanReview.Line("Valor", XRPLFormat.xrp(intent.drops)))
        lines.append(PlanReview.Line("Taxa da rede", XRPLFormat.xrp(base.fee)))
        if let text = intent.memo, !text.isEmpty { lines.append(PlanReview.Line("Memo", text)) }
        lines += notices

        let review = PlanReview(
            kind: .send, title: "Enviar \(XRPLFormat.xrp(intent.drops))", lines: lines, warnings: warnings,
            recipient: resolved.address, recipientTag: tag.map { String($0) }
        )
        return SigningPlan(walletID: walletID, chain: .xrpl, review: review, transactions: [transaction], createdAt: now)
    }

    // MARK: Linha de confianca

    public static func planTrustline(
        _ intent: XRPLTrustlineIntent, signer: XRPLSigner, account: XRPLAccountState, ledger: XRPLLedgerState,
        curated: [XRPLCuratedAsset], walletID: UUID, now: Date = .now
    ) throws -> SigningPlan {
        let base = try common(signer: signer, account: account, ledger: ledger)
        let asset = try curatedAsset(intent.currency, intent.issuer, in: curated)
        let limit: XRPLDecimal
        do { limit = try XRPLDecimal(intent.limit) } catch { throw XRPLPlanError.invalidValue(intent.limit) }
        guard !limit.isZero, !limit.isNegative else { throw XRPLPlanError.invalidValue(intent.limit) }

        // A linha e um objeto novo do dono: prende mais uma reserva por objeto.
        try requireFunds(base, objectsAdded: 1, xrpOut: 0, ledger: ledger)

        let transaction = try build {
            let amount = try XRPLIssuedAmount(value: limit, currency: asset.currency, issuer: asset.issuer)
            return try XRPLTransaction(
                signer: signer, body: .trustSet(XRPLTrustSet(limit: amount)), fee: base.fee, sequence: base.sequence,
                lastLedgerSequence: base.lastLedgerSequence, networkID: mainnetNetworkID
            )
        }

        let code = asset.currency.displayCode
        let lines = [
            PlanReview.Line("Moeda", code),
            PlanReview.Line("Emissor", asset.issuerName),
            PlanReview.Line("Endereço do emissor", asset.issuer, verbatim: true),
            PlanReview.Line("Limite", "\(XRPLFormat.decimal(limit)) \(code)"),
            PlanReview.Line("Reserva", "\(XRPLFormat.xrp(ledger.reserveIncrement)) ficam presos enquanto a linha existir"),
            PlanReview.Line("Taxa da rede", XRPLFormat.xrp(base.fee)),
        ]
        let review = PlanReview(kind: .trustline, title: "Aceitar \(code) de \(asset.issuerName)", lines: lines)
        return SigningPlan(walletID: walletID, chain: .xrpl, review: review, transactions: [transaction], createdAt: now)
    }

    // MARK: Oferta (ordem limite)

    public static func planOffer(
        _ intent: XRPLOfferIntent, signer: XRPLSigner, account: XRPLAccountState, ledger: XRPLLedgerState,
        curated: [XRPLCuratedAsset], walletID: UUID, now: Date = .now
    ) throws -> SigningPlan {
        let base = try common(signer: signer, account: account, ledger: ledger)
        let gets = try resolve(intent.give, curated: curated)
        let pays = try resolve(intent.receiveAtLeast, curated: curated)
        guard !(gets.amount.isXRP && pays.amount.isXRP) else { throw XRPLPlanError.xrpBothSides }
        guard !XRPLPayment.sameAsset(gets.amount, pays.amount) else { throw XRPLPlanError.sameAssetBothSides }

        let lifetime = intent.expiration.timeIntervalSince(now)
        guard lifetime >= minOfferLifetime else { throw XRPLPlanError.expirationInPast }
        guard lifetime <= maxOfferLifetime else {
            throw XRPLPlanError.expirationTooFar(maxDays: Int(maxOfferLifetime / 86_400))
        }
        guard let expiration = rippleTime(intent.expiration) else { throw XRPLPlanError.expirationTooFar(maxDays: 30) }

        var options: XRPLOfferOptions = []
        if intent.sell { options.insert(.sell) }
        if intent.passive { options.insert(.passive) }
        switch intent.timeInForce {
        case .goodTilExpiration: break
        case .immediateOrCancel: options.insert(.immediateOrCancel)
        case .fillOrKill: options.insert(.fillOrKill)
        }

        // A oferta que fica no livro e um objeto do dono; o XRP que ela entrega tem de
        // estar acima da reserva, senao a oferta nasce sem fundos.
        var xrpOut = BigUInt()
        if case .xrp(let drops) = gets.amount { xrpOut = drops }
        try requireFunds(base, objectsAdded: 1, xrpOut: xrpOut, ledger: ledger)

        let transaction = try build {
            let offer = try XRPLOfferCreate(takerGets: gets.amount, takerPays: pays.amount, expiration: expiration, options: options)
            return try XRPLTransaction(
                signer: signer, body: .offerCreate(offer), fee: base.fee, sequence: base.sequence,
                lastLedgerSequence: base.lastLedgerSequence, networkID: mainnetNetworkID
            )
        }

        var lines = [
            PlanReview.Line("Você entrega", intent.sell ? gets.label : "até \(gets.label)"),
            PlanReview.Line("Você recebe no mínimo", pays.label),
        ]
        for side in [gets, pays] {
            guard let asset = side.asset else { continue }
            let code = asset.currency.displayCode
            lines.append(PlanReview.Line("Emissor de \(code)", asset.issuerName))
            lines.append(PlanReview.Line("Endereço do emissor de \(code)", asset.issuer, verbatim: true))
        }
        lines.append(PlanReview.Line("Execução", executionText(intent)))
        lines.append(PlanReview.Line("Expira em", XRPLFormat.date(intent.expiration)))
        lines.append(PlanReview.Line("Reserva", "\(XRPLFormat.xrp(ledger.reserveIncrement)) ficam presos enquanto a oferta estiver no livro"))
        lines.append(PlanReview.Line("Taxa da rede", XRPLFormat.xrp(base.fee)))

        let review = PlanReview(kind: .limitOrder, title: "Ordem limite: \(gets.label) por \(pays.label)", lines: lines)
        return SigningPlan(walletID: walletID, chain: .xrpl, review: review, transactions: [transaction], createdAt: now)
    }

    // MARK: Cancelar oferta

    public static func planCancelOffer(
        _ intent: XRPLCancelOfferIntent, signer: XRPLSigner, account: XRPLAccountState, ledger: XRPLLedgerState,
        walletID: UUID, now: Date = .now
    ) throws -> SigningPlan {
        let base = try common(signer: signer, account: account, ledger: ledger)
        guard intent.offerSequence > 0, intent.offerSequence < base.sequence else { throw XRPLPlanError.invalidOfferSequence }
        // Cancelar libera reserva; a taxa pode sair de dentro dela, como o rippled permite.
        guard base.fee <= account.balance else {
            throw XRPLPlanError.insufficientFunds(spendable: account.balance, required: base.fee)
        }

        let transaction = try build {
            try XRPLTransaction(
                signer: signer, body: .offerCancel(XRPLOfferCancel(offerSequence: intent.offerSequence)), fee: base.fee,
                sequence: base.sequence, lastLedgerSequence: base.lastLedgerSequence, networkID: mainnetNetworkID
            )
        }
        let lines = [
            PlanReview.Line("Oferta", String(intent.offerSequence), verbatim: true),
            PlanReview.Line("Reserva", "\(XRPLFormat.xrp(ledger.reserveIncrement)) voltam a ficar livres"),
            PlanReview.Line("Taxa da rede", XRPLFormat.xrp(base.fee)),
        ]
        let review = PlanReview(kind: .cancelOrder, title: "Cancelar a oferta \(intent.offerSequence)", lines: lines)
        return SigningPlan(walletID: walletID, chain: .xrpl, review: review, transactions: [transaction], createdAt: now)
    }

    // MARK: Regras comuns

    struct Common {
        let sequence: UInt32
        let fee: BigUInt
        let lastLedgerSequence: UInt32
        /// Saldo menos a reserva atual (base + owner count x por objeto), ou zero.
        let spendable: BigUInt
    }

    /// Taxa = max(open_ledger_fee, 10) x 1,2, arredondada para cima.
    public static func fee(openLedgerFee: BigUInt) -> BigUInt {
        let floor = max(openLedgerFee, minimumFeeDrops)
        return (floor * 12 + 9) / 10
    }

    /// Saldo gastavel = saldo - (reserva base + owner count x reserva por objeto).
    public static func spendable(account: XRPLAccountState, ledger: XRPLLedgerState) -> BigUInt {
        let reserve = ledger.reserveBase + BigUInt(account.ownerCount) * ledger.reserveIncrement
        return account.balance.subtractingReportingUnderflow(reserve) ?? BigUInt()
    }

    static func common(signer: XRPLSigner, account: XRPLAccountState, ledger: XRPLLedgerState) throws -> Common {
        guard account.address == signer.address else { throw XRPLPlanError.stateForOtherAccount }
        guard account.flags & XRPLAccountFlags.disableMaster == 0 else { throw XRPLPlanError.masterKeyDisabled }

        guard account.sequenceReadings.count >= 2 else {
            throw XRPLPlanError.sequenceUnconfirmed(readings: account.sequenceReadings.count)
        }
        guard Set(account.sequenceReadings).count == 1, let sequence = account.sequenceReadings.first, sequence > 0 else {
            throw XRPLPlanError.sequenceMismatch(account.sequenceReadings)
        }

        guard !ledger.reserveBase.isZero else { throw XRPLPlanError.implausibleReserve }

        let fee = fee(openLedgerFee: ledger.openLedgerFee)
        guard fee <= maxFeeDrops else { throw XRPLPlanError.feeAboveCap(fee: fee, cap: maxFeeDrops) }

        let (last, overflow) = ledger.validatedLedgerIndex.addingReportingOverflow(ledgerWindow)
        guard !overflow, ledger.validatedLedgerIndex > 0 else { throw XRPLPlanError.invalidLedgerIndex }

        return Common(sequence: sequence, fee: fee, lastLedgerSequence: last, spendable: spendable(account: account, ledger: ledger))
    }

    /// Exige que taxa, XRP que sai e a reserva dos objetos novos caibam no gastavel.
    static func requireFunds(_ base: Common, objectsAdded: UInt32, xrpOut: BigUInt, ledger: XRPLLedgerState) throws {
        let required = base.fee + xrpOut + BigUInt(objectsAdded) * ledger.reserveIncrement
        guard required <= base.spendable else {
            throw XRPLPlanError.insufficientFunds(spendable: base.spendable, required: required)
        }
    }

    static func curatedAsset(_ currency: XRPLCurrency, _ issuer: String, in curated: [XRPLCuratedAsset]) throws -> XRPLCuratedAsset {
        guard let asset = curated.first(where: { $0.currency == currency && $0.issuer == issuer }) else {
            throw XRPLPlanError.assetNotCurated(currency: currency.code, issuer: issuer)
        }
        return asset
    }

    struct ResolvedSide {
        let amount: XRPLAmount
        let label: String
        let asset: XRPLCuratedAsset?
    }

    static func resolve(_ side: XRPLOfferAsset, curated: [XRPLCuratedAsset]) throws -> ResolvedSide {
        switch side {
        case .xrp(let drops):
            guard !drops.isZero else { throw XRPLPlanError.zeroAmount }
            guard drops <= XRPLAmount.maxDrops else { throw XRPLPlanError.amountTooLarge }
            return ResolvedSide(amount: .xrp(drops: drops), label: XRPLFormat.xrp(drops), asset: nil)
        case .issued(let currency, let issuer, let text):
            let asset = try curatedAsset(currency, issuer, in: curated)
            let value: XRPLDecimal
            do { value = try XRPLDecimal(text) } catch { throw XRPLPlanError.invalidValue(text) }
            guard !value.isZero else { throw XRPLPlanError.zeroAmount }
            guard !value.isNegative else { throw XRPLPlanError.invalidValue(text) }
            let amount = try build { try XRPLIssuedAmount(value: value, currency: asset.currency, issuer: asset.issuer) }
            return ResolvedSide(
                amount: .issued(amount), label: "\(XRPLFormat.decimal(value)) \(asset.currency.displayCode)", asset: asset
            )
        }
    }

    /// Segundos desde 01/01/2000 UTC, arredondados para baixo.
    public static func rippleTime(_ date: Date) -> UInt32? {
        let seconds = (date.timeIntervalSince1970 - rippleEpoch).rounded(.down)
        guard seconds >= 0, seconds <= TimeInterval(UInt32.max) else { return nil }
        return UInt32(seconds)
    }

    static func executionText(_ intent: XRPLOfferIntent) -> String {
        var text: String
        switch intent.timeInForce {
        case .goodTilExpiration: text = "Fica no livro até executar, ser cancelada ou expirar"
        case .immediateOrCancel: text = "Executa o que der agora e cancela o resto"
        case .fillOrKill: text = "Executa tudo agora ou nada"
        }
        if intent.passive { text += "; passiva, não consome ofertas de mesmo preço" }
        return text
    }

    /// Traduz o erro de montagem para o erro de plano.
    static func build<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as XRPLTransactionError {
            throw XRPLPlanError.transaction(error)
        } catch let error as XRPLCodecError {
            switch error {
            case .invalidAccount(let text): throw XRPLPlanError.transaction(.invalidAccount(text))
            default: throw XRPLPlanError.invalidValue("\(error)")
            }
        }
    }
}

/// Texto de valor para a tela de revisao: virgula decimal, sem separador de milhar,
/// sem arredondar (o que se assina e o que se le).
enum XRPLFormat {
    static func xrp(_ drops: BigUInt) -> String {
        let (whole, fraction) = drops.quotientAndRemainder(dividingBy: BigUInt(1_000_000))
        var digits = fraction.decimalString
        digits = String(repeating: "0", count: 6 - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return digits.isEmpty ? "\(whole) XRP" : "\(whole),\(digits) XRP"
    }

    static func decimal(_ value: XRPLDecimal) -> String {
        value.decimalString.replacingOccurrences(of: ".", with: ",")
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "dd/MM/yyyy HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}
