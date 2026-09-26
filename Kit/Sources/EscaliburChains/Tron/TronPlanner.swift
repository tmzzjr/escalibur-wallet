import EscaliburCore
import Foundation

// Planejamento Tron: a intencao do dono mais o estado da rede viram um SigningPlan, ou
// uma recusa com motivo. Nada aqui busca dado; tudo que e da rede entra pelo
// `TronNetworkState`, que EscaliburNetwork preenche.
//
// Como a Tron cobra, da fonte (java-tron, commit d5c3d1d1fd0cad12f09c4346d6ac937ab2cbb071):
// - Bandwidth (BandwidthProcessor.consume): a transacao assinada mais 64 bytes. Tenta,
//   nesta ordem, o stake, a cota gratis do dia e, por fim, queima bytes x getTransactionFee.
//   E tudo ou nada: se o stake ou a cota nao cobrem a transacao inteira, queima tudo.
// - Conta nova (TransferActuator + consumeForCreateNewAccount): TRX para endereco que
//   nao existe cobra getCreateNewAccountFeeInSystemContract (1 TRX) e, no lugar da
//   bandwidth normal, usa so stake (bytes x getCreateNewAccountBandwidthRate, 1 hoje)
//   ou queima getCreateAccountFee (0,1 TRX). A cota gratis nao vale para criar conta.
// - Energy (VMActuator.getAccountEnergyLimitWithFixRatio): o limite da execucao e
//   min(energy em stake + saldo / preco, fee_limit / preco). O fee_limit limita a
//   energy TOTAL, inclusive a de stake, entao ele precisa cobrir a estimativa inteira
//   mesmo para quem tem stake. Fee_limit curto demais da OUT_OF_ENERGY: a transacao
//   falha e a energy e queimada do mesmo jeito.
// - Memo: getMemoFee (1 TRX) quando `raw.data` nao esta vazio.

/// A conta que assina: caminho e chave publica. O endereco e derivado da chave aqui.
public struct TronOwner: Sendable, Equatable {
    public let path: DerivationPath
    /// secp256k1 comprimida, 33 bytes.
    public let publicKey: [UInt8]
    public let address: TronAddress

    public init(path: DerivationPath, publicKey: [UInt8]) throws {
        guard publicKey.count == 33, let address = try? TronAddress(publicKey: publicKey) else {
            throw TronPlanError.invalidOwnerKey
        }
        self.path = path
        self.publicKey = publicKey
        self.address = address
    }
}

/// Parametros da rede, lidos pelo chamador em `POST /wallet/getchainparameters`. Todos
/// em sun. Valores na mainnet em 25/09/2026 entre parenteses.
public struct TronChainParameters: Sendable, Equatable {
    /// `getEnergyFee`: sun por unidade de energy (100, Proposta 104).
    public let energyPrice: BigUInt
    /// `getTransactionFee`: sun por byte de bandwidth (1.000).
    public let bandwidthPrice: BigUInt
    /// `getCreateNewAccountFeeInSystemContract`: taxa por criar a conta destino (1.000.000).
    public let createAccountFee: BigUInt
    /// `getCreateAccountFee`: queimado na criacao quando o remetente nao tem
    /// bandwidth em stake (100.000).
    public let createAccountBandwidthFee: BigUInt
    /// `getMemoFee`: cobrado quando o memo nao esta vazio (1.000.000).
    public let memoFee: BigUInt

    public init(energyPrice: BigUInt, bandwidthPrice: BigUInt, createAccountFee: BigUInt, createAccountBandwidthFee: BigUInt, memoFee: BigUInt) {
        self.energyPrice = energyPrice
        self.bandwidthPrice = bandwidthPrice
        self.createAccountFee = createAccountFee
        self.createAccountBandwidthFee = createAccountBandwidthFee
        self.memoFee = memoFee
    }

