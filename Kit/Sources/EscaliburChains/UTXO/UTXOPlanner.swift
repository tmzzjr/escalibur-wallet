import EscaliburCore
import Foundation

// MARK: Estado da rede (preenchido por EscaliburNetwork)

/// Uma moeda (UTXO) da carteira, como a camada de rede entrega.
public struct UTXOCoin: Sendable, Equatable {
    public let outpoint: UTXOOutpoint
    /// A transacao anterior inteira, crua, com ou sem witness (o `/tx/{txid}/hex` do
    /// Esplora). Valor e script saem dela depois de conferir o txid; nenhum campo
    /// "value" do provedor e usado.
    public let previousTransaction: [UInt8]
    /// Confirmacoes. Zero significa que ainda esta na mempool.
    public let confirmations: UInt32
    /// Caminho da chave que recebeu a moeda: `m/purpose'/coin'/account'/cadeia/indice`.
    public let path: DerivationPath
    /// A chave publica comprimida desse caminho, derivada localmente da xpub da conta.
    public let publicKey: [UInt8]

    public init(outpoint: UTXOOutpoint, previousTransaction: [UInt8], confirmations: UInt32, path: DerivationPath, publicKey: [UInt8]) {
        self.outpoint = outpoint
        self.previousTransaction = previousTransaction
        self.confirmations = confirmations
        self.path = path
        self.publicKey = publicKey
    }
}

/// O estado publico da rede no momento do envio. Dados puros, vindos de fora, que
/// o planejamento confere antes de usar.
public struct UTXONetworkState: Sendable {
    /// As moedas da conta que vai pagar. Todas da mesma conta (`coin'/account'`).
    public let coins: [UTXOCoin]
    /// A estimativa de prioridade mais alta de cada fonte, uma por fonte (ex.:
    /// `fastestFee` do mempool.space e o alvo de 1 bloco do Esplora). Pelo menos duas.
    public let feeEstimates: [UTXOFeeRate]
    /// Altura do ultimo bloco. Vira o nLockTime, contra fee sniping.
    public let tipHeight: UInt32
    /// As moedas que o provedor listou e que ficaram fora da leitura, com o motivo. Nao
    /// entram na transacao; entram na revisao, para "enviar tudo" nao esconder o que
    /// fica para tras (auditoria 2, M3).
    public let skipped: [UTXOSkippedCoin]

    public init(coins: [UTXOCoin], feeEstimates: [UTXOFeeRate], tipHeight: UInt32, skipped: [UTXOSkippedCoin] = []) {
        self.coins = coins
        self.feeEstimates = feeEstimates
        self.tipHeight = tipHeight
        self.skipped = skipped
    }
}

/// Uma moeda que a leitura deixou de fora.
public struct UTXOSkippedCoin: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// Vale menos do que custa gasta-la agora (poeira). Nem foi conferida.
        case uneconomic
        /// Alem do teto de moedas conferidas numa leitura (ficam as maiores).
        case overLimit
        /// A transacao anterior nao veio, nao fecha com o txid, ou a saida nao e desta
        /// chave ou nao vale o anunciado: sem prova, a moeda nao entra.
        case unverified
    }

    public let outpoint: UTXOOutpoint
    public let reason: Reason

    public init(outpoint: UTXOOutpoint, reason: Reason) {
        self.outpoint = outpoint
        self.reason = reason
    }
}

// MARK: Intencao do dono

/// O endereco de troco que o app derivou, com o que prova que e da carteira.
public struct UTXOChangeAddress: Sendable {
    /// O endereco como o app o mostra e guarda.
    public let address: String
    /// `m/purpose'/coin'/account'/1/i`: sempre a cadeia interna.
    public let path: DerivationPath
    public let publicKey: [UInt8]
    /// A xpub da conta (`m/purpose'/coin'/account'`). A chave do troco tem de sair
    /// dela, e ela tem de gerar as chaves das moedas gastas, que o assinador confere
    /// contra a seed. Assim o troco fica amarrado a seed sem abrir a seed aqui.
    public let accountKey: ExtendedPublicKey

    public init(address: String, path: DerivationPath, publicKey: [UInt8], accountKey: ExtendedPublicKey) {
        self.address = address
        self.path = path
        self.publicKey = publicKey
        self.accountKey = accountKey
    }
}

