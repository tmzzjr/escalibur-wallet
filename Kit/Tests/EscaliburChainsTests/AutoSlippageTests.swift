import Foundation
import Testing
@testable import EscaliburChains

@Suite("Tolerancia automatica")
struct AutoSlippageTests {
    static let usdc = TokenRegistry.tokens.first { $0.chainID == "base" && $0.symbol == "USDC" }!
    static let usdt = TokenRegistry.tokens.first { $0.chainID == "arbitrum" && $0.symbol == "USDT" }!
    static let link = TokenRegistry.tokens.first { $0.chainID == "base" && $0.symbol == "LINK" }!
    static let longTail = Asset(chainID: "base", kind: .token(contract: "0x0000206329b97db379d5e1bf586bbdb969c63274"), symbol: "X",
                                name: "X", decimals: 18, coingeckoID: nil, isStablecoin: false)

    @Test("Stablecoin com stablecoin fica no piso; grande com stablecoin, 0,3%; o resto, 1%")
    func tiers() {
        #expect(AutoSlippage.basisPoints(sell: Self.usdc, buy: Self.usdt, chainID: "base") == 10)
        #expect(AutoSlippage.basisPoints(sell: .native(.base), buy: Self.usdc, chainID: "base") == 30)
        #expect(AutoSlippage.basisPoints(sell: Self.link, buy: .native(.base), chainID: "base") == 30)
        #expect(AutoSlippage.basisPoints(sell: Self.longTail, buy: Self.usdc, chainID: "base") == 100)
    }

    @Test("Dia agitado, pool raso e Ethereum somam folga, dentro de 0,1% a 3%")
    func buffers() {
        #expect(AutoSlippage.basisPoints(sell: .native(.base), buy: Self.usdc, chainID: "base", volatilityPercent: 10) == 50)
        #expect(AutoSlippage.basisPoints(sell: .native(.base), buy: Self.usdc, chainID: "base", volatilityPercent: -60) == 80)
        #expect(AutoSlippage.basisPoints(sell: .native(.base), buy: Self.usdc, chainID: "base", priceImpactBps: 80) == 30)
        #expect(AutoSlippage.basisPoints(sell: .native(.base), buy: Self.usdc, chainID: "base", priceImpactBps: 300) == 105)
        #expect(AutoSlippage.basisPoints(sell: .native(.ethereum), buy: Self.usdc, chainID: "ethereum") == 40)
        let worst = AutoSlippage.basisPoints(sell: Self.longTail, buy: Self.longTail, chainID: "ethereum", volatilityPercent: 90, priceImpactBps: 2_000)
        #expect(worst == 260)
        #expect(AutoSlippage.basisPoints(sell: Self.usdc, buy: Self.usdt, chainID: "base", volatilityPercent: .nan) == 10)
    }
}
