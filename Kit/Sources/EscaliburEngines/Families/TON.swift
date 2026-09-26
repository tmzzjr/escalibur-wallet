import EscaliburChains

extension EngineRegistry {
    static func tonSend(_ chain: Chain) -> (any SendEngine)? { nil }
    static func tonActivity(_ chain: Chain) -> (any ActivitySource)? { nil }
    static func tonTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
