import EscaliburChains
import EscaliburCore
import Foundation

/// Um item da Atividade, igual para todas as redes. Cada leitor de historico
/// converte o formato da propria rede para este.
public struct ActivityEntry: Identifiable, Hashable, Sendable {
    public enum Direction: String, Sendable { case sent, received, swap, approval, order, other }
    public enum Status: Hashable, Sendable { case pending(String?), confirmed, failed(String?) }

    public let id: String
    public let chainID: String
    public let direction: Direction
    public let asset: Asset?
    public let amount: BigUInt
    public let counterparty: String?
    public let date: Date
    public let status: Status
    public let fee: BigUInt?
    public let hash: String
    /// Valor zero ou poeira vinda de desconhecido, de endereco parecido com um
    /// nosso, ou token fora da lista: escondido por padrao (envenenamento).
    public let suspicious: Bool
    /// Na troca, o que entrou (`asset` e `amount` sao o que saiu). Nil fora de troca, ou
    /// quando a rede so diz um lado.
    public let receivedAsset: Asset?
    public let receivedAmount: BigUInt?

    public init(
        id: String, chainID: String, direction: Direction, asset: Asset?, amount: BigUInt, counterparty: String?,
        date: Date, status: Status, fee: BigUInt?, hash: String, suspicious: Bool,
        receivedAsset: Asset? = nil, receivedAmount: BigUInt? = nil
    ) {
        self.id = id
        self.chainID = chainID
        self.direction = direction
        self.asset = asset
        self.amount = amount
        self.counterparty = counterparty
        self.date = date
        self.status = status
        self.fee = fee
        self.hash = hash
        self.suspicious = suspicious
        self.receivedAsset = receivedAsset
        self.receivedAmount = receivedAmount
    }

    public var chain: Chain? { Chain.find(chainID) }
}

/// Quem sabe ler o historico de uma rede. Registrado por rede quando o leitor existe.
public protocol ActivitySource: Sendable {
    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry]
}

public enum ActivitySources {
    public static func source(for chain: Chain) -> (any ActivitySource)? {
        switch chain.family {
        case .utxo: return EngineRegistry.utxoActivity(chain)
        case .evm: return EngineRegistry.evmActivity(chain)
        case .solana: return EngineRegistry.solanaActivity(chain)
        case .xrpl: return EngineRegistry.xrplActivity(chain)
        case .stellar: return EngineRegistry.stellarActivity(chain)
        case .tron: return EngineRegistry.tronActivity(chain)
        case .ton: return EngineRegistry.tonActivity(chain)
        case .sui: return EngineRegistry.suiActivity(chain)
        case .cardano: return EngineRegistry.cardanoActivity(chain)
        case .polkadot: return EngineRegistry.polkadotActivity(chain)
        case .near: return EngineRegistry.nearActivity(chain)
        case .aptos: return EngineRegistry.aptosActivity(chain)
        }
    }
}
