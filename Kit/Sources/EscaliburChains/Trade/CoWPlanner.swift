import EscaliburCore
import Foundation

// O plano da ordem limite pela CoW, e os dois cancelamentos.
//
// Ordem: [approve exato ao VaultRelayer] + [embrulhar o nativo] + assinatura EIP-712 da
// ordem. As transacoes sao montadas aqui (nao ha calldata de provedor), e a ordem so vai
// para a API depois que elas confirmarem: a CoW recusa ordem sem saldo e allowance.
//
// Cancelar, dito com honestidade na tela (docs/seguranca.md 4.5):
// - fora da cadeia: `OrderCancellations` assinado e enviado a API. Gratis, mas nao
//   garantido (um solver pode estar liquidando naquele instante);
// - na cadeia: `invalidateOrder(uid)` no GPv2Settlement. Garantido depois de confirmar,
//   custa taxa de rede. Revogar a aprovacao do VaultRelayer tambem impede a execucao.

public enum CoWRefusal: Error, Equatable, Sendable {
    case unsupportedChain
    case validityOutOfRange
    case zeroBuyAmount
    case sameToken
    /// Ja existe ordem aberta vendendo o mesmo token: uma ordem antiga e esquecida
    /// executaria quando o saldo voltasse. So com confirmacao explicita, e com a soma
    /// cabendo no saldo e na aprovacao.
    case openOrderExists
    case invalidUID
    case relayerHasNoCode
    case insufficientBalance(needed: BigUInt, available: BigUInt)
    case missingWrapGas
    case plan(EVMPlanError)
}

/// A intencao da ordem limite: vender `sellAmount` recebendo pelo menos o preco-alvo.
public struct CoWLimitOrderIntent: Sendable, Equatable {
    public let owner: EVMAddress
    public let sell: TradeAsset
    public let buy: TradeAsset
    public let sellAmount: BigUInt
    public let price: CoWLimitPrice
    public let validFor: TimeInterval
    public let partiallyFillable: Bool

    public init(owner: EVMAddress, sell: TradeAsset, buy: TradeAsset, sellAmount: BigUInt, price: CoWLimitPrice,
                validFor: TimeInterval = CoWProtocol.defaultValidity, partiallyFillable: Bool = true) throws {
        guard CoWProtocol.supports(sell.chain), buy.chain.id == sell.chain.id else { throw CoWRefusal.unsupportedChain }
        guard sell != buy else { throw CoWRefusal.sameToken }
        guard !sellAmount.isZero else { throw TradeRefusal.zeroAmount }
        guard validFor == CoWProtocol.untilCancelledValidity || (validFor >= CoWProtocol.minValidity && validFor <= CoWProtocol.maxValidity) else {
            throw CoWRefusal.validityOutOfRange
        }
        self.owner = owner
        self.sell = sell
        self.buy = buy
        self.sellAmount = sellAmount
        self.price = price
        self.validFor = validFor
        self.partiallyFillable = partiallyFillable
    }

    public var chain: Chain { sell.chain }

    /// O dono pediu "ate cancelar": a ordem vale o maximo pratico da CoW.
    public var isUntilCancelled: Bool { validFor == CoWProtocol.untilCancelledValidity }

    /// O token que a ordem vende de fato: o embrulhado, se o dono vende o nativo.
    public var orderSellToken: EVMToken? {
        switch sell {
        case .token(let token): return token
        case .native(let chain): return CoWProtocol.wrappedNative(on: chain)
        }
    }

    /// O minimo que a ordem exige, calculado aqui.
    public var buyAmount: BigUInt {
        price.buyAmount(sellAmount: sellAmount, sellDecimals: sell.decimals, buyDecimals: buy.decimals)
    }
}