public struct UTXOSendIntent: Sendable {
    public enum Amount: Sendable, Equatable {
        /// Valor exato na unidade da rede (satoshi, litoshi, koinu).
        case exact(BigUInt)
        /// Tudo o que as moedas escolhidas pagam, menos a taxa. Sem troco.
        case all
    }

    /// Destino ja validado por `Address.validate`; e validado de novo aqui.
    public let destination: Address.Destination
    public let amount: Amount
    public let feeRate: UTXOFeeRate
    /// Obrigatorio em `.exact`. Ignorado em `.all`.
    public let change: UTXOChangeAddress?
    /// Moedas escolhidas a mao pelo dono. Quando presente, so estas entram, e as
    /// protecoes automaticas (moeda pequena, sem confirmacao) nao se aplicam: o dono
    /// escolheu.
    public let coinControl: [UTXOOutpoint]?
    /// Enderecos para os quais a carteira ja enviou (historico e catalogo). Quando
    /// presente, liga os avisos de primeiro envio e de endereco parecido.
    public let knownAddresses: [String]?

    public init(
        destination: Address.Destination, amount: Amount, feeRate: UTXOFeeRate,
        change: UTXOChangeAddress?, coinControl: [UTXOOutpoint]? = nil, knownAddresses: [String]? = nil
    ) {
        self.destination = destination
        self.amount = amount
        self.feeRate = feeRate
        self.change = change
        self.coinControl = coinControl
        self.knownAddresses = knownAddresses
    }
}

public enum UTXOPlanError: Error, Equatable, Sendable {
    case wrongFamily
    case invalidDestination(Address.Problem)
    case amountZero
    case amountAboveMaximum
    /// Saida abaixo do dust: o no nao repassa.
    case amountBelowDust(minimum: BigUInt)
    case insufficientFunds(available: BigUInt, required: BigUInt)
    case noSpendableCoins
    case duplicateCoin(UTXOOutpoint)
    /// A transacao anterior nao e uma transacao valida.
    case previousTransactionMalformed(UTXOOutpoint)
    /// O txid da transacao anterior nao bate com o outpoint: o provedor entregou
    /// outra transacao (ou uma adulterada) e o valor dela nao vale nada.
    case previousTransactionMismatch(UTXOOutpoint)
    case outputIndexOutOfRange(UTXOOutpoint)
    /// O script da saida nao e o da chave informada.
    case coinNotOurs(UTXOOutpoint)
    /// Script que a carteira nao assina (P2TR, P2WSH, multisig).
    case unsupportedCoinType(UTXOOutpoint)
    case coinValueOutOfRange(UTXOOutpoint)
    /// A soma das moedas passa do que a rede pode ter: estado inventado.
    case balanceOutOfRange
    case badDerivationPath(DerivationPath)
    /// Moedas de mais de uma conta no mesmo envio ligariam as contas na blockchain.
    case mixedAccounts
    case coinControlUnknown(UTXOOutpoint)
    case needTwoFeeEstimates
    /// As fontes de taxa discordam mais de 3x: uma delas mente ou esta quebrada.
    case feeEstimatesDisagree
    /// Taxa acima do teto compilado da rede.
    case feeRateAboveNetworkCap(cap: UTXOFeeRate)
    case feeRateBelowMinimum(minimum: UTXOFeeRate)
    /// Taxa acima de 2x a maior estimativa: recusada, nao so avisada.
    case feeRateAboveCeiling(ceiling: UTXOFeeRate)
    case feeAboveAbsoluteCap(cap: BigUInt)
    case changeRequired
    /// Caminho, chave, xpub e endereco do troco nao fecham entre si.
    case changeNotOurs
    /// Nenhuma moeda da conta do troco para conferir a xpub contra a seed.
    case changeAccountNotSpent
    case invalidTipHeight
    case transactionTooLarge
    /// A conferencia final da transacao montada nao fechou. Nao deveria acontecer;
    /// se acontecer, nada e assinado.
    case internalCheckFailed
}

// MARK: Transacao anterior

