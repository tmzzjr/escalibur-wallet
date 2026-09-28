import EscaliburCore
import Foundation

// Planejamento validado do envio de APT: da intencao do dono e do estado publico da rede
// (lido por EscaliburNetwork em dois provedores concordando, na mesma versao do ledger)
// ate um `SigningPlan`.
//
// A transacao que sai daqui chama so `0x1::aptos_account::transfer(destino, valor)`. Essa
// funcao cria a conta de destino quando ela ainda nao existe e deposita na loja primaria
// de APT dela, criando a loja se preciso: destino que nunca recebeu nada recebe, e o
// armazenamento novo entra na taxa. Tokens (fungible assets), staking e troca ficam fora.

// MARK: Estado publico que a camada de rede preenche

/// O estado da conta e da rede para um envio, lido em dois provedores concordando.
public struct AptosAccountState: Hashable, Sendable {
    /// `0x1::account::get_sequence_number` do dono.
    public let sequenceNumber: UInt64
    /// `0x1::account::get_authentication_key` do dono. Tem de ser o proprio endereco: se
    /// a chave foi trocada na rede, a chave da frase nao assina mais pela conta.
    public let authenticationKey: [UInt8]
    /// `0x1::coin::balance<AptosCoin>` do dono, em octas (moeda e loja primaria juntas).
    public let balance: UInt64
    /// `gas_estimate` de `/estimate_gas_price`, em octas por unidade.
    public let gasUnitPrice: UInt64
    /// O `chain_id` que os dois provedores dizem servir.
    public let chainID: UInt8
    /// A versao do ledger em que as leituras foram feitas nos dois provedores.
    public let ledgerVersion: UInt64
    /// A hora do ledger nessa versao, em segundos Unix. A validade conta dela, nao do
    /// relogio do aparelho.
    public let ledgerTimestamp: UInt64
    /// O destino ja tem loja primaria de APT (`primary_fungible_store::primary_store_exists`).
    /// Sem ela, o envio cria a conta e a loja, e a taxa inclui o armazenamento novo.
    public let destinationExists: Bool

    public init(
        sequenceNumber: UInt64, authenticationKey: [UInt8], balance: UInt64, gasUnitPrice: UInt64, chainID: UInt8,
        ledgerVersion: UInt64, ledgerTimestamp: UInt64, destinationExists: Bool
    ) {
        self.sequenceNumber = sequenceNumber
        self.authenticationKey = authenticationKey
        self.balance = balance
        self.gasUnitPrice = gasUnitPrice
        self.chainID = chainID
        self.ledgerVersion = ledgerVersion
        self.ledgerTimestamp = ledgerTimestamp
        self.destinationExists = destinationExists
    }
}

/// O resultado de uma simulacao (`POST /v1/transactions/simulate`) num provedor.
public struct AptosSimulation: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        /// `0x1::fungible_asset::Withdraw`: saiu `amount` da loja.
        case withdraw(store: AptosAddress, amount: UInt64)
        /// `0x1::fungible_asset::Deposit`: entrou `amount` na loja.
        case deposit(store: AptosAddress, amount: UInt64)
        /// `0x1::transaction_fee::FeeStatement`: o gas cobrado, em unidades.
        case fee(totalGasUnits: UInt64)
        /// Qualquer outro evento, pelo tipo.
        case other(String)
    }

    public let success: Bool
    public let gasUsed: UInt64
    /// O hash que o no calculou para os bytes simulados. Tem de ser o calculado aqui: e a
    /// prova de que ele simulou exatamente a transacao enviada.
    public let hash: String
    public let events: [Event]

    public init(success: Bool, gasUsed: UInt64, hash: String, events: [Event]) {
        self.success = success
        self.gasUsed = gasUsed
        self.hash = hash
        self.events = events
    }
}

/// A conta do dono: o caminho SLIP-10 e a chave publica que ele gera.
public struct AptosOwner: Hashable, Sendable {
    public let path: DerivationPath
    public let publicKey: [UInt8]

    public init(path: DerivationPath, publicKey: [UInt8]) {
        self.path = path
        self.publicKey = publicKey
    }
}

// MARK: Recusas

