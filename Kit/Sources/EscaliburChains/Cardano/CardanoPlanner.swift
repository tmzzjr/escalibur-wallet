import EscaliburCore
import Foundation

// MARK: Estado que a rede preenche

/// Uma moeda (saida nao gasta) do endereco do dono.
public struct CardanoUTXO: Hashable, Sendable {
    /// Id da transacao que criou a saida, 64 caracteres hex.
    public let transactionID: String
    public let index: UInt32
    public let lovelace: UInt64
    /// A saida carrega tokens nativos. A carteira nao move token na v1, e gastar a saida
    /// exigiria devolver os tokens numa saida de troco: ela fica de fora.
    public let hasTokens: Bool
    /// A saida guarda um script de referencia. Gastar cobra o custo de script de
    /// referencia da Conway, que o calculo de taxa daqui nao faz: fica de fora.
    public let hasReferenceScript: Bool

    public init(transactionID: String, index: UInt32, lovelace: UInt64, hasTokens: Bool, hasReferenceScript: Bool) {
        self.transactionID = transactionID
        self.index = index
        self.lovelace = lovelace
        self.hasTokens = hasTokens
        self.hasReferenceScript = hasReferenceScript
    }

    /// So ADA, sem script: a moeda que o envio pode gastar.
    public var isPlainADA: Bool { !hasTokens && !hasReferenceScript }
}

/// Os parametros de protocolo que decidem taxa e minimo por saida.
public struct CardanoProtocolParameters: Equatable, Sendable {
    /// Lovelace por byte da transacao (`min_fee_a`, `txFeePerByte`).
    public let minFeeA: UInt64
    /// Lovelace fixo por transacao (`min_fee_b`, `txFeeFixed`).
    public let minFeeB: UInt64
    /// Lovelace por byte de saida (`coins_per_utxo_size`, `utxoCostPerByte`).
    public let coinsPerUTxOByte: UInt64
    public let maxTxSize: UInt64

    public init(minFeeA: UInt64, minFeeB: UInt64, coinsPerUTxOByte: UInt64, maxTxSize: UInt64) {
        self.minFeeA = minFeeA
        self.minFeeB = minFeeB
        self.coinsPerUTxOByte = coinsPerUTxOByte
        self.maxTxSize = maxTxSize
    }
}

/// O que o envio precisa da rede, lido em dois provedores concordando.
public struct CardanoSpendState: Sendable {
    /// As moedas do endereco do dono que os dois provedores listam, com o mesmo valor.
    public let utxos: [CardanoUTXO]
    public let parameters: CardanoProtocolParameters
    /// O slot da ponta da cadeia (o menor dos dois provedores). O TTL parte dele.
    public let tipSlot: UInt64

    public init(utxos: [CardanoUTXO], parameters: CardanoProtocolParameters, tipSlot: UInt64) {
        self.utxos = utxos
        self.parameters = parameters
        self.tipSlot = tipSlot
    }
}

/// A conta do dono: o caminho CIP-1852, a chave publica de pagamento e o endereco base.
public struct CardanoSource: Sendable {
    public let path: DerivationPath
    public let publicKey: [UInt8]
    public let address: String

    public init(path: DerivationPath, publicKey: [UInt8], address: String) {
        self.path = path
        self.publicKey = publicKey
        self.address = address
    }
}

public enum CardanoPlanError: Error, Equatable, Sendable {
    /// O caminho nao e m/1852'/1815'/i'/0/0.
    case invalidPath
    /// A chave publica nao e a do endereco do dono.
    case keyMismatch
    case invalidDestination(Address.Problem)
    case destinationIsSelf
    case zeroAmount
    case amountTooLarge
    /// A saida para o destino fica abaixo do minimo de ADA que a rede exige nela.
    case belowMinimumOutput(minimum: UInt64)
    case insufficientBalance(needed: BigUInt, available: BigUInt)
    /// Sobraria um troco abaixo do minimo por saida. `maximumWithChange` e o maior valor
    /// que ainda deixa um troco valido com as mesmas moedas; zero quando nenhum deixa.
    case changeBelowMinimum(leftover: UInt64, minimum: UInt64, maximumWithChange: UInt64)
    case duplicateUTXO
    case parametersOutOfRange
    case feeAboveCeiling(fee: UInt64, ceiling: UInt64)
    case transactionTooLarge
    /// A ponta da cadeia lida esta longe do relogio: provedor parado ou de outra rede.
    case staleTip
}