public enum UTXOPreviousOutput {
    /// Confere a transacao anterior e devolve a saida que o outpoint aponta.
    ///
    /// `txid == dSHA256(serializacao sem witness)`: se o provedor mudar um bit do
    /// valor, o txid muda e a moeda e recusada. E a unica defesa no P2PKH, cujo
    /// digesto nao cobre o valor; sem ela, um servidor mentindo o valor faz a
    /// carteira pagar a diferenca em taxa.
    public static func verify(previousTransaction raw: [UInt8], outpoint: UTXOOutpoint) throws -> UTXOTxOut {
        guard let tx = try? UTXOTransaction(parsing: raw) else { throw UTXOPlanError.previousTransactionMalformed(outpoint) }
        guard tx.txid == outpoint.txid else { throw UTXOPlanError.previousTransactionMismatch(outpoint) }
        guard Int(outpoint.vout) < tx.outputs.count else { throw UTXOPlanError.outputIndexOutOfRange(outpoint) }
        return tx.outputs[Int(outpoint.vout)]
    }
}

// MARK: Planejamento

public enum UTXOPlanner {
    /// Uma moeda que passou por todas as conferencias.
    struct VerifiedCoin {
        let coin: UTXOCoin
        let output: UTXOTxOut
        let kind: UTXOInputKind
    }