    /// Faixas largas em volta dos valores de hoje. Parametro fora delas e provedor
    /// errado ou malicioso: com preco zero a tela mostraria custo zero e a transacao
    /// queimaria de verdade; com preco absurdo, o fee_limit iria junto.
    func validate() throws {
        guard energyPrice >= 1, energyPrice <= 1_000 else { throw TronPlanError.parameterOutOfRange("energyPrice") }
        guard bandwidthPrice >= 1, bandwidthPrice <= 10_000 else { throw TronPlanError.parameterOutOfRange("bandwidthPrice") }
        let tenTRX: BigUInt = 10_000_000
        guard createAccountFee <= tenTRX else { throw TronPlanError.parameterOutOfRange("createAccountFee") }
        guard createAccountBandwidthFee <= tenTRX else { throw TronPlanError.parameterOutOfRange("createAccountBandwidthFee") }
        guard memoFee <= tenTRX else { throw TronPlanError.parameterOutOfRange("memoFee") }
    }
}

/// Recursos que a conta do dono ainda tem hoje, de `POST /wallet/getaccountresource`.
public struct TronAccountResources: Sendable, Equatable {
    /// Cota gratis restante: `freeNetLimit - freeNetUsed`.
    public let freeBandwidth: UInt64
    /// Bandwidth de stake restante: `NetLimit - NetUsed`.
    public let stakedBandwidth: UInt64
    /// Energy de stake restante: `EnergyLimit - EnergyUsed`.
    public let energy: UInt64

    public init(freeBandwidth: UInt64, stakedBandwidth: UInt64, energy: UInt64) {
        self.freeBandwidth = freeBandwidth
        self.stakedBandwidth = stakedBandwidth
        self.energy = energy
    }
}

/// Tudo que o planejamento precisa saber da rede, lido pelo chamador logo antes de
/// planejar. Dado publico, nenhum segredo.
public struct TronNetworkState: Sendable {
    /// Bloco recente (`/wallet/getnowblock`), base do TaPoS e da expiracao.
    public let block: TronBlockReference
    /// Saldo de TRX livre do dono, em sun (`balance` do getaccount).
    public let trxBalance: BigUInt
    /// Saldo de USDT do dono, em unidades de 6 casas (`balanceOf`).
    public let usdtBalance: BigUInt
    public let resources: TronAccountResources
    public let parameters: TronChainParameters
    /// O destino ja existe na rede (getaccount do destino nao veio vazio).
    public let destinationActivated: Bool
    /// O destino e um contrato (`/wallet/getcontract` devolveu bytecode).
    public let destinationIsContract: Bool
    /// Energy estimada para ESTA transferencia de USDT (mesmo destino e valor), de
    /// `/wallet/triggerconstantcontract` (`energy_used`) ou `/wallet/estimateenergy`.
    /// So o envio de USDT usa; `nil` no envio de TRX.
    public let usdtEnergyEstimate: UInt64?
    /// O destino ja tem USDT (`balanceOf` > 0). Sem USDT, a transferencia grava um
    /// saldo novo no contrato e gasta cerca do dobro de energy (~13 TRX hoje, contra
    /// ~6,5). `nil` se o chamador nao consultou.
    public let destinationHoldsUSDT: Bool?
    /// O resultado de `TronPermissions.check` sobre o getaccount do dono.
    public let ownerControl: TronAccountControl

    public init(
        block: TronBlockReference, trxBalance: BigUInt, usdtBalance: BigUInt, resources: TronAccountResources,
        parameters: TronChainParameters, destinationActivated: Bool, destinationIsContract: Bool = false,
        usdtEnergyEstimate: UInt64? = nil, destinationHoldsUSDT: Bool? = nil, ownerControl: TronAccountControl
    ) {
        self.block = block
        self.trxBalance = trxBalance
        self.usdtBalance = usdtBalance
        self.resources = resources
        self.parameters = parameters
        self.destinationActivated = destinationActivated
        self.destinationIsContract = destinationIsContract
        self.usdtEnergyEstimate = usdtEnergyEstimate
        self.destinationHoldsUSDT = destinationHoldsUSDT
        self.ownerControl = ownerControl
    }
}

