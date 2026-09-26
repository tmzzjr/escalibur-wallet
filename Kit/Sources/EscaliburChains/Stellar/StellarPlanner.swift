import EscaliburCore
import Foundation

/// Por que um plano Stellar foi recusado. `reason` e o texto que a tela mostra.
public enum StellarPlanError: Error, Equatable, Sendable {
    case invalidDestination(Address.Problem)
    case destinationIsSelf
    /// Pagar ao emissor destroi o ativo: ele nao volta como saldo de ninguem.
    case destinationIsIssuer
    case memoRequired
    case memoIDWithMuxedDestination
    case amountZero
    case amountTooLarge
    case insufficientBalance(available: BigUInt, required: BigUInt, asset: StellarAsset)
    case belowAccountMinimum(minimum: BigUInt)
    case destinationMissing
    case muxedDestinationMissing
    case destinationLacksTrustline(StellarAsset)
    case destinationTrustlineNotAuthorized(StellarAsset)
    case destinationTrustlineFull(StellarAsset)
    case assetNotAllowed(StellarAsset)
    case nativeAssetHasNoTrustline
    case trustlineExists(StellarAsset)
    case missingOwnTrustline(StellarAsset)
    case ownTrustlineNotAuthorized(StellarAsset)
    case ownTrustlineFull(StellarAsset)
    case sameAsset
    case slippageTooHigh(maxBasisPoints: UInt32)
    case minimumReceiveZero
    case priceNotRepresentable
    case tooManyPathHops
    case invalidOfferID
    case stateForAnotherAccount
    case sequenceOverflow
    case feeAboveCeiling
    case suspiciousNetworkState

    public var reason: String {
        switch self {
        case .invalidDestination(.otherNetwork(let chain)):
            return "Este endereço é da rede \(chain.name). Na Stellar o endereço começa com G ou M."
        case .invalidDestination(.badChecksum):
            return "O endereço tem um caractere errado ou está incompleto."
        case .invalidDestination:
            return "Isto não é um endereço Stellar."
        case .destinationIsSelf:
            return "O destino é a própria conta."
        case .destinationIsIssuer:
            return "O destino é o emissor do ativo. Enviar ao emissor destrói o ativo."
        case .memoRequired:
            return "O destino exige memo (SEP-29). Sem ele o depósito se perde."
        case .memoIDWithMuxedDestination:
            return "Endereço M já carrega o ID. Um memo ID junto seria um segundo ID, e o depósito pode ir para a pessoa errada."
        case .amountZero:
            return "O valor precisa ser maior que zero."
        case .amountTooLarge:
            return "O valor passa do máximo que a rede representa."
        case .insufficientBalance(let available, let required, let asset):
            return "Saldo insuficiente: disponível \(StellarAmount.format(available, asset)), necessário \(StellarAmount.format(required, asset))."
        case .belowAccountMinimum(let minimum):
            return "O destino ainda não existe. Para criar a conta, envie pelo menos \(StellarAmount.format(minimum, .native))."
        case .destinationMissing:
            return "A conta de destino não existe e não pode receber este ativo."
        case .muxedDestinationMissing:
            return "A conta por trás do endereço M não existe."
        case .destinationLacksTrustline(let asset):
            return "O destino ainda não aceita \(asset.code). Ele precisa abrir a linha de confiança antes."
        case .destinationTrustlineNotAuthorized(let asset):
            return "O emissor não autorizou o destino a receber \(asset.code)."
        case .destinationTrustlineFull(let asset):
            return "O destino atingiu o limite de \(asset.code) que aceita receber."
        case .assetNotAllowed(let asset):
            return "\(asset.code) deste emissor não está na lista de ativos da carteira."
        case .nativeAssetHasNoTrustline:
            return "XLM não precisa de linha de confiança."
        case .trustlineExists(let asset):
            return "A conta já aceita \(asset.code)."
        case .missingOwnTrustline(let asset):
            return "A conta ainda não aceita \(asset.code)."
        case .ownTrustlineNotAuthorized(let asset):
            return "O emissor não autorizou esta conta a usar \(asset.code)."
        case .ownTrustlineFull(let asset):
            return "A conta atingiu o limite de \(asset.code) que aceita receber."
        case .sameAsset:
            return "Os dois lados da operação são o mesmo ativo."
        case .slippageTooHigh(let maxBasisPoints):
            return "A tolerância passa do máximo de \(StellarPlanner.percentText(basisPoints: maxBasisPoints))."
        case .minimumReceiveZero:
            return "Com esta tolerância o mínimo a receber seria zero."
        case .priceNotRepresentable:
            return "Este preço não cabe na fração que a Stellar usa. Ajuste os valores."
        case .tooManyPathHops:
            return "A rota tem mais de 5 ativos intermediários."
        case .invalidOfferID:
            return "Oferta inválida."
        case .stateForAnotherAccount:
            return "Os dados recebidos são de outra conta."
        case .sequenceOverflow:
            return "A sequência da conta chegou ao fim."
        case .feeAboveCeiling:
            return "A taxa da rede está acima do teto da carteira."
        case .suspiciousNetworkState:
            return "Os parâmetros da rede recebidos não são plausíveis. Tente outro provedor."
        }
    }
}

