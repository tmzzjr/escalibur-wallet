import Foundation

/// A tolerancia automatica de uma troca: a menor que costuma passar para aquele par,
/// recalculada a cada cotacao.
///
/// Tolerancia alta demais deixa espaco para robo de sanduiche e aceita receber menos;
/// baixa demais faz a troca falhar, e na EVM a taxa da rede e cobrada mesmo assim. O
/// ponto certo depende do par:
///   - duas stablecoins: o preco quase nao anda entre a cotacao e o bloco (0,1%);
///   - moeda grande (nativa, embrulhada, as de maior liquidez) contra stablecoin ou
///     contra outra grande: 0,3%;
///   - o resto, liquidez rasa: 1%.
/// Em cima disso, folga pelo dia agitado (a maior variacao de 24 h das duas pontas, 2
/// pontos-base por ponto percentual, ate 0,5%), pelo pool raso (impacto acima de 1%
/// soma um quarto do impacto, ate 1%) e pela Ethereum, que leva mais tempo ate o bloco
/// (0,1%). O resultado fica entre 0,1% e 3%, a mesma faixa do controle manual.
///
/// A conferencia que importa nao muda: o minimo garantido sai da cotacao e da tolerancia
/// e e conferido na transacao antes de assinar (docs/seguranca.md §5.4).
public enum AutoSlippage {
    public static let floor = 10
    public static let ceiling = 300

    /// Moedas de liquidez profunda em qualquer rede: as nativas e as embrulhadas delas,
    /// e as maiores por volume.
    static let majors: Set<String> = [
        "ethereum", "weth", "bitcoin", "wrapped-bitcoin", "coinbase-wrapped-btc", "binance-bitcoin", "binancecoin",
        "solana", "wrapped-solana", "avalanche-2", "polygon-ecosystem-token", "tron", "the-open-network", "ripple",
        "stellar", "sui", "aptos", "near", "cardano", "polkadot", "chainlink", "wrapped-steth", "wrapped-eeth", "okb",
        "sonic-3", "celo", "arbitrum", "optimism", "uniswap",
    ]

    public enum Tier: Int, Sendable { case stable, major, longTail }

    public static func tier(_ asset: Asset) -> Tier {
        if asset.isStablecoin { return .stable }
        if asset.kind == .native { return .major }
        if let id = asset.coingeckoID, majors.contains(id) { return .major }
        return .longTail
    }

    /// Pontos-base. `volatilityPercent`: a maior variacao de 24 h das duas pontas, em %
    /// (sem sinal). `priceImpactBps`: o impacto da cotacao, quando ja existe.
    public static func basisPoints(
        sell: Asset, buy: Asset, chainID: String, volatilityPercent: Double? = nil, priceImpactBps: Int? = nil
    ) -> Int {
        let pair = [tier(sell), tier(buy)]
        var bps: Double
        if pair.allSatisfy({ $0 == .stable }) {
            bps = 10
        } else if !pair.contains(.longTail) {
            bps = 30
        } else {
            bps = 100
        }
        if let volatility = volatilityPercent, volatility.isFinite {
            bps += min(abs(volatility) * 2, 50)
        }
        if let impact = priceImpactBps, impact > 100 {
            bps += min(Double(impact) / 4, 100)
        }
        if chainID == "ethereum" { bps += 10 }
        let rounded = Int((bps / 5).rounded(.up)) * 5
        return min(max(rounded, floor), ceiling)
    }
}
