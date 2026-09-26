import EscaliburChains

extension EngineRegistry {
    static func xrplSend(_ chain: Chain) -> (any SendEngine)? { chain == .xrpl ? XRPLSendEngine() : nil }
    static func xrplActivity(_ chain: Chain) -> (any ActivitySource)? { chain == .xrpl ? XRPLActivitySource() : nil }
    /// So existe com pelo menos um token do XRP Ledger na lista curada: sem ele nao ha
    /// par, e a aba Trocar diz que a rede chega em breve.
    static func xrplTrade(_ chain: Chain) -> (any TradeEngine)? { chain == .xrpl ? XRPLTradeEngine() : nil }
}
