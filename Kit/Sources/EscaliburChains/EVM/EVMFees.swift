import EscaliburCore
import Foundation

// Taxa e estado publico da rede.
//
// O estado entra como dado puro, preenchido por EscaliburNetwork. Nada aqui busca
// nada. A regra de taxa segue docs/seguranca.md 4.3 item 8 e docs/blockchain.md 2.2:
//
//   maxFeePerGas <= 2 * baseFee + tip, e nunca acima do teto compilado da rede
//   gasLimit     =  estimativa * 1,2 (nunca acima de estimativa * 1,3 nem de 2^24)
//
// Gas e preco sugeridos por provedor de swap sao ignorados: a carteira estima.

/// Gorjetas sugeridas, dos percentis 25, 50 e 75 do `eth_feeHistory`.
public struct EVMPriorityFees: Sendable, Equatable {
    public let slow: BigUInt
    public let normal: BigUInt
    public let fast: BigUInt

    public init(slow: BigUInt, normal: BigUInt, fast: BigUInt) {
        self.slow = slow
        self.normal = normal
        self.fast = fast
    }
}

public enum EVMFeeSpeed: String, Sendable, CaseIterable {
    case slow, normal, fast
}

public enum EVMTransactionFormat: String, Sendable {
    /// Tipo 2. O padrao em todas as redes.
    case eip1559
    /// Legado com EIP-155. So onde o perfil da rede permite (BNB), como alternativa
    /// para RPC que recusa tipo 2.
    case legacy
}

/// O estado publico da rede que o planejamento precisa. A camada de rede preenche;
/// o planejamento confere e recusa o que nao fecha.
public struct EVMNetworkState: Sendable, Equatable {
    /// A rede a que estes dados se referem. Tem de ser a do plano.
    public let chain: Chain
    /// `eth_getTransactionCount(conta, "pending")` de pelo menos duas fontes
    /// independentes. O plano usa o maior e recusa se divergirem demais.
    public let pendingNonces: [UInt64]
    /// O proximo nonce segundo a fila local de transacoes enviadas e ainda nao vistas.
    public let localNextNonce: UInt64?
    /// baseFee do proximo bloco. Com mais de um provedor, o maior.
    public let baseFeePerGas: BigUInt
    public let priorityFees: EVMPriorityFees
    /// `eth_estimateGas` da chamada exata que vai ser assinada.
    public let gasEstimate: UInt64
    /// OP e Base: taxa de dados da L1, cobrada a parte (GasPriceOracle
    /// `0x420000000000000000000000000000000000000F`, `getL1FeeUpperBound`). Nas
    /// outras redes, `nil`.
    public let l1DataFee: BigUInt?
    /// Saldo nativo da conta, em wei.
    public let nativeBalance: BigUInt
    /// `eth_getCode` do destino diferente de `0x`. Envio nativo: o `to`. Envio de
    /// token: o destinatario do token (nao o contrato). Approve: o spender.
    public let destinationHasCode: Bool

    public init(
        chain: Chain, pendingNonces: [UInt64], localNextNonce: UInt64? = nil, baseFeePerGas: BigUInt,
        priorityFees: EVMPriorityFees, gasEstimate: UInt64, l1DataFee: BigUInt? = nil,
        nativeBalance: BigUInt, destinationHasCode: Bool
    ) {
        self.chain = chain
        self.pendingNonces = pendingNonces
        self.localNextNonce = localNextNonce
        self.baseFeePerGas = baseFeePerGas
        self.priorityFees = priorityFees
        self.gasEstimate = gasEstimate
        self.l1DataFee = l1DataFee
        self.nativeBalance = nativeBalance
        self.destinationHasCode = destinationHasCode
    }
}

/// Estado do token para os planos ERC-20.
public struct EVMTokenState: Sendable, Equatable {
    /// `eth_getCode` do contrato do token diferente de `0x`.
    public let contractHasCode: Bool
    /// `balanceOf(dono)`.
    public let balance: BigUInt
    /// `allowance(dono, spender)`. Obrigatorio nos planos de approve e revogacao.
    public let allowance: BigUInt?

    public init(contractHasCode: Bool, balance: BigUInt, allowance: BigUInt? = nil) {
        self.contractHasCode = contractHasCode
        self.balance = balance
        self.allowance = allowance
    }
}