/// O custo estimado de uma transacao, em sun queimados.
public struct TronFeeEstimate: Sendable, Equatable {
    /// Bytes de bandwidth: a transacao assinada mais 64.
    public let bandwidthBytes: UInt64
    /// Zero quando o stake ou a cota gratis cobrem.
    public let bandwidthBurn: BigUInt
    public let energy: UInt64
    /// A parte da energy que o stake nao cobre, vezes o preco.
    public let energyBurn: BigUInt
    /// Criacao da conta destino: 1 TRX, mais 0,1 TRX sem bandwidth em stake.
    public let activationFee: BigUInt
    public let memoFee: BigUInt
    /// O fee_limit gravado na transacao (zero em TRX).
    public let feeLimit: BigUInt

    public var totalBurn: BigUInt { bandwidthBurn + energyBurn + activationFee + memoFee }
}

public enum TronPlanError: Error, Equatable, Sendable {
    case invalidOwnerKey
    /// A chave publica nao e a dona do contrato da transacao.
    case ownerKeyMismatch
    case invalidBlockReference
    case parameterOutOfRange(String)
    /// A checagem de permissoes foi feita para outra conta.
    case controlForOtherAccount
    case accountCompromised([TronPermissionIssue])
    case ownerNotActivated
    case invalidDestination(Address.Problem)
    case destinationIsOwner
    /// Destino e o proprio contrato do USDT: o que vai para la fica preso.
    case destinationIsTokenContract
    /// Endereco de queima (T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb, conta zero).
    case destinationIsBurnAddress
    /// TRX para contrato: a rede recusa (TransferActuator: "Cannot transfer TRX to a smartContract").
    case destinationIsContract
    case zeroAmount
    case amountTooLarge
    case memoTooLong(maxBytes: Int)
    case insufficientTRX(needed: BigUInt, available: BigUInt)
    case insufficientUSDT(needed: BigUInt, available: BigUInt)
    /// Tem USDT e nenhum TRX: nao da para pagar a energy, e a Escalibur nao paga.
    case noTRXForFees(needed: BigUInt)
    case insufficientTRXForFees(needed: BigUInt, available: BigUInt)
    case missingEnergyEstimate
    case energyEstimateOutOfRange(UInt64)
    case feeLimitAboveCeiling(BigUInt)

    /// O motivo, para a tela.
    public var message: String {
        switch self {
        case .invalidOwnerKey, .ownerKeyMismatch:
            return "A chave desta conta não confere. Nada foi assinado."
        case .invalidBlockReference:
            return "O bloco recebido da rede é inconsistente. Tente de novo em instantes."
        case .parameterOutOfRange:
            return "Os parâmetros de taxa recebidos da rede estão fora do normal. Tente de novo em instantes."
        case .controlForOtherAccount:
            return "A verificação de permissões não corresponde a esta conta. Tente de novo."
        case .accountCompromised:
            return "Esta conta Tron é controlada por outra chave. Quem tem a frase não consegue mover o saldo, e qualquer TRX enviado para cá pode ser levado. É o golpe da frase com USDT: não envie nada para esta conta."
        case .ownerNotActivated:
            return "Esta conta ainda não existe na rede Tron. Ela passa a existir quando recebe TRX."
        case .invalidDestination(let problem):
            if case .otherNetwork(let chain) = problem {
                return "Este endereço é da rede \(chain.name). Para Tron, use um endereço que começa com T."
            }
            return "Endereço Tron inválido. Confira se ele começa com T e tem 34 caracteres."
        case .destinationIsOwner:
            return "O destino é a própria conta."
        case .destinationIsTokenContract:
            return "O destino é o contrato do USDT. O que é enviado para ele fica preso para sempre."
        case .destinationIsBurnAddress:
            return "O destino é o endereço de queima da Tron. O que é enviado para ele se perde."
        case .destinationIsContract:
            return "O destino é um contrato. A rede Tron não aceita TRX enviado direto para contrato."
        case .zeroAmount:
            return "Informe um valor maior que zero."
        case .amountTooLarge:
            return "Valor acima do que a rede aceita."
        case .memoTooLong(let max):
            return "O memo passa de \(max) bytes."
        case .insufficientTRX(let needed, let available):
            return "Saldo insuficiente. Este envio precisa de \(TronFormat.trx(needed)) com as taxas, e a conta tem \(TronFormat.trx(available))."
        case .insufficientUSDT(let needed, let available):
            return "Saldo de USDT insuficiente: \(TronFormat.usdt(needed)) pedidos, \(TronFormat.usdt(available)) disponíveis."
        case .noTRXForFees(let needed):
            return "Para enviar USDT na Tron é preciso ter TRX: cada envio queima TRX para pagar a energia da rede (cerca de \(TronFormat.trx(needed)) neste). A Escalibur não paga essa taxa por você. Envie TRX para esta conta e tente de novo."
        case .insufficientTRXForFees(let needed, let available):
            return "TRX insuficiente para as taxas da rede: este envio queima cerca de \(TronFormat.trx(needed)), e a conta tem \(TronFormat.trx(available)). A Escalibur não paga essa taxa por você."
        case .missingEnergyEstimate, .energyEstimateOutOfRange:
            return "Não foi possível estimar a energia deste envio. Tente de novo em instantes."
        case .feeLimitAboveCeiling(let limit):
            return "A taxa máxima calculada (\(TronFormat.trx(limit))) passa do teto de segurança da carteira. Nada foi assinado."
        }
    }
}

