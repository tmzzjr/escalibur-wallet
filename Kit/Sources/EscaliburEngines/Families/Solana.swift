import EscaliburChains

extension EngineRegistry {
    static func solanaSend(_ chain: Chain) -> (any SendEngine)? { nil }
    static func solanaActivity(_ chain: Chain) -> (any ActivitySource)? { nil }
    static func solanaTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
