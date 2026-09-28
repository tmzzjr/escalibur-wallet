import EscaliburCore
import Foundation

// Planejamento validado do envio de NEAR: da intencao do dono e do estado publico da rede
// (lido por EscaliburNetwork em dois provedores concordando, no mesmo bloco final) ate um
// `SigningPlan`.

// MARK: Estado publico que a camada de rede preenche

/// O bloco de referencia: o final mais baixo entre dois provedores, com o hash igual nos
/// dois. O hash vai na transacao, e todo o estado e lido nele.
public struct NEARCheckpoint: Equatable, Sendable {
    public let height: UInt64
    public let hash: [UInt8]

    public init(height: UInt64, hash: [UInt8]) {
        self.height = height
        self.hash = hash
    }
}

/// `view_account`: saldo livre, saldo em stake, armazenamento usado e o hash do contrato.
public struct NEARAccountState: Equatable, Sendable {
    /// Em yoctoNEAR, fora do stake.
    public let amount: BigUInt
    public let locked: BigUInt
    public let storageUsage: UInt64
    /// 32 bytes zerados quando nao ha contrato proprio.
    public let codeHash: [UInt8]
    /// A conta usa um contrato global (protocolo 77), que nao aparece no `code_hash`.
    public let globalContract: Bool

    public init(
        amount: BigUInt, locked: BigUInt = 0, storageUsage: UInt64, codeHash: [UInt8] = [UInt8](repeating: 0, count: 32),
        globalContract: Bool = false
    ) {
        self.amount = amount
        self.locked = locked
        self.storageUsage = storageUsage
        self.codeHash = codeHash
        self.globalContract = globalContract
    }

    public var hasContract: Bool { globalContract || codeHash.contains { $0 != 0 } }

    /// O que a regra de armazenamento deixa sair (`check_storage_stake` do nearcore):
    /// conta de ate 770 bytes nao precisa de saldo para o armazenamento (NEP-448, conta
    /// de saldo zero); acima disso, cada byte prende `storageAmountPerByte`, pago
    /// primeiro pelo stake.
    public func liquid(storageAmountPerByte: BigUInt) -> BigUInt {
        guard storageUsage > NEARRules.zeroBalanceStorageLimit else { return amount }
        let required = BigUInt(storageUsage) * storageAmountPerByte
        let short = required.subtractingReportingUnderflow(locked) ?? 0
        return amount.subtractingReportingUnderflow(short) ?? 0
    }
}

/// `view_access_key` da chave do dono na conta do dono.
public struct NEARAccessKeyState: Equatable, Sendable {
    public let nonce: UInt64
    /// So chave de acesso total assina transferencia; chave de chamada de funcao nao.
    public let fullAccess: Bool

    public init(nonce: UInt64, fullAccess: Bool) {
        self.nonce = nonce
        self.fullAccess = fullAccess
    }
}

/// Uma taxa de acao do protocolo, em gas: a de envio para outra conta e a de execucao.
public struct NEARActionFee: Equatable, Sendable {
    public let sendNotSir: UInt64
    public let execution: UInt64

    public init(sendNotSir: UInt64, execution: UInt64) {
        self.sendNotSir = sendNotSir
        self.execution = execution
    }
}

/// As regras do protocolo no bloco de referencia (`EXPERIMENTAL_protocol_config` e
/// `gas_price`), iguais nos dois provedores. A taxa e o saldo preso por armazenamento
/// saem daqui, e nao de numero compilado: uma atualizacao do protocolo que mude a conta
/// muda aqui tambem, e o teto compilado segura o absurdo.
public struct NEARProtocolRules: Equatable, Sendable {
    public let chainID: String
    public let gasPrice: BigUInt
    /// O gas anexado ao recibo e comprado a pelo menos este preco (protocolo 85); o que
    /// nao for queimado volta.
    public let minGasPurchasePrice: BigUInt
    /// Quanto a rede cobra, alem das taxas, por uma conta que a transferencia cria
    /// (protocolo 85: 0,007 NEAR).
    public let accountCreationCharge: BigUInt
    public let storageAmountPerByte: BigUInt
    public let actionReceipt: NEARActionFee
    public let transfer: NEARActionFee
    public let createAccount: NEARActionFee
    public let addFullAccessKey: NEARActionFee

