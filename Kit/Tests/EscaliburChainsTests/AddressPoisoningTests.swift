import Testing
@testable import EscaliburChains

@Suite("Endereco parecido (envenenamento)")
struct AddressPoisoningTests {
    let ethereum = Chain.all.first { $0.id == "ethereum" }!
    let bitcoin = Chain.all.first { $0.id == "bitcoin" }!

    @Test("EVM: pontas iguais e meio diferente e parecido; o prefixo 0x nao conta")
    func evm() {
        let real = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        let fake = "0xd8dA000000000000000000000000000000A96045"
        #expect(AddressPoisoning.lookalike(fake, among: [real], chain: ethereum) == real)
        // So o 0x e uma ponta: nao e parecido.
        #expect(AddressPoisoning.lookalike("0x1111111111111111111111111111111111116045", among: [real], chain: ethereum) == nil)
        // A mesma conta em outra caixa nao e parecida, e a propria.
        #expect(AddressPoisoning.lookalike(real.lowercased(), among: [real], chain: ethereum) == nil)
    }

    @Test("Bitcoin bech32: bc1q nao conta como coincidencia")
    func bech32() {
        let real = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        #expect(AddressPoisoning.body(real, chain: bitcoin).hasPrefix("w508"))
        let fake = "bc1qw50xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx8f3t4"
        #expect(AddressPoisoning.lookalike(fake, among: [real], chain: bitcoin) == real)
    }

    @Test("Tron: o T inicial nao conta")
    func tron() {
        let real = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
        let fake = "TR7NHzzzzzzzzzzzzzzzzzzzzzzzgjLj6t"
        #expect(AddressPoisoning.lookalike(fake, among: [real], chain: .tron) == real)
        #expect(AddressPoisoning.lookalike("TXYZzzzzzzzzzzzzzzzzzzzzzzzzzzLj6t", among: [real], chain: .tron) == nil)
    }
}
