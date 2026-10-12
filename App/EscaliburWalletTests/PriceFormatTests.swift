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

/// A moeda do app e uma escolha so, a de Ativos: ela decide em que moeda os precos sao
/// buscados e mostrados. Com o bitcoin, os precos vem em dolar.
struct CurrencyChoiceTests {
    @Test func walletUnitDrivesPrices() {
        var settings = Settings()
        #expect(settings.displayUnit == .brl)
        let toDollar = settings.choose(.usd)
        #expect(toDollar)
        #expect(settings.currency == "usd" && settings.totalUnit == "usd")
        let toEuro = settings.choose(.eur)
        #expect(toEuro)
        #expect(settings.currency == "eur")
        let toBitcoin = settings.choose(.btc)
        #expect(toBitcoin)
        #expect(settings.currency == "usd" && settings.displayUnit == .btc)
        // Do bitcoin para o dolar a moeda dos precos nao muda: nada a recarregar.
        let backToDollar = settings.choose(.usd)
        #expect(!backToDollar)
    }

    @Test func oldMetadataBecomesCoherent() {
        // Antes de 12/10/2026: Ajustes em real e Ativos em dolar.
        var settings = Settings()
        settings.currency = "brl"
        settings.totalUnit = "usd"
        let fixed = settings.choose(settings.displayUnit)
        #expect(fixed)
        #expect(settings.currency == "usd")
        // Sem unidade escolhida, vale a moeda que estava em Ajustes.
        var legacy = Settings()
        legacy.currency = "usd"
        let changed = legacy.choose(legacy.displayUnit)
        #expect(!changed)
        #expect(legacy.displayUnit == .usd)
    }

    @Test func euroFormats() {
        #expect(Fmt.fiat(1234.5, .eur) == "€\u{00A0}1.234,50")
        #expect(Fmt.DisplayUnit(Fmt.Currency.eur) == .eur)
        #expect(Fmt.DisplayUnit.btc.fiat == .usd)
    }
}
