import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

// O preco de referencia das trocas, independente de quem cota.
//
// A cotacao vem do provedor da rota (Horizon, Jupiter, agregadores EVM); a referencia vem
// do `MarketService` (CoinGecko), outro caminho. Com ela, a cotacao mais de 5% pior que o
// mercado recusa e acima de 2% a tela avisa (docs/seguranca.md 4.3 item 7). E sanidade,
// nao garantia: a garantia continua sendo o minimo gravado na transacao.

/// Precos em dolar, como texto decimal, por id do CoinGecko.
protocol TradePriceOracle: Sendable {
    func usdPrices(_ ids: [String]) async throws -> [String: String]
}

/// O `MarketService` do app. O preco chega como `Double` (so exibicao); vira texto
/// decimal aqui, e daqui em diante as contas sao inteiras.
struct MarketPriceOracle: TradePriceOracle {
    let service: MarketService

    static let shared = MarketPriceOracle(service: .shared)

    func usdPrices(_ ids: [String]) async throws -> [String: String] {
        let quotes = try await service.quotes(ids: ids, currency: "usd")
        return quotes.compactMapValues { Self.decimalText($0.price) }
    }

    /// Texto decimal sem expoente, ou `nil` para preco nao positivo ou nao finito.
    static func decimalText(_ price: Double) -> String? {
        guard price.isFinite, price > 0 else { return nil }
        let text = Decimal(price).description
        return TradeDecimal(text) == nil ? nil : text
    }
}

enum MarketReference {
    /// Quanto `amountIn` de `sell` vale em `buy`, pelo mercado.
    ///
    /// Dois stablecoins da lista valem um dolar cada: a referencia e a paridade, sem
    /// perguntar a ninguem. Nos outros pares, o preco dos dois lados no oraculo; sem ele
    /// (oraculo fora, ativo sem id), `.none`, e quem chama decide se a troca pode seguir
    /// sem referencia.
    static func reference(amountIn: BigUInt, sell: Asset, buy: Asset, oracle: any TradePriceOracle) async -> TradeMarketReference {
        if sell.isStablecoin, buy.isStablecoin {
            return TradeMarketReference(amountIn: amountIn, sellDecimals: sell.decimals, buyDecimals: buy.decimals, sellPriceUSD: "1", buyPriceUSD: "1")
        }
        guard let sellID = sell.coingeckoID, let buyID = buy.coingeckoID,
              let prices = try? await oracle.usdPrices(Array(Set([sellID, buyID]))),
              let sellPrice = prices[sellID], let buyPrice = prices[buyID]
        else { return .none }
        return TradeMarketReference(amountIn: amountIn, sellDecimals: sell.decimals, buyDecimals: buy.decimals, sellPriceUSD: sellPrice, buyPriceUSD: buyPrice)
    }

    /// A frase da recusa por preco longe da referencia.
    static func farText(deviationBps: Int) -> String {
        let percent = EngineFormat.decimal(BigUInt(UInt64(max(0, deviationBps))), decimals: 2)
        return "A cotação está \(percent)% pior que o preço de referência do mercado. Troca bloqueada."
    }
}
