import EscaliburChains

// NEAR: envio de NEAR da conta implicita e historico (NEAR/). Troca fica de fora na v1:
// nenhum agregador sem chave, com a transacao conferivel na cadeia, foi avaliado para a
// NEAR ainda. Tokens NEP-141, stake e contas com nome do proprio dono tambem.
extension EngineRegistry {
    static func nearSend(_ chain: Chain) -> (any SendEngine)? { chain.id == Chain.near.id ? NEARSendEngine() : nil }
    static func nearActivity(_ chain: Chain) -> (any ActivitySource)? { chain.id == Chain.near.id ? NEARActivitySource() : nil }
    static func nearTrade(_ chain: Chain) -> (any TradeEngine)? { nil }
}
