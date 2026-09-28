import EscaliburCore
import Foundation

// Planejamento validado do envio de DOT na Polkadot Asset Hub: da intencao do dono e do
// estado publico da rede (lido por EscaliburNetwork em dois provedores concordando, no
// mesmo bloco finalizado) ate um `SigningPlan`.

// MARK: Estado publico que a camada de rede preenche

/// `frame_system::AccountInfo` com o `pallet_balances::AccountData` da Asset Hub, como o
/// armazenamento `System.Account` guarda: quatro u32 (nonce, consumers, providers,
/// sufficients) e quatro u128 (free, reserved, frozen, flags), 80 bytes. Conta que nao
/// existe nao tem valor no armazenamento, e vale `empty`.
public struct PolkadotAccountInfo: Equatable, Sendable {
    public let nonce: UInt32
    public let consumers: UInt32
    public let providers: UInt32
    public let sufficients: UInt32
    public let free: BigUInt
    public let reserved: BigUInt
    public let frozen: BigUInt
    public let flags: BigUInt

    public init(
        nonce: UInt32, consumers: UInt32 = 0, providers: UInt32 = 0, sufficients: UInt32 = 0,
        free: BigUInt, reserved: BigUInt = 0, frozen: BigUInt = 0, flags: BigUInt = 0
    ) {
        self.nonce = nonce
        self.consumers = consumers
        self.providers = providers
        self.sufficients = sufficients
        self.free = free
        self.reserved = reserved
        self.frozen = frozen
        self.flags = flags
    }

    public static let empty = PolkadotAccountInfo(nonce: 0, free: 0)

    public static let encodedLength = 80

    /// Le o valor cru do armazenamento. Tamanho diferente de 80 bytes e recusa: e outro
    /// runtime, e os campos seguintes estariam deslocados.
    public static func decode(_ bytes: [UInt8]) throws -> PolkadotAccountInfo {
        guard bytes.count == encodedLength else { throw PolkadotSCALE.Failure.nonCanonical }
        var reader = PolkadotSCALE.Reader(bytes)
        return PolkadotAccountInfo(
            nonce: try reader.uint32(), consumers: try reader.uint32(), providers: try reader.uint32(), sufficients: try reader.uint32(),
            free: try reader.unsigned(width: 16), reserved: try reader.unsigned(width: 16),
            frozen: try reader.unsigned(width: 16), flags: try reader.unsigned(width: 16)
        )
    }

    /// Livre mais reservado: a conta existe para a rede se isto nao e zero.
    public var total: BigUInt { free + reserved }

    /// O que `transfer_keep_alive` pode tirar da conta (`reducible_balance` com
    /// `Preservation::Preserve`, `Fortitude::Polite`): o livre menos o que esta congelado
    /// (staking, voto, vesting) alem do reservado, e nunca abaixo do deposito existencial.
    /// A taxa tambem sai daqui, com a mesma regra.
    public func reducible(existentialDeposit: BigUInt) -> BigUInt {
        let frozenBeyondReserved = frozen.subtractingReportingUnderflow(reserved) ?? 0
        let untouchable = max(frozenBeyondReserved, existentialDeposit)
        return free.subtractingReportingUnderflow(untouchable) ?? 0
    }
}

/// O bloco de referencia: o finalizado mais baixo entre os provedores, com o hash igual
/// nos dois. A era nasce nele, e todo o estado e lido nele.
public struct PolkadotCheckpoint: Equatable, Sendable {
    public let number: UInt64
    public let hash: [UInt8]

    public init(number: UInt64, hash: [UInt8]) {
        self.number = number
        self.hash = hash
    }
}

/// O que o runtime do bloco de referencia diz de si (`state_getRuntimeVersion`) e o hash
/// de genese do provedor.
public struct PolkadotRuntimeState: Equatable, Sendable {
    public let specName: String
    public let specVersion: UInt32
    public let transactionVersion: UInt32
    public let genesisHash: [UInt8]

    public init(specName: String, specVersion: UInt32, transactionVersion: UInt32, genesisHash: [UInt8]) {
        self.specName = specName
        self.specVersion = specVersion
        self.transactionVersion = transactionVersion
        self.genesisHash = genesisHash
    }
}

/// O estado de um envio, lido em dois provedores concordando no mesmo bloco.
public struct PolkadotChainState: Equatable, Sendable {
    public let checkpoint: PolkadotCheckpoint
    public let runtime: PolkadotRuntimeState
    public let sender: PolkadotAccountInfo
    public let destination: PolkadotAccountInfo
    /// A taxa desta transacao (`partial_fee` do `TransactionPaymentApi_query_info`), igual
    /// nos dois provedores, em planck. Na Polkadot a taxa nao entra no que se assina: a
    /// rede cobra a do bloco em que a transacao entra, e a margem cobre a variacao.
    public let fee: BigUInt

