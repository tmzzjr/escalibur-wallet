import Foundation
import Testing
@testable import EscaliburNetwork

@Suite("Alertas de preco: regras")
struct PriceAlertRulesTests {
    let start = Date(timeIntervalSince1970: 1_791_133_200)

    func hours(_ value: Double) -> Date { start.addingTimeInterval(value * 3600) }

    @Test("Numero redondo tem dois algarismos significativos, em qualquer faixa")
    func levels() {
        #expect(PriceAlertRules.level(atOrBelow: 80_999) == 80_000)
        #expect(PriceAlertRules.level(above: 80_999) == 81_000)
        #expect(PriceAlertRules.level(atOrBelow: 81_000) == 81_000)
        #expect(PriceAlertRules.level(atOrBelow: 2_345) == 2_300)
        #expect(PriceAlertRules.level(atOrBelow: 1_000) == 1_000)
        #expect(PriceAlertRules.level(above: 99.5) == 100)
        #expect(PriceAlertRules.level(above: 9.95) == 10)
        #expect(PriceAlertRules.level(atOrBelow: 1) == 1)
        #expect(PriceAlertRules.level(atOrBelow: 0.001) == 0.001)
        #expect(PriceAlertRules.level(atOrBelow: 0.000012345) == 0.000012)
        #expect(PriceAlertRules.level(above: 0.000012345) == 0.000013)
        #expect(PriceAlertRules.level(atOrBelow: 612_480.55) == 610_000)
    }

    @Test("Cruzar para cima e para baixo avisa o nivel mais perto do preco novo")
    func crossings() {
        #expect(PriceAlertRules.crossing(from: 80_900, to: 81_050) == .crossedUp(level: 81_000))
        #expect(PriceAlertRules.crossing(from: 79_500, to: 85_200) == .crossedUp(level: 85_000))
        #expect(PriceAlertRules.crossing(from: 81_050, to: 80_900) == .crossedDown(level: 81_000))
        #expect(PriceAlertRules.crossing(from: 85_000, to: 79_500) == .crossedDown(level: 80_000))
        #expect(PriceAlertRules.crossing(from: 0.98, to: 1.01) == .crossedUp(level: 1))
        #expect(PriceAlertRules.crossing(from: 101, to: 99.4) == .crossedDown(level: 100))
        // Mexer dentro do mesmo degrau, ou sair de cima de um nivel, nao e cruzar.
        #expect(PriceAlertRules.crossing(from: 81_100, to: 81_900) == nil)
        #expect(PriceAlertRules.crossing(from: 81_000, to: 81_500) == nil)
        #expect(PriceAlertRules.crossing(from: 81_000, to: 81_000) == nil)
    }

    @Test("A primeira leitura so marca a base, mesmo num dia de alta forte")
    func firstReadingIsSilent() {
        var memory = PriceAlertMemory()
        let events = PriceAlertRules.evaluate(price: 81_000, change24h: 14, memory: &memory, roundNumbers: true, moveThreshold: 10, now: start)
        #expect(events.isEmpty)
        #expect(memory.lastPrice == 81_000)
        #expect(memory.moveBand == 1)
    }

    @Test("Um nivel avisado nao repete em 12 h, mesmo oscilando em cima dele")
    func levelQuiet() {
        var memory = PriceAlertMemory()
        _ = PriceAlertRules.evaluate(price: 80_900, change24h: 1, memory: &memory, roundNumbers: true, moveThreshold: 10, now: start)
        let up = PriceAlertRules.evaluate(price: 81_100, change24h: 1, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(1))
        #expect(up == [.crossedUp(level: 81_000)])
        let down = PriceAlertRules.evaluate(price: 80_900, change24h: 1, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(2))
        #expect(down.isEmpty)
        let again = PriceAlertRules.evaluate(price: 81_100, change24h: 1, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(3))
        #expect(again.isEmpty)
        // Outro nivel avisa na hora; o mesmo, so depois de 12 h.
        let next = PriceAlertRules.evaluate(price: 82_050, change24h: 2, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(4))
        #expect(next == [.crossedUp(level: 82_000)])
        _ = PriceAlertRules.evaluate(price: 81_900, change24h: 2, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(5))
        let later = PriceAlertRules.evaluate(price: 82_100, change24h: 2, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(18))
        #expect(later == [.crossedUp(level: 82_000)])
    }

