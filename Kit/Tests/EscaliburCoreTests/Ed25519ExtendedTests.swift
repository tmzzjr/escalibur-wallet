import CryptoKit
import Testing
@testable import EscaliburCore

/// Ed25519 com chave estendida (a da Cardano) contra a RFC 8032, secao 7.1.
///
/// A Ed25519 e deterministica: com kL = SHA-512(semente)[0..32] com os bits ajustados e
/// kR = a outra metade, a assinatura com chave estendida tem de ser, byte a byte, a do
/// vetor da RFC. E a unica forma de conferir a assinatura contra vetor publicado, ja que o
/// CryptoKit aleatoriza a dele.
@Suite("Ed25519 com chave estendida")
struct Ed25519ExtendedTests {
    struct Vector {
        let secret: String
        let publicKey: String
        let message: String
        let signature: String
    }

    // RFC 8032 §7.1: TEST 1, TEST 2, TEST 3 e TEST SHA(abc).
    static let vectors = [
        Vector(
            secret: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
            publicKey: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", message: "",
            signature: "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
        ),
        Vector(
            secret: "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
            publicKey: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", message: "72",
            signature: "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
        ),
        Vector(
            secret: "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
            publicKey: "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", message: "af82",
            signature: "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"
        ),
        Vector(
            secret: "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
            publicKey: "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
            message: "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
            signature: "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704"
        ),
    ]

    /// kL || kR como a RFC 8032 tira da semente.
    static func extended(fromSeed hex: String) -> SecureBytes {
        var digest = Hash.sha512(Hex.decode(hex)!)
        digest[0] &= 248
        digest[31] &= 127
        digest[31] |= 64
        let key = SecureBytes(capacity: 64)
        key.replaceAll(with: digest)
        return key
    }

    @Test("Chave publica e assinatura iguais as da RFC 8032", arguments: vectors.indices)
    func rfc8032(index: Int) throws {
        let vector = Self.vectors[index]
        let key = Self.extended(fromSeed: vector.secret)
        defer { key.wipe() }
        #expect(Hex.encode(try Ed25519.publicKey(extendedKey: key)) == vector.publicKey)
        let message = Hex.decode(vector.message)!
        let signature = try Ed25519.signExtended(message, extendedKey: key)
        #expect(Hex.encode(signature) == vector.signature)
        #expect(Ed25519.verify(signature: signature, message: message, publicKey: Hex.decode(vector.publicKey)!))
    }

    @Test("A mesma chave publica que o CryptoKit tira da semente")
    func matchesCryptoKit() throws {
        let seed = SecureBytes(capacity: 32)
        seed.replaceAll(with: Array(repeating: 0x42, count: 32))
        let key = Self.extended(fromSeed: Hex.encode(Array(repeating: 0x42, count: 32)))
        #expect(try Ed25519.publicKey(extendedKey: key) == Ed25519.publicKey(of: seed))
    }

    @Test("Chave de tamanho errado e recusada")
    func wrongSize() {
        let short = SecureBytes(capacity: 31)
        short.replaceAll(with: Array(repeating: 1, count: 31))
        #expect(throws: Ed25519.Failure.self) { try Ed25519.publicKey(extendedKey: short) }
        let half = SecureBytes(capacity: 32)
        half.replaceAll(with: Array(repeating: 1, count: 32))
        #expect(throws: Ed25519.Failure.self) { try Ed25519.signExtended([1], extendedKey: half) }
    }
}
