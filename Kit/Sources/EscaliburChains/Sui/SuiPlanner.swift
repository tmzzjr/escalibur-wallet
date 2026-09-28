import EscaliburCore
import Foundation

// Planejamento validado do envio de SUI: da intencao do dono e do estado publico da
// rede (lido por EscaliburNetwork em dois provedores concordando) ate um `SigningPlan`.
//
// O envio sai da moeda de gas: as moedas de SUI do dono pagam o gas e viram uma so, e o
// valor e separado dela para o destino. Nada de chamada Move, objeto compartilhado ou
// outra moeda: a transacao que sai daqui so separa SUI e transfere.

// MARK: Estado publico que a camada de rede preenche

/// Uma moeda de SUI (`Coin<0x2::sui::SUI>`) do dono, numa versao exata.
public struct SuiCoin: Hashable, Sendable {
    public let ref: SuiObjectRef
    /// Em MIST (10^-9 SUI).
    public let balance: UInt64

    public init(ref: SuiObjectRef, balance: UInt64) {
        self.ref = ref
        self.balance = balance
    }
}

/// O estado da conta e da rede para um envio, lido em dois provedores concordando.
public struct SuiAccountState: Hashable, Sendable {
    /// As moedas de SUI do dono (`ListOwnedObjects` filtrado por `Coin<SUI>`), com id,
    /// versao, digesto e saldo iguais nos dois provedores. Sao elas que entram como gas.
    public let coins: [SuiCoin]
    /// Preco de referencia do gas da epoca (`GetEpoch`), em MIST por unidade.
    public let referenceGasPrice: UInt64
    /// A epoca atual. A transacao vale ate o fim da seguinte.
    public let epoch: UInt64
    /// SUI no saldo de endereco (fora das moedas). A carteira ainda nao move esse saldo;
    /// so aparece na tela.
    public let addressBalance: UInt64

    public init(coins: [SuiCoin], referenceGasPrice: UInt64, epoch: UInt64, addressBalance: UInt64 = 0) {
        self.coins = coins
        self.referenceGasPrice = referenceGasPrice
        self.epoch = epoch
        self.addressBalance = addressBalance
    }
}

/// Custo de gas de uma simulacao, em MIST (`GasCostSummary`).
public struct SuiGasCost: Hashable, Sendable {
    public let computationCost: UInt64
    public let storageCost: UInt64
    public let storageRebate: UInt64

    public init(computationCost: UInt64, storageCost: UInt64, storageRebate: UInt64) {
        self.computationCost = computationCost
        self.storageCost = storageCost
        self.storageRebate = storageRebate
    }

    /// Computacao mais armazenamento, sem descontar a devolucao: o que o orcamento tem
    /// de cobrir.
    public var gross: UInt64 { computationCost.addingReportingOverflow(storageCost).overflow ? .max : computationCost + storageCost }

    /// O que sai de fato da conta em gas. Pode ser negativo: juntar moedas devolve o
    /// armazenamento das que deixam de existir.
    public var net: (negative: Bool, magnitude: UInt64) {
        gross >= storageRebate ? (false, gross - storageRebate) : (true, storageRebate - gross)
    }

    /// A maior de cada parcela entre duas leituras.
    public static func maximum(_ a: SuiGasCost, _ b: SuiGasCost) -> SuiGasCost {
        SuiGasCost(
            computationCost: max(a.computationCost, b.computationCost),
            storageCost: max(a.storageCost, b.storageCost),
            storageRebate: min(a.storageRebate, b.storageRebate)
        )
    }
}

/// Uma variacao de saldo lida da simulacao (`balance_changes`): quem, qual moeda e
/// quanto, com sinal.
public struct SuiBalanceChange: Hashable, Sendable {
    public let address: SuiAddress
    /// Tipo da moeda na forma longa ("0x000...0002::sui::SUI").
    public let coinType: String
    public let negative: Bool
    public let magnitude: BigUInt

    public init(address: SuiAddress, coinType: String, negative: Bool, magnitude: BigUInt) {
        self.address = address
        self.coinType = coinType
        self.negative = negative && !magnitude.isZero
        self.magnitude = magnitude
    }
}

/// O resultado de uma simulacao (`SimulateTransaction`) num provedor.
public struct SuiSimulation: Hashable, Sendable {
    public let success: Bool
    public let gas: SuiGasCost
    public let balanceChanges: [SuiBalanceChange]

    public init(success: Bool, gas: SuiGasCost, balanceChanges: [SuiBalanceChange]) {
        self.success = success
        self.gas = gas
        self.balanceChanges = balanceChanges
    }
}

/// A conta do dono: o caminho SLIP-10 e a chave publica que ele gera.
public struct SuiOwner: Hashable, Sendable {
    public let path: DerivationPath
    public let publicKey: [UInt8]

