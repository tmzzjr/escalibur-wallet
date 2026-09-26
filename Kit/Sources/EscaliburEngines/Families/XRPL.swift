import EscaliburChains

extension EngineRegistry {
    static func xrplSend(_ chain: Chain) -> (any SendEngine)? { nil }
    static func xrplActivity(_ chain: Chain) -> (any ActivitySource)? { nil }
    static func xrplTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