    public init(
        chainID: String, gasPrice: BigUInt, minGasPurchasePrice: BigUInt, accountCreationCharge: BigUInt,
        storageAmountPerByte: BigUInt, actionReceipt: NEARActionFee, transfer: NEARActionFee,
        createAccount: NEARActionFee, addFullAccessKey: NEARActionFee
    ) {
        self.chainID = chainID
        self.gasPrice = gasPrice
        self.minGasPurchasePrice = minGasPurchasePrice
        self.accountCreationCharge = accountCreationCharge
        self.storageAmountPerByte = storageAmountPerByte
        self.actionReceipt = actionReceipt
        self.transfer = transfer
        self.createAccount = createAccount
        self.addFullAccessKey = addFullAccessKey
    }
}

/// O estado de um envio, lido em dois provedores concordando no mesmo bloco.
public struct NEARChainState: Equatable, Sendable {
    public let checkpoint: NEARCheckpoint
    public let sender: NEARAccountState
    public let accessKey: NEARAccessKeyState
    /// `nil`: a conta de destino nao existe na rede.
    public let destination: NEARAccountState?
    public let rules: NEARProtocolRules

    public init(
        checkpoint: NEARCheckpoint, sender: NEARAccountState, accessKey: NEARAccessKeyState,
        destination: NEARAccountState?, rules: NEARProtocolRules
    ) {
        self.checkpoint = checkpoint
        self.sender = sender
        self.accessKey = accessKey
        self.destination = destination
        self.rules = rules
    }
}

/// A conta do dono: o caminho SLIP-10 e a chave publica que ele gera.
public struct NEAROwner: Hashable, Sendable {
    public let path: DerivationPath
    public let publicKey: [UInt8]

    public init(path: DerivationPath, publicKey: [UInt8]) {
        self.path = path
        self.publicKey = publicKey
    }
}

/// Constantes da rede principal, compiladas.
public enum NEARRules {
    /// `chain_id` da rede principal e o hash de genese dela (RPC `status`).
    public static let chainID = "mainnet"
    public static let genesisHash = "EPnLgE7iEq9s7yTkos96M3cWymH5avBAPm3qx3NXqR8H"
    /// `ZERO_BALANCE_ACCOUNT_STORAGE_LIMIT` do nearcore (NEP-448).
    public static let zeroBalanceStorageLimit: UInt64 = 770
    /// `ACCESS_KEY_NONCE_RANGE_MULTIPLIER`: o nonce tem de ficar abaixo da altura vezes isto.
    public static let nonceRangeMultiplier: UInt64 = 1_000_000
    /// `transaction_validity_period` da rede principal. Com blocos de cerca de 0,6 s,
    /// umas 14 horas.
    public static let validityBlocks: UInt64 = 86_400
    /// Teto do que a transacao reserva para taxa: 0,05 NEAR. Uma transferencia comum
    /// reserva uns 0,00025 NEAR, e a que cria conta implicita uns 0,0076 NEAR.
    public static let feeCeiling = BigUInt(5) * BigUInt.power(of: 10, 22)
    /// Uma unidade de NEAR em yocto.
    public static let oneNEAR = BigUInt.power(of: 10, 24)
}

/// O custo de uma transferencia, pela conta do nearcore (`calculate_tx_cost` e o acerto
/// do recibo, `runtime/src/lib.rs`).
public struct NEARTransferCost: Equatable, Sendable {
    /// Gas queimado ao converter a transacao em recibo, ao preco do bloco.
    public let burntGas: UInt64
    /// Gas anexado ao recibo, comprado a `max(preco, minGasPurchasePrice)`.
    public let receiptGas: UInt64
    /// O que a conta precisa ter alem do valor para a rede aceitar a transacao. O que
    /// sobrar volta num recibo de reembolso.
    public let reserved: BigUInt
    /// A taxa que deve ficar de fato, com a cobranca por conta criada quando houver.
    public let expected: BigUInt
    public let createsAccount: Bool