    public init(path: DerivationPath, publicKey: [UInt8]) {
        self.path = path
        self.publicKey = publicKey
    }
}

// MARK: Recusas

public enum SuiPlanError: Error, Equatable, Sendable {
    /// Caminho vazio ou com indice nao endurecido: Ed25519 (SLIP-10) nao deriva.
    case invalidPath
    /// A chave nao da o endereco do remetente.
    case keyMismatch
    case invalidDestination(Address.Problem)
    case destinationIsSelf
    /// Endereco do sistema (0x0 a 0xffff): pacote do framework ou objeto do sistema.
    case destinationIsSystem
    case zeroAmount
    case amountTooLarge
    /// Nenhuma moeda de SUI para pagar o gas.
    case noCoins
    case duplicateCoin
    case gasPriceOutOfRange(UInt64)
    /// Estimativa de gas sem computacao: provedor errado ou simulacao que nao rodou.
    case invalidEstimate
    case feeAboveCeiling(budget: UInt64, ceiling: UInt64)
    case insufficientBalance(needed: BigUInt, available: BigUInt)
    /// Menos de duas simulacoes da transacao exata.
    case simulationMissing
    /// A simulacao falhou num provedor.
    case simulationFailed
    /// A simulacao move valores diferentes dos da transacao, gasta mais que o orcamento,
    /// ou mexe em outra conta ou outra moeda.
    case simulationMismatch
}

// MARK: Planejador

public enum SuiPlanner {
    /// Tipo da moeda nativa, forma longa, como os provedores escrevem.
    public static let suiCoinType = "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"
    /// O filtro de `ListOwnedObjects` para as moedas de SUI.
    public static let suiCoinObjectType = "0x2::coin::Coin<0x2::sui::SUI>"

    /// Teto do orcamento de gas: 0,05 SUI. Um envio simples custa cerca de 0,002 SUI de
    /// computacao e armazenamento (medido em 27/09/2026, preco de referencia 100 MIST).
    /// Orcamento acima disso e provedor errado ou mentindo.
    public static let budgetCeiling: UInt64 = 50_000_000
    /// Teto do preco de referencia do gas, em MIST: dez vezes o maior ja praticado
    /// (1.000 em 2023; 100 em 27/09/2026). A rede cobra pelo menos o de referencia.
    public static let gasPriceCeiling: UInt64 = 10_000
    /// Orcamento minimo do protocolo: 1.000 unidades ao preco (`min_transaction_budget`,
    /// o erro "Gas budget: 1000 is lower than min: 100000" com preco 100).
    public static let minimumBudgetUnits: UInt64 = 1_000
    /// Mais moedas que isso nao entram como gas (o protocolo aceita 256): as maiores.
    public static let maxGasCoins = 250

    // MARK: Moedas e orcamento

    /// As moedas que pagam o gas: todas, da maior para a menor (empate pelo id), ate
    /// `maxGasCoins`. Juntar todas simplifica a conta e devolve o armazenamento das
    /// moedas pequenas.
    public static func gasCoins(_ state: SuiAccountState) throws -> [SuiCoin] {
        guard !state.coins.isEmpty else { throw SuiPlanError.noCoins }
        guard Set(state.coins.map(\.ref.objectID)).count == state.coins.count else { throw SuiPlanError.duplicateCoin }
        let sorted = state.coins.sorted {
            $0.balance != $1.balance ? $0.balance > $1.balance : $0.ref.objectID.hex < $1.ref.objectID.hex
        }
        return Array(sorted.prefix(maxGasCoins))
    }

    /// O total das moedas que entram como gas.
    public static func spendableTotal(_ coins: [SuiCoin]) -> BigUInt {
        coins.reduce(BigUInt()) { $0 + BigUInt($1.balance) }
    }

    static func checkedPrice(_ state: SuiAccountState) throws -> UInt64 {
        let price = state.referenceGasPrice
        guard price > 0, price <= gasPriceCeiling else { throw SuiPlanError.gasPriceOutOfRange(price) }
        return price
    }

    /// O orcamento: computacao mais armazenamento da simulacao, mais 20%, nunca abaixo do
    /// minimo do protocolo. O armazenamento entra inteiro, sem descontar a devolucao: a
    /// rede retem o orcamento da moeda de gas antes de executar, e uma transacao sem
    /// orcamento para o armazenamento falha cobrando a computacao.
    public static func budget(for estimate: SuiGasCost, price: UInt64) throws -> UInt64 {
        guard estimate.computationCost > 0 else { throw SuiPlanError.invalidEstimate }
        let gross = BigUInt(estimate.gross)
        let withMargin = (gross * BigUInt(12) + BigUInt(9)) / BigUInt(10)
        let minimum = BigUInt(minimumBudgetUnits) * BigUInt(price)
        let budget = max(withMargin, minimum)
        guard let value = budget.uint64, value <= budgetCeiling else {
            throw SuiPlanError.feeAboveCeiling(budget: budget.uint64 ?? .max, ceiling: budgetCeiling)
        }
        return value
    }

