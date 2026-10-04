import Testing
@testable import EscaliburWallet

/// A escala da tolerancia: marcas a distancias iguais, ida e volta sem perder valor.
struct SlippageScaleTests {
    @Test func marksAreEvenlySpaced() {
        #expect(SlippageSlider.position(10) == 0)
        #expect(SlippageSlider.position(50) == 0.25)
        #expect(SlippageSlider.position(100) == 0.5)
        #expect(SlippageSlider.position(200) == 0.75)
        #expect(SlippageSlider.position(300) == 1)
    }

    @Test func roundTripOnEveryStep() {
        for bps in stride(from: 10, through: 300, by: 10) {
            #expect(SlippageSlider.value(at: Double(SlippageSlider.position(bps))) == bps, "\(bps)")
        }
        #expect(SlippageSlider.value(at: -1) == 10)
        #expect(SlippageSlider.value(at: 2) == 300)
    }
}
