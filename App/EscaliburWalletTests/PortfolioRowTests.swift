import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburWallet

/// A linha da carteira soma o mesmo ativo em redes com casas diferentes: o USDT tem 6
/// casas na Ethereum e 18 na BNB (revisao de seguranca de 15/10/2026, A1).
struct PortfolioRowTests {
    @Test func totalAcrossDifferentDecimals() throws {
        let usdt = TokenRegistry.tokens.filter { $0.symbol == "USDT" }
        let ethereum = try #require(usdt.first { $0.chainID == "ethereum" })
        let bnb = try #require(usdt.first { $0.chainID == "bnb" })
        let row = PortfolioRow(
            id: "tether", symbol: "USDT", name: "Tether", coingeckoID: "tether", isStablecoin: true,
            positions: [Holding(asset: ethereum, amount: BigUInt(1_000_000)), Holding(asset: bnb, amount: BigUInt.power(of: 10, 18))],
            price: 1, change24h: nil
        )
        #expect(row.decimals == 18)
        #expect(row.totalAmount == BigUInt(2) * BigUInt.power(of: 10, 18))
        #expect(row.fiatValue == 2)
    }

    /// Os tokens da Binance tem id de preco proprio: nunca entram na linha da moeda nativa.
    @Test func peggedTokensHaveTheirOwnPriceID() {
        let natives = Set(Chain.all.compactMap(\.coingeckoID))
        for token in TokenRegistry.tokens where token.name.hasSuffix("(Binance-Peg)") {
            #expect(!natives.contains(token.coingeckoID ?? ""), "\(token.symbol) na BNB com o id de uma moeda nativa")
        }
    }
}