/// O estado publico que a ordem precisa.
public struct CoWChainState: Sendable {
    /// Nonce, taxas e saldo nativo. `gasEstimate` e o do approve; `destinationHasCode` e
    /// o codigo do VaultRelayer.
    public let network: EVMNetworkState
    /// O token que a ordem vende (o embrulhado, se vende nativo): saldo e
    /// `allowance(dono, VaultRelayer)`.
    public let sellToken: EVMTokenState
    /// Vende nativo: gas do `deposit()` do token embrulhado.
    public let wrapGasEstimate: UInt64?
    public let wrapL1DataFee: BigUInt?
    /// Soma do `sellAmount` das ordens abertas deste dono vendendo o mesmo token (do
    /// registro local e de `GET /api/v1/account/{dono}/orders`).
    public let openOrdersSellTotal: BigUInt

    public init(network: EVMNetworkState, sellToken: EVMTokenState, wrapGasEstimate: UInt64? = nil,
                wrapL1DataFee: BigUInt? = nil, openOrdersSellTotal: BigUInt = 0) {
        self.network = network
        self.sellToken = sellToken
        self.wrapGasEstimate = wrapGasEstimate
        self.wrapL1DataFee = wrapL1DataFee
        self.openOrdersSellTotal = openOrdersSellTotal
    }
}

/// O plano da ordem: o `SigningPlan` e o que a rede precisa para enviar depois.
public struct CoWLimitOrderPlan: Sendable {
    public let signingPlan: SigningPlan
    public let order: CoWOrder
    public let owner: EVMAddress
    /// O UID calculado aqui. A API tem de devolver exatamente este.
    public let uid: [UInt8]
    public let appData: CoWAppData
    /// Posicao da assinatura da ordem dentro do plano (a ultima).
    public var orderSignatureIndex: Int { signingPlan.transactions.count - 1 }
    /// Transacoes que precisam confirmar antes de enviar a ordem.
    public var prerequisiteCount: Int { signingPlan.transactions.count - 1 }
}

