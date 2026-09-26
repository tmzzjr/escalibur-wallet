import EscaliburChains

extension EngineRegistry {
    static func stellarSend(_ chain: Chain) -> (any SendEngine)? { nil }
    static func stellarActivity(_ chain: Chain) -> (any ActivitySource)? { nil }
    static func stellarTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
