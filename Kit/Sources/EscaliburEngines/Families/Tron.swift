import EscaliburChains

extension EngineRegistry {
    static func tronSend(_ chain: Chain) -> (any SendEngine)? {
        chain.id == Chain.tron.id ? TronSendEngine() : nil
    }

    static func tronActivity(_ chain: Chain) -> (any ActivitySource)? {
        chain.id == Chain.tron.id ? TronActivitySource() : nil
    }

    /// Fora da v1: nenhum agregador de troca sem chave, com a transacao conferivel na
    /// cadeia, foi avaliado para a Tron ainda.
    static func tronTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