public enum CoWPlanner {
    public static func planLimitOrder(
        walletID: UUID, account: EVMAccount, intent: CoWLimitOrderIntent, state: CoWChainState,
        stackingConfirmed: Bool = false, speed: EVMFeeSpeed = .normal, now: Date = .now
    ) throws -> CoWLimitOrderPlan {
        let chain = intent.chain
        guard account.address == intent.owner else { throw TradeRefusal.ownerMismatch }
        guard state.network.chain.id == chain.id else { throw CoWRefusal.plan(.chainMismatch) }
        guard let sellToken = intent.orderSellToken else { throw CoWRefusal.unsupportedChain }
        guard state.network.destinationHasCode else { throw CoWRefusal.relayerHasNoCode }
        let buyToken = intent.buy.contract ?? CoWProtocol.buyNativeToken
        guard buyToken != sellToken.contract else { throw CoWRefusal.sameToken }
        let buyAmount = intent.buyAmount
        guard !buyAmount.isZero else { throw CoWRefusal.zeroBuyAmount }

        // Uma ordem aberta por token vendido, salvo confirmacao; com confirmacao, a
        // aprovacao cobre exatamente a soma, e a soma tem de caber no saldo.
        let open = state.openOrdersSellTotal
        guard open.isZero || stackingConfirmed else { throw CoWRefusal.openOrderExists }
        let approvalTotal = open + intent.sellAmount
        let wrapping = intent.sell.isNative
        let available = state.sellToken.balance + (wrapping ? intent.sellAmount : 0)
        guard available >= approvalTotal else { throw CoWRefusal.insufficientBalance(needed: approvalTotal, available: available) }

        let validTo = UInt32(min(Double(UInt32.max), (now.timeIntervalSince1970 + intent.validFor).rounded(.down)))
        let appData = CoWAppData.limitOrder
        let order = CoWOrder(
            chain: chain, sellToken: sellToken.contract, buyToken: buyToken, receiver: account.address,
            sellAmount: intent.sellAmount, buyAmount: buyAmount, validTo: validTo, appData: appData.hash,
            partiallyFillable: intent.partiallyFillable
        )

        var transactions = [any SignableTransaction]()
        var feeQuotes = [EVMFeeQuote]()
        do {
            // 1. Approve exato ao VaultRelayer, se a allowance nao cobre.
            let allowance = state.sellToken.allowance ?? 0
            if allowance < approvalTotal {
                let approve = try EVMPlanner.planApprove(
                    walletID: walletID, account: account, token: sellToken, spender: CoWProtocol.vaultRelayer,
                    amount: .exact(approvalTotal), state: state.network, tokenState: state.sellToken,
                    policy: EVMCallPolicy(approvedSpenders: [CoWProtocol.vaultRelayer]), speed: speed, now: now
                )
                transactions += approve.transactions
                let quote = try EVMFeeCalculator.quote(chain: chain, state: state.network, speed: speed, format: .eip1559, plainTransfer: false)
                feeQuotes += Array(repeating: quote, count: approve.transactions.count)
            }
            // 2. Embrulhar o nativo, depois do approve (approve nao depende de saldo).
            if wrapping {
                guard let wrapGas = state.wrapGasEstimate else { throw CoWRefusal.missingWrapGas }
                let wrapState = TradePlanner.derivedState(state.network, gas: wrapGas, l1: state.wrapL1DataFee, hasCode: true)
                let quote = try EVMFeeCalculator.quote(chain: chain, state: wrapState, speed: speed, format: .eip1559, plainTransfer: false)
                let nonce = try EVMFeeCalculator.nonce(state.network) + UInt64(transactions.count)
                let wrap = try EVMTransaction(
                    chain: chain, account: account, nonce: nonce, fee: quote.fee, gasLimit: quote.gasLimit,
                    to: sellToken.contract, value: intent.sellAmount, data: CoWProtocol.depositFunction.selector
                )
                try confirmWrap(wrap, token: sellToken.contract, amount: intent.sellAmount)
                transactions.append(wrap)
                feeQuotes.append(quote)
            }
        } catch let error as EVMPlanError {
            throw CoWRefusal.plan(error)
        } catch let error as EVMTransactionError {
            throw CoWRefusal.plan(error == .notEVMChain ? .notEVMChain : .gasLimitAboveCap)
        }

        // Saldo nativo: taxa maxima de tudo e o valor embrulhado.
        let feeMax = feeQuotes.reduce(BigUInt()) { $0 + $1.maxCost }
        let nativeNeeded = feeMax + (wrapping ? intent.sellAmount : 0)
        guard state.network.nativeBalance >= nativeNeeded else {
            throw CoWRefusal.plan(.insufficientNativeBalance(needed: nativeNeeded, available: state.network.nativeBalance))
        }

        // 3. A ordem, validada contra a allowlist de mensagens tipadas.
        let message = try EIP712ValidatedMessage(
            order.typedData(), chain: chain, account: account,
            allowlist: [orderRule(chain: chain, order: order, now: now)]
        )
        transactions.append(message)
        let uid = message.digest + account.address.bytes + withUnsafeBytes(of: validTo.bigEndian) { Array($0) }

        let review = orderReview(intent: intent, order: order, sellToken: sellToken, feeQuotes: feeQuotes,
                                 approvalTotal: approvalTotal, needsApproval: (state.sellToken.allowance ?? 0) < approvalTotal,
                                 wrapping: wrapping, stacked: !open.isZero)
        let plan = SigningPlan(walletID: walletID, chain: chain, review: review, transactions: transactions, createdAt: now)
        return CoWLimitOrderPlan(signingPlan: plan, order: order, owner: account.address, uid: uid, appData: appData)
    }