/// O planejamento Stellar: intencao do dono mais estado publico, validados, viram
/// um `SigningPlan`. Nenhuma funcao daqui busca nada nem assina nada.
///
/// Regras comuns a todos os planos:
/// - origem = a conta da carteira, e o estado recebido tem de ser dela;
/// - `seqNum` = sequence + 1; `timeBounds` = [0, agora + 180 s];
/// - taxa por operacao = max(100, taxa base, p90 cobrado), com teto de 0,01 XLM;
/// - saldo gastavel = saldo - (2 + subentradas) x reserva - liabilities, contando as
///   subentradas que a propria transacao cria;
/// - ativos so da lista curada, por codigo e emissor.
public enum StellarPlanner {

    // MARK: Enviar XLM

    /// Envia XLM. Se o destino nao existe, usa `CreateAccount` (so XLM, minimo de
    /// 2 reservas, hoje 1 XLM) e avisa que o envio ativa a conta.
    public static func planSendNative(
        amount: BigUInt, to destinationText: String, memo: StellarMemo = .none,
        destination: StellarDestinationState, context: StellarPlanContext
    ) throws -> SigningPlan {
        try check(context)
        let target = try resolveDestination(destinationText, context: context)
        let value = try int64(amount)
        try checkMemo(memo, destination: target, state: destination)
        let fee = try feePerOperation(context.network)

        let body: StellarOperation.Body
        var warnings: [PlanReview.Warning] = []
        var extraLines: [PlanReview.Line] = []
        if destination.exists {
            body = .payment(destination: target, asset: .native, amount: value)
        } else {
            // CreateAccount recebe AccountID, sem id de muxed: criar a conta base
            // perderia o id, e o credito nao chegaria a quem o endereco M indica.
            guard !target.isMuxed else { throw StellarPlanError.muxedDestinationMissing }
            let minimum = context.network.baseReserve * BigUInt(2)
            guard amount >= minimum else { throw StellarPlanError.belowAccountMinimum(minimum: minimum) }
            body = .createAccount(destination: target.account, startingBalance: value)
            warnings.append(.activatesAccount(minimum: StellarAmount.format(minimum, .native)))
            extraLines.append(PlanReview.Line("Conta nova", "Este envio cria a conta de destino"))
        }

        let spendable = context.account.spendable(baseReserve: context.network.baseReserve)
        try requireBalance(spendable, covers: amount + fee, asset: .native)
        if let percent = feePercent(fee: fee, amount: amount), percent > 3 {
            warnings.append(.highFee(percentOfAmount: percent))
        }

        let review = PlanReview(
            kind: .send,
            title: "Enviar \(StellarAmount.format(amount, .native))",
            lines: destinationLines(target) + memoLines(memo) + extraLines + feeLines(fee, operations: 1),
            warnings: warnings
        )
        return try makePlan([body], memo: memo, feePerOperation: fee, review: review, context: context)
    }