    /// `destinationExists` so importa para a conta implicita: e a transferencia para ela
    /// que cria a conta. A taxa de gas da conta implicita inclui criar a conta e a chave
    /// sempre, pelo formato do destino, exista ele ou nao.
    public static func transfer(to receiver: NEARAccountID, destinationExists: Bool, rules: NEARProtocolRules) -> NEARTransferCost {
        let implicit = receiver.kind == .implicit
        var burnt = rules.actionReceipt.sendNotSir + rules.transfer.sendNotSir
        var receipt = rules.actionReceipt.execution + rules.transfer.execution
        if implicit {
            burnt += rules.createAccount.sendNotSir + rules.addFullAccessKey.sendNotSir
            receipt += rules.createAccount.execution + rules.addFullAccessKey.execution
        }
        // O preco pode subir ate 1% por bloco ate a transacao entrar; 20% de folga cobre
        // quase 20 blocos cheios seguidos. Folga que nao for usada nunca sai da conta.
        let price = (rules.gasPrice * BigUInt(12) + BigUInt(9)) / BigUInt(10)
        let receiptPrice = max(price, rules.minGasPurchasePrice)
        let reserved = BigUInt(burnt) * price + BigUInt(receipt) * receiptPrice

        let creates = implicit && !destinationExists
        var expected = BigUInt(burnt + receipt) * rules.gasPrice
        if creates {
            // A rede cobra `account_creation_charge` no lugar da execucao do CreateAccount,
            // descontando do reembolso: nunca menos que o gas dela.
            let createGas = BigUInt(rules.createAccount.execution) * rules.gasPrice
            expected = (expected.subtractingReportingUnderflow(createGas) ?? 0) + max(rules.accountCreationCharge, createGas)
        }
        return NEARTransferCost(burntGas: burnt, receiptGas: receipt, reserved: reserved, expected: expected, createsAccount: creates)
    }
}

// MARK: Recusas

public enum NEARPlanError: Error, Equatable, Sendable {
    /// Caminho vazio ou com indice nao endurecido: Ed25519 (SLIP-10) nao deriva.
    case invalidPath
    case keyMismatch
    case invalidDestination(Address.Problem)
    case destinationIsSelf
    /// Conta com nome que nao existe na rede: a transferencia voltaria, com a taxa paga.
    case destinationMissing
    case zeroAmount
    /// O provedor esta em outra rede.
    case wrongNetwork
    /// A chave do dono nao esta na conta, ou esta com permissao so de chamar contrato.
    case keyNotFullAccess
    /// A chave acabou de ser criada no bloco de referencia; o nonce seguinte ainda nao vale.
    case nonceNotReady
    case feeAboveCeiling(fee: BigUInt, ceiling: BigUInt)
    case missingGasPrice
    case insufficientBalance(needed: BigUInt, available: BigUInt)
    case amountTooLarge
}

// MARK: Planejador

public enum NEARPlanner {
    /// O maximo que pode sair agora: o que a regra de armazenamento deixa, menos a reserva
    /// da taxa para este destino.
    public static func maximumSendable(to receiver: NEARAccountID, state: NEARChainState) -> BigUInt {
        let cost = NEARTransferCost.transfer(to: receiver, destinationExists: state.destination != nil, rules: state.rules)
        let liquid = state.sender.liquid(storageAmountPerByte: state.rules.storageAmountPerByte)
        return liquid.subtractingReportingUnderflow(cost.reserved) ?? 0
    }

