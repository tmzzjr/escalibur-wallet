import EscaliburChains

// Solana: envio de SOL e dos tokens da lista, historico e troca pela Jupiter
// (Solana/). Ordem limite fica de fora na v1 (`SolanaTradeEngine`).
extension EngineRegistry {
    static func solanaSend(_ chain: Chain) -> (any SendEngine)? { chain == .solana ? SolanaSendEngine.shared : nil }
    static func solanaActivity(_ chain: Chain) -> (any ActivitySource)? { chain == .solana ? SolanaActivitySource.shared : nil }
    static func solanaTrade(_ chain: Chain) -> (any TradeEngine)? { chain == .solana ? SolanaTradeEngine.shared : nil }
}