public enum TronPlanner {
    /// Teto do fee_limit: 100 TRX. Uma transferencia de USDT para quem nao tem USDT
    /// consome ~130 mil de energy; ao preco de hoje (100 sun) sao 13 TRX, e mesmo ao
    /// preco mais alto que a rede ja teve (420 sun) ficaria em ~55 TRX mais a margem.
    /// Acima disso a estimativa esta errada, e a carteira recusa em vez de autorizar
    /// a queima.
    public static let feeLimitCeiling: BigUInt = 100_000_000

    /// Faixa plausivel de energy para `transfer` do USDT. Hoje: ~65 mil para quem ja
    /// tem USDT e ~130 mil para quem nao tem (docs/blockchain.md §2.6), com
    /// `energy_factor` no maximo. Fora da faixa, a estimativa do provedor esta errada:
    /// baixa demais daria OUT_OF_ENERGY e queima sem transferencia.
    public static let usdtEnergyRange: ClosedRange<UInt64> = 10_000...200_000

    /// Margem do fee_limit sobre a estimativa: 25%. O `energy_factor` do contrato so
    /// muda nos periodos de manutencao, e o fee_limit e teto, nao cobranca: a rede
    /// queima o que a execucao gastar.
    static let feeLimitMargin = (numerator: BigUInt(5), denominator: BigUInt(4))

    public static let maxMemoBytes = 256

    static let sunPerTRX: BigUInt = 1_000_000

    // MARK: TRX