    /// A regra da mensagem tipada da ordem: dominio e tipo compilados, e o conteudo igual
    /// a ordem montada (destinatario = dono, taxa zero, venda, saldo ERC-20, appData
    /// nosso, prazo dentro da janela).
    static func orderRule(chain: Chain, order: CoWOrder, now: Date) -> EIP712Rule {
        // O prazo e o que o dono escolheu (1 hora a 30 dias) ou exatamente o "ate
        // cancelar" (o maximo pratico da CoW); nada entre um e outro.
        let base = now.timeIntervalSince1970
        let windows = [
            (base + CoWProtocol.minValidity - 60)...(base + CoWProtocol.maxValidity + 60),
            (base + CoWProtocol.untilCancelledValidity - 60)...(base + CoWProtocol.untilCancelledValidity + 60),
        ]
        return EIP712Rule(
            chain: chain, verifyingContract: CoWProtocol.settlement, primaryType: "Order",
            encodedType: CoWProtocol.orderEncodedType, domainName: CoWProtocol.domainName, domainVersion: CoWProtocol.domainVersion
        ) { message, owner in
            func text(_ key: String) -> String? {
                switch message[key] {
                case .string(let value)?, .number(let value)?: return value
                default: return nil
                }
            }
            guard let receiver = text("receiver").flatMap({ try? EVMAddress($0) }), receiver == owner,
                  text("sellToken").flatMap({ try? EVMAddress($0) }) == order.sellToken,
                  text("buyToken").flatMap({ try? EVMAddress($0) }) == order.buyToken,
                  text("sellAmount") == order.sellAmount.decimalString,
                  text("buyAmount") == order.buyAmount.decimalString,
                  text("feeAmount") == "0", text("kind") == "sell",
                  text("sellTokenBalance") == "erc20", text("buyTokenBalance") == "erc20",
                  text("appData")?.lowercased() == CoWAppData.limitOrder.hashHex.lowercased(),
                  let validTo = text("validTo").flatMap(Double.init), windows.contains(where: { $0.contains(validTo) })
            else { throw EIP712Error.notAllowlisted }
        }
    }

    static func confirmWrap(_ transaction: EVMTransaction, token: EVMAddress, amount: BigUInt) throws {
        let rule = EVMContractCallRule(contract: token, function: CoWProtocol.depositFunction) { arguments, value in
            guard arguments.isEmpty, value == amount else { throw EVMCallRefusal.ruleRejected("deposit") }
        }
        do {
            _ = try EVMCallGuard.inspect(EVMCallProposal(transaction), policy: EVMCallPolicy(contractRules: [rule]))
        } catch let refusal as EVMCallRefusal {
            throw EVMPlanError.refused(refusal)
        }
    }

    // MARK: Cancelamento fora da cadeia