    // MARK: Enviar ativo

    /// Envia um ativo da lista. O destino precisa existir e ter trustline
    /// autorizada com espaco; se nao tiver, recusa dizendo por que (a alternativa,
    /// claimable balance, fica para depois). XLM cai em `planSendNative`.
    public static func planSendAsset(
        _ asset: StellarAsset, amount: BigUInt, to destinationText: String, memo: StellarMemo = .none,
        destination: StellarDestinationState, context: StellarPlanContext
    ) throws -> SigningPlan {
        if asset.isNative {
            return try planSendNative(amount: amount, to: destinationText, memo: memo, destination: destination, context: context)
        }
        try check(context)
        guard context.isAllowed(asset) else { throw StellarPlanError.assetNotAllowed(asset) }
        let target = try resolveDestination(destinationText, context: context)
        guard target.account != asset.issuer else { throw StellarPlanError.destinationIsIssuer }
        let value = try int64(amount)
        guard destination.exists else { throw StellarPlanError.destinationMissing }
        try checkMemo(memo, destination: target, state: destination)

        guard let theirs = destination.trustline(for: asset) else { throw StellarPlanError.destinationLacksTrustline(asset) }
        guard theirs.isAuthorized else { throw StellarPlanError.destinationTrustlineNotAuthorized(asset) }
        guard theirs.room >= amount else { throw StellarPlanError.destinationTrustlineFull(asset) }

        let ours = try ownTrustline(asset, context: context)
        try requireBalance(ours.available, covers: amount, asset: asset)
        let fee = try feePerOperation(context.network)
        try requireBalance(context.account.spendable(baseReserve: context.network.baseReserve), covers: fee, asset: .native)

        let review = PlanReview(
            kind: .send,
            title: "Enviar \(StellarAmount.format(amount, asset))",
            lines: destinationLines(target) + memoLines(memo) + assetLines(asset, label: "Emissor")
                + feeLines(fee, operations: 1)
        )
        return try makePlan(
            [.payment(destination: target, asset: asset, amount: value)],
            memo: memo, feePerOperation: fee, review: review, context: context
        )
    }

    // MARK: Aceitar ativo

    /// Abre a linha de confianca num ativo da lista (`ChangeTrust` sem teto). A
    /// linha e uma subentrada: prende 0,5 XLM de reserva enquanto existir, e a tela
    /// diz isso antes da assinatura.
    public static func planAddTrustline(_ asset: StellarAsset, context: StellarPlanContext) throws -> SigningPlan {
        try check(context)
        guard !asset.isNative else { throw StellarPlanError.nativeAssetHasNoTrustline }
        guard context.isAllowed(asset) else { throw StellarPlanError.assetNotAllowed(asset) }
        guard context.account.trustline(for: asset) == nil else { throw StellarPlanError.trustlineExists(asset) }
        let fee = try feePerOperation(context.network)
        let reserve = context.network.baseReserve
        let spendable = context.account.spendable(baseReserve: reserve)
        guard spendable >= reserve + fee else {
            throw StellarPlanError.insufficientBalance(available: spendable, required: reserve + fee, asset: .native)
        }

        let review = PlanReview(
            kind: .trustline,
            title: "Aceitar \(asset.code)",
            lines: assetLines(asset, label: "Emissor")
                + [PlanReview.Line("Reserva", "\(StellarAmount.format(reserve, .native)) ficam presos enquanto a conta aceitar \(asset.code)")]
                + feeLines(fee, operations: 1)
        )
        return try makePlan(
            [.changeTrust(asset: asset, limit: StellarLimits.trustlineLimit)],
            memo: .none, feePerOperation: fee, review: review, context: context
        )
    }

    // MARK: Trocar

