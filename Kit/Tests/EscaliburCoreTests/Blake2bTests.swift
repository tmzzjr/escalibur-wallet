import Testing
@testable import EscaliburCore

/// BLAKE2b de referencia exposto ao Swift. Vetores da RFC 7693 (Apendice A) e os de
/// tamanho menor e com chave conferidos contra o hashlib do Python.
@Suite("BLAKE2b")
struct Blake2bTests {
    func hex(_ text: String, _ length: Int, key: [UInt8] = []) -> String {
        Blake2b.hash(Array(text.utf8), outputLength: length, key: key).map { String(format: "%02x", $0) }.joined()
    }

    @Test("RFC 7693: BLAKE2b-512 de abc e da entrada vazia")
    func rfc() {
        #expect(hex("abc", 64) == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        #expect(hex("", 64) == "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
    }

    @Test("Saidas de 256 e 224 bits, e com chave")
    func sizesAndKey() {
        #expect(hex("abc", 32) == "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
        #expect(hex("abc", 28) == "9bd237b02a29e43bdd6738afa5b53ff0eee178d6210b618e4511aec8")
        #expect(hex("", 64, key: Array(0..<64)) == "10ebb67700b1868efb4417987acf4690ae9d972fb7a590c2f02871799aaa4786b5e996e8f0f4eb981fc214b005f42d2ff4233499391653df7aefcbc13fc51568")
    }
}
