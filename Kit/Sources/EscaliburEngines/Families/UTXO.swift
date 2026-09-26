import EscaliburChains

extension EngineRegistry {
    static func utxoSend(_ chain: Chain) -> (any SendEngine)? { nil }
    static func utxoActivity(_ chain: Chain) -> (any ActivitySource)? { nil }
    static func utxoTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
