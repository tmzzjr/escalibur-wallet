import EscaliburChains

// Os motores da familia EVM: Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain,
// Avalanche, Plasma, X Layer, Linea, Unichain, Sonic e Celo. O codigo fica em EVM/.
//
// - Envio: nas treze.
// - Historico: nas treze. BNB Chain, X Layer e Sonic nao tem indexador publico sem
//   chave, e o historico delas diz isso em vez de mostrar uma lista vazia.
// - Troca: onde ha duas fontes de `eth_simulateV1` (a simulacao e obrigatoria) e algum
//   agregador da allowlist; ficam de fora Avalanche, X Layer e Celo. Ordem limite pela
//   CoW onde ha troca e a CoW atende: Ethereum, Arbitrum, Base, Polygon, BNB Chain,
//   Plasma e Linea.
extension EngineRegistry {
    static func evmSend(_ chain: Chain) -> (any SendEngine)? {
        EVMSendEngine(chain: chain)
    }

    static func evmActivity(_ chain: Chain) -> (any ActivitySource)? {
        guard EVMEngineSupport.isSupported(chain) else { return nil }
        return EVMActivitySource(chain: chain) ?? EVMUnavailableActivitySource(chain: chain)
    }

    static func evmTrade(_ chain: Chain) -> (any TradeEngine)? {
        EVMTradeEngine(chain: chain)
    }
}