/// Parametros de taxa por rede, compilados. Os tetos sao de **sanidade**, nao de
/// mercado: existem para limitar o estrago de um provedor que mente sobre baseFee ou
/// gorjeta. Ficam bem acima dos picos historicos de cada rede; passar deles recusa o
/// plano em vez de assinar uma taxa absurda.
public struct EVMFeeProfile: Sendable, Equatable {
    /// Teto absoluto de `maxFeePerGas`, em wei.
    public let maxFeeCeiling: BigUInt
    /// Menor gorjeta que a rede aceita.
    public let minPriorityFee: BigUInt
    /// Maior gorjeta que a carteira paga. Sugestao acima disso e cortada.
    public let maxPriorityFee: BigUInt
    /// OP Stack: taxa de dados da L1 a parte.
    public let chargesL1DataFee: Bool
    /// BNB: baseFee zero e `maxFee = maxPriority`.
    public let priorityEqualsMaxFee: Bool
    public let allowsLegacy: Bool

    static let gwei = BigUInt(1_000_000_000)

    static func gwei(_ value: UInt64) -> BigUInt { BigUInt(value) * gwei }

    /// O perfil de cada rede EVM, pelo chainId compilado.
    public static func `for`(_ chain: Chain) -> EVMFeeProfile? {
        guard chain.family == .evm else { return nil }
        switch chain.evmChainID {
        case 1:
            // Ethereum: baseFee ~0,07 gwei hoje; picos historicos de centenas de gwei.
            return EVMFeeProfile(maxFeeCeiling: gwei(500), minPriorityFee: 0, maxPriorityFee: gwei(10),
                                 chargesL1DataFee: false, priorityEqualsMaxFee: false, allowsLegacy: false)
        case 42161:
            // Arbitrum: a gorjeta e ignorada pelo sequenciador; o estimateGas ja
            // inclui a parcela L1 em unidades de gas.
            return EVMFeeProfile(maxFeeCeiling: gwei(20), minPriorityFee: 0, maxPriorityFee: 0,
                                 chargesL1DataFee: false, priorityEqualsMaxFee: false, allowsLegacy: false)
        case 8453, 10:
            // Base e OP: baseFee de milesimos de gwei; a taxa L1 vem a parte.
            return EVMFeeProfile(maxFeeCeiling: gwei(20), minPriorityFee: 0, maxPriorityFee: gwei(2),
                                 chargesL1DataFee: true, priorityEqualsMaxFee: false, allowsLegacy: false)
        case 137:
            // Polygon: baseFee ~245 gwei e gorjeta minima de 25 gwei (conferido ao vivo).
            return EVMFeeProfile(maxFeeCeiling: gwei(10_000), minPriorityFee: gwei(25), maxPriorityFee: gwei(2_000),
                                 chargesL1DataFee: false, priorityEqualsMaxFee: false, allowsLegacy: false)
        case 56:
            // BNB: baseFee zero, gorjeta minima de 0,05 gwei (conferido ao vivo).
            return EVMFeeProfile(maxFeeCeiling: gwei(20), minPriorityFee: BigUInt(50_000_000), maxPriorityFee: gwei(10),
                                 chargesL1DataFee: false, priorityEqualsMaxFee: true, allowsLegacy: true)
        case 43114:
            // Avalanche C: ~0,04 gwei hoje; picos de centenas de gwei em 2023/2024.
            return EVMFeeProfile(maxFeeCeiling: gwei(2_000), minPriorityFee: 0, maxPriorityFee: gwei(100),
                                 chargesL1DataFee: false, priorityEqualsMaxFee: false, allowsLegacy: false)
        default:
            return nil
        }
    }
}

/// A taxa calculada para uma transacao.
public struct EVMFeeQuote: Sendable, Equatable {
    public let fee: EVMTransaction.Fee
    public let gasLimit: UInt64
    /// `gasLimit * maxFee + taxa L1`: o que o saldo precisa cobrir.
    public let maxCost: BigUInt
    /// `estimativa * (baseFee + gorjeta) + taxa L1`: o provavel, para a tela.
    public let expectedCost: BigUInt
    public let l1DataFee: BigUInt
}

public enum EVMPlanError: Error, Equatable, Sendable {
    case notEVMChain
    /// Estado, token e plano nao sao da mesma rede.
    case chainMismatch
    case nonceNeedsTwoSources
    /// As fontes de nonce divergem mais do que uma transacao em transito explica.
    case nonceSourcesDisagree
    case invalidGasEstimate
    case gasLimitAboveCap
    /// A baseFee atual ja passa do teto da rede: esperar.
    case feeAboveCeiling
    case missingL1DataFee
    case legacyNotSupported
    case zeroAmount
    case insufficientNativeBalance(needed: BigUInt, available: BigUInt)
    case insufficientTokenBalance(needed: BigUInt, available: BigUInt)
    case tokenHasNoCode
    case spenderHasNoCode
    case selfApproval
    case missingAllowance
    case allowanceAlreadySet
    case nothingToRevoke
    /// `approve(uint256 max)` pedido como valor exato: aprovacao ilimitada so por
    /// escolha explicita.
    case unlimitedMustBeExplicit
    case refused(EVMCallRefusal)
}