public enum AptosPlanError: Error, Equatable, Sendable {
    /// Caminho vazio ou com indice nao endurecido: Ed25519 (SLIP-10) nao deriva.
    case invalidPath
    /// A chave nao da o endereco do remetente.
    case keyMismatch
    /// A chave de autenticacao da conta na rede nao e a da frase: foi trocada.
    case authenticationKeyRotated
    /// Os provedores servem outra rede (chain id diferente de 1).
    case wrongNetwork
    case invalidDestination(Address.Problem)
    case destinationIsSelf
    /// Endereco reservado do sistema (framework, metadados do APT).
    case destinationIsSystem
    case zeroAmount
    case amountTooLarge
    case gasPriceOutOfRange(UInt64)
    /// Estimativa sem gas usado: provedor errado ou simulacao que nao rodou.
    case invalidEstimate
    case feeAboveCeiling(fee: UInt64, ceiling: UInt64)
    case insufficientBalance(needed: BigUInt, available: BigUInt)
    /// O relogio do aparelho esta a mais de 2 minutos da hora do ledger.
    case clockSkew
    /// Menos de duas simulacoes da transacao exata.
    case simulationMissing
    /// A simulacao falhou num provedor.
    case simulationFailed
    /// A simulacao e de outros bytes, gasta mais que o teto, ou move outro valor, outra
    /// conta ou outro ativo.
    case simulationMismatch
}

// MARK: Planejador

public enum AptosPlanner {
    /// Rede principal (aptos-core, `types/src/chain_id.rs`: `NamedChain::MAINNET = 1`).
    /// Compilado: nenhum provedor decide para que rede a carteira assina.
    public static let mainnetChainID: UInt8 = 1
    /// Preco minimo do gas que a rede aceita, em octas por unidade
    /// (`min_price_per_gas_unit`); 100 no `/estimate_gas_price` em 28/09/2026.
    public static let minimumGasUnitPrice: UInt64 = 100
    /// Teto do preco: cem vezes o minimo. Acima disso e provedor errado ou mentindo.
    public static let gasUnitPriceCeiling: UInt64 = 10_000
    /// Teto de unidades de gas. Um envio para conta com APT usa 63 unidades; para conta
    /// nova, 5.415, quase tudo armazenamento da conta e da loja (medido em 28/09/2026).
    public static let maxGasCeiling: UInt64 = 20_000
    /// Teto da taxa maxima (gas maximo vezes preco): 0,05 APT.
    public static let feeCeiling: UInt64 = 5_000_000
    /// Menor gas maximo que a carteira pede: folga sobre o minimo do protocolo
    /// (`min_transaction_gas_units`; 5 unidades e recusado, 100 passa).
    public static let minimumMaxGas: UInt64 = 200
    /// A transacao vale ate 2 minutos depois da hora do ledger lida: os 60 s de vida do
    /// plano mais uma folga para chegar a um bloco.
    public static let validitySeconds: UInt64 = UInt64(SigningPlan.lifetime) + 60
    /// Diferenca maxima entre o relogio do aparelho e a hora do ledger.
    public static let clockTolerance: TimeInterval = 120

    // MARK: Gas e maximo

    /// O gas maximo do envio: a maior leitura de gas usado das duas simulacoes, mais 20%,
    /// nunca abaixo de `minimumMaxGas`. A rede cobra so o que usar.
    public static func maxGas(forGasUsed gasUsed: UInt64, price: UInt64) throws -> UInt64 {
        guard gasUsed > 0 else { throw AptosPlanError.invalidEstimate }
        let withMargin = (BigUInt(gasUsed) * BigUInt(12) + BigUInt(9)) / BigUInt(10)
        let value = max(withMargin, BigUInt(minimumMaxGas))
        guard let units = value.uint64, units <= maxGasCeiling else {
            throw AptosPlanError.feeAboveCeiling(fee: value.uint64.map { $0 &* price } ?? .max, ceiling: feeCeiling)
        }
        let fee = BigUInt(units) * BigUInt(price)
        guard let octas = fee.uint64, octas <= feeCeiling else {
            throw AptosPlanError.feeAboveCeiling(fee: fee.uint64 ?? .max, ceiling: feeCeiling)
        }
        return units
    }

    /// O maximo que pode sair: o saldo menos a taxa maxima (o gas maximo ao preco). A rede
    /// exige a taxa maxima no saldo antes de executar, e cobra so a usada.
    public static func maximumSendable(_ state: AptosAccountState, gasUsed: UInt64) throws -> BigUInt {
        let price = try checkedPrice(state)
        let gas = try maxGas(forGasUsed: gasUsed, price: price)
        return BigUInt(state.balance).subtractingReportingUnderflow(BigUInt(gas) * BigUInt(price)) ?? BigUInt()
    }

