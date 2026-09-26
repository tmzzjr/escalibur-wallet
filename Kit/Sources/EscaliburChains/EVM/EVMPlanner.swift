import EscaliburCore
import Foundation

// Planejamento validado: a unica porta de uma transacao EVM ate o assinador.
//
// Cada funcao recebe a intencao do dono e o estado publico da rede, confere tudo e
// so entao devolve um `SigningPlan`. Toda transacao montada aqui passa de novo pela
// guarda de chamada, e o que a guarda decodifica tem de ser igual a intencao: se um
// dia o codificador e o decodificador discordarem, o plano nao sai.

/// Valor de uma aprovacao. Ilimitada so por escolha explicita, nunca como padrao.
public enum EVMApprovalAmount: Sendable, Equatable {
    case exact(BigUInt)
    case unlimited

    var value: BigUInt {
        switch self {
        case .exact(let amount): return amount
        case .unlimited: return .uint256Max
        }
    }
}

public enum EVMPlanner {
    /// Tokens que recusam mudar uma allowance diferente de zero para outro valor
    /// diferente de zero: e preciso `approve(0)` antes. O USDT da Ethereum e o caso
    /// conhecido (TetherToken.approve: `require(!((_value != 0) && (allowed != 0)))`).
    static let zeroFirstApprovalTokens: [(chainID: UInt64, contract: EVMAddress)] = [
        (1, EVMAddress(uncheckedBytes: [UInt8](hex: "dac17f958d2ee523a2206206994597c13d831ec7")!)),
    ]

    public static func requiresZeroFirstApproval(_ token: EVMToken) -> Bool {
        zeroFirstApprovalTokens.contains { $0.chainID == token.chain.evmChainID && $0.contract == token.contract }
    }

    // MARK: Envio nativo

