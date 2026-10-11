import Foundation
import Testing
@testable import EscaliburWallet

/// O preco-alvo da ordem limite: preenchido com seis algarismos que contam, e os zeros
/// resumidos quando sao muitos.
struct LimitPriceTextTests {
    @Test func priceKeepsSignificantDigits() {
        #expect(TradeView.priceText(2535.0512) == "2535,05")
        #expect(TradeView.priceText(0.000000000123456789) == "0,000000000123457")
        #expect(TradeView.priceText(0) == "")
    }

    @Test func manyZerosAreCompacted() {
        #expect(Fmt.compactZeros("0,00000000001234") == "0,0₁₀1234")
        #expect(Fmt.compactZeros("0.0000123") == "0,0₄123")
        #expect(Fmt.compactZeros("0,001") == nil)
        #expect(Fmt.compactZeros("12,5") == nil)
        #expect(Fmt.compactZeros("0,0000") == nil)
    }
}
