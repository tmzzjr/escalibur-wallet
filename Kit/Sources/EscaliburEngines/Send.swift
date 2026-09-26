import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation

/// O que o app precisa de cada rede para enviar: saber do destino, calcular o
/// maximo, montar o plano validado, transmitir e acompanhar.
///
/// Cada rede tem um motor que junta o leitor de estado (EscaliburNetwork) e o
/// planejador (EscaliburChains). O app nunca monta transacao: ele entrega a
/// intencao, e o planejador valida e monta. Nada aqui assina.
public protocol SendEngine: Sendable {
    /// O que a rede sabe do destino antes do valor: se existe, se exige tag ou memo,
    /// se e contrato.
    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo

    /// Quanto do ativo pode sair agora, ja descontando reserva e taxa.
    func spendable(_ request: SendRequest) async throws -> Spendable

    /// Le o estado, valida e monta o plano. Nada e assinado aqui. O plano sai com
    /// `review.recipient` e `review.recipientTag`, que o app confere contra o digitado.
    func plan(_ request: SendRequest) async throws -> SigningPlan

    /// Transmite os mesmos bytes assinados. Devolve o id que o explorador entende,
    /// calculado localmente a partir dos bytes, nunca o que o provedor devolveu.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String

    func status(_ id: String, chain: Chain) async -> TransferStatus
}

public struct SendRequest: Sendable {
    public let walletID: UUID
    public let chain: Chain
    public let asset: Asset
    public let account: DerivedAccount
    public let destination: String
    /// Tag de destino (XRP Ledger), memo (Stellar, Tron) ou comentario (TON).
    public let tag: String?
    public let amount: BigUInt
    public let sendAll: Bool
    public let feeLevel: FeeLevel
    public let utxoUsage: UTXOUsage?
    /// Enderecos para onde esta carteira ja enviou nesta rede, para os avisos do plano.
    public let knownAddresses: [String]

    public init(
        walletID: UUID, chain: Chain, asset: Asset, account: DerivedAccount, destination: String, tag: String?,
        amount: BigUInt, sendAll: Bool, feeLevel: FeeLevel, utxoUsage: UTXOUsage?, knownAddresses: [String] = []
    ) {
        self.walletID = walletID
        self.chain = chain
        self.asset = asset
        self.account = account
        self.destination = destination
        self.tag = tag
        self.amount = amount
        self.sendAll = sendAll
        self.feeLevel = feeLevel
        self.utxoUsage = utxoUsage
        self.knownAddresses = knownAddresses
    }
}

public enum FeeLevel: String, Sendable, CaseIterable { case slow, normal, fast }

public struct DestinationInfo: Sendable {
    public var exists: Bool
    /// A propria rede exige tag/memo (RequireDest, SEP-29).
    public var requiresTag: Bool
    public var isContract: Bool
    /// Minimo para ativar a conta de destino, quando ela ainda nao existe.
    public var activationMinimum: BigUInt?
    public var note: String?

    public init(exists: Bool = true, requiresTag: Bool = false, isContract: Bool = false, activationMinimum: BigUInt? = nil, note: String? = nil) {
        self.exists = exists
        self.requiresTag = requiresTag
        self.isContract = isContract
        self.activationMinimum = activationMinimum
        self.note = note
    }
}

public struct Spendable: Sendable {
    public let amount: BigUInt
    /// "1 XRP fica reservado pela rede enquanto a conta existir."
    public let reserveNote: String?
    public let feeNote: String?

    public init(amount: BigUInt, reserveNote: String? = nil, feeNote: String? = nil) {
        self.amount = amount
        self.reserveNote = reserveNote
        self.feeNote = feeNote
    }
}

public enum TransferStatus: Sendable, Equatable {
    case pending
    case confirmed(detail: String?)
    case failed(reason: String)
}

/// O erro que a tela mostra. `message` ja vem em portugues, sem travessao e sem
/// dado que o provedor devolveu.
public enum SendEngineError: LocalizedError, Equatable {
    case unsupported(Chain)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let chain): return "Enviar pela rede \(chain.name) chega numa atualização em breve. Receber já funciona."
        case .message(let text): return text
        }
    }
}

/// Enderecos UTXO ja usados, por rede: indices de recebimento e troco.
public struct UTXOUsage: Codable, Equatable, Hashable, Sendable {
    public var receiveUsed: Int
    public var changeUsed: Int

    public init(receiveUsed: Int = 0, changeUsed: Int = 0) {
        self.receiveUsed = receiveUsed
        self.changeUsed = changeUsed
    }
}

/// Os motores disponiveis nesta versao.
public enum SendEngines {
    public static func engine(for chain: Chain) -> (any SendEngine)? {
        nil
    }
}
