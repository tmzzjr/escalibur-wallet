import EscaliburChains

extension EngineRegistry {
    static func tonSend(_ chain: Chain) -> (any SendEngine)? {
        chain.id == Chain.ton.id ? TONSendEngine() : nil
    }

    static func tonActivity(_ chain: Chain) -> (any ActivitySource)? {
        chain.id == Chain.ton.id ? TONActivitySource() : nil
    }

    /// Fora da v1: nenhum agregador de troca sem chave, com a mensagem conferivel na
    /// cadeia, foi avaliado para a TON ainda.
    static func tonTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
