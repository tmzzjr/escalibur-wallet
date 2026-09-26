import EscaliburCore
import Foundation

// O estado publico que o planejamento precisa, como dado puro.
//
// EscaliburNetwork preenche estes structs (Horizon ou Stellar RPC); EscaliburChains
// nunca busca nada. Tudo aqui e dado que um provedor pode mentir, entao o
// planejamento trata cada campo como alegacao: confere o que da para conferir
// (a conta do estado e a da carteira, a reserva numa faixa plausivel, a taxa com
// teto compilado) e, no resto, erra para o lado de recusar.

/// A conta da carteira que assina: caminho SEP-0005 e chave publica.
public struct StellarSource: Sendable, Equatable {
    public let path: DerivationPath
    public let account: StellarAccountID

    public enum Problem: Error, Equatable, Sendable {
        /// Fora de `m/44'/148'/i'`: seria assinar com a chave de outra rede ou de
        /// um caminho que nenhuma carteira Stellar reconstroi.
        case notAStellarPath
        case invalidPublicKey
    }

    public init(path: DerivationPath, publicKey: [UInt8]) throws {
        let h = DerivationPath.hardened
        guard path.components.count == 3, path.isFullyHardened,
              path.components[0] == h(44), path.components[1] == h(148)
        else { throw Problem.notAStellarPath }
        guard let account = try? StellarAccountID(publicKey: publicKey) else { throw Problem.invalidPublicKey }
        self.path = path
        self.account = account
    }
}

/// Uma linha de confianca (trustline), da propria conta ou do destino.
/// Horizon: cada item de `balances` com `asset_type` diferente de `native`.
public struct StellarTrustline: Sendable, Equatable {
    public let asset: StellarAsset
    /// Stroops do ativo (7 casas, como o XLM).
    public let balance: BigUInt
    public let limit: BigUInt
    public let buyingLiabilities: BigUInt
    public let sellingLiabilities: BigUInt
    /// `is_authorized`. Emissor com AUTH_REQUIRED deixa a linha existir sem
    /// autorizacao, e pagamento para ela falha.
    public let isAuthorized: Bool

    public init(
        asset: StellarAsset, balance: BigUInt, limit: BigUInt,
        buyingLiabilities: BigUInt = 0, sellingLiabilities: BigUInt = 0, isAuthorized: Bool = true
    ) {
        self.asset = asset
        self.balance = balance
        self.limit = limit
        self.buyingLiabilities = buyingLiabilities
        self.sellingLiabilities = sellingLiabilities
        self.isAuthorized = isAuthorized
    }

    /// O que da para gastar: saldo menos o que ofertas abertas ja prometeram vender.
    public var available: BigUInt {
        balance.subtractingReportingUnderflow(sellingLiabilities) ?? 0
    }

    /// Quanto ainda cabe: limite menos saldo menos o que ofertas abertas vao comprar.
    public var room: BigUInt {
        limit.subtractingReportingUnderflow(balance + buyingLiabilities) ?? 0
    }
}

/// O estado publico da propria conta. Horizon: `/accounts/{G}`.
public struct StellarAccountState: Sendable, Equatable {
    /// De qual conta e este estado. O planejamento recusa se nao for a da carteira.
    public let account: StellarAccountID
    /// `sequence` atual da conta; a transacao usa este mais 1.
    public let sequence: Int64
    /// Saldo de XLM, em stroops.
    public let balance: BigUInt
    /// `subentry_count`: trustlines, ofertas, dados e signatarios extras.
    public let subentryCount: UInt32
    /// `selling_liabilities` do XLM: o que ofertas abertas ja prometeram vender.
    public let sellingLiabilities: BigUInt
    /// `num_sponsoring` e `num_sponsored` (CAP-33): reservas que esta conta paga
    /// por outras, e que outras pagam por ela.
    public let numSponsoring: UInt32
    public let numSponsored: UInt32
    public let trustlines: [StellarTrustline]

    public init(
        account: StellarAccountID, sequence: Int64, balance: BigUInt, subentryCount: UInt32,
        sellingLiabilities: BigUInt = 0, numSponsoring: UInt32 = 0, numSponsored: UInt32 = 0,
        trustlines: [StellarTrustline] = []
    ) {
        self.account = account
        self.sequence = sequence
        self.balance = balance
        self.subentryCount = subentryCount
        self.sellingLiabilities = sellingLiabilities
        self.numSponsoring = numSponsoring
        self.numSponsored = numSponsored
        self.trustlines = trustlines
    }

    public func trustline(for asset: StellarAsset) -> StellarTrustline? {
        trustlines.first { $0.asset == asset }
    }

    /// XLM que da para gastar sem ferir a reserva:
    /// `saldo - (2 + subentradas + patrocinando - patrocinadas + novas) x reserva - liabilities`.
    /// `newSubentries` sao as que a propria transacao cria (trustline, oferta).
    public func spendable(baseReserve: BigUInt, newSubentries: UInt32 = 0) -> BigUInt {
        let entries = Int64(2) + Int64(subentryCount) + Int64(numSponsoring) - Int64(numSponsored) + Int64(newSubentries)
        let minimum = BigUInt(UInt64(max(0, entries))) * baseReserve
        return balance.subtractingReportingUnderflow(minimum + sellingLiabilities) ?? 0
    }
}

