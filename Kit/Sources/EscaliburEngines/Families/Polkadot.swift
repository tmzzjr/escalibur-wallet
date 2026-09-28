import EscaliburChains

// Polkadot: envio de DOT e historico na Polkadot Asset Hub (Polkadot/). Troca fica de
// fora na v1: nenhum agregador sem chave, com a transacao conferivel na cadeia, foi
// avaliado para a Polkadot ainda. Staking, tokens da Asset Hub e parachains tambem.
extension EngineRegistry {
    static func polkadotSend(_ chain: Chain) -> (any SendEngine)? { chain.id == Chain.polkadot.id ? PolkadotSendEngine() : nil }
    static func polkadotActivity(_ chain: Chain) -> (any ActivitySource)? { chain.id == Chain.polkadot.id ? PolkadotActivitySource() : nil }
    static func polkadotTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
