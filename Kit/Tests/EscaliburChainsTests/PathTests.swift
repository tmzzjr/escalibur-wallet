import Testing
import EscaliburChains

@Suite("Caminhos")
struct PathTests {
    @Test("Caminhos")
    func paths() {
        #expect(DerivationPath("m/44'/60'/0'/0/0")?.description == "m/44'/60'/0'/0/0")
        #expect(DerivationPath("m/44h/501H/0'")?.description == "m/44'/501'/0'")
        #expect(DerivationPath("44'/0") == nil)
        #expect(DerivationPath("m/2147483648") == nil)
        #expect(DerivationPath("m/-1") == nil)
    }
}