    /// Troca pela DEX nativa com `PathPaymentStrictSend` para a propria conta.
    ///
    /// A cotacao (`quotedReceive`, `path`) vem do pathfinding de fora; o que protege
    /// o dono e o `destMin`, calculado **aqui** a partir da tolerancia:
    /// `destMin = floor(quotedReceive x (10000 - bps) / 10000)`. A rede garante que
    /// sai exatamente `sendAmount` e entra pelo menos `destMin`, seja qual for a
    /// rota. Se a conta ainda nao aceita o ativo comprado, o `ChangeTrust` vai na
    /// mesma transacao (uma assinatura, atomico).
    public static func planSwap(
        send sendAsset: StellarAsset, amount sendAmount: BigUInt,
        receive receiveAsset: StellarAsset, quotedReceive: BigUInt,
        slippageBasisPoints: UInt32, path: [StellarAsset] = [],
        context: StellarPlanContext
    ) throws -> SigningPlan {
        try check(context)
        guard sendAsset != receiveAsset else { throw StellarPlanError.sameAsset }
        for asset in [sendAsset, receiveAsset] where !context.isAllowed(asset) {
            throw StellarPlanError.assetNotAllowed(asset)
        }
        guard slippageBasisPoints <= StellarLimits.maxSlippageBasisPoints else {
            throw StellarPlanError.slippageTooHigh(maxBasisPoints: StellarLimits.maxSlippageBasisPoints)
        }
        guard path.count <= StellarOperation.maxPathLength else { throw StellarPlanError.tooManyPathHops }
        let sendValue = try int64(sendAmount)
        let destMin = quotedReceive * BigUInt(10_000 - slippageBasisPoints) / BigUInt(10_000)
        guard !destMin.isZero else { throw StellarPlanError.minimumReceiveZero }
        let destMinValue = try int64(destMin)

        var bodies: [StellarOperation.Body] = []
        var extraLines: [PlanReview.Line] = []
        let opensTrustline = try receivingSide(receiveAsset, expecting: quotedReceive, context: context)
        if opensTrustline {
            bodies.append(.changeTrust(asset: receiveAsset, limit: StellarLimits.trustlineLimit))
            extraLines.append(PlanReview.Line(
                "Linha de confiança",
                "Esta troca abre a linha de \(receiveAsset.code): \(StellarAmount.format(context.network.baseReserve, .native)) presos enquanto a conta aceitar \(receiveAsset.code)"
            ))
        }
        bodies.append(.pathPaymentStrictSend(
            sendAsset: sendAsset, sendAmount: sendValue, destination: StellarMuxedAccount(account: context.source.account),
            destAsset: receiveAsset, destMin: destMinValue, path: path
        ))

        let fee = try feePerOperation(context.network)
        try payingSide(sendAsset, amount: sendAmount, fee: fee * BigUInt(bodies.count),
                       newSubentries: opensTrustline ? 1 : 0, context: context)

        let route = ([sendAsset] + path + [receiveAsset]).map(\.code).joined(separator: " > ")
        var lines: [PlanReview.Line] = [
            PlanReview.Line("Você entrega", StellarAmount.format(sendAmount, sendAsset)),
            PlanReview.Line("Recebe no mínimo", StellarAmount.format(destMin, receiveAsset)),
            PlanReview.Line("Cotação", StellarAmount.format(quotedReceive, receiveAsset)),
            PlanReview.Line("Tolerância", percentText(basisPoints: slippageBasisPoints)),
            PlanReview.Line("Rota", route),
        ]
        lines += assetLines(sendAsset, label: "Emissor de \(sendAsset.code)")
        lines += assetLines(receiveAsset, label: "Emissor de \(receiveAsset.code)")
        lines += extraLines + feeLines(fee, operations: bodies.count)

        let review = PlanReview(
            kind: .swap,
            title: "Trocar \(StellarAmount.format(sendAmount, sendAsset)) por \(receiveAsset.code)",
            lines: lines
        )
        return try makePlan(bodies, memo: .none, feePerOperation: fee, review: review, context: context)
    }

    // MARK: Ordem limite

