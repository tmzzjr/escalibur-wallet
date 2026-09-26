import EscaliburChains
import EscaliburEngines
import Testing

/// A revisao que cada planejador monta passa na conferencia que o app faz antes de
/// revisar e de assinar (auditoria 2, M1): uma troca legitima nunca e recusada por
/// movimento mal preenchido.
func expectIntent(_ plan: SigningPlan, _ request: TradeRequest, _ quote: TradeQuote, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(throws: Never.self, sourceLocation: sourceLocation) {
        try PlanIntentCheck.trade(plan.review, sell: request.sell, amountIn: request.amountIn, buy: request.buy,
                                  minimumOut: quote.minimumOut, owner: request.account.address, chain: request.chain)
    }
}

func expectIntent(_ plan: SigningPlan, _ request: LimitOrderRequest, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(throws: Never.self, sourceLocation: sourceLocation) {
        try PlanIntentCheck.trade(plan.review, sell: request.sell, amountIn: request.amountIn, buy: request.buy,
                                  minimumOut: request.minimumOut, owner: request.account.address, chain: request.chain)
    }
}