    public init(checkpoint: PolkadotCheckpoint, runtime: PolkadotRuntimeState, sender: PolkadotAccountInfo, destination: PolkadotAccountInfo, fee: BigUInt) {
        self.checkpoint = checkpoint
        self.runtime = runtime
        self.sender = sender
        self.destination = destination
        self.fee = fee
    }
}

/// A conta do dono: o caminho SLIP-10 e a chave publica que ele gera.
public struct PolkadotOwner: Hashable, Sendable {
    public let path: DerivationPath
    public let publicKey: [UInt8]

    public init(path: DerivationPath, publicKey: [UInt8]) {
        self.path = path
        self.publicKey = publicKey
    }
}

// MARK: Recusas

public enum PolkadotPlanError: Error, Equatable, Sendable {
    /// Caminho vazio ou com indice nao endurecido: Ed25519 (SLIP-10) nao deriva.
    case invalidPath
    case keyMismatch
    case invalidDestination(Address.Problem)
    case destinationIsSelf
    case zeroAmount
    /// O provedor esta em outra rede: genese ou nome de runtime diferentes dos compilados.
    case wrongNetwork
    /// O runtime mudou a codificacao das transacoes (`transaction_version`): a carteira
    /// precisa ser conferida de novo contra os metadados antes de assinar.
    case runtimeChanged(transactionVersion: UInt32)
    case missingFee
    case feeAboveCeiling(fee: BigUInt, ceiling: BigUInt)
    /// Valor, taxa e deposito existencial nao cabem no que a conta pode tirar.
    case insufficientBalance(needed: BigUInt, available: BigUInt)
    /// A conta de destino esta vazia, e a rede so a cria com pelo menos o deposito
    /// existencial.
    case belowExistentialDeposit(minimum: BigUInt)
    case nonceOverflow
}

// MARK: Planejador

public enum PolkadotPlanner {
    /// A taxa lida mais 20%: a rede cobra a taxa do bloco em que a transacao entra, que
    /// muda um pouco a cada bloco (`NextFeeMultiplier`). A conferencia de saldo usa esta.
    public static func feeWithMargin(_ fee: BigUInt) -> BigUInt {
        (fee * BigUInt(12) + BigUInt(9)) / BigUInt(10)
    }

    /// O maximo que pode sair: o que a conta pode tirar menos a taxa com margem.
    public static func maximumSendable(_ state: PolkadotChainState) -> BigUInt {
        let reducible = state.sender.reducible(existentialDeposit: PolkadotRuntime.existentialDeposit)
        return reducible.subtractingReportingUnderflow(feeWithMargin(state.fee)) ?? 0
    }

    /// A transacao que os provedores avaliam para dar a taxa: os mesmos campos da que vai
    /// ser assinada, com assinatura zerada (a avaliacao nao confere assinatura). O valor e
    /// o maior entre o pedido e o saldo livre: a taxa depende do tamanho, e o compacto do
    /// saldo nunca e menor que o do valor enviado. Nunca e assinada nem vira plano.
    public static func feeEstimationExtrinsic(
        owner: PolkadotOwner, to destination: String, amount: BigUInt, sender: PolkadotAccountInfo,
        checkpoint: PolkadotCheckpoint, runtime: PolkadotRuntimeState
    ) throws -> [UInt8] {
        let from = try ownerAddress(owner)
        let to = try parseDestination(destination, sender: from)
        let fields = PolkadotTransferFields(
            sender: from, destination: to, amount: max(amount, sender.free), nonce: sender.nonce,
            blockNumber: checkpoint.number, blockHash: checkpoint.hash,
            specVersion: runtime.specVersion, transactionVersion: runtime.transactionVersion
        )
        return fields.extrinsic(signature: [UInt8](repeating: 0, count: 64))
    }