/// Monta e valida o envio de ADA. Nada aqui busca na rede nem ve chave privada.
///
/// Regras (conway.cddl e a especificacao formal do ledger Babbage/Conway):
/// - taxa = min_fee_a x tamanho da transacao assinada + min_fee_b. O tamanho e o exato:
///   a testemunha (32 + 64 bytes) tem tamanho fixo, entao a conta com uma assinatura de
///   zeros da o mesmo numero de bytes da assinada. E a conta do cardano-serialization-lib,
///   com a transacao inteira; o ledger cobra um byte a menos (o marcador de validade fica
///   fora do tamanho desde a Alonzo), e os 44 lovelace ficam de margem;
/// - cada saida precisa de pelo menos (160 + bytes da saida) x coins_per_utxo_size;
/// - entradas = saidas + taxa, exatamente: o que nao volta como troco vira taxa, e por
///   isso troco abaixo do minimo e recusado em vez de somado a taxa em silencio;
/// - TTL = ponta da cadeia + 900 slots (15 minutos). Depois dele a transacao nao entra
///   mais, e "venceu" quer dizer que nada saiu.
public enum CardanoPlanner {
    static let ttlSlots: UInt64 = 900
    /// Mais moedas numa transacao so, nao. Cada entrada custa ~40 bytes de taxa e a
    /// transacao tem teto de tamanho; 100 entradas ficam bem abaixo dele.
    public static let maxInputs = 100
    /// Taxa acima disto e recusa: um envio de ADA custa ~0,17 ADA hoje.
    public static let feeCeiling: UInt64 = 2_000_000
    /// Slot 0 da contagem Shelley em tempo Unix: slot = segundos Unix - este numero, com
    /// slot de 1 segundo desde a Shelley (genese: systemStart da Byron mais os 4.492.800
    /// slots de 20 s ate a epoca 208). Conferido contra a ponta da rede em 27/09/2026.
    public static let shelleySlotOffset: Int64 = 1_591_566_291
    /// Distancia maxima entre a ponta lida e o relogio.
    static let tipTolerance: Int64 = 600

    // MARK: Plano

    /// O envio de `amount` lovelace (ou de tudo o que as moedas so de ADA permitem, com
    /// `amount` nil) para `destination`.
    public static func planSend(
        walletID: UUID, source: CardanoSource, to destination: String, amount: BigUInt?,
        state: CardanoSpendState, now: Date = .now
    ) throws -> SigningPlan {
        let draft = try draft(source: source, to: destination, amount: amount, state: state, now: now)
        let body = draft.body
        let transfer = CardanoTransfer(body: body, path: source.path, publicKey: source.publicKey)
        let sent = body.outputs[0].lovelace

        let amountText = CardanoFormat.ada(BigUInt(sent))
        var lines = [
            PlanReview.Line("Para", draft.recipient, verbatim: true),
            PlanReview.Line("Valor", amountText),
            PlanReview.Line("Taxa da rede", CardanoFormat.ada(BigUInt(body.fee))),
        ]
        if body.outputs.count > 1 {
            lines.append(PlanReview.Line("Troco", "\(CardanoFormat.ada(BigUInt(body.outputs[1].lovelace))) volta para esta conta"))
        }
        lines.append(PlanReview.Line("Rede", "Cardano"))
        lines.append(PlanReview.Line("Validade", "Até o slot \(CardanoFormat.grouped(body.ttl)) da rede, cerca de 15 minutos"))
        if body.inputs.count > 1 {
            lines.append(PlanReview.Line("Moedas usadas", "\(body.inputs.count) moedas desta conta"))
        }

        var warnings = [PlanReview.Warning]()
        // Taxa acima de 10% do valor: o dono provavelmente nao quer pagar isso.
        if body.fee * 10 > sent {
            warnings.append(.highFee(percentOfAmount: Double(body.fee) / Double(max(sent, 1)) * 100))
        }

        let review = PlanReview(
            kind: .send, title: "Enviar \(amountText)", lines: lines, warnings: warnings,
            recipient: draft.recipient, recipientTag: nil, outgoing: .native(.cardano, BigUInt(sent))
        )
        return SigningPlan(walletID: walletID, chain: .cardano, review: review, transactions: [transfer], createdAt: now)
    }

