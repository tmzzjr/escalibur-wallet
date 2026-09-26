import Testing
@testable import EscaliburChains
@testable import EscaliburEngines

@Suite("Motores registrados")
struct RegistryTests {
    @Test("Toda rede com motor de envio tambem tem historico")
    func sendHasActivity() {
        for chain in Chain.all where SendEngines.engine(for: chain) != nil {
            #expect(ActivitySources.source(for: chain) != nil, "\(chain.id)")
        }
    }

    @Test("Impacto no preco em degraus")
    func impact() {
        #expect(PriceImpact.level(nil) == .normal)
        #expect(PriceImpact.level(0.5) == .normal)
        #expect(PriceImpact.level(3) == .visible)
        #expect(PriceImpact.level(10) == .confirm)
        #expect(PriceImpact.level(20) == .blocked)
    }
}