    /// Monta e valida um envio. Devolve o plano que o assinador aceita.
    ///
    /// Recusa (em vez de avisar) tudo o que nao pode estar certo: destino invalido,
    /// transacao anterior que nao bate, moeda que nao e da chave, taxa fora do teto,
    /// troco que nao prova ser da carteira. Avisa o que pode estar certo mas merece
    /// um segundo olhar: taxa acima de 1% do valor, primeiro envio, endereco parecido.
    public static func planSend(
        walletID: UUID, chain: Chain, intent: UTXOSendIntent, network: UTXONetworkState, now: Date = .now
    ) throws -> SigningPlan {
        guard chain.family == .utxo else { throw UTXOPlanError.wrongFamily }
        let rules = UTXORules.for(chain)
        let params = UTXOParams.for(chain)

        // Destino: validado de novo, e o script sai do endereco normalizado.
        let destination: Address.Destination
        switch Address.validate(intent.destination.address, for: chain) {
        case .success(let d): destination = d
        case .failure(let problem): throw UTXOPlanError.invalidDestination(problem)
        }
        let destinationScript: [UInt8]
        do {
            destinationScript = try UTXOScript.scriptPubKey(for: destination.address, chain: chain)
        } catch let problem as Address.Problem {
            throw UTXOPlanError.invalidDestination(problem)
        }
        guard let destinationType = UTXOScript.classify(destinationScript)?.type else {
            throw UTXOPlanError.invalidDestination(.unsupportedType)
        }
        let destinationDust = params.dustThreshold(for: destinationType, chain: chain)

        // Taxa: duas fontes que nao discordam demais, o piso e o teto compilados da rede,
        // e ate 2x a maior estimativa.
        try UTXOFeeConsensus.check(network.feeEstimates, rules: rules)
        let feeRate = intent.feeRate
        guard feeRate >= rules.minimumFeeRate else { throw UTXOPlanError.feeRateBelowMinimum(minimum: rules.minimumFeeRate) }
        guard feeRate <= rules.maxFeeRate else { throw UTXOPlanError.feeRateAboveNetworkCap(cap: rules.maxFeeRate) }
        // Com a mempool vazia, 2x a maior estimativa pode ficar abaixo do piso da rede;
        // o piso continua permitido, senao nao haveria taxa possivel.
        let highest = network.feeEstimates.max()!.satPerKvB
        let ceiling = max(UTXOFeeRate(satPerKvB: highest > UInt64.max / 2 ? .max : highest * 2), rules.minimumFeeRate)
        guard feeRate <= ceiling else { throw UTXOPlanError.feeRateAboveCeiling(ceiling: ceiling) }

        // Taxa que nem a menor transacao possivel paga sem passar do teto absoluto:
        // recusada ja, antes de qualquer soma (e de qualquer estouro de inteiro com
        // estimativas absurdas vindas de fora).
        let smallest = UTXOSizing.weight(inputs: [rules.segwit ? .p2wpkh : .p2pkh], outputs: [destinationType])
        guard feeRate.fee(weight: smallest) <= rules.maxAbsoluteFee else {
            throw UTXOPlanError.feeAboveAbsoluteCap(cap: BigUInt(rules.maxAbsoluteFee))
        }

        guard network.tipHeight > 0, network.tipHeight < UTXORules.lockTimeThreshold else { throw UTXOPlanError.invalidTipHeight }

        // Moedas: cada uma conferida contra a propria transacao anterior.
        var seen = Set<UTXOOutpoint>()
        var verified = [VerifiedCoin]()
        for coin in network.coins {
            guard seen.insert(coin.outpoint).inserted else { throw UTXOPlanError.duplicateCoin(coin.outpoint) }
            verified.append(try verify(coin, chain: chain, rules: rules))
        }
        let accounts = Set(verified.map { Array($0.coin.path.components[1...2]) })
        guard accounts.count <= 1 else { throw UTXOPlanError.mixedAccounts }
        // Transacao anterior conferida prova o valor, nao a existencia: um provedor
        // pode inventar moedas. Nenhuma carteira real passa de MAX_MONEY, e o teto
        // mantem toda soma daqui para baixo longe de estourar.
        _ = try sum(verified.map(\.output.value), max: rules.maxMoney * 2, error: .balanceOutOfRange)

        // Candidatas.
        var candidates: [VerifiedCoin]
        if let chosen = intent.coinControl {
            candidates = []
            var picked = Set<UTXOOutpoint>()
            for outpoint in chosen where picked.insert(outpoint).inserted {
                guard let coin = verified.first(where: { $0.coin.outpoint == outpoint }) else {
                    throw UTXOPlanError.coinControlUnknown(outpoint)
                }
                candidates.append(coin)
            }
        } else {
            candidates = verified.filter { coin in
                // Moeda pequena pode carregar inscricao ou runa; sem confirmacao, so o
                // proprio troco (cadeia 1), que so nos podemos substituir.
                coin.output.value > rules.protectionThreshold(for: coin.kind, chain: chain)
                    && (coin.coin.confirmations > 0 || coin.coin.path.components[3] == 1)
            }
        }
        let selectionCoins = candidates.enumerated().map { index, coin in
            UTXOSelectionCoin(
                id: index, value: coin.output.value,
                fee: feeRate.fee(weight: coin.kind.inputWeight),
                longTermFee: rules.longTermFeeRate.fee(weight: coin.kind.inputWeight)
            )
        }

        // Troco: so em envio de valor exato.
        var changeInfo: (script: [UInt8], type: UTXOScriptType, kind: UTXOInputKind, address: String)?
        if case .exact = intent.amount {
            guard let change = intent.change else { throw UTXOPlanError.changeRequired }
            changeInfo = try verifyChange(change, chain: chain, rules: rules, coins: verified)
        }

        // Selecao.
        let selected: [VerifiedCoin]
        let amount: UInt64
        var changeValue: UInt64?
        let fee: UInt64
        let absorbed: UInt64
        var leftBehind = [VerifiedCoin]()
        var leftBehindUneconomic = 0

        switch intent.amount {
        case .all:
            let usable = zip(candidates, selectionCoins).filter { $0.1.effectiveValue > 0 }
            selected = usable.map(\.0)
            if intent.coinControl == nil {
                leftBehind = verified.filter { coin in !selected.contains { $0.coin.outpoint == coin.coin.outpoint } }
                // As que nao pagam a propria entrada a esta taxa sao poeira; as outras (pequenas
                // protegidas, sem confirmacao) ainda valem alguma coisa.
                leftBehindUneconomic = leftBehind.filter { coin in
                    feeRate.fee(weight: coin.kind.inputWeight) >= coin.output.value
                }.count
            }
            guard !selected.isEmpty else { throw UTXOPlanError.noSpendableCoins }
            let total = try sum(selected.map(\.output.value), max: rules.maxMoney * 2)
            fee = feeRate.fee(weight: UTXOSizing.weight(inputs: selected.map(\.kind), outputs: [destinationType]))
            guard total > fee, total - fee >= destinationDust else {
                throw UTXOPlanError.amountBelowDust(minimum: BigUInt(destinationDust))
            }
            amount = total - fee
            absorbed = 0

        case .exact(let requested):
            guard !requested.isZero else { throw UTXOPlanError.amountZero }
            guard let value = requested.uint64, value <= rules.maxMoney else { throw UTXOPlanError.amountAboveMaximum }
            guard value >= destinationDust else { throw UTXOPlanError.amountBelowDust(minimum: BigUInt(destinationDust)) }
            guard let change = changeInfo else { throw UTXOPlanError.changeRequired }
            amount = value

            let anySegwit = candidates.contains { $0.kind.isSegwit }
            let fixedWeight = UTXOSizing.weight(inputs: [], outputs: [destinationType]) + (anySegwit ? 2 : 0)
            let changeOutputFee = feeRate.fee(weight: change.type.outputSize * 4)
            let changeSpendFee = rules.discardFeeRate(for: feeRate).fee(weight: change.kind.inputWeight)
            let changeDust = params.dustThreshold(for: change.type, chain: chain)
            let minViableChange = max(changeSpendFee + 1, changeDust)
            let target = amount + feeRate.fee(weight: fixedWeight)
            let parameters = UTXOSelectionParameters(
                target: Int64(target), changeOutputFee: Int64(changeOutputFee),
                costOfChange: Int64(changeOutputFee + changeSpendFee), minViableChange: Int64(minViableChange)
            )
            guard let result = UTXOCoinSelection.select(selectionCoins, parameters) else {
                let available = selectionCoins.filter { $0.effectiveValue > 0 }.reduce(UInt64(0)) { $0 + UInt64($1.effectiveValue) }
                throw UTXOPlanError.insufficientFunds(available: BigUInt(available), required: BigUInt(target))
            }
            selected = result.ids.map { candidates[$0] }

            // Com as moedas escolhidas, a conta exata: peso real da transacao e troco
            // so se ele sair viavel. O que nao vira troco vira taxa, e a tela mostra.
            let kinds = selected.map(\.kind)
            let total = try sum(selected.map(\.output.value), max: rules.maxMoney * 2)
            let feeWithoutChange = feeRate.fee(weight: UTXOSizing.weight(inputs: kinds, outputs: [destinationType]))
            guard total >= amount + feeWithoutChange else {
                throw UTXOPlanError.insufficientFunds(available: BigUInt(total), required: BigUInt(amount + feeWithoutChange))
            }
            let feeWithChange = feeRate.fee(weight: UTXOSizing.weight(inputs: kinds, outputs: [destinationType, change.type]))
            if result.withChange, total >= amount + feeWithChange, total - amount - feeWithChange >= minViableChange {
                changeValue = total - amount - feeWithChange
                fee = feeWithChange
                absorbed = 0
            } else {
                fee = total - amount
                absorbed = fee - feeWithoutChange
            }
        }

        guard fee <= rules.maxAbsoluteFee else { throw UTXOPlanError.feeAboveAbsoluteCap(cap: BigUInt(rules.maxAbsoluteFee)) }

        // A transacao. Entradas e saidas na ordem do BIP-69 (lexicografica): a
        // mesma entrada da sempre os mesmos bytes, e a posicao do troco nao o denuncia.
        let orderedCoins = selected.sorted { ($0.coin.outpoint.txid, $0.coin.outpoint.vout) < ($1.coin.outpoint.txid, $1.coin.outpoint.vout) }
        var outputs = [UTXOTxOut(value: amount, scriptPubKey: destinationScript)]
        if let changeValue, let change = changeInfo {
            outputs.append(UTXOTxOut(value: changeValue, scriptPubKey: change.script))
        }
        outputs.sort { $0.value != $1.value ? $0.value < $1.value : $0.scriptPubKey.lexicographicallyPrecedes($1.scriptPubKey) }
        let transaction = UTXOTransaction(
            version: rules.transactionVersion,
            inputs: orderedCoins.map { UTXOTxIn(outpoint: $0.coin.outpoint, sequence: UTXORules.rbfSequence) },
            outputs: outputs,
            lockTime: network.tipHeight
        )
        let spends = orderedCoins.map { UTXOSpend(kind: $0.kind, path: $0.coin.path, publicKey: $0.coin.publicKey, value: $0.output.value) }

        // Conferencia final, independente da conta acima: o que entra paga o que sai
        // mais a taxa, cada saida passa do dust, e a taxa cobre o peso de pior caso.
        let estimatedWeight = UTXOSizing.weight(inputs: spends.map(\.kind), outputs: outputs.map { UTXOScript.classify($0.scriptPubKey)!.type })
        guard estimatedWeight <= UTXORules.maxStandardWeight else { throw UTXOPlanError.transactionTooLarge }
        let totalIn = try sum(spends.map(\.value), max: rules.maxMoney * 2)
        let totalOut = try sum(outputs.map(\.value), max: rules.maxMoney * 2)
        guard totalIn == totalOut + fee, fee >= feeRate.fee(weight: estimatedWeight),
              outputs.allSatisfy({ $0.value >= params.dustThreshold(for: UTXOScript.classify($0.scriptPubKey)!.type, chain: chain) }),
              outputs.filter({ $0.scriptPubKey == destinationScript }).contains(where: { $0.value == amount })
        else { throw UTXOPlanError.internalCheckFailed }

        let summary = UTXOSendSummary(
            destination: destination.address,
            amount: BigUInt(amount), fee: BigUInt(fee), feeRate: feeRate,
            virtualSize: (estimatedWeight + 3) / 4,
            change: changeValue.map { BigUInt($0) }, changeAddress: changeValue == nil ? nil : changeInfo?.address,
            absorbedIntoFee: BigUInt(absorbed), inputCount: spends.count,
            sendsAll: intent.amount == .all
        )
        let signable = try UTXOSignableTransaction(chain: chain, unsigned: transaction, spends: spends, summary: summary)

        // Revisao.
        // Taxa acima de 1% do valor avisa: com o teto compilado alto, o aviso e o que faz
        // o dono ver uma taxa desproporcional antes de assinar.
        var warnings = [PlanReview.Warning]()
        if fee * 100 > amount {
            warnings.append(.highFee(percentOfAmount: Double(fee) * 100 / Double(amount)))
        }
        let own = verified.compactMap { UTXOScript.address(for: $0.output.scriptPubKey, chain: chain) } + [changeInfo?.address].compactMap { $0 }
        warnings += addressWarnings(destination: destination.address, known: intent.knownAddresses, own: own)

        // "Enviar tudo" so e dito quando o que fica de fora e poeira: moeda que ainda vale
        // (pequena protegida, sem confirmacao, alem do teto de leitura ou sem prova) fica de
        // fora e a revisao diz quantas e por que.
        let skipped = intent.coinControl == nil ? network.skipped : []
        let valuableLeft = (leftBehind.count - leftBehindUneconomic) + skipped.filter { $0.reason != .uneconomic }.count
        let review = PlanReview(
            kind: .send,
            title: "Enviar \(UTXOFormat.amount(amount, chain: chain))",
            lines: reviewLines(
                chain: chain, destination: destination.address, summary: summary,
                leftBehind: intent.amount == .all ? leftBehind.map(\.output.value) : [],
                skipped: skipped, valuableLeft: intent.amount == .all ? valuableLeft : 0
            ),
            warnings: warnings,
            transactionCount: 1,
            recipient: destination.address,
            // A saida para o destino, conferida acima na transacao montada.
            outgoing: .native(chain, BigUInt(amount))
        )
        return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: [signable], createdAt: now)
    }

    // MARK: Conferencias

    static func verify(_ coin: UTXOCoin, chain: Chain, rules: UTXORules) throws -> VerifiedCoin {
        let output = try UTXOPreviousOutput.verify(previousTransaction: coin.previousTransaction, outpoint: coin.outpoint)
        guard output.value <= rules.maxMoney else { throw UTXOPlanError.coinValueOutOfRange(coin.outpoint) }
        guard coin.publicKey.count == 33, (try? Secp256k1.reformat(publicKey: coin.publicKey, compressed: true)) == coin.publicKey else {
            throw UTXOPlanError.coinNotOurs(coin.outpoint)
        }
        let kinds = rules.segwit ? UTXOInputKind.allCases : [.p2pkh]
        guard let kind = kinds.first(where: { $0.scriptPubKey(publicKey: coin.publicKey) == output.scriptPubKey }) else {
            switch UTXOScript.classify(output.scriptPubKey)?.type {
            case .p2pkh?, .p2wpkh?, .p2sh?: throw UTXOPlanError.coinNotOurs(coin.outpoint)
            default: throw UTXOPlanError.unsupportedCoinType(coin.outpoint)
            }
        }
        guard isWalletPath(coin.path, kind: kind, chain: chain, internalOnly: false) else {
            throw UTXOPlanError.badDerivationPath(coin.path)
        }
        return VerifiedCoin(coin: coin, output: output, kind: kind)
    }

    /// `m/purpose'/coin'/account'/cadeia/indice`, com purpose do tipo do script e
    /// coin da rede. Cadeia 0 (recebimento) ou 1 (troco).
    static func isWalletPath(_ path: DerivationPath, kind: UTXOInputKind, chain: Chain, internalOnly: Bool) -> Bool {
        let c = path.components
        let h = DerivationPath.hardenedOffset
        guard c.count == 5 else { return false }
        return c[0] == kind.purpose | h
            && c[1] == chain.coinType | h
            && c[2] >= h
            && (internalOnly ? c[3] == 1 : c[3] <= 1)
            && c[4] < h
    }

    static func verifyChange(
        _ change: UTXOChangeAddress, chain: Chain, rules: UTXORules, coins: [VerifiedCoin]
    ) throws -> (script: [UInt8], type: UTXOScriptType, kind: UTXOInputKind, address: String) {
        let c = change.path.components
        let kinds = rules.segwit ? UTXOInputKind.allCases : [.p2pkh]
        guard c.count == 5, c[0] >= DerivationPath.hardenedOffset,
              let kind = UTXOInputKind(purpose: c[0] - DerivationPath.hardenedOffset), kinds.contains(kind),
              isWalletPath(change.path, kind: kind, chain: chain, internalOnly: true)
        else { throw UTXOPlanError.changeNotOurs }
        // A chave sai da xpub no caminho dito, e o endereco sai da chave.
        guard change.publicKey.count == 33,
              let derived = try? change.accountKey.derive([c[3], c[4]]), derived.publicKey == change.publicKey
        else { throw UTXOPlanError.changeNotOurs }
        let script = kind.scriptPubKey(publicKey: change.publicKey)
        guard let given = try? UTXOScript.scriptPubKey(for: change.address, chain: chain), given == script,
              let address = UTXOScript.address(for: script, chain: chain)
        else { throw UTXOPlanError.changeNotOurs }
        // A xpub gera as chaves das moedas da mesma conta, e o assinador confere essas
        // chaves contra a seed: a xpub (e o troco) ficam provados como da carteira.
        let sameAccount = coins.filter { Array($0.coin.path.components.prefix(3)) == Array(c.prefix(3)) }
        guard !sameAccount.isEmpty else { throw UTXOPlanError.changeAccountNotSpent }
        for coin in sameAccount {
            let p = coin.coin.path.components
            guard let key = try? change.accountKey.derive([p[3], p[4]]), key.publicKey == coin.coin.publicKey else {
                throw UTXOPlanError.changeNotOurs
            }
        }
        return (script, kind.outputType, kind, address)
    }

    private static func sum(_ values: [UInt64], max limit: UInt64, error: UTXOPlanError = .internalCheckFailed) throws -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow, next <= limit else { throw error }
            total = next
        }
        return total
    }

    // MARK: Revisao

    static func reviewLines(
        chain: Chain, destination: String, summary: UTXOSendSummary, leftBehind: [UInt64], skipped: [UTXOSkippedCoin] = [], valuableLeft: Int = 0
    ) -> [PlanReview.Line] {
        let sats = { (value: BigUInt) in value.uint64 ?? 0 }
        var lines = [
            PlanReview.Line("Para", destination, verbatim: true),
            PlanReview.Line("Valor", UTXOFormat.amount(sats(summary.amount), chain: chain)),
            PlanReview.Line("Rede", chain.name),
            PlanReview.Line("Taxa", "\(UTXOFormat.amount(sats(summary.fee), chain: chain)) (\(UTXOFormat.feeRate(summary.feeRate, chain: chain)))"),
        ]
        let absorbed = sats(summary.absorbedIntoFee)
        if let change = summary.change {
            lines.append(PlanReview.Line("Troco", "\(UTXOFormat.amount(sats(change), chain: chain)), volta para a sua carteira"))
        } else if summary.sendsAll, valuableLeft == 0 {
            lines.append(PlanReview.Line("Troco", "Nenhum: enviar tudo"))
        } else if summary.sendsAll {
            let noun = valuableLeft == 1 ? "1 moeda que ainda vale fica" : "\(valuableLeft) moedas que ainda valem ficam"
            lines.append(PlanReview.Line("Troco", "Nenhum: envia tudo o que as moedas escolhidas pagam; \(noun) de fora"))
        } else if absorbed > 0 {
            lines.append(PlanReview.Line(
                "Troco",
                "Nenhum: \(UTXOFormat.amount(absorbed, chain: chain)) que sobraria fica abaixo do mínimo que vale guardar e vai para a taxa"
            ))
        } else {
            lines.append(PlanReview.Line("Troco", "Nenhum"))
        }
        if !leftBehind.isEmpty {
            let total = leftBehind.reduce(UInt64(0)) { $0 &+ $1 }
            let noun = leftBehind.count == 1 ? "moeda" : "moedas"
            lines.append(PlanReview.Line(
                "Fica na carteira",
                "\(leftBehind.count) \(noun), \(UTXOFormat.amount(total, chain: chain)): pequenas, sem confirmação ou que não pagam a própria taxa"
            ))
        }
        if let text = skippedText(skipped) {
            lines.append(PlanReview.Line("Fora da leitura", text))
        }
        return lines
    }

    /// "3 moedas: 2 que não pagam a própria taxa, 1 sem prova da transação anterior".
    public static func skippedText(_ skipped: [UTXOSkippedCoin]) -> String? {
        guard !skipped.isEmpty else { return nil }
        var parts = [String]()
        for (reason, one, many) in [
            (UTXOSkippedCoin.Reason.uneconomic, "que não paga a própria taxa", "que não pagam a própria taxa"),
            (.overLimit, "além do limite de moedas lidas de uma vez", "além do limite de moedas lidas de uma vez"),
            (.unverified, "sem prova da transação anterior", "sem prova da transação anterior"),
        ] {
            let count = skipped.filter { $0.reason == reason }.count
            if count > 0 { parts.append("\(count) \(count == 1 ? one : many)") }
        }
        let noun = skipped.count == 1 ? "1 moeda" : "\(skipped.count) moedas"
        return "\(noun): \(parts.joined(separator: ", "))"
    }

    /// Primeiro envio e endereco parecido (docs/seguranca.md §4.10): mesmos 4
    /// primeiros e 4 ultimos caracteres depois do prefixo, sem ser identico.
    static func addressWarnings(destination: String, known: [String]?, own: [String]) -> [PlanReview.Warning] {
        var warnings = [PlanReview.Warning]()
        let knownList = known ?? []
        if known != nil, !knownList.contains(destination), !own.contains(destination) {
            warnings.append(.firstSendToAddress)
        }
        let body = significant(destination)
        for candidate in knownList + own where candidate != destination {
            let other = significant(candidate)
            if other.prefix(4) == body.prefix(4), other.suffix(4) == body.suffix(4) {
                warnings.append(.lookalikeAddress(known: candidate))
                break
            }
        }
        return warnings
    }

    /// O endereco sem o prefixo fixo: `bc1q`, `ltc1p`, ou o primeiro caractere do Base58.
    private static func significant(_ address: String) -> Substring {
        if let separator = address.lastIndex(of: "1"), address.hasPrefix("bc1") || address.hasPrefix("ltc1") {
            return address[address.index(after: separator)...].dropFirst()
        }
        return address.dropFirst()
    }
}