    /// Oferta de venda no livro da DEX (`ManageSellOffer`, offerID 0): "voce entrega
    /// X, recebe no minimo Y". O preco n/d e calculado aqui a partir de X e Y,
    /// arredondado para cima (`StellarPrice.atLeast`). A oferta e uma subentrada
    /// (0,5 XLM de reserva) e **nao expira**: vive ate ser executada ou cancelada.
    public static func planLimitOrder(
        sell sellingAsset: StellarAsset, amount sellAmount: BigUInt,
        buy buyingAsset: StellarAsset, minimumReceive: BigUInt,
        context: StellarPlanContext
    ) throws -> SigningPlan {
        try check(context)
        guard sellingAsset != buyingAsset else { throw StellarPlanError.sameAsset }
        for asset in [sellingAsset, buyingAsset] where !context.isAllowed(asset) {
            throw StellarPlanError.assetNotAllowed(asset)
        }
        let sellValue = try int64(sellAmount)
        guard !minimumReceive.isZero else { throw StellarPlanError.minimumReceiveZero }
        _ = try int64(minimumReceive)
        let price: StellarPrice
        do {
            price = try StellarPrice.atLeast(receive: minimumReceive, forSelling: sellAmount)
        } catch {
            throw StellarPlanError.priceNotRepresentable
        }

        var bodies: [StellarOperation.Body] = []
        let opensTrustline = try receivingSide(buyingAsset, expecting: minimumReceive, context: context)
        if opensTrustline {
            bodies.append(.changeTrust(asset: buyingAsset, limit: StellarLimits.trustlineLimit))
        }
        bodies.append(.manageSellOffer(selling: sellingAsset, buying: buyingAsset, amount: sellValue, price: price, offerID: 0))

        let fee = try feePerOperation(context.network)
        let newSubentries: UInt32 = opensTrustline ? 2 : 1
        try payingSide(sellingAsset, amount: sellAmount, fee: fee * BigUInt(bodies.count),
                       newSubentries: newSubentries, context: context)

        let reserve = StellarAmount.format(context.network.baseReserve, .native)
        var lines: [PlanReview.Line] = [
            PlanReview.Line("Você entrega", StellarAmount.format(sellAmount, sellingAsset)),
            PlanReview.Line("Recebe no mínimo", StellarAmount.format(minimumReceive, buyingAsset)),
            PlanReview.Line("Preço limite", "\(price.n)/\(price.d) \(buyingAsset.code) por \(sellingAsset.code)"),
            PlanReview.Line("Validade", "Até você cancelar. A Stellar não expira ofertas."),
            PlanReview.Line("Reserva", "\(reserve) ficam presos enquanto a oferta estiver aberta"),
        ]
        if opensTrustline {
            lines.append(PlanReview.Line(
                "Linha de confiança",
                "Esta ordem abre a linha de \(buyingAsset.code): mais \(reserve) presos enquanto a conta aceitar \(buyingAsset.code)"
            ))
        }
        lines += assetLines(sellingAsset, label: "Emissor de \(sellingAsset.code)")
        lines += assetLines(buyingAsset, label: "Emissor de \(buyingAsset.code)")
        lines += feeLines(fee, operations: bodies.count)

        let review = PlanReview(
            kind: .limitOrder,
            title: "Vender \(StellarAmount.format(sellAmount, sellingAsset)) por \(buyingAsset.code)",
            lines: lines
        )
        return try makePlan(bodies, memo: .none, feePerOperation: fee, review: review, context: context)
    }