    /// Planeja um envio de TRX. `amount` em sun.
    public static func planSendTRX(
        walletID: UUID, owner: TronOwner, to destination: String, amount: BigUInt, memo: String? = nil,
        state: TronNetworkState, now: Date = .now
    ) throws -> SigningPlan {
        try state.parameters.validate()
        try checkControl(owner: owner, state: state)
        guard state.ownerControl.verdict != .notActivated else { throw TronPlanError.ownerNotActivated }
        let to = try resolveDestination(destination, owner: owner)
        guard !state.destinationIsContract else { throw TronPlanError.destinationIsContract }
        guard !amount.isZero else { throw TronPlanError.zeroAmount }
        guard amount.tronInt64 != nil else { throw TronPlanError.amountTooLarge }
        let memoBytes = try encodeMemo(memo)

        let raw = try TronRawTransaction(
            refBlockBytes: state.block.refBlockBytes, refBlockHash: state.block.refBlockHash,
            expiration: state.block.expiration(now: milliseconds(now)), memo: memoBytes,
            contract: .transfer(owner: owner.address, to: to, amount: amount),
            timestamp: milliseconds(now)
        )

        let p = state.parameters
        let r = state.resources
        let bytes = TronTransaction.bandwidthBytes(of: raw)
        var bandwidthBurn: BigUInt = 0
        var activationFee: BigUInt = 0
        if state.destinationActivated {
            bandwidthBurn = bandwidthCost(bytes: bytes, resources: r, price: p.bandwidthPrice)
        } else {
            activationFee = p.createAccountFee + (r.stakedBandwidth >= bytes ? 0 : p.createAccountBandwidthFee)
        }
        let fees = TronFeeEstimate(
            bandwidthBytes: bytes, bandwidthBurn: bandwidthBurn, energy: 0, energyBurn: 0,
            activationFee: activationFee, memoFee: memoBytes.isEmpty ? 0 : p.memoFee, feeLimit: 0
        )
        let needed = amount + fees.totalBurn
        guard state.trxBalance >= needed else {
            throw TronPlanError.insufficientTRX(needed: needed, available: state.trxBalance)
        }

        var lines: [PlanReview.Line] = [
            .init("Para", to.base58, verbatim: true),
            .init("Rede", "Tron"),
            .init("Valor", TronFormat.trx(amount)),
        ]
        if !memoBytes.isEmpty {
            lines.append(.init("Memo", memo ?? "", verbatim: true))
            lines.append(.init("Taxa do memo", TronFormat.trx(fees.memoFee)))
        }
        var warnings: [PlanReview.Warning] = []
        if !state.destinationActivated {
            lines.append(.init("Ativação da conta de destino", TronFormat.trx(activationFee)))
            warnings.append(.activatesAccount(minimum: TronFormat.trx(activationFee)))
        }
        lines.append(bandwidthLine(fees: fees))
        lines.append(.init("Custo estimado", "\(TronFormat.trx(fees.totalBurn)) queimados"))
        lines.append(.init("Sai da conta", TronFormat.trx(needed)))
        if !fees.totalBurn.isZero {
            let percent = TronFormat.ratio(fees.totalBurn * 100, amount)
            if percent > 10 { warnings.append(.highFee(percentOfAmount: percent)) }
        }

        let review = PlanReview(
            kind: .send, title: "Enviar \(TronFormat.trx(amount))", lines: lines, warnings: warnings,
            recipient: to.base58, recipientTag: memoBytes.isEmpty ? nil : memo
        )
        let transaction = try TronTransaction(raw: raw, path: owner.path, publicKey: owner.publicKey)
        return SigningPlan(walletID: walletID, chain: .tron, review: review, transactions: [transaction], createdAt: now)
    }

    // MARK: USDT