    public static func planNativeSend(
        walletID: UUID, account: EVMAccount, chain: Chain, to recipient: EVMAddress, amount: BigUInt,
        state: EVMNetworkState, speed: EVMFeeSpeed = .normal, format: EVMTransactionFormat = .eip1559,
        policy: EVMCallPolicy = EVMCallPolicy(), now: Date = .now
    ) throws -> SigningPlan {
        guard chain.family == .evm else { throw EVMPlanError.notEVMChain }
        guard state.chain.id == chain.id else { throw EVMPlanError.chainMismatch }
        guard !amount.isZero else { throw EVMPlanError.zeroAmount }
        try refuseRecipient(recipient, policy: policy)

        let quote = try EVMFeeCalculator.quote(chain: chain, state: state, speed: speed, format: format, plainTransfer: !state.destinationHasCode)
        let nonce = try EVMFeeCalculator.nonce(state)
        try requireNative(amount + quote.maxCost, state: state)

        let transaction = try EVMTransaction(
            chain: chain, account: account, nonce: nonce, fee: quote.fee, gasLimit: quote.gasLimit,
            to: recipient, value: amount, data: []
        )
        try confirm(transaction, decodesTo: .nativeTransfer(to: recipient, amount: amount), policy: policy)

        var warnings = [PlanReview.Warning]()
        if state.destinationHasCode { warnings.append(.destinationIsContract) }
        if let percent = feePercent(quote.expectedCost, of: amount) { warnings.append(.highFee(percentOfAmount: percent)) }

        let amountText = EVMText.amount(amount, decimals: chain.nativeDecimals, symbol: chain.nativeSymbol)
        let review = PlanReview(
            kind: .send, title: "Enviar \(amountText)",
            lines: [
                .init("Rede", chain.name),
                .init("Para", recipient.checksummed, verbatim: true),
                .init("Valor", amountText),
            ] + feeLines(chain: chain, quote: quote, count: 1) + [.init("Nonce", "\(nonce)")],
            warnings: warnings, transactionCount: 1, recipient: recipient.checksummed
        )
        return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: [transaction], createdAt: now)
    }

    /// Quanto da para enviar do nativo com a taxa maxima descontada. Zero se a taxa
    /// ja passa do saldo.
    public static func maxNativeSendAmount(
        chain: Chain, state: EVMNetworkState, speed: EVMFeeSpeed = .normal, format: EVMTransactionFormat = .eip1559
    ) throws -> BigUInt {
        let quote = try EVMFeeCalculator.quote(chain: chain, state: state, speed: speed, format: format, plainTransfer: !state.destinationHasCode)
        return state.nativeBalance.subtractingReportingUnderflow(quote.maxCost) ?? 0
    }

    // MARK: Envio de token

    /// `valueInNativeUnits` e o valor do envio convertido para wei do nativo, pelo
    /// preco que o app tem; so serve para o aviso de taxa alta. Sem ele, sem aviso.
    public static func planTokenSend(
        walletID: UUID, account: EVMAccount, token: EVMToken, to recipient: EVMAddress, amount: BigUInt,
        state: EVMNetworkState, tokenState: EVMTokenState, valueInNativeUnits: BigUInt? = nil,
        speed: EVMFeeSpeed = .normal, format: EVMTransactionFormat = .eip1559,
        policy: EVMCallPolicy = EVMCallPolicy(), now: Date = .now
    ) throws -> SigningPlan {
        let chain = token.chain
        guard chain.family == .evm else { throw EVMPlanError.notEVMChain }
        guard state.chain.id == chain.id else { throw EVMPlanError.chainMismatch }
        guard !amount.isZero else { throw EVMPlanError.zeroAmount }
        guard tokenState.contractHasCode else { throw EVMPlanError.tokenHasNoCode }
        // Mandar o token para o proprio contrato do token prende o saldo para sempre.
        guard recipient != token.contract else { throw EVMPlanError.refused(.recipientIsTokenContract) }
        try refuseRecipient(recipient, policy: policy)
        guard tokenState.balance >= amount else {
            throw EVMPlanError.insufficientTokenBalance(needed: amount, available: tokenState.balance)
        }

        let quote = try EVMFeeCalculator.quote(chain: chain, state: state, speed: speed, format: format, plainTransfer: false)
        let nonce = try EVMFeeCalculator.nonce(state)
        try requireNative(quote.maxCost, state: state)

        let transaction = try EVMTransaction(
            chain: chain, account: account, nonce: nonce, fee: quote.fee, gasLimit: quote.gasLimit,
            to: token.contract, value: 0, data: ERC20.transfer(to: recipient, amount: amount)
        )
        try confirm(transaction, decodesTo: .tokenTransfer(token: token.contract, to: recipient, amount: amount), policy: policy)

        var warnings = [PlanReview.Warning]()
        if state.destinationHasCode { warnings.append(.destinationIsContract) }
        if let value = valueInNativeUnits, let percent = feePercent(quote.expectedCost, of: value) {
            warnings.append(.highFee(percentOfAmount: percent))
        }

        let amountText = EVMText.amount(amount, decimals: Int(token.decimals), symbol: token.symbol)
        let review = PlanReview(
            kind: .send, title: "Enviar \(amountText)",
            lines: [
                .init("Rede", chain.name),
                .init("Para", recipient.checksummed, verbatim: true),
                .init("Valor", amountText),
                .init("Contrato do token", token.contract.checksummed, verbatim: true),
            ] + feeLines(chain: chain, quote: quote, count: 1) + [.init("Nonce", "\(nonce)")],
            warnings: warnings, transactionCount: 1, recipient: recipient.checksummed
        )
        return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: [transaction], createdAt: now)
    }

    // MARK: Aprovacao

    /// Approve de valor exato para um spender da allowlist (`policy.approvedSpenders`).
    /// No USDT da Ethereum com allowance atual diferente de zero, o plano leva duas
    /// transacoes: `approve(0)` e depois o novo valor, as duas na tela.
    ///
    /// `state.gasEstimate` vale para as duas. A camada de rede estima o approve do
    /// novo valor a partir de allowance zero (com state override): estimar direto,
    /// com a allowance atual, reverte no USDT.
    public static func planApprove(
        walletID: UUID, account: EVMAccount, token: EVMToken, spender: EVMAddress, amount: EVMApprovalAmount,
        state: EVMNetworkState, tokenState: EVMTokenState, policy: EVMCallPolicy,
        speed: EVMFeeSpeed = .normal, format: EVMTransactionFormat = .eip1559, now: Date = .now
    ) throws -> SigningPlan {
        let chain = token.chain
        guard chain.family == .evm else { throw EVMPlanError.notEVMChain }
        guard state.chain.id == chain.id else { throw EVMPlanError.chainMismatch }
        if case .exact(let value) = amount {
            guard !value.isZero else { throw EVMPlanError.zeroAmount }
            guard value != .uint256Max else { throw EVMPlanError.unlimitedMustBeExplicit }
        }
        guard spender != account.address else { throw EVMPlanError.selfApproval }
        guard policy.approvedSpenders.contains(spender) else { throw EVMPlanError.refused(.spenderNotAllowed(spender)) }
        guard tokenState.contractHasCode else { throw EVMPlanError.tokenHasNoCode }
        // Spender da allowlist sem codigo nesta rede e allowlist errada para a rede:
        // o approve iria para um endereco que qualquer um pode vir a controlar.
        guard state.destinationHasCode else { throw EVMPlanError.spenderHasNoCode }
        guard let current = tokenState.allowance else { throw EVMPlanError.missingAllowance }
        guard current != amount.value else { throw EVMPlanError.allowanceAlreadySet }

        let quote = try EVMFeeCalculator.quote(chain: chain, state: state, speed: speed, format: format, plainTransfer: false)
        let nonce = try EVMFeeCalculator.nonce(state)
        let resetFirst = requiresZeroFirstApproval(token) && !current.isZero
        let values: [BigUInt] = resetFirst ? [0, amount.value] : [amount.value]
        try requireNative(quote.maxCost * BigUInt(values.count), state: state)

        var transactions = [EVMTransaction]()
        for (offset, value) in values.enumerated() {
            let transaction = try EVMTransaction(
                chain: chain, account: account, nonce: nonce + UInt64(offset), fee: quote.fee, gasLimit: quote.gasLimit,
                to: token.contract, value: 0, data: ERC20.approve(spender: spender, amount: value)
            )
            try confirm(transaction, decodesTo: .tokenApproval(token: token.contract, spender: spender, amount: value), policy: policy)
            transactions.append(transaction)
        }

        let valueText: String
        let title: String
        var warnings = [PlanReview.Warning]()
        switch amount {
        case .exact(let value):
            valueText = EVMText.amount(value, decimals: Int(token.decimals), symbol: token.symbol)
            title = "Autorizar \(valueText)"
        case .unlimited:
            valueText = "Sem limite"
            title = "Autorizar \(token.symbol) sem limite"
            warnings.append(.unlimitedApproval)
        }
        var lines: [PlanReview.Line] = [
            .init("Rede", chain.name),
            .init("Autorizado a gastar", spender.checksummed, verbatim: true),
            .init("Valor autorizado", valueText),
            .init("Contrato do token", token.contract.checksummed, verbatim: true),
        ]
        if resetFirst {
            lines.append(.init("Etapas", "Zerar a autorização atual e aprovar o novo valor"))
        }
        lines += feeLines(chain: chain, quote: quote, count: values.count)
        lines.append(.init("Nonce", resetFirst ? "\(nonce) e \(nonce + 1)" : "\(nonce)"))
        let review = PlanReview(kind: .approve, title: title, lines: lines, warnings: warnings, transactionCount: transactions.count)
        return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: transactions, createdAt: now)
    }

    /// `approve(spender, 0)`. Vale para qualquer spender, dentro ou fora da
    /// allowlist: revogar nunca expoe nada, e e assim que se desfaz aprovacao antiga.
    public static func planRevoke(
        walletID: UUID, account: EVMAccount, token: EVMToken, spender: EVMAddress,
        state: EVMNetworkState, tokenState: EVMTokenState,
        speed: EVMFeeSpeed = .normal, format: EVMTransactionFormat = .eip1559, now: Date = .now
    ) throws -> SigningPlan {
        let chain = token.chain
        guard chain.family == .evm else { throw EVMPlanError.notEVMChain }
        guard state.chain.id == chain.id else { throw EVMPlanError.chainMismatch }
        guard tokenState.contractHasCode else { throw EVMPlanError.tokenHasNoCode }
        guard let current = tokenState.allowance else { throw EVMPlanError.missingAllowance }
        guard !current.isZero else { throw EVMPlanError.nothingToRevoke }

        let quote = try EVMFeeCalculator.quote(chain: chain, state: state, speed: speed, format: format, plainTransfer: false)
        let nonce = try EVMFeeCalculator.nonce(state)
        try requireNative(quote.maxCost, state: state)

        let transaction = try EVMTransaction(
            chain: chain, account: account, nonce: nonce, fee: quote.fee, gasLimit: quote.gasLimit,
            to: token.contract, value: 0, data: ERC20.approve(spender: spender, amount: 0)
        )
        try confirm(transaction, decodesTo: .tokenApproval(token: token.contract, spender: spender, amount: 0), policy: EVMCallPolicy())

        let review = PlanReview(
            kind: .revoke, title: "Revogar autorização de \(token.symbol)",
            lines: [
                .init("Rede", chain.name),
                .init("Autorizado a gastar", spender.checksummed, verbatim: true),
                .init("Contrato do token", token.contract.checksummed, verbatim: true),
            ] + feeLines(chain: chain, quote: quote, count: 1) + [.init("Nonce", "\(nonce)")],
            transactionCount: 1
        )
        return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: [transaction], createdAt: now)
    }

    // MARK: Comum

    static func refuseRecipient(_ recipient: EVMAddress, policy: EVMCallPolicy) throws {
        do {
            try EVMCallGuard.checkRecipient(recipient, policy: policy)
        } catch let refusal as EVMCallRefusal {
            throw EVMPlanError.refused(refusal)
        }
    }

    static func requireNative(_ needed: BigUInt, state: EVMNetworkState) throws {
        guard state.nativeBalance >= needed else {
            throw EVMPlanError.insufficientNativeBalance(needed: needed, available: state.nativeBalance)
        }
    }

    /// A transacao montada volta pela guarda, e o que ela le tem de ser a intencao.
    static func confirm(_ transaction: EVMTransaction, decodesTo expected: EVMDecodedCall, policy: EVMCallPolicy) throws {
        let decoded: EVMDecodedCall
        do {
            decoded = try EVMCallGuard.inspect(EVMCallProposal(transaction), policy: policy)
        } catch let refusal as EVMCallRefusal {
            throw EVMPlanError.refused(refusal)
        }
        guard decoded == expected else { throw EVMPlanError.refused(.malformedCalldata) }
    }

    /// Taxa acima de 3% do valor pede confirmacao extra (docs/seguranca.md 4.3).
    static func feePercent(_ fee: BigUInt, of value: BigUInt) -> Double? {
        guard !value.isZero, fee * BigUInt(100) > value * BigUInt(3) else { return nil }
        // Centesimos de ponto percentual, so para exibir.
        let hundredths = fee * BigUInt(10_000) / value
        guard let small = hundredths.uint64 else { return Double.greatestFiniteMagnitude }
        return Double(small) / 100
    }

    static func feeLines(chain: Chain, quote: EVMFeeQuote, count: Int) -> [PlanReview.Line] {
        let factor = BigUInt(count)
        var lines: [PlanReview.Line] = [
            .init("Taxa estimada", EVMText.amount(quote.expectedCost * factor, decimals: chain.nativeDecimals, symbol: chain.nativeSymbol)),
            .init("Taxa máxima", EVMText.amount(quote.maxCost * factor, decimals: chain.nativeDecimals, symbol: chain.nativeSymbol)),
        ]
        if !quote.l1DataFee.isZero {
            lines.append(.init("Parte da taxa paga à L1", EVMText.amount(quote.l1DataFee * factor, decimals: chain.nativeDecimals, symbol: chain.nativeSymbol)))
        }
        return lines
    }
}

/// Texto exato de valor para a revisao: sem arredondar, virgula decimal, ponto de
/// milhar, espaco nao separavel antes do simbolo. O que a tela de revisao mostra
/// tem de ser o que vai ser assinado, digito por digito.
enum EVMText {
    static func amount(_ value: BigUInt, decimals: Int, symbol: String) -> String {
        number(value, decimals: decimals) + "\u{00A0}" + symbol
    }

    static func number(_ value: BigUInt, decimals: Int) -> String {
        let digits = Array(value.decimalString)
        let padded = [Character](repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let integer = Array(padded.prefix(padded.count - decimals))
        var fraction = Array(padded.suffix(decimals))
        while fraction.last == "0" { fraction.removeLast() }
        var grouped = [Character]()
        for (index, digit) in integer.enumerated() {
            if index > 0, (integer.count - index) % 3 == 0 { grouped.append(".") }
            grouped.append(digit)
        }
        return fraction.isEmpty ? String(grouped) : String(grouped) + "," + String(fraction)
    }
}