    /// O maximo que pode sair: as moedas de gas menos o orcamento.
    public static func maximumSendable(_ state: SuiAccountState, estimate: SuiGasCost) throws -> BigUInt {
        let coins = try gasCoins(state)
        let budget = try budget(for: estimate, price: try checkedPrice(state))
        return spendableTotal(coins).subtractingReportingUnderflow(BigUInt(budget)) ?? BigUInt()
    }

    /// A transacao que a rede simula para estimar o gas: as mesmas moedas, o mesmo
    /// destino e 1 MIST no lugar do valor (o custo nao depende do valor), com o
    /// orcamento no maximo que as moedas e o teto deixam. Nunca e assinada: nao vira
    /// plano.
    public static func estimationTransaction(owner: SuiOwner, to destination: String, state: SuiAccountState) throws -> SuiTransactionData {
        let sender = try ownerAddress(owner)
        let recipient = try parseDestination(destination, sender: sender)
        let price = try checkedPrice(state)
        let coins = try gasCoins(state)
        let total = spendableTotal(coins)
        let minimum = BigUInt(minimumBudgetUnits) * BigUInt(price)
        guard let room = total.subtractingReportingUnderflow(BigUInt(1)), room >= minimum else {
            throw SuiPlanError.insufficientBalance(needed: minimum + BigUInt(1), available: total)
        }
        let budget = min(room.uint64 ?? .max, budgetCeiling)
        let gas = SuiGasData(payment: coins.map(\.ref), owner: sender, price: price, budget: budget)
        return .payFromGas(sender: sender, recipient: recipient, amount: 1, gas: gas, expiration: .epoch(state.epoch &+ 1))
    }

    // MARK: Envio

    /// Enviar SUI. `amount` em MIST; `estimate` e o custo da simulacao (a maior parcela
    /// de dois provedores). A transacao vale ate o fim da epoca seguinte a atual.
    public static func planSend(
        walletID: UUID, owner: SuiOwner, to destination: String, amount: BigUInt,
        state: SuiAccountState, estimate: SuiGasCost, now: Date = .now
    ) throws -> SigningPlan {
        let sender = try ownerAddress(owner)
        let recipient = try parseDestination(destination, sender: sender)
        guard !amount.isZero else { throw SuiPlanError.zeroAmount }
        guard let value = amount.uint64 else { throw SuiPlanError.amountTooLarge }
        let price = try checkedPrice(state)
        let coins = try gasCoins(state)
        let budget = try budget(for: estimate, price: price)
        let total = spendableTotal(coins)
        let needed = amount + BigUInt(budget)
        guard total >= needed else { throw SuiPlanError.insufficientBalance(needed: needed, available: total) }

        let gas = SuiGasData(payment: coins.map(\.ref), owner: sender, price: price, budget: budget)
        let validUntil = state.epoch &+ 1
        let data = SuiTransactionData.payFromGas(sender: sender, recipient: recipient, amount: value, gas: gas, expiration: .epoch(validUntil))
        let transfer = try SuiTransfer(data: data, path: owner.path, publicKey: owner.publicKey)

        let amountText = SuiFormat.sui(amount)
        var lines = [
            PlanReview.Line("Para", recipient.hex, verbatim: true),
            PlanReview.Line("Valor", amountText),
            PlanReview.Line("Taxa estimada", estimatedFeeText(estimate)),
            PlanReview.Line("Taxa máxima", "\(SuiFormat.sui(BigUInt(budget))), o que não for usado volta"),
            PlanReview.Line("Rede", "Sui"),
            PlanReview.Line("Validade", "Até o fim da época \(validUntil) da rede, cerca de um a dois dias"),
        ]
        if coins.count > 1 {
            lines.append(PlanReview.Line("Moedas de SUI", "As \(coins.count) moedas da conta viram uma só"))
        }

        var warnings = [PlanReview.Warning]()
        // Taxa acima de 10% do valor: o dono provavelmente nao quer pagar isso.
        let gross = BigUInt(estimate.gross)
        if gross * BigUInt(10) > amount {
            let percent = (Double(gross.decimalString) ?? 0) / (Double(amount.decimalString) ?? 1) * 100
            warnings.append(.highFee(percentOfAmount: percent))
        }

        let review = PlanReview(
            kind: .send, title: "Enviar \(amountText)", lines: lines, warnings: warnings,
            recipient: recipient.hex, recipientTag: nil, outgoing: .native(.sui, amount)
        )
        return SigningPlan(walletID: walletID, chain: .sui, review: review, transactions: [transfer], createdAt: now)
    }

    // MARK: Simulacao da transacao exata

