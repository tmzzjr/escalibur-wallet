import Foundation
import Testing
@testable import EscaliburWallet

/// O preco unitario miudo: os zeros depois da virgula viram um subscrito, e os
/// algarismos que contam aparecem em qualquer tamanho.
struct PriceFormatTests {
    @Test func subscriptKeepsTheDigits() {
        // O que ja saia certo continua igual.
        #expect(Fmt.subscriptZeros(0.00005234) == "0,0₄5234")
        #expect(Fmt.subscriptZeros(0.0000309) == "0,0₄3090")
        // Abaixo de 10^-18 o preco sumia: "0,0₁₈" sem algarismo nenhum.
        #expect(Fmt.subscriptZeros(4.831481811110613e-19) == "0,0₁₈4831")
        #expect(Fmt.subscriptZeros(2.5e-24) == "0,0₂₃2500")
    }

    @Test func tinyPriceHasDigits() {
        #expect(Fmt.price(4.83e-19, .brl) == "R$\u{00A0}0,0₁₈4830")
        #expect(Fmt.price(0.5, .brl) == "R$\u{00A0}0,5000")
    }
}