    /// Planeja um envio de USDT (TRC-20). `amount` em unidades de 6 casas.
    public static func planSendUSDT(
        walletID: UUID, owner: TronOwner, to destination: String, amount: BigUInt, memo: String? = nil,
        state: TronNetworkState, now: Date = .now
    ) throws -> SigningPlan {
        try state.parameters.validate()
        try checkControl(owner: owner, state: state)
        let to = try resolveDestination(destination, owner: owner)
        guard !amount.isZero else { throw TronPlanError.zeroAmount }
        guard amount <= state.usdtBalance else {
            throw TronPlanError.insufficientUSDT(needed: amount, available: state.usdtBalance)
        }
        let memoBytes = try encodeMemo(memo)

        guard let energy = state.usdtEnergyEstimate else { throw TronPlanError.missingEnergyEstimate }
        guard usdtEnergyRange.contains(energy) else { throw TronPlanError.energyEstimateOutOfRange(energy) }
        let p = state.parameters
        let r = state.resources
        let feeLimit = feeLimit(energy: energy, price: p.energyPrice)
        guard feeLimit <= feeLimitCeiling else { throw TronPlanError.feeLimitAboveCeiling(feeLimit) }

        let raw = try TronRawTransaction(
            refBlockBytes: state.block.refBlockBytes, refBlockHash: state.block.refBlockHash,
            expiration: state.block.expiration(now: milliseconds(now)), memo: memoBytes,
            contract: .triggerSmartContract(
                owner: owner.address, contract: TRC20.usdt.contract, callValue: 0,
                data: try TRC20.transferCalldata(to: to, amount: amount)
            ),
            timestamp: milliseconds(now), feeLimit: feeLimit
        )

        let bytes = TronTransaction.bandwidthBytes(of: raw)
        let energyBurn = energy > r.energy ? BigUInt(energy - r.energy) * p.energyPrice : 0
        let fees = TronFeeEstimate(
            bandwidthBytes: bytes, bandwidthBurn: bandwidthCost(bytes: bytes, resources: r, price: p.bandwidthPrice),
            energy: energy, energyBurn: energyBurn, activationFee: 0,
            memoFee: memoBytes.isEmpty ? 0 : p.memoFee, feeLimit: feeLimit
        )
        let needed = fees.totalBurn
        // Conta que so recebeu USDT nao existe na rede: nao tem stake nem cota e nao
        // assina nada ate receber TRX. Depois de ativada ganha a cota gratis de
        // bandwidth, entao o que ela vai precisar e a energy inteira mais o memo.
        if state.ownerControl.verdict == .notActivated {
            throw TronPlanError.noTRXForFees(needed: BigUInt(energy) * p.energyPrice + fees.memoFee)
        }
        guard state.trxBalance >= needed else {
            if state.trxBalance.isZero { throw TronPlanError.noTRXForFees(needed: needed) }
            throw TronPlanError.insufficientTRXForFees(needed: needed, available: state.trxBalance)
        }

        var lines: [PlanReview.Line] = [
            .init("Para", to.base58, verbatim: true),
            .init("Rede", "Tron (TRC-20)"),
            .init("Contrato do USDT", TRC20.usdt.contract.base58, verbatim: true),
            .init("Valor", TronFormat.usdt(amount)),
        ]
        if !memoBytes.isEmpty {
            lines.append(.init("Memo", memo ?? "", verbatim: true))
            lines.append(.init("Taxa do memo", TronFormat.trx(fees.memoFee)))
        }
        var warnings: [PlanReview.Warning] = []
        if state.destinationHoldsUSDT == false {
            lines.append(.init(
                "Destino sem USDT",
                "A primeira transferência para este endereço grava um saldo novo no contrato e gasta cerca do dobro de energia."
            ))
        }
        if !state.destinationActivated {
            lines.append(.init(
                "Destino sem conta ativa",
                "O USDT chega, mas para movimentá-lo o dono do endereço vai precisar de TRX."
            ))
        }
        if state.destinationIsContract { warnings.append(.destinationIsContract) }
        lines.append(energyLine(fees: fees))
        lines.append(bandwidthLine(fees: fees))
        lines.append(.init("Custo estimado", "\(TronFormat.trx(fees.totalBurn)) queimados"))
        lines.append(.init("Taxa máxima (fee_limit)", TronFormat.trx(feeLimit)))

        let review = PlanReview(
            kind: .send, title: "Enviar \(TronFormat.usdt(amount))", lines: lines, warnings: warnings,
            recipient: to.base58, recipientTag: memoBytes.isEmpty ? nil : memo
        )
        let transaction = try TronTransaction(raw: raw, path: owner.path, publicKey: owner.publicKey)
        return SigningPlan(walletID: walletID, chain: .tron, review: review, transactions: [transaction], createdAt: now)
    }

    // MARK: Regras comuns

    static func checkControl(owner: TronOwner, state: TronNetworkState) throws {
        guard state.ownerControl.address == owner.address else { throw TronPlanError.controlForOtherAccount }
        if case .compromised(let issues) = state.ownerControl.verdict {
            throw TronPlanError.accountCompromised(issues)
        }
    }