    /// Enviar DOT. `amount` em planck.
    public static func planSend(
        walletID: UUID, owner: PolkadotOwner, to destination: String, amount: BigUInt,
        state: PolkadotChainState, now: Date = .now
    ) throws -> SigningPlan {
        let sender = try ownerAddress(owner)
        let recipient = try parseDestination(destination, sender: sender)
        try checkRuntime(state.runtime)
        guard state.checkpoint.hash.count == 32 else { throw PolkadotPlanError.wrongNetwork }
        guard !amount.isZero else { throw PolkadotPlanError.zeroAmount }
        guard !state.fee.isZero else { throw PolkadotPlanError.missingFee }
        guard state.fee <= PolkadotRuntime.feeCeiling else {
            throw PolkadotPlanError.feeAboveCeiling(fee: state.fee, ceiling: PolkadotRuntime.feeCeiling)
        }
        guard state.sender.nonce < UInt32.max else { throw PolkadotPlanError.nonceOverflow }

        let ed = PolkadotRuntime.existentialDeposit
        let available = state.sender.reducible(existentialDeposit: ed)
        let needed = amount + feeWithMargin(state.fee)
        guard available >= needed else { throw PolkadotPlanError.insufficientBalance(needed: needed, available: available) }
        // A rede so credita se o livre do destino ficar no deposito existencial ou acima
        // (`deposit_consequence`, `BelowMinimum`); abaixo disso a transacao falha e a taxa
        // e cobrada do mesmo jeito.
        let createsAccount = state.destination.total.isZero
        guard state.destination.free + amount >= ed else { throw PolkadotPlanError.belowExistentialDeposit(minimum: ed) }

        let fields = PolkadotTransferFields(
            sender: sender, destination: recipient, amount: amount, nonce: state.sender.nonce,
            blockNumber: state.checkpoint.number, blockHash: state.checkpoint.hash,
            specVersion: state.runtime.specVersion, transactionVersion: state.runtime.transactionVersion
        )
        let transfer = PolkadotTransfer(fields: fields, path: owner.path)

        let amountText = PolkadotFormat.dot(amount)
        var lines = [
            PlanReview.Line("Para", recipient.ss58, verbatim: true),
            PlanReview.Line("Valor", amountText),
            PlanReview.Line("Taxa estimada", PolkadotFormat.dot(state.fee)),
            PlanReview.Line("Rede", "Polkadot (Asset Hub)"),
            PlanReview.Line("Na sua conta", "Pelo menos \(PolkadotFormat.dot(ed)) fica, o mínimo que a rede exige para a conta existir"),
            PlanReview.Line("Validade", "Até o bloco \(fields.era.death(current: fields.blockNumber)) da rede, cerca de 9 minutos"),
        ]
        var warnings = [PlanReview.Warning]()
        if createsAccount {
            lines.append(PlanReview.Line("Destino", "Conta ainda vazia na rede. Este envio a cria"))
            warnings.append(.activatesAccount(minimum: PolkadotFormat.dot(ed)))
        }
        // Taxa acima de 10% do valor: o dono provavelmente nao quer pagar isso.
        if state.fee * BigUInt(10) > amount {
            let percent = (Double(state.fee.decimalString) ?? 0) / (Double(amount.decimalString) ?? 1) * 100
            warnings.append(.highFee(percentOfAmount: percent))
        }

        let review = PlanReview(
            kind: .send, title: "Enviar \(amountText)", lines: lines, warnings: warnings,
            recipient: recipient.ss58, recipientTag: nil, outgoing: .native(.polkadot, fields.amount)
        )
        return SigningPlan(walletID: walletID, chain: .polkadot, review: review, transactions: [transfer], createdAt: now)
    }

    // MARK: Comum

    /// Genese e nome do runtime sao os da Polkadot Asset Hub, e a codificacao das
    /// chamadas e a que a carteira conhece.
    public static func checkRuntime(_ runtime: PolkadotRuntimeState) throws {
        guard runtime.genesisHash == PolkadotRuntime.genesisHash, runtime.specName == PolkadotRuntime.specName, runtime.specVersion > 0 else {
            throw PolkadotPlanError.wrongNetwork
        }
        guard runtime.transactionVersion == PolkadotRuntime.transactionVersion else {
            throw PolkadotPlanError.runtimeChanged(transactionVersion: runtime.transactionVersion)
        }
    }

    static func ownerAddress(_ owner: PolkadotOwner) throws -> PolkadotAddress {
        guard !owner.path.components.isEmpty, owner.path.isFullyHardened else { throw PolkadotPlanError.invalidPath }
        guard let address = PolkadotAddress(accountID: owner.publicKey) else { throw PolkadotPlanError.keyMismatch }
        return address
    }

    /// Valida o destino como qualquer tela faria (`Address.validate`).
    static func parseDestination(_ text: String, sender: PolkadotAddress) throws -> PolkadotAddress {
        switch Address.validate(text, for: .polkadot) {
        case .failure(let problem):
            throw PolkadotPlanError.invalidDestination(problem)
        case .success(let destination):
            guard case .success(let address) = PolkadotAddress.parse(destination.address) else {
                throw PolkadotPlanError.invalidDestination(.malformed)
            }
            guard address != sender else { throw PolkadotPlanError.destinationIsSelf }
            return address
        }
    }
}

/// Valor exato para a revisao: todas as casas, sem arredondar, ponto no milhar e
/// virgula decimal (pt_BR, como `Fmt` do app).
enum PolkadotFormat {
    static func dot(_ planck: BigUInt) -> String {
        let decimals = Chain.polkadot.nativeDecimals
        let digits = planck.decimalString
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
        return (fraction.isEmpty ? grouped : "\(grouped),\(fraction)") + " DOT"
    }
}
