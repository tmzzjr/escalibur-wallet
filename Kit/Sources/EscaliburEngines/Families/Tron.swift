import EscaliburChains

extension EngineRegistry {
    static func tronSend(_ chain: Chain) -> (any SendEngine)? { nil }
    static func tronActivity(_ chain: Chain) -> (any ActivitySource)? { nil }
    static func tronTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
