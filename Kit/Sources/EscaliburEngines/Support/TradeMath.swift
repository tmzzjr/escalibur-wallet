import EscaliburChains
import EscaliburCore
import Foundation

/// As contas da cotacao que as DEXs nativas (Stellar e XRP Ledger) fazem igual.
enum TradeMath {
    /// Tolerancia maxima de troca nas DEXs nativas: 5%, o teto do `StellarPlanner`.
    static let maxSlippageBasisPoints = 500

    /// Por quanto tempo a cotacao vale na tela antes de ser refeita.
    static let quoteLifetime: TimeInterval = 30

    /// O minimo que a transacao garante: a cotacao menos a tolerancia, para baixo. A
    /// mesma conta do `StellarPlanner.planSwap`.
    static func minimumOut(_ expected: BigUInt, slippageBasisPoints: Int) -> BigUInt {
        let bps = BigUInt(UInt64(max(0, min(10_000, slippageBasisPoints))))
        return expected * (BigUInt(10_000) - bps) / BigUInt(10_000)
    }

    /// Quanto o preco medio desta troca fica abaixo do preco de uma troca pequena do
    /// mesmo par, em porcentagem. So para a tela avisar e, acima do teto, bloquear; o
    /// que o dono recebe e garantido pelo minimo da transacao, nao por este numero.
    static func impactPercent(amountIn: BigUInt, out: BigUInt, referenceIn: BigUInt, referenceOut: BigUInt) -> Double? {
        guard let a = double(amountIn), let o = double(out), let ra = double(referenceIn), let ro = double(referenceOut),
              a > 0, ra > 0, ro > 0
        else { return nil }
        let impact = (1 - (o / a) / (ro / ra)) * 100
        return max(0, impact)
    }

    static func requireSlippage(_ basisPoints: Int) throws {
        guard (0...maxSlippageBasisPoints).contains(basisPoints) else {
            throw SendEngineError.message("A tolerância de preço vai de 0% a 5% nesta rede.")
        }
    }

    /// A cotacao e deste pedido, com a mesma tolerancia, e ainda vale.
    static func requireCurrent(_ quote: TradeQuote, for request: TradeRequest, now: Date = Date()) throws {
        guard quote.sell == request.sell, quote.buy == request.buy, quote.amountIn == request.amountIn,
              minimumOut(quote.expectedOut, slippageBasisPoints: request.slippageBasisPoints) == quote.minimumOut
        else { throw SendEngineError.message(priceMoved) }
        guard quote.expiresAt > now else { throw SendEngineError.message("A cotação venceu. Atualize para ver o preço de agora.") }
    }

    static let priceMoved = "O preço mudou desde a cotação. Atualize para ver o preço de agora."

    private static func double(_ value: BigUInt) -> Double? {
        Double(value.decimalString)
    }
}