    /// O maximo que sai num "enviar tudo": as moedas so de ADA (ate `maxInputs`, as
    /// maiores) menos a taxa, numa saida so. Zero se nao cobre a taxa e o minimo.
    public static func maximumSendable(source: CardanoSource, to destination: String, state: CardanoSpendState, now: Date = .now) throws -> BigUInt {
        do {
            let draft = try draft(source: source, to: destination, amount: nil, state: state, now: now)
            return BigUInt(draft.body.outputs[0].lovelace)
        } catch CardanoPlanError.insufficientBalance, CardanoPlanError.belowMinimumOutput {
            return 0
        }
    }

    /// As moedas que o envio pode gastar, das maiores para as menores.
    public static func spendableUTXOs(_ state: CardanoSpendState) throws -> [CardanoUTXO] {
        var seen = Set<String>()
        for utxo in state.utxos {
            guard seen.insert("\(utxo.transactionID):\(utxo.index)").inserted else { throw CardanoPlanError.duplicateUTXO }
        }
        return state.utxos.filter(\.isPlainADA).sorted {
            $0.lovelace != $1.lovelace ? $0.lovelace > $1.lovelace
                : ($0.transactionID, $0.index) < ($1.transactionID, $1.index)
        }
    }

    // MARK: Montagem

    struct Draft {
        let body: CardanoTransactionBody
        let recipient: String
    }

    static func draft(source: CardanoSource, to destination: String, amount: BigUInt?, state: CardanoSpendState, now: Date) throws -> Draft {
        let owner = try ownerAddress(source)
        let recipient = try destinationAddress(destination, owner: owner)
        let parameters = try checkedParameters(state.parameters)
        let ttl = try checkedTTL(state.tipSlot, now: now)
        let coins = Array(try spendableUTXOs(state).prefix(maxInputs))
        let inputs = try coins.map(input)

        if let amount {
            guard !amount.isZero else { throw CardanoPlanError.zeroAmount }
            guard let value = amount.uint64 else { throw CardanoPlanError.amountTooLarge }
            let minimum = minimumCoin(CardanoOutput(address: recipient.bytes, lovelace: value), parameters)
            guard value >= minimum else { throw CardanoPlanError.belowMinimumOutput(minimum: minimum) }
            return Draft(
                body: try select(inputs: inputs, coins: coins, recipient: recipient.bytes, amount: value,
                                 change: owner.bytes, ttl: ttl, parameters: parameters),
                recipient: recipient.bech32
            )
        }

        // Enviar tudo: todas as moedas escolhidas, uma saida, sem troco.
        let total = coins.reduce(UInt64(0)) { $0 + $1.lovelace }
        guard !coins.isEmpty else { throw CardanoPlanError.insufficientBalance(needed: 1, available: 0) }
        let body = try settle(inputs: inputs, ttl: ttl, parameters: parameters) { fee in
            guard total > fee else { return nil }
            return [CardanoOutput(address: recipient.bytes, lovelace: total - fee)]
        }
        guard let body else { throw CardanoPlanError.insufficientBalance(needed: BigUInt(parameters.minFeeB), available: BigUInt(total)) }
        let minimum = minimumCoin(body.outputs[0], parameters)
        guard body.outputs[0].lovelace >= minimum else { throw CardanoPlanError.belowMinimumOutput(minimum: minimum) }
        return Draft(body: body, recipient: recipient.bech32)
    }