    /// A transacao que a rede simula para estimar o gas: o mesmo destino e 1 octa no lugar
    /// do valor (o custo nao depende do valor), com o gas maximo que o saldo e os tetos
    /// deixam. Nunca e assinada: nao vira plano.
    public static func estimationTransaction(owner: AptosOwner, to destination: String, state: AptosAccountState, now: Date = .now) throws -> AptosRawTransaction {
        let sender = try ownerAddress(owner)
        try checkState(state, sender: sender, now: now)
        let recipient = try parseDestination(destination, sender: sender)
        let price = try checkedPrice(state)
        let affordable = state.balance > 0 ? (state.balance - 1) / price : 0
        let gas = min(maxGasCeiling, feeCeiling / price, affordable)
        guard gas >= minimumMaxGas else {
            throw AptosPlanError.insufficientBalance(needed: BigUInt(minimumMaxGas) * BigUInt(price) + BigUInt(1), available: BigUInt(state.balance))
        }
        return AptosRawTransaction(
            sender: sender, sequenceNumber: state.sequenceNumber, recipient: recipient, amount: 1,
            maxGasAmount: gas, gasUnitPrice: price, expirationTimestampSecs: state.ledgerTimestamp + validitySeconds,
            chainID: mainnetChainID
        )
    }

    // MARK: Envio

    /// Enviar APT. `amount` em octas; `gasUsed` e o maior gas usado nas duas simulacoes da
    /// estimativa.
    public static func planSend(
        walletID: UUID, owner: AptosOwner, to destination: String, amount: BigUInt,
        state: AptosAccountState, gasUsed: UInt64, now: Date = .now
    ) throws -> SigningPlan {
        let sender = try ownerAddress(owner)
        try checkState(state, sender: sender, now: now)
        let recipient = try parseDestination(destination, sender: sender)
        guard !amount.isZero else { throw AptosPlanError.zeroAmount }
        guard let value = amount.uint64 else { throw AptosPlanError.amountTooLarge }
        let price = try checkedPrice(state)
        let gas = try maxGas(forGasUsed: gasUsed, price: price)
        let maximumFee = BigUInt(gas) * BigUInt(price)
        let needed = amount + maximumFee
        guard BigUInt(state.balance) >= needed else {
            throw AptosPlanError.insufficientBalance(needed: needed, available: BigUInt(state.balance))
        }

        let raw = AptosRawTransaction(
            sender: sender, sequenceNumber: state.sequenceNumber, recipient: recipient, amount: value,
            maxGasAmount: gas, gasUnitPrice: price, expirationTimestampSecs: state.ledgerTimestamp + validitySeconds,
            chainID: mainnetChainID
        )
        let transfer = try AptosTransfer(raw: raw, path: owner.path, publicKey: owner.publicKey)

        let estimatedFee = BigUInt(gasUsed) * BigUInt(price)
        let amountText = AptosFormat.apt(amount)
        var lines = [
            PlanReview.Line("Para", recipient.hex, verbatim: true),
            PlanReview.Line("Valor", amountText),
            PlanReview.Line("Taxa estimada", AptosFormat.apt(estimatedFee)),
            PlanReview.Line("Taxa máxima", "\(AptosFormat.apt(maximumFee)), o que não for usado não é cobrado"),
            PlanReview.Line("Rede", "Aptos"),
            PlanReview.Line("Validade", "Até 2 minutos depois desta revisão"),
        ]
        if !state.destinationExists {
            lines.append(PlanReview.Line("Conta de destino", "Ainda não existe na Aptos. Este envio cria a conta, e a taxa inclui o armazenamento dela"))
        }

        var warnings = [PlanReview.Warning]()
        // Taxa acima de 10% do valor: o dono provavelmente nao quer pagar isso.
        if estimatedFee * BigUInt(10) > amount {
            let percent = (Double(estimatedFee.decimalString) ?? 0) / (Double(amount.decimalString) ?? 1) * 100
            warnings.append(.highFee(percentOfAmount: percent))
        }

        let review = PlanReview(
            kind: .send, title: "Enviar \(amountText)", lines: lines, warnings: warnings,
            recipient: recipient.hex, recipientTag: nil, outgoing: .native(.aptos, amount)
        )
        return SigningPlan(walletID: walletID, chain: .aptos, review: review, transactions: [transfer], createdAt: now)
    }