    /// Cancela uma oferta aberta: `ManageSellOffer` com `amount` 0 e o `offerID`.
    /// O core so olha o id e o dono; os ativos vao os da oferta, para a tela e o
    /// explorador mostrarem o par certo. Cancelar nunca prende saldo, entao vale
    /// para qualquer ativo, mesmo fora da lista.
    public static func planCancelOrder(
        offerID: Int64, selling sellingAsset: StellarAsset, buying buyingAsset: StellarAsset,
        context: StellarPlanContext
    ) throws -> SigningPlan {
        try check(context)
        guard offerID > 0 else { throw StellarPlanError.invalidOfferID }
        guard sellingAsset != buyingAsset else { throw StellarPlanError.sameAsset }
        let fee = try feePerOperation(context.network)
        try requireBalance(context.account.spendable(baseReserve: context.network.baseReserve), covers: fee, asset: .native)

        let review = PlanReview(
            kind: .cancelOrder,
            title: "Cancelar oferta",
            lines: [
                PlanReview.Line("Oferta", String(offerID), verbatim: true),
                PlanReview.Line("Par", "\(sellingAsset.code) por \(buyingAsset.code)"),
                PlanReview.Line("Reserva", "\(StellarAmount.format(context.network.baseReserve, .native)) voltam a ficar livres"),
            ] + feeLines(fee, operations: 1)
        )
        return try makePlan(
            [.manageSellOffer(selling: sellingAsset, buying: buyingAsset, amount: 0, price: StellarPrice(n: 1, d: 1), offerID: offerID)],
            memo: .none, feePerOperation: fee, review: review, context: context
        )
    }

    // MARK: Regras comuns

    private static func check(_ context: StellarPlanContext) throws {
        guard context.account.account == context.source.account else { throw StellarPlanError.stateForAnotherAccount }
        guard let reserve = context.network.baseReserve.uint64, StellarLimits.baseReserveRange.contains(reserve) else {
            throw StellarPlanError.suspiciousNetworkState
        }
        guard context.account.sequence >= 0, context.account.sequence < Int64.max else {
            throw StellarPlanError.sequenceOverflow
        }
    }

    /// max(100, taxa base, p90 cobrado), limitado ao teto. Se a propria taxa base
    /// passa do teto, recusa: ou a rede esta num surto fora do comum, ou o provedor
    /// mente, e nos dois casos o dono decide depois.
    static func feePerOperation(_ network: StellarNetworkState) throws -> BigUInt {
        guard network.baseFee <= StellarLimits.maxFeePerOperation else { throw StellarPlanError.feeAboveCeiling }
        let bid = max(StellarLimits.minFeePerOperation, network.baseFee, network.feeChargedP90)
        return min(bid, StellarLimits.maxFeePerOperation)
    }

    private static func resolveDestination(_ text: String, context: StellarPlanContext) throws -> StellarMuxedAccount {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination = StellarMuxedAccount(address: trimmed) else {
            if case .failure(let problem) = Address.validate(trimmed, for: .stellar) {
                throw StellarPlanError.invalidDestination(problem)
            }
            throw StellarPlanError.invalidDestination(.malformed)
        }
        guard destination.account != context.source.account else { throw StellarPlanError.destinationIsSelf }
        return destination
    }

    /// SEP-29 e contas muxed. Endereco M ja identifica o cliente: o SEP-29 nao se
    /// aplica a ele, e um memo ID junto seria um segundo id disputando o credito.
    private static func checkMemo(_ memo: StellarMemo, destination: StellarMuxedAccount, state: StellarDestinationState) throws {
        if destination.isMuxed {
            if case .id = memo { throw StellarPlanError.memoIDWithMuxedDestination }
        } else if state.memoRequired, memo.isNone {
            throw StellarPlanError.memoRequired
        }
    }

    private static func int64(_ amount: BigUInt) throws -> Int64 {
        guard !amount.isZero else { throw StellarPlanError.amountZero }
        guard let value = amount.uint64, value <= UInt64(Int64.max) else { throw StellarPlanError.amountTooLarge }
        return Int64(value)
    }

    private static func requireBalance(_ available: BigUInt, covers required: BigUInt, asset: StellarAsset) throws {
        guard available >= required else {
            throw StellarPlanError.insufficientBalance(available: available, required: required, asset: asset)
        }
    }

    private static func ownTrustline(_ asset: StellarAsset, context: StellarPlanContext) throws -> StellarTrustline {
        guard let line = context.account.trustline(for: asset) else { throw StellarPlanError.missingOwnTrustline(asset) }
        guard line.isAuthorized else { throw StellarPlanError.ownTrustlineNotAuthorized(asset) }
        return line
    }

