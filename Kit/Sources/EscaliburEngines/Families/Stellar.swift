import EscaliburChains

extension EngineRegistry {
    static func stellarSend(_ chain: Chain) -> (any SendEngine)? { chain == .stellar ? StellarSendEngine() : nil }
    static func stellarActivity(_ chain: Chain) -> (any ActivitySource)? { chain == .stellar ? StellarActivitySource() : nil }
    static func stellarTrade(_ chain: Chain) -> (any TradeEngine)? { chain == .stellar ? StellarTradeEngine() : nil }
}
