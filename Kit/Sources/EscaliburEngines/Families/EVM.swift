import EscaliburChains

// Os motores da familia EVM: Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain e
// Avalanche. O codigo fica em EVM/.
//
// - Envio: nas sete.
// - Historico: nas sete. A BNB Chain nao tem indexador publico sem chave, e o historico
//   dela diz isso em vez de mostrar uma lista vazia.
// - Troca: onde ha duas fontes de `eth_simulateV1` (a simulacao e obrigatoria); fica de
//   fora a Avalanche. Ordem limite pela CoW, que nao atende a Optimism.
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
