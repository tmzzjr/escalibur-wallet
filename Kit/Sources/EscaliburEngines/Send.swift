import EscaliburChains
import EscaliburCore
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
    /// EVM: a fila local de transacoes desta conta ainda em transito. Sem ela, as fontes
    /// de nonce tem de concordar exatamente.
    public let nonceQueue: PendingNonceQueue?

    public init(
        walletID: UUID, chain: Chain, asset: Asset, account: DerivedAccount, destination: String, tag: String?,
        amount: BigUInt, sendAll: Bool, feeLevel: FeeLevel, utxoUsage: UTXOUsage?, knownAddresses: [String] = [],
        nonceQueue: PendingNonceQueue? = nil
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
        self.nonceQueue = nonceQueue
    }
}

/// A fila local de transacoes EVM de uma conta: o que este aparelho transmitiu e a rede
/// ainda nao confirmou (auditoria 2, M1).
///
/// O app guarda, por carteira, rede e endereco, cada transacao transmitida (nonce e id)
/// ate o `status` dela dizer confirmada ou falhou, e o proximo nonce depois da ultima. O
/// motor le a rede em duas fontes e so aceita a diferenca entre elas que estas
/// transacoes explicam; sem a fila, as fontes tem de concordar exatamente.
public struct PendingNonceQueue: Sendable, Equatable {
    /// O nonce seguinte ao da ultima transacao transmitida desta conta.
    public let nextNonce: UInt64
    /// Os ids (hash) das transacoes transmitidas e ainda nao confirmadas, em ordem de
    /// nonce. Os nonces delas sao `nextNonce - pendingHashes.count` ate `nextNonce - 1`.
    public let pendingHashes: [String]

    public init(nextNonce: UInt64, pendingHashes: [String]) {
        self.nextNonce = nextNonce
        self.pendingHashes = pendingHashes
    }
}

extension PendingNonceQueue {
    /// A fila a partir das transacoes que o app anotou: so a sequencia consecutiva que
    /// termina no maior nonce, porque o contrato le os nonces como `nextNonce - count`
    /// ate `nextNonce - 1`. Um buraco quer dizer que algo antes dele ja saiu da conta de
    /// quem esta em transito. Sem entradas, nil.
    public static func trailingRun(_ entries: [(nonce: UInt64, hash: String)]) -> PendingNonceQueue? {
        let sorted = entries.sorted { $0.nonce < $1.nonce }
        guard let last = sorted.last else { return nil }
        var run = [last]
        for entry in sorted.dropLast().reversed() {
            guard entry.nonce + 1 == run[0].nonce else { break }
            run.insert(entry, at: 0)
        }
        return PendingNonceQueue(nextNonce: last.nonce + 1, pendingHashes: run.map(\.hash))
    }
}

extension EVMNetworkState {
    /// O estado lido da rede com a fila local do app e, numa troca em varias pernas, as
    /// transacoes das pernas anteriores deste mesmo plano (`plannedAhead`, que ainda nem
    /// foram transmitidas e que `plannedNext` segue).
    func applying(_ queue: PendingNonceQueue?, plannedNext: UInt64? = nil, plannedAhead: UInt64 = 0) -> EVMNetworkState {
        let next = plannedNext ?? queue?.nextNonce
        let pending = UInt64(queue?.pendingHashes.count ?? 0) + plannedAhead
        return withLocalQueue(nextNonce: next, pendingCount: pending)
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
    /// O recurso nao existe nesta versao para esta rede (sem indexador publico, sem
    /// protocolo avaliado). Tentar de novo nao muda nada: a tela diz o motivo e nao
    /// oferece "tentar de novo".
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let chain): return "Enviar pela rede \(chain.name) chega numa atualização em breve. Receber já funciona."
        case .message(let text), .unavailable(let text): return text
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

/// Os motores disponiveis nesta versao. Cada familia registra os seus no proprio
/// arquivo (Families/), para os motores de redes diferentes nunca disputarem linha.
public enum SendEngines {
    public static func engine(for chain: Chain) -> (any SendEngine)? {
        switch chain.family {
        case .utxo: return EngineRegistry.utxoSend(chain)
        case .evm: return EngineRegistry.evmSend(chain)
        case .solana: return EngineRegistry.solanaSend(chain)
        case .xrpl: return EngineRegistry.xrplSend(chain)
        case .stellar: return EngineRegistry.stellarSend(chain)
        case .tron: return EngineRegistry.tronSend(chain)
        case .ton: return EngineRegistry.tonSend(chain)
        case .sui: return EngineRegistry.suiSend(chain)
        case .cardano: return EngineRegistry.cardanoSend(chain)
        }
    }
}

extension SendEngine {
    /// Depois de um envio, o novo uso de enderecos UTXO (indice de troco que
    /// avancou). Nil quando a rede nao tem isso ou nada mudou.
    public func usage(after plan: SigningPlan, current: UTXOUsage?) -> UTXOUsage? { nil }
}
