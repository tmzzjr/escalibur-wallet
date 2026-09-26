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

    @Test("O desafio pede o meio onde os dois diferem, nunca as pontas copiadas")
    func differingSegment() throws {
        let real = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        let fake = "0xd8dA000000000000000000000000000000A96045"
        let segment = try #require(AddressPoisoning.differingSegment(fake, from: real, chain: ethereum))
        #expect(segment.start == 6)
        #expect(segment.text(in: fake) == "000000")
        #expect(segment.text(in: fake).lowercased() != segment.text(in: real).lowercased())
        #expect(!fake.hasSuffix(segment.text(in: fake)))
        // Diferenca so perto do fim: o trecho encosta no fim e ainda a inclui.
        let late = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96099"
        let tail = try #require(AddressPoisoning.differingSegment(late, from: real, chain: ethereum))
        #expect(tail.text(in: late) == "A96099")
        // Bech32: o prefixo bc1q fica fora.
        let btcReal = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        let btcFake = "bc1qw50xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx8f3t4"
        #expect(AddressPoisoning.differingSegment(btcFake, from: btcReal, chain: bitcoin)?.text(in: btcFake) == "xxxxxx")
        #expect(AddressPoisoning.differingSegment(real, from: real, chain: ethereum) == nil)
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
