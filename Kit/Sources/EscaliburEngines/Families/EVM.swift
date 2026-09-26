import EscaliburChains

extension EngineRegistry {
    static func evmSend(_ chain: Chain) -> (any SendEngine)? { nil }
    static func evmActivity(_ chain: Chain) -> (any ActivitySource)? { nil }
    static func evmTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
