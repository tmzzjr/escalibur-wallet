import EscaliburChains

extension EngineRegistry {
    static func utxoSend(_ chain: Chain) -> (any SendEngine)? { UTXOSendEngine(chain: chain) }
    static func utxoActivity(_ chain: Chain) -> (any ActivitySource)? { UTXOActivitySource(chain: chain) }
    /// Troca nas redes UTXO depende de ponte entre redes (docs/blockchain.md §3.6), fora
    /// desta versao.
    static func utxoTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