    static func resolveDestination(_ text: String, owner: TronOwner) throws -> TronAddress {
        let destination: Address.Destination
        switch Address.validate(text, for: .tron) {
        case .failure(let problem): throw TronPlanError.invalidDestination(problem)
        case .success(let value): destination = value
        }
        guard let to = TronAddress(base58: destination.address) else { throw TronPlanError.invalidDestination(.malformed) }
        guard to != owner.address else { throw TronPlanError.destinationIsOwner }
        guard to != TRC20.usdt.contract else { throw TronPlanError.destinationIsTokenContract }
        guard to.account20.contains(where: { $0 != 0 }) else { throw TronPlanError.destinationIsBurnAddress }
        return to
    }

    static func encodeMemo(_ memo: String?) throws -> [UInt8] {
        let bytes = Array((memo ?? "").utf8)
        guard bytes.count <= maxMemoBytes else { throw TronPlanError.memoTooLong(maxBytes: maxMemoBytes) }
        return bytes
    }

    /// Tudo ou nada, como o BandwidthProcessor: stake ou cota gratis precisam cobrir a
    /// transacao inteira; se nao, queima o tamanho todo.
    static func bandwidthCost(bytes: UInt64, resources: TronAccountResources, price: BigUInt) -> BigUInt {
        if resources.stakedBandwidth >= bytes || resources.freeBandwidth >= bytes { return 0 }
        return BigUInt(bytes) * price
    }

    /// Estimativa x preco x 1,25, arredondado para cima ate o TRX inteiro.
    static func feeLimit(energy: UInt64, price: BigUInt) -> BigUInt {
        let raw = BigUInt(energy) * price * feeLimitMargin.numerator
        let withMargin = (raw + feeLimitMargin.denominator - 1) / feeLimitMargin.denominator
        return (withMargin + sunPerTRX - 1) / sunPerTRX * sunPerTRX
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    private static func bandwidthLine(fees: TronFeeEstimate) -> PlanReview.Line {
        let usage = "\(TronFormat.integer(fees.bandwidthBytes)) bytes"
        if fees.activationFee > 0 {
            return .init("Banda", "\(usage), incluída na ativação")
        }
        if fees.bandwidthBurn.isZero {
            return .init("Banda", "\(usage), coberta pela cota da conta")
        }
        return .init("Banda", "\(usage), \(TronFormat.trx(fees.bandwidthBurn)) queimados")
    }

    private static func energyLine(fees: TronFeeEstimate) -> PlanReview.Line {
        let usage = "\(TronFormat.integer(fees.energy)) de energia"
        if fees.energyBurn.isZero {
            return .init("Energia", "\(usage), coberta pelo stake")
        }
        return .init("Energia", "\(usage), \(TronFormat.trx(fees.energyBurn)) queimados")
    }
}

/// Numeros para a tela de revisao, no padrao pt-BR da carteira (ponto no milhar,
/// virgula decimal, sem zeros a direita, sem arredondar).
enum TronFormat {
    static func units(_ amount: BigUInt, decimals: Int) -> String {
        let digits = amount.decimalString
        let whole: String
        var fraction: String
        if digits.count <= decimals {
            whole = "0"
            fraction = String(repeating: "0", count: decimals - digits.count) + digits
        } else {
            let cut = digits.index(digits.endIndex, offsetBy: -decimals)
            whole = String(digits[..<cut])
            fraction = String(digits[cut...])
        }
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let grouped = group(whole)
        return fraction.isEmpty ? grouped : "\(grouped),\(fraction)"
    }

    static func trx(_ sun: BigUInt) -> String { "\(units(sun, decimals: 6)) TRX" }

    static func usdt(_ amount: BigUInt) -> String { "\(units(amount, decimals: TRC20.usdt.decimals)) USDT" }

    static func integer(_ value: UInt64) -> String { group(String(value)) }

    /// `a / b` so para exibir (porcentagem de taxa). Nunca entra em transacao.
    static func ratio(_ a: BigUInt, _ b: BigUInt) -> Double {
        guard !b.isZero else { return 0 }
        return (Double(a.decimalString) ?? 0) / (Double(b.decimalString) ?? 1)
    }

    private static func group(_ digits: String) -> String {
        var out = ""
        for (index, c) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { out.append(".") }
            out.append(c)
        }
        return String(out.reversed())
    }
}