    /// Escolhe as maiores moedas, uma a uma, ate cobrir valor, taxa e um troco valido
    /// (ou fechar exato, sem troco).
    static func select(
        inputs: [CardanoInput], coins: [CardanoUTXO], recipient: [UInt8], amount: UInt64,
        change: [UInt8], ttl: UInt64, parameters: CardanoProtocolParameters
    ) throws -> CardanoTransactionBody {
        var total: UInt64 = 0
        var shortLeftover: (leftover: UInt64, minimum: UInt64, maximum: UInt64)?
        for count in 1...max(1, inputs.count) where count <= inputs.count {
            total += coins[count - 1].lovelace
            guard total > amount else { continue }
            let chosen = Array(inputs.prefix(count))

            // Com troco.
            if let body = try settle(inputs: chosen, ttl: ttl, parameters: parameters, outputs: { fee in
                guard total >= amount + fee, total - amount - fee > 0 else { return nil }
                return [CardanoOutput(address: recipient, lovelace: amount), CardanoOutput(address: change, lovelace: total - amount - fee)]
            }) {
                let minimum = minimumCoin(body.outputs[1], parameters)
                if body.outputs[1].lovelace >= minimum { return body }
                let maximum = total > body.fee + minimum ? total - body.fee - minimum : 0
                shortLeftover = (body.outputs[1].lovelace, minimum, maximum)
            }

            // Exato, sem troco.
            if let body = try settle(inputs: chosen, ttl: ttl, parameters: parameters, outputs: { fee in
                guard total >= amount + fee else { return nil }
                return [CardanoOutput(address: recipient, lovelace: amount)]
            }), total == amount + body.fee {
                return body
            }
        }
        if let shortLeftover {
            throw CardanoPlanError.changeBelowMinimum(
                leftover: shortLeftover.leftover, minimum: shortLeftover.minimum, maximumWithChange: shortLeftover.maximum
            )
        }
        let available = coins.reduce(BigUInt(0)) { $0 + BigUInt($1.lovelace) }
        let estimatedFee = parameters.minFeeB + parameters.minFeeA * 300
        throw CardanoPlanError.insufficientBalance(needed: BigUInt(amount) + BigUInt(estimatedFee), available: available)
    }

    /// Acha a taxa: monta com uma taxa, mede, e sobe ate a taxa cobrir o minimo do
    /// tamanho. `outputs` devolve nil quando a taxa nao cabe no que as entradas trazem.
    static func settle(
        inputs: [CardanoInput], ttl: UInt64, parameters: CardanoProtocolParameters,
        outputs: (UInt64) -> [CardanoOutput]?
    ) throws -> CardanoTransactionBody? {
        var fee = parameters.minFeeB
        for _ in 0..<8 {
            guard let outs = outputs(fee) else { return nil }
            let body = CardanoTransactionBody(inputs: inputs.sorted(), outputs: outs, fee: fee, ttl: ttl)
            let size = signedSize(body)
            guard UInt64(size) <= parameters.maxTxSize else { throw CardanoPlanError.transactionTooLarge }
            let required = minimumFee(size: size, parameters)
            if fee >= required {
                guard fee <= feeCeiling else { throw CardanoPlanError.feeAboveCeiling(fee: fee, ceiling: feeCeiling) }
                return body
            }
            fee = required
        }
        return nil
    }

    // MARK: Regras da rede

    /// Tamanho da transacao com uma testemunha de chave: o mesmo da assinada, em bytes
    /// da transacao inteira.
    public static func signedSize(_ body: CardanoTransactionBody) -> Int {
        let placeholder = CardanoWitness(publicKey: [UInt8](repeating: 0, count: 32), signature: [UInt8](repeating: 0, count: 64))
        return CardanoSignedTransaction(body: body, witnesses: [placeholder]).bytes.count
    }