    // MARK: Simulacao da transacao exata

    /// Confere a simulacao da transacao que vai ser assinada, em dois provedores: as duas
    /// com sucesso, do mesmo hash calculado aqui (os mesmos bytes), com gas dentro do
    /// maximo, e com os eventos exatamente os do envio: sai o valor da loja de APT do dono,
    /// entra o valor na loja de APT do destino, e a taxa. Qualquer outro evento, outra loja
    /// ou outro valor e recusa.
    public static func verifySimulation(_ plan: SigningPlan, results: [AptosSimulation]) throws {
        guard results.count >= 2 else { throw AptosPlanError.simulationMissing }
        guard plan.chain.id == Chain.aptos.id, plan.transactions.count == 1,
              let transfer = plan.transactions.first as? AptosTransfer
        else { throw AptosPlanError.simulationMismatch }
        let raw = transfer.raw
        let expectedHash = AptosSignedTransaction.hash(of: AptosSignedTransaction.simulationBytes(raw, publicKey: transfer.publicKey))
        let movements: Set<AptosSimulation.Event> = [
            .withdraw(store: raw.sender.primaryAPTStore, amount: raw.amount),
            .deposit(store: raw.recipient.primaryAPTStore, amount: raw.amount),
        ]
        for result in results {
            guard result.success else { throw AptosPlanError.simulationFailed }
            guard result.hash.lowercased() == expectedHash, result.gasUsed <= raw.maxGasAmount, result.events.count == 3,
                  Set(result.events.filter { if case .fee = $0 { return false }; return true }) == movements,
                  result.events.contains(.fee(totalGasUnits: result.gasUsed))
            else { throw AptosPlanError.simulationMismatch }
        }
    }

    // MARK: Comum

    static func ownerAddress(_ owner: AptosOwner) throws -> AptosAddress {
        guard !owner.path.components.isEmpty, owner.path.isFullyHardened else { throw AptosPlanError.invalidPath }
        guard let address = try? AptosAddress(ed25519PublicKey: owner.publicKey) else { throw AptosPlanError.keyMismatch }
        return address
    }

    /// Rede principal, chave de autenticacao sem troca e relogio perto da hora do ledger.
    static func checkState(_ state: AptosAccountState, sender: AptosAddress, now: Date) throws {
        guard state.chainID == mainnetChainID else { throw AptosPlanError.wrongNetwork }
        guard state.authenticationKey == sender.bytes else { throw AptosPlanError.authenticationKeyRotated }
        guard abs(now.timeIntervalSince1970 - TimeInterval(state.ledgerTimestamp)) <= clockTolerance else {
            throw AptosPlanError.clockSkew
        }
    }

    static func checkedPrice(_ state: AptosAccountState) throws -> UInt64 {
        let price = state.gasUnitPrice
        guard price >= minimumGasUnitPrice, price <= gasUnitPriceCeiling else { throw AptosPlanError.gasPriceOutOfRange(price) }
        return price
    }

    /// Valida o destino como qualquer tela faria (`Address.validate`).
    static func parseDestination(_ text: String, sender: AptosAddress) throws -> AptosAddress {
        switch Address.validate(text, for: .aptos) {
        case .failure(let problem):
            throw AptosPlanError.invalidDestination(problem)
        case .success(let destination):
            guard case .success(let address) = AptosAddress.parse(destination.address) else {
                throw AptosPlanError.invalidDestination(.malformed)
            }
            guard address != sender else { throw AptosPlanError.destinationIsSelf }
            guard !address.isSystem else { throw AptosPlanError.destinationIsSystem }
            return address
        }
    }
}

/// Valor exato para a revisao: todas as casas, sem arredondar, ponto no milhar e virgula
/// decimal (pt_BR, como `Fmt` do app).
enum AptosFormat {
    static func apt(_ octas: BigUInt) -> String {
        let decimals = Chain.aptos.nativeDecimals
        let digits = octas.decimalString
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
        return (fraction.isEmpty ? grouped : "\(grouped),\(fraction)") + " APT"
    }
}