    @Test("Variacao avisa quando a faixa cresce ou a direcao inverte, nao a cada leitura")
    func moves() {
        var memory = PriceAlertMemory()
        _ = PriceAlertRules.evaluate(price: 100.5, change24h: 2, memory: &memory, roundNumbers: false, moveThreshold: 10, now: start)
        #expect(PriceAlertRules.evaluate(price: 100.6, change24h: 11.2, memory: &memory, roundNumbers: false, moveThreshold: 10, now: hours(1)) == [.moved(change: 11.2)])
        #expect(PriceAlertRules.evaluate(price: 100.7, change24h: 13, memory: &memory, roundNumbers: false, moveThreshold: 10, now: hours(2)).isEmpty)
        #expect(PriceAlertRules.evaluate(price: 100.8, change24h: 21, memory: &memory, roundNumbers: false, moveThreshold: 10, now: hours(3)) == [.moved(change: 21)])
        #expect(PriceAlertRules.evaluate(price: 100.9, change24h: 4, memory: &memory, roundNumbers: false, moveThreshold: 10, now: hours(4)).isEmpty)
        #expect(PriceAlertRules.evaluate(price: 100.4, change24h: -10.5, memory: &memory, roundNumbers: false, moveThreshold: 10, now: hours(5)) == [.moved(change: -10.5)])
        #expect(PriceAlertRules.evaluate(price: 100.3, change24h: -12, memory: &memory, roundNumbers: false, moveThreshold: 10, now: hours(6)).isEmpty)
        // Passadas 20 h, a mesma faixa e outro dia: avisa de novo.
        #expect(PriceAlertRules.evaluate(price: 100.2, change24h: -12, memory: &memory, roundNumbers: false, moveThreshold: 10, now: hours(26)) == [.moved(change: -12)])
    }

    @Test("Limite desligado nao avisa variacao; numeros redondos desligados nao avisam nivel")
    func switchedOff() {
        var memory = PriceAlertMemory()
        _ = PriceAlertRules.evaluate(price: 80_900, change24h: 0, memory: &memory, roundNumbers: false, moveThreshold: nil, now: start)
        #expect(PriceAlertRules.evaluate(price: 95_000, change24h: 17, memory: &memory, roundNumbers: false, moveThreshold: nil, now: hours(1)).isEmpty)
        #expect(memory.lastPrice == 95_000)
    }

    @Test("Salto de mais de 50% espera a leitura seguinte confirmar")
    func jumpNeedsConfirmation() {
        var memory = PriceAlertMemory()
        _ = PriceAlertRules.evaluate(price: 612_000, change24h: 1, memory: &memory, roundNumbers: true, moveThreshold: 10, now: start)
        // Uma leitura mentirosa: nada na tela e a base fica.
        #expect(PriceAlertRules.evaluate(price: 12_000, change24h: -98, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(1)).isEmpty)
        #expect(memory.lastPrice == 612_000)
        // A leitura seguinte volta ao normal: a suspeita cai sem aviso nenhum.
        #expect(PriceAlertRules.evaluate(price: 611_500, change24h: 1, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(2)).isEmpty)
        #expect(memory.suspectPrice == nil)
        // Uma queda de verdade aparece duas vezes seguidas e entao avisa.
        #expect(PriceAlertRules.evaluate(price: 250_000, change24h: -59, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(3)).isEmpty)
        let confirmed = PriceAlertRules.evaluate(price: 248_000, change24h: -60, memory: &memory, roundNumbers: true, moveThreshold: 10, now: hours(4))
        #expect(confirmed == [.crossedDown(level: 250_000), .moved(change: -60)])
        #expect(memory.lastPrice == 248_000)
    }

    @Test("Preco invalido nao mexe em nada")
    func invalidPrice() {
        var memory = PriceAlertMemory()
        #expect(PriceAlertRules.evaluate(price: .nan, change24h: 1, memory: &memory, roundNumbers: true, moveThreshold: 10, now: start).isEmpty)
        #expect(PriceAlertRules.evaluate(price: 0, change24h: 1, memory: &memory, roundNumbers: true, moveThreshold: 10, now: start).isEmpty)
        #expect(memory == PriceAlertMemory())
    }
}
