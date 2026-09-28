import EscaliburChains

// Sui: envio de SUI e historico (Sui/). Troca fica de fora na v1: nenhum agregador sem
// chave, com a transacao conferivel na cadeia, foi avaliado para a Sui ainda.
extension EngineRegistry {
    static func suiSend(_ chain: Chain) -> (any SendEngine)? { chain.id == Chain.sui.id ? SuiSendEngine() : nil }
    static func suiActivity(_ chain: Chain) -> (any ActivitySource)? { chain.id == Chain.sui.id ? SuiActivitySource() : nil }
    static func suiTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
