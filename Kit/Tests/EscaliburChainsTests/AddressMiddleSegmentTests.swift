import Testing
@testable import EscaliburChains

@Suite("Trecho do meio do endereco")
struct AddressMiddleSegmentTests {
    @Test("Seis caracteres no meio, para o dono ler e digitar")
    func middle() throws {
        let address = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
        let segment = try #require(AddressPoisoning.middleSegment(address))
        #expect(segment.length == 6)
        #expect(segment.start == (address.count - 6) / 2)
        #expect(segment.text(in: address) == "E47d90")
        #expect(AddressPoisoning.middleSegment("curto") == nil)
    }
}
