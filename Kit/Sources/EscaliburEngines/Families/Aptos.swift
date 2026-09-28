import EscaliburChains

// Aptos: envio de APT e historico (Aptos/). Troca fica de fora na v1: nenhum agregador sem
// chave, com a transacao conferivel na cadeia, foi avaliado para a Aptos ainda.
extension EngineRegistry {
    static func aptosSend(_ chain: Chain) -> (any SendEngine)? { chain.id == Chain.aptos.id ? AptosSendEngine() : nil }
    static func aptosActivity(_ chain: Chain) -> (any ActivitySource)? { chain.id == Chain.aptos.id ? AptosActivitySource() : nil }
    static func aptosTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