    public static func minimumFee(size: Int, _ parameters: CardanoProtocolParameters) -> UInt64 {
        parameters.minFeeA * UInt64(size) + parameters.minFeeB
    }

    /// Minimo de ADA numa saida (Babbage em diante): (160 + bytes da saida) x
    /// coins_per_utxo_size.
    public static func minimumCoin(_ output: CardanoOutput, _ parameters: CardanoProtocolParameters) -> UInt64 {
        (160 + UInt64(output.serializedSize)) * parameters.coinsPerUTxOByte
    }

    /// Faixas de sanidade compiladas. Os valores de hoje (27/09/2026, Koios e o backend
    /// da Yoroi, protocolo 11.0): 44, 155.381, 4.310 e 16.384. Fora da faixa, o provedor
    /// esta errado ou a rede mudou de um jeito que pede revisao antes de assinar.
    static func checkedParameters(_ parameters: CardanoProtocolParameters) throws -> CardanoProtocolParameters {
        guard (1...100).contains(parameters.minFeeA), (1...1_000_000).contains(parameters.minFeeB),
              (1_000...20_000).contains(parameters.coinsPerUTxOByte), (4_096...65_536).contains(parameters.maxTxSize)
        else { throw CardanoPlanError.parametersOutOfRange }
        return parameters
    }

    static func checkedTTL(_ tipSlot: UInt64, now: Date) throws -> UInt64 {
        let expected = Int64(now.timeIntervalSince1970) - shelleySlotOffset
        guard tipSlot <= UInt64(Int64.max), abs(Int64(tipSlot) - expected) <= tipTolerance else { throw CardanoPlanError.staleTip }
        return tipSlot + ttlSlots
    }

    // MARK: Contas

    /// O endereco do dono tem de ser o base da rede principal cuja chave de pagamento e a
    /// do plano, derivada em m/1852'/1815'/i'/0/0.
    static func ownerAddress(_ source: CardanoSource) throws -> CardanoAddress {
        let h = DerivationPath.hardened
        let c = source.path.components
        guard c.count == 5, c[0] == h(1852), c[1] == h(1815), c[2] >= DerivationPath.hardenedOffset, c[3] == 0, c[4] == 0 else {
            throw CardanoPlanError.invalidPath
        }
        guard source.publicKey.count == 32, case .success(let address) = CardanoAddress.parse(source.address),
              address.type == 0, address.paymentHash == CardanoAddress.keyHash(source.publicKey)
        else { throw CardanoPlanError.keyMismatch }
        return address
    }

    static func destinationAddress(_ text: String, owner: CardanoAddress) throws -> CardanoAddress {
        switch Address.validate(text, for: .cardano) {
        case .failure(let problem):
            throw CardanoPlanError.invalidDestination(problem)
        case .success(let destination):
            guard case .success(let address) = CardanoAddress.parse(destination.address) else {
                throw CardanoPlanError.invalidDestination(.malformed)
            }
            guard address != owner else { throw CardanoPlanError.destinationIsSelf }
            return address
        }
    }

    static func input(_ utxo: CardanoUTXO) throws -> CardanoInput {
        guard utxo.transactionID.count == 64, let id = Hex.decode(utxo.transactionID), id.count == 32 else {
            throw CardanoPlanError.duplicateUTXO
        }
        return CardanoInput(transactionID: id, index: utxo.index)
    }
}

/// Texto de valores em ADA, com virgula decimal e ponto de milhar.
enum CardanoFormat {
    static func ada(_ lovelace: BigUInt) -> String {
        let digits = lovelace.decimalString
        let decimals = Chain.cardano.nativeDecimals
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let cut = padded.index(padded.endIndex, offsetBy: -decimals)
        var fraction = String(padded[cut...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let whole = grouped(String(padded[..<cut]))
        return fraction.isEmpty ? "\(whole) ADA" : "\(whole),\(fraction) ADA"
    }

    static func grouped(_ value: UInt64) -> String { grouped(String(value)) }

    static func grouped(_ digits: String) -> String {
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(".") }
            out.append(digit)
        }
        return out
    }
}