    /// O lado que recebe numa troca ou oferta. Devolve `true` se a transacao
    /// precisa abrir a trustline antes.
    private static func receivingSide(_ asset: StellarAsset, expecting amount: BigUInt, context: StellarPlanContext) throws -> Bool {
        guard !asset.isNative else { return false }
        guard let line = context.account.trustline(for: asset) else { return true }
        guard line.isAuthorized else { throw StellarPlanError.ownTrustlineNotAuthorized(asset) }
        guard line.room >= amount else { throw StellarPlanError.ownTrustlineFull(asset) }
        return false
    }

    /// O lado que paga: o ativo vendido e a taxa, que sempre sai em XLM, contando a
    /// reserva das subentradas que a transacao cria.
    private static func payingSide(
        _ asset: StellarAsset, amount: BigUInt, fee: BigUInt, newSubentries: UInt32, context: StellarPlanContext
    ) throws {
        let spendable = context.account.spendable(baseReserve: context.network.baseReserve, newSubentries: newSubentries)
        if asset.isNative {
            try requireBalance(spendable, covers: amount + fee, asset: .native)
        } else {
            try requireBalance(try ownTrustline(asset, context: context).available, covers: amount, asset: asset)
            try requireBalance(spendable, covers: fee, asset: .native)
        }
    }

    private static func makePlan(
        _ bodies: [StellarOperation.Body], memo: StellarMemo, feePerOperation fee: BigUInt,
        review: PlanReview, context: StellarPlanContext
    ) throws -> SigningPlan {
        guard let totalFee = (fee * BigUInt(bodies.count)).uint64, totalFee <= UInt64(UInt32.max) else {
            throw StellarPlanError.feeAboveCeiling
        }
        let now = UInt64(max(0, context.now.timeIntervalSince1970))
        let tx = try StellarTx(
            source: StellarMuxedAccount(account: context.source.account),
            fee: UInt32(totalFee),
            sequence: context.account.sequence + 1,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: now + StellarLimits.validitySeconds),
            memo: memo,
            operations: bodies.map { StellarOperation($0) }
        )
        let transaction = StellarTransaction(tx: tx, path: context.source.path, signer: context.source.account)
        return SigningPlan(walletID: context.walletID, chain: .stellar, review: review, transactions: [transaction], createdAt: context.now)
    }

    // MARK: Tela

    private static func destinationLines(_ destination: StellarMuxedAccount) -> [PlanReview.Line] {
        var lines = [PlanReview.Line("Para", destination.address, verbatim: true)]
        if let id = destination.id {
            lines.append(PlanReview.Line("Conta base", destination.account.address, verbatim: true))
            lines.append(PlanReview.Line("ID no endereço M", String(id), verbatim: true))
        }
        return lines
    }

    private static func memoLines(_ memo: StellarMemo) -> [PlanReview.Line] {
        guard !memo.isNone else { return [] }
        return [PlanReview.Line(memo.reviewLabel, memo.reviewValue, verbatim: true)]
    }

    private static func assetLines(_ asset: StellarAsset, label: String) -> [PlanReview.Line] {
        guard let issuer = asset.issuer else { return [] }
        return [PlanReview.Line(label, issuer.address, verbatim: true)]
    }

    private static func feeLines(_ fee: BigUInt, operations: Int) -> [PlanReview.Line] {
        [
            PlanReview.Line("Rede", "Stellar"),
            PlanReview.Line("Taxa máxima", StellarAmount.format(fee * BigUInt(operations), .native)),
        ]
    }

    static func percentText(basisPoints: UInt32) -> String {
        let whole = basisPoints / 100
        let fraction = basisPoints % 100
        guard fraction != 0 else { return "\(whole)%" }
        let digits = fraction % 10 == 0 ? String(fraction / 10) : String(format: "%02d", fraction)
        return "\(whole),\(digits)%"
    }

    /// Taxa como porcentagem do valor, so para o aviso de taxa alta.
    private static func feePercent(fee: BigUInt, amount: BigUInt) -> Double? {
        guard let f = fee.uint64, let a = amount.uint64, a > 0 else { return nil }
        return Double(f) / Double(a) * 100
    }
}