enum EVMFeeCalculator {
    /// Diferenca maxima aceita entre as fontes de nonce pending. Uma ou duas
    /// transacoes em transito explicam diferenca pequena; diferenca grande e
    /// provedor mentindo, e um nonce la na frente produziria uma transacao assinada
    /// que so executa no futuro, quando o dono ja esqueceu dela.
    static let maxNonceSpread: UInt64 = 4
    /// Quanto a fila local pode estar a frente das fontes.
    static let maxLocalLead: UInt64 = 16

    static func nonce(_ state: EVMNetworkState) throws -> UInt64 {
        guard state.pendingNonces.count >= 2, let high = state.pendingNonces.max(), let low = state.pendingNonces.min() else {
            throw EVMPlanError.nonceNeedsTwoSources
        }
        guard high - low <= maxNonceSpread else { throw EVMPlanError.nonceSourcesDisagree }
        guard let local = state.localNextNonce else { return high }
        guard local <= high + maxLocalLead else { throw EVMPlanError.nonceSourcesDisagree }
        return max(high, local)
    }

    static func quote(
        chain: Chain, state: EVMNetworkState, speed: EVMFeeSpeed, format: EVMTransactionFormat, plainTransfer: Bool
    ) throws -> EVMFeeQuote {
        guard let profile = EVMFeeProfile.for(chain) else { throw EVMPlanError.notEVMChain }
        guard state.chain.id == chain.id else { throw EVMPlanError.chainMismatch }
        if format == .legacy, !profile.allowsLegacy { throw EVMPlanError.legacyNotSupported }

        // Gas: 21.000 exato para transferencia simples a conta sem codigo (o custo e
        // deterministico, e o "enviar tudo" fecha); fora isso, estimativa * 1,2.
        let estimate = state.gasEstimate
        guard estimate >= 21_000, estimate <= EVMTransaction.maxGasLimit else {
            throw estimate > EVMTransaction.maxGasLimit ? EVMPlanError.gasLimitAboveCap : EVMPlanError.invalidGasEstimate
        }
        let gasLimit: UInt64
        if plainTransfer, estimate == 21_000 {
            gasLimit = 21_000
        } else {
            gasLimit = min((estimate * 12 + 9) / 10, EVMTransaction.maxGasLimit)
        }

        // Gorjeta: a sugestao da velocidade, entre o minimo da rede e o teto.
        var tip: BigUInt
        switch speed {
        case .slow: tip = state.priorityFees.slow
        case .normal: tip = state.priorityFees.normal
        case .fast: tip = state.priorityFees.fast
        }
        if tip < profile.minPriorityFee { tip = profile.minPriorityFee }
        if tip > profile.maxPriorityFee { tip = profile.maxPriorityFee }

        let baseFee = state.baseFeePerGas
        guard baseFee + tip <= profile.maxFeeCeiling else { throw EVMPlanError.feeAboveCeiling }

        let fee: EVMTransaction.Fee
        let perGasExpected: BigUInt
        if profile.priorityEqualsMaxFee {
            // BNB: um preco so. A baseFee e zero; se um dia nao for, ela entra no
            // preco para a transacao nao ficar abaixo do minimo do bloco.
            let price = baseFee + tip
            fee = format == .legacy ? .legacy(gasPrice: price) : .eip1559(maxPriorityFeePerGas: price, maxFeePerGas: price)
            perGasExpected = price
        } else {
            var maxFee = baseFee * BigUInt(2) + tip
            if maxFee > profile.maxFeeCeiling { maxFee = profile.maxFeeCeiling }
            fee = format == .legacy ? .legacy(gasPrice: maxFee) : .eip1559(maxPriorityFeePerGas: tip, maxFeePerGas: maxFee)
            perGasExpected = format == .legacy ? maxFee : baseFee + tip
        }

        let l1Fee: BigUInt
        if profile.chargesL1DataFee {
            guard let reported = state.l1DataFee else { throw EVMPlanError.missingL1DataFee }
            l1Fee = reported
        } else {
            l1Fee = 0
        }
        return EVMFeeQuote(
            fee: fee, gasLimit: gasLimit,
            maxCost: BigUInt(gasLimit) * fee.maxPerGas + l1Fee,
            expectedCost: BigUInt(estimate) * perGasExpected + l1Fee,
            l1DataFee: l1Fee
        )
    }
}