    /// Confere a simulacao da transacao que vai ser assinada, em dois provedores: as duas
    /// com sucesso, gas dentro do orcamento, e variacao de saldo exatamente a do envio,
    /// so em SUI: o destino recebe o valor e o dono paga o valor e o gas. Qualquer outra
    /// conta, outra moeda ou outro valor e recusa.
    public static func verifySimulation(_ plan: SigningPlan, results: [SuiSimulation]) throws {
        guard results.count >= 2 else { throw SuiPlanError.simulationMissing }
        guard plan.chain.id == Chain.sui.id, plan.transactions.count == 1,
              let transfer = plan.transactions.first as? SuiTransfer,
              let (recipient, amount) = sendParameters(transfer.data)
        else { throw SuiPlanError.simulationMismatch }
        let sender = transfer.data.sender
        for result in results {
            guard result.success else { throw SuiPlanError.simulationFailed }
            guard result.gas.gross <= transfer.data.gas.budget else { throw SuiPlanError.simulationMismatch }
            // Dono: -(valor + computacao + armazenamento - devolucao).
            let outflow = BigUInt(amount) + BigUInt(result.gas.gross)
            let rebate = BigUInt(result.gas.storageRebate)
            let ownerNegative = outflow >= rebate
            let ownerMagnitude = ownerNegative ? outflow - rebate : rebate - outflow
            var expected: [SuiBalanceChange] = [
                SuiBalanceChange(address: recipient, coinType: suiCoinType, negative: false, magnitude: BigUInt(amount)),
            ]
            if !ownerMagnitude.isZero {
                expected.append(SuiBalanceChange(address: sender, coinType: suiCoinType, negative: ownerNegative, magnitude: ownerMagnitude))
            }
            guard Set(result.balanceChanges) == Set(expected), result.balanceChanges.count == expected.count else {
                throw SuiPlanError.simulationMismatch
            }
        }
    }

    /// Destino e valor de uma transacao no formato de `payFromGas`, lidos dos campos.
    public static func sendParameters(_ data: SuiTransactionData) -> (SuiAddress, UInt64)? {
        guard data.commands == [.splitCoins(.gasCoin, amounts: [.input(0)]), .transferObjects([.nestedResult(0, 0)], to: .input(1))],
              data.inputs.count == 2,
              case .pure(let amountBytes) = data.inputs[0], amountBytes.count == 8,
              case .pure(let recipientBytes) = data.inputs[1], let recipient = SuiAddress(bytes: recipientBytes)
        else { return nil }
        let amount = amountBytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        return (recipient, amount)
    }

    // MARK: Comum

    static func ownerAddress(_ owner: SuiOwner) throws -> SuiAddress {
        guard !owner.path.components.isEmpty, owner.path.isFullyHardened else { throw SuiPlanError.invalidPath }
        guard let address = try? SuiAddress(ed25519PublicKey: owner.publicKey) else { throw SuiPlanError.keyMismatch }
        return address
    }

    /// Valida o destino como qualquer tela faria (`Address.validate`).
    static func parseDestination(_ text: String, sender: SuiAddress) throws -> SuiAddress {
        switch Address.validate(text, for: .sui) {
        case .failure(let problem):
            throw SuiPlanError.invalidDestination(problem)
        case .success(let destination):
            guard case .success(let address) = SuiAddress.parse(destination.address) else {
                throw SuiPlanError.invalidDestination(.malformed)
            }
            guard address != sender else { throw SuiPlanError.destinationIsSelf }
            guard !address.isSystem else { throw SuiPlanError.destinationIsSystem }
            return address
        }
    }

    static func estimatedFeeText(_ estimate: SuiGasCost) -> String {
        let net = estimate.net
        if net.negative || net.magnitude == 0 {
            return "Nenhuma: juntar as moedas devolve mais armazenamento do que o envio custa"
        }
        return SuiFormat.sui(BigUInt(net.magnitude))
    }
}

/// Valor exato para a revisao: todas as casas, sem arredondar, ponto no milhar e
/// virgula decimal (pt_BR, como `Fmt` do app).
enum SuiFormat {
    static func sui(_ mist: BigUInt) -> String { amount(mist, decimals: Chain.sui.nativeDecimals, symbol: "SUI") }

    static func amount(_ value: BigUInt, decimals: Int, symbol: String) -> String {
        let digits = value.decimalString
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let cut = padded.index(padded.endIndex, offsetBy: -decimals)
        let whole = Array(padded[..<cut])
        var fraction = String(padded[cut...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        var grouped = ""
        for (index, digit) in whole.enumerated() {
            if index > 0, (whole.count - index) % 3 == 0 { grouped.append(".") }
            grouped.append(digit)
        }
        return (fraction.isEmpty ? grouped : "\(grouped),\(fraction)") + " " + symbol
    }
}
