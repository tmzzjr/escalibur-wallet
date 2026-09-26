import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation

/// O que o app precisa de cada rede para enviar: saber do destino, calcular o
/// maximo, montar o plano validado, transmitir e acompanhar.
///
/// Cada rede tem um motor que junta o leitor de estado (EscaliburNetwork) e o
/// planejador (EscaliburChains). O app nunca monta transacao: ele entrega a
/// intencao, e o planejador valida e monta.
protocol SendEngine: Sendable {
    /// O que a rede sabe do destino antes do valor: se existe, se exige tag ou memo,
    /// se e contrato.
    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo

    /// Quanto do ativo pode sair agora, ja descontando reserva e taxa.
    func spendable(_ request: SendRequest) async throws -> Spendable

    /// Le o estado, valida e monta o plano. Nada e assinado aqui.
    func plan(_ request: SendRequest) async throws -> SigningPlan

    /// Transmite os mesmos bytes assinados. Devolve o id que o explorador entende.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String

    func status(_ id: String, chain: Chain) async -> TransferStatus
}

struct SendRequest: Sendable {
    let walletID: UUID
    let chain: Chain
    let asset: Asset
    let account: DerivedAccount
    let destination: String
    /// Tag de destino (XRP Ledger), memo (Stellar) ou comentario (TON).
    let tag: String?
    let amount: BigUInt
    let sendAll: Bool
    let feeLevel: FeeLevel
    let utxoUsage: UTXOUsage?
}

enum FeeLevel: String, Sendable, CaseIterable { case slow, normal, fast }

struct DestinationInfo: Sendable {
    var exists = true
    /// A propria rede exige tag/memo (RequireDest, SEP-29).
    var requiresTag = false
    var isContract = false
    /// Minimo para ativar a conta de destino, quando ela ainda nao existe.
    var activationMinimum: BigUInt?
    var note: String?
}

struct Spendable: Sendable {
    let amount: BigUInt
    /// "1 XRP fica reservado pela rede enquanto a conta existir."
    let reserveNote: String?
    let feeNote: String?
}

enum TransferStatus: Sendable, Equatable {
    case pending
    case confirmed(detail: String?)
    case failed(reason: String)
}

enum SendEngineError: LocalizedError {
    case unsupported(Chain)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let chain): return "Enviar pela rede \(chain.name) chega numa atualização em breve. Receber já funciona."
        case .message(let text): return text
        }
    }
}

/// Os motores disponiveis nesta versao.
enum SendEngines {
    static func engine(for chain: Chain) -> (any SendEngine)? {
        nil
    }
}