    /// Enviar NEAR. `amount` em yoctoNEAR.
    public static func planSend(
        walletID: UUID, owner: NEAROwner, to destination: String, amount: BigUInt,
        state: NEARChainState, now: Date = .now
    ) throws -> SigningPlan {
        let sender = try ownerAccount(owner)
        let receiver = try parseDestination(destination, sender: sender)
        try checkNetwork(state)
        guard state.accessKey.fullAccess else { throw NEARPlanError.keyNotFullAccess }
        guard state.accessKey.nonce < UInt64.max - 1 else { throw NEARPlanError.nonceNotReady }
        let nonce = state.accessKey.nonce + 1
        let (limit, overflow) = state.checkpoint.height.multipliedReportingOverflow(by: NEARRules.nonceRangeMultiplier)
        guard overflow || nonce < limit else { throw NEARPlanError.nonceNotReady }
        if receiver.kind == .named, state.destination == nil { throw NEARPlanError.destinationMissing }
        guard !amount.isZero else { throw NEARPlanError.zeroAmount }
        guard amount.bitWidth <= 128 else { throw NEARPlanError.amountTooLarge }

        let cost = NEARTransferCost.transfer(to: receiver, destinationExists: state.destination != nil, rules: state.rules)
        guard cost.reserved <= NEARRules.feeCeiling else {
            throw NEARPlanError.feeAboveCeiling(fee: cost.reserved, ceiling: NEARRules.feeCeiling)
        }
        let available = state.sender.liquid(storageAmountPerByte: state.rules.storageAmountPerByte)
        let needed = amount + cost.reserved
        guard available >= needed else { throw NEARPlanError.insufficientBalance(needed: needed, available: available) }

        let fields = NEARTransferFields(
            signer: sender, publicKey: owner.publicKey, nonce: nonce, receiver: receiver,
            blockHash: state.checkpoint.hash, deposit: amount
        )
        let transfer = try NEARTransfer(fields: fields, path: owner.path)

        let amountText = NEARFormat.near(amount)
        var lines = [
            PlanReview.Line("Para", receiver.text, verbatim: true),
            PlanReview.Line("Valor", amountText),
            PlanReview.Line("Taxa estimada", NEARFormat.near(cost.expected)),
            PlanReview.Line("Reservado para a taxa", "\(NEARFormat.near(cost.reserved)). O que não for usado volta para a conta"),
            PlanReview.Line("Rede", "NEAR"),
            PlanReview.Line("Validade", "Até \(NEARFormat.grouped(NEARRules.validityBlocks)) blocos depois do bloco \(NEARFormat.grouped(state.checkpoint.height)), cerca de 14 horas"),
        ]
        var warnings = [PlanReview.Warning]()
        if cost.createsAccount {
            lines.append(PlanReview.Line(
                "Destino", "Conta ainda sem registro na rede. Este envio a cria, e a taxa inclui a cobrança da rede por conta nova. Confira que é uma conta NEAR: um endereço de outra rede sem o 0x recebe aqui, e ninguém consegue mover"
            ))
        }
        if state.destination?.hasContract == true { warnings.append(.destinationIsContract) }
        // Taxa acima de 10% do valor: o dono provavelmente nao quer pagar isso.
        if cost.expected * BigUInt(10) > amount {
            let percent = (Double(cost.expected.decimalString) ?? 0) / (Double(amount.decimalString) ?? 1) * 100
            warnings.append(.highFee(percentOfAmount: percent))
        }

        let review = PlanReview(
            kind: .send, title: "Enviar \(amountText)", lines: lines, warnings: warnings,
            recipient: receiver.text, recipientTag: nil, outgoing: .native(.near, fields.deposit)
        )
        return SigningPlan(walletID: walletID, chain: .near, review: review, transactions: [transfer], createdAt: now)
    }

    // MARK: Comum

    /// A rede do provedor e a principal, o bloco tem hash de 32 bytes, e as regras que
    /// entram na conta existem.
    public static func checkNetwork(_ state: NEARChainState) throws {
        guard state.rules.chainID == NEARRules.chainID, state.checkpoint.hash.count == 32 else { throw NEARPlanError.wrongNetwork }
        guard !state.rules.gasPrice.isZero, !state.rules.storageAmountPerByte.isZero else { throw NEARPlanError.missingGasPrice }
    }

    static func ownerAccount(_ owner: NEAROwner) throws -> NEARAccountID {
        guard !owner.path.components.isEmpty, owner.path.isFullyHardened else { throw NEARPlanError.invalidPath }
        guard let account = NEARAccountID(implicitPublicKey: owner.publicKey) else { throw NEARPlanError.keyMismatch }
        return account
    }

    /// Valida o destino como qualquer tela faria (`Address.validate`).
    static func parseDestination(_ text: String, sender: NEARAccountID) throws -> NEARAccountID {
        switch Address.validate(text, for: .near) {
        case .failure(let problem):
            throw NEARPlanError.invalidDestination(problem)
        case .success(let destination):
            guard case .success(let account) = NEARAccountID.parse(destination.address) else {
                throw NEARPlanError.invalidDestination(.malformed)
            }
            guard account != sender else { throw NEARPlanError.destinationIsSelf }
            return account
        }
    }
}

/// Valor exato para a revisao: todas as casas, sem arredondar, ponto no milhar e
/// virgula decimal (pt_BR, como `Fmt` do app).
enum NEARFormat {
    static func near(_ yocto: BigUInt) -> String {
        let decimals = Chain.near.nativeDecimals
        let digits = yocto.decimalString
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let cut = padded.index(padded.endIndex, offsetBy: -decimals)
        var fraction = String(padded[cut...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let whole = grouped(String(padded[..<cut]))
        return (fraction.isEmpty ? whole : "\(whole),\(fraction)") + " NEAR"
    }

    static func grouped<T: BinaryInteger>(_ value: T) -> String { grouped(String(value)) }

    static func grouped(_ digits: String) -> String {
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(".") }
            out.append(digit)
        }
        return out
    }
}