/// O que se sabe do destino. Horizon: `/accounts/{G}` (404 significa inexistente).
public struct StellarDestinationState: Sendable, Equatable {
    public let exists: Bool
    public let trustlines: [StellarTrustline]
    /// SEP-29: a entrada de dados `config.memo_required` igual a "1".
    public let memoRequired: Bool

    public init(exists: Bool, trustlines: [StellarTrustline] = [], memoRequired: Bool = false) {
        self.exists = exists
        self.trustlines = exists ? trustlines : []
        self.memoRequired = exists && memoRequired
    }

    public static let missing = StellarDestinationState(exists: false)

    public func trustline(for asset: StellarAsset) -> StellarTrustline? {
        trustlines.first { $0.asset == asset }
    }

    /// Le o SEP-29 do campo `data` do Horizon, cujos valores vem em base64
    /// (`"config.memo_required": "MQ=="`). A regra fica aqui, e nao na rede, para
    /// o "1" ser conferido sempre do mesmo jeito.
    public static func memoRequired(dataEntries: [String: String]) -> Bool {
        guard let encoded = dataEntries["config.memo_required"], let value = Data(base64Encoded: encoded) else { return false }
        return Array(value) == [0x31]
    }
}

/// Parametros da rede no momento. Horizon: `/ledgers?order=desc&limit=1` e `/fee_stats`.
public struct StellarNetworkState: Sendable, Equatable {
    /// `base_reserve_in_stroops`. 5.000.000 (0,5 XLM) desde 2019.
    public let baseReserve: BigUInt
    /// `base_fee_in_stroops`. 100 hoje.
    public let baseFee: BigUInt
    /// `fee_stats.fee_charged.p90`: o que a rede cobrou por operacao nos ultimos
    /// ledgers. Sobe quando ha disputa por espaco.
    public let feeChargedP90: BigUInt

    public init(baseReserve: BigUInt, baseFee: BigUInt, feeChargedP90: BigUInt) {
        self.baseReserve = baseReserve
        self.baseFee = baseFee
        self.feeChargedP90 = feeChargedP90
    }
}

/// Tudo o que um plano precisa alem da intencao do dono.
public struct StellarPlanContext: Sendable {
    public let walletID: UUID
    public let source: StellarSource
    public let account: StellarAccountState
    public let network: StellarNetworkState
    /// A lista curada de ativos que a carteira aceita, com codigo **e** emissor. O
    /// XLM e sempre aceito. Ativo fora dela e recusado, nunca "avisado".
    public let allowedAssets: [StellarAsset]
    public let now: Date

    public init(
        walletID: UUID, source: StellarSource, account: StellarAccountState, network: StellarNetworkState,
        allowedAssets: [StellarAsset], now: Date = .now
    ) {
        self.walletID = walletID
        self.source = source
        self.account = account
        self.network = network
        self.allowedAssets = allowedAssets
        self.now = now
    }

    func isAllowed(_ asset: StellarAsset) -> Bool {
        asset.isNative || allowedAssets.contains(asset)
    }
}

/// Limites compilados. Nenhum vem de servidor.
public enum StellarLimits {
    /// A transacao vale ate agora + 180 s. Assinatura que fica na gaveta nao vira
    /// transacao valida semanas depois.
    public static let validitySeconds: UInt64 = 180
    /// Menor taxa por operacao que o protocolo aceita (100 stroops).
    public static let minFeePerOperation: BigUInt = 100
    /// Teto do lance de taxa por operacao: 0,01 XLM. O lance e um maximo (a rede
    /// cobra o preco de surto, nao o lance), mas um provedor que infla o
    /// `fee_stats` nao pode fazer o dono oferecer mais que isto.
    public static let maxFeePerOperation: BigUInt = 100_000
    /// Faixa plausivel da reserva de base: 0,1 a 5 XLM. Fora disso o estado de rede
    /// e tratado como suspeito (a reserva e 0,5 XLM desde 2019).
    public static let baseReserveRange: ClosedRange<UInt64> = 1_000_000...50_000_000
    /// Tolerancia maxima de troca: 5%.
    public static let maxSlippageBasisPoints: UInt32 = 500
    /// Limite de trustline "sem teto", o mesmo que as carteiras usam (int64 maximo).
    public static let trustlineLimit = Int64.max
}

/// Stroops em texto para a tela: 7 casas, virgula decimal, sem zeros sobrando.
public enum StellarAmount {
    public static let decimals = 7

    public static func format(_ stroops: BigUInt) -> String {
        let text = stroops.decimalString
        let padded = String(repeating: "0", count: max(0, decimals + 1 - text.count)) + text
        let integer = padded.dropLast(decimals)
        var fraction = padded.suffix(decimals)
        while fraction.last == "0" { fraction = fraction.dropLast() }
        return fraction.isEmpty ? String(integer) : "\(integer),\(fraction)"
    }

    public static func format(_ stroops: BigUInt, _ asset: StellarAsset) -> String {
        "\(format(stroops)) \(asset.code)"
    }
}