    /// `OrderCancellations(bytes[] orderUids)` assinado, para `DELETE /api/v1/orders`.
    public static func planOffchainCancellation(
        walletID: UUID, account: EVMAccount, chain: Chain, uids: [[UInt8]], now: Date = .now
    ) throws -> SigningPlan {
        guard CoWProtocol.supports(chain) else { throw CoWRefusal.unsupportedChain }
        guard !uids.isEmpty, uids.count <= 128 else { throw CoWRefusal.invalidUID }
        for uid in uids { guard CoWProtocol.owner(ofUID: uid) == account.address else { throw CoWRefusal.invalidUID } }
        let typed = try cancellationTypedData(chain: chain, uids: uids)
        let message = try EIP712ValidatedMessage(typed, chain: chain, account: account, allowlist: [cancellationRule(chain: chain)])
        var lines: [PlanReview.Line] = [
            .init("Rede", chain.name),
            .init("Como", "Pedido assinado à CoW, sem taxa de rede"),
            .init("Garantia", "Não é garantido: se um solver já estiver liquidando, a ordem ainda pode executar. Para ter certeza, cancele na cadeia."),
        ]
        for uid in uids { lines.append(.init("Ordem", Hex.encode(uid, prefix: true), verbatim: true)) }
        let review = PlanReview(kind: .cancelOrder, title: uids.count == 1 ? "Cancelar ordem limite" : "Cancelar \(uids.count) ordens limite",
                                lines: lines, transactionCount: 1)
        return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: [message], createdAt: now)
    }

    public static func cancellationTypedData(chain: Chain, uids: [[UInt8]]) throws -> EIP712TypedData {
        try EIP712TypedData(
            types: ["OrderCancellations": [.init(name: "orderUids", type: "bytes[]")]],
            primaryType: "OrderCancellations", domain: CoWOrder.domain(chain),
            message: ["orderUids": .array(uids.map { .string(Hex.encode($0, prefix: true)) })]
        )
    }

    static func cancellationRule(chain: Chain) -> EIP712Rule {
        EIP712Rule(
            chain: chain, verifyingContract: CoWProtocol.settlement, primaryType: "OrderCancellations",
            encodedType: CoWProtocol.cancellationsEncodedType, domainName: CoWProtocol.domainName,
            domainVersion: CoWProtocol.domainVersion
        ) { message, owner in
            guard case .array(let items)? = message["orderUids"], !items.isEmpty else { throw EIP712Error.notAllowlisted }
            for item in items {
                guard case .string(let hex) = item, let uid = Hex.decode(hex), CoWProtocol.owner(ofUID: uid) == owner else {
                    throw EIP712Error.notAllowlisted
                }
            }
        }
    }

    // MARK: Cancelamento na cadeia

    /// `invalidateOrder(uid)` no GPv2Settlement. `state.gasEstimate` e o desta chamada.
    public static func planOnchainCancellation(
        walletID: UUID, account: EVMAccount, chain: Chain, uid: [UInt8], state: EVMNetworkState,
        speed: EVMFeeSpeed = .normal, now: Date = .now
    ) throws -> SigningPlan {
        guard CoWProtocol.supports(chain) else { throw CoWRefusal.unsupportedChain }
        guard CoWProtocol.owner(ofUID: uid) == account.address else { throw CoWRefusal.invalidUID }
        guard state.chain.id == chain.id else { throw CoWRefusal.plan(.chainMismatch) }
        let owner = account.address
        let rule = EVMContractCallRule(contract: CoWProtocol.settlement, function: CoWProtocol.invalidateOrderFunction) { arguments, value in
            guard value.isZero, arguments.count == 1, let raw = arguments[0].bytesValue, CoWProtocol.owner(ofUID: raw) == owner else {
                throw EVMCallRefusal.ruleRejected("invalidateOrder")
            }
        }
        do {
            let quote = try EVMFeeCalculator.quote(chain: chain, state: state, speed: speed, format: .eip1559, plainTransfer: false)
            let nonce = try EVMFeeCalculator.nonce(state)
            guard state.nativeBalance >= quote.maxCost else {
                throw EVMPlanError.insufficientNativeBalance(needed: quote.maxCost, available: state.nativeBalance)
            }
            let transaction = try EVMTransaction(
                chain: chain, account: account, nonce: nonce, fee: quote.fee, gasLimit: quote.gasLimit,
                to: CoWProtocol.settlement, value: 0, data: try CoWProtocol.invalidateOrderFunction.encodeCall([.bytes(uid)])
            )
            do {
                _ = try EVMCallGuard.inspect(EVMCallProposal(transaction), policy: EVMCallPolicy(contractRules: [rule]))
            } catch let refusal as EVMCallRefusal {
                throw EVMPlanError.refused(refusal)
            }
            let review = PlanReview(
                kind: .cancelOrder, title: "Cancelar ordem limite na cadeia",
                lines: [
                    .init("Rede", chain.name),
                    .init("Como", "invalidateOrder no contrato da CoW"),
                    .init("Garantia", "Garantido depois que a transação confirmar: o contrato marca a ordem como executada"),
                    .init("Contrato", CoWProtocol.settlement.checksummed, verbatim: true),
                    .init("Ordem", Hex.encode(uid, prefix: true), verbatim: true),
                ] + EVMPlanner.feeLines(chain: chain, quote: quote, count: 1) + [.init("Nonce", "\(nonce)")],
                transactionCount: 1
            )
            return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: [transaction], createdAt: now)
        } catch let error as EVMPlanError {
            throw CoWRefusal.plan(error)
        } catch is EVMTransactionError {
            throw CoWRefusal.plan(.gasLimitAboveCap)
        }
    }

    // MARK: Revisao

    static func orderReview(
        intent: CoWLimitOrderIntent, order: CoWOrder, sellToken: EVMToken, feeQuotes: [EVMFeeQuote],
        approvalTotal: BigUInt, needsApproval: Bool, wrapping: Bool, stacked: Bool
    ) -> PlanReview {
        let chain = intent.chain
        let native = TradeAsset.native(chain)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "dd/MM/yyyy HH:mm 'UTC'"
        let expiry = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(order.validTo)))

        var lines: [PlanReview.Line] = [
            .init("Rede", chain.name),
            .init("Vende", TradeText.amount(intent.sellAmount, intent.sell)),
            .init("Recebe, no mínimo", TradeText.amount(order.buyAmount, intent.buy)),
            .init("Preço-alvo", TradeText.price(amountIn: order.buyAmount, out: intent.sellAmount, sell: intent.buy, buy: intent.sell)),
            .init("Válida até", intent.isUntilCancelled
                ? "\(expiry), o prazo mais longo que a CoW aceita. Até lá, fica aberta até executar ou você cancelar"
                : expiry),
            .init("Execução parcial", intent.partiallyFillable ? "Permitida" : "Só inteira"),
            .init("Destinatário", order.receiver.checksummed, verbatim: true),
            .init("Contrato da CoW", CoWProtocol.settlement.checksummed, verbatim: true),
        ]
        if wrapping {
            lines.append(.init("Antes", "Converter \(TradeText.amount(intent.sellAmount, intent.sell)) em \(sellToken.symbol): a ordem vende \(sellToken.symbol)"))
        }
        if needsApproval {
            lines.append(.init("Autorização", "Exata: \(EVMText.amount(approvalTotal, decimals: Int(sellToken.decimals), symbol: sellToken.symbol)), nunca ilimitada"))
            lines.append(.init("Autorizado a gastar", CoWProtocol.vaultRelayer.checksummed, verbatim: true))
        } else {
            lines.append(.init("Autorização", "Já existe e cobre o valor"))
        }
        if stacked {
            lines.append(.init("Outras ordens", "Há outra ordem aberta vendendo \(sellToken.symbol); a autorização cobre só a soma das duas"))
        }
        if !feeQuotes.isEmpty {
            let expected = feeQuotes.reduce(BigUInt()) { $0 + $1.expectedCost }
            let maximum = feeQuotes.reduce(BigUInt()) { $0 + $1.maxCost }
            lines.append(.init("Taxa da rede (estimada)", TradeText.amount(expected, native)))
            lines.append(.init("Taxa da rede (máxima)", TradeText.amount(maximum, native)))
        }
        lines += [
            .init("Taxa da CoW", "Sem cobrança à parte: a ordem só executa se entregar pelo menos o mínimo"),
            .init("Taxa da Escalibur", "Sem taxa da Escalibur"),
            .init("Envio", feeQuotes.isEmpty
                ? "A ordem assinada vai direto para a CoW"
                : "A ordem assinada vai para a CoW depois que as transações acima confirmarem"),
            .init("Cancelar", "Nas ordens abertas da carteira: pedido à CoW, grátis mas sem garantia, ou na cadeia, garantido, pagando taxa de rede"),
        ]
        let title = "Ordem limite: vender \(TradeText.amount(order.sellAmount, intent.sell)) por \(intent.buy.symbol)"
        // Os movimentos saem da ordem assinada: vende `sellAmount` (o nativo, quando o
        // embrulho vem antes, pelo mesmo valor), recebe pelo menos `buyAmount`, e quem
        // recebe e o `receiver` gravado.
        return PlanReview(
            kind: .limitOrder, title: title, lines: lines, transactionCount: feeQuotes.count + 1,
            outgoing: intent.sell.movement(order.sellAmount), incomingMinimum: intent.buy.movement(order.buyAmount),
            beneficiary: order.receiver.checksummed
        )
    }
}