// MARK: Texto da revisao

/// Valores e taxas como a tela mostra: virgula decimal e ponto de milhar.
enum UTXOFormat {
    static func amount(_ units: UInt64, chain: Chain) -> String {
        "\(decimal(units, decimals: chain.nativeDecimals)) \(chain.nativeSymbol)"
    }

    static func feeRate(_ rate: UTXOFeeRate, chain: Chain) -> String {
        if chain.id == Chain.dogecoin.id {
            // Dogecoin conta taxa por kB, em DOGE.
            return "\(decimal(rate.satPerKvB, decimals: 8)) DOGE/kB"
        }
        return "\(decimal(rate.satPerKvB, decimals: 3)) sat/vB"
    }

    static func decimal(_ value: UInt64, decimals: Int) -> String {
        var digits = String(value)
        if digits.count <= decimals {
            digits = String(repeating: "0", count: decimals - digits.count + 1) + digits
        }
        let cut = digits.index(digits.endIndex, offsetBy: -decimals)
        let whole = String(digits[..<cut])
        var fraction = String(digits[cut...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        var grouped = ""
        for (index, c) in whole.reversed().enumerated() {
            if index > 0, index % 3 == 0 { grouped.append(".") }
            grouped.append(c)
        }
        let integer = String(grouped.reversed())
        return fraction.isEmpty ? integer : "\(integer),\(fraction)"
    }
}
