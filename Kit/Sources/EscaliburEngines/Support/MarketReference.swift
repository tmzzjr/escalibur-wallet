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
///
/// So preco de agora. Com as fontes fora, o `MarketService` devolve o ultimo preco bom,
/// que pode ser de horas atras; como referencia, ele deixaria passar com uma cotacao so
/// a troca que o mercado de agora ja nao sustenta (auditoria de 16/10/2026, R7-B2).
/// Mais velho que `maxAge`, o preco nao vem, e a troca segue como sem referencia: duas
/// cotacoes e a maior estimativa como ancora (`TradeValidator.anchored`), ou recusa na
/// Solana.
struct MarketPriceOracle: TradePriceOracle {
    let service: MarketService
    /// `nil`: qualquer idade. So o aviso de taxa alta do envio usa assim: ele compara a
    /// taxa com o valor em ordem de grandeza e nao decide minimo nenhum.
    var maxAge: TimeInterval? = MarketPriceOracle.referenceMaxAge

    /// Dois minutos: quatro vezes a validade do cache de cotacao (30 s), folga para uma
    /// consulta que falhou, e curto para o preco andar pouco nesse tempo.
    static let referenceMaxAge: TimeInterval = 120

    static let shared = MarketPriceOracle(service: .shared)
    /// O do aviso de taxa alta do envio EVM, que aceita o ultimo preco bom de qualquer idade.
    static let anyAge = MarketPriceOracle(service: .shared, maxAge: nil)

    func usdPrices(_ ids: [String]) async throws -> [String: String] {
        let quotes = try await service.datedQuotes(ids: ids, currency: "usd", maxAge: maxAge)
        return quotes.compactMapValues { Self.decimalText($0.quote.price) }
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

    /// Mais de 5% pior que o mercado: recusa, com a frase da tela. Sem referencia, segue;
    /// a garantia continua sendo o minimo gravado na transacao.
    static func requireSane(_ reference: TradeMarketReference, expected: BigUInt) throws {
        do {
            try reference.check(expected: expected)
        } catch TradeRefusal.priceFarFromOracle(let deviation) {
            throw SendEngineError.message(farText(deviationBps: deviation))
        }
    }

    /// A frase da recusa por preco longe da referencia.
    static func farText(deviationBps: Int) -> String {
        let percent = EngineFormat.decimal(BigUInt(UInt64(max(0, deviationBps))), decimals: 2)
        return kitText("A cotação está \(percent)% pior que o preço de referência do mercado. Troca bloqueada.")
    }
}
