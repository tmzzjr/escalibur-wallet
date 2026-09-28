import EscaliburChains

// Cardano: envio de ADA e historico (Cardano/). Tokens nativos, stake e troca ficam de fora
// na v1: nenhum agregador sem chave, com a transacao conferivel, foi avaliado para a Cardano.
extension EngineRegistry {
    static func cardanoSend(_ chain: Chain) -> (any SendEngine)? { chain.id == Chain.cardano.id ? CardanoSendEngine() : nil }
    static func cardanoActivity(_ chain: Chain) -> (any ActivitySource)? { chain.id == Chain.cardano.id ? CardanoActivitySource() : nil }
    static func cardanoTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
