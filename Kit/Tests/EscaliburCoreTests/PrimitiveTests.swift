import Foundation
import Testing
@testable import EscaliburCore

// Vetores oficiais. Cada um cita a fonte, para quem auditar poder conferir sem
// confiar neste arquivo.

@Suite("Hashes")
struct HashTests {
    @Test("Keccak-256 (vetores da equipe Keccak, usados pela Ethereum)")
    func keccak() {
        #expect(Keccak.hash256([UInt8]()).hex == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        #expect(Keccak.hash256(Array("abc".utf8)).hex == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        #expect(Keccak.hash256(Array("The quick brown fox jumps over the lazy dog".utf8)).hex == "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15")
        // A permutacao em mensagens de varios blocos, conferida contra SHA3-256
        // (mesma esponja, outro byte de dominio). Valores do hashlib do Python.
        #expect(Keccak.sha3_256ForTesting([UInt8]()).hex == "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
        #expect(Keccak.sha3_256ForTesting([UInt8](repeating: 0x61, count: 135)).hex == SHA3Vectors.a135)
        #expect(Keccak.sha3_256ForTesting([UInt8](repeating: 0x61, count: 136)).hex == SHA3Vectors.a136)
        #expect(Keccak.sha3_256ForTesting([UInt8](repeating: 0x61, count: 1000)).hex == SHA3Vectors.a1000)
        // Assinatura de funcao ERC-20 conhecida: transfer(address,uint256) = a9059cbb
        #expect(Array(Keccak.hash256(Array("transfer(address,uint256)".utf8)).prefix(4)).hex == "a9059cbb")
        #expect(Array(Keccak.hash256(Array("approve(address,uint256)".utf8)).prefix(4)).hex == "095ea7b3")
    }

    @Test("RIPEMD-160 (vetores do artigo original)")
    func ripemd() {
        #expect(RIPEMD160.hash([UInt8]()).hex == "9c1185a5c5e9fc54612808977ee8f548b2258d31")
        #expect(RIPEMD160.hash(Array("abc".utf8)).hex == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
        #expect(RIPEMD160.hash(Array("message digest".utf8)).hex == "5d0689ef49d2fae572b881b123a85ffa21595f36")
        #expect(RIPEMD160.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)).hex == "12a053384a9c0c88e405a06c27dcf49ada62eb2b")
        #expect(RIPEMD160.hash([UInt8](repeating: 0x61, count: 1_000_000)).hex == "52783243c1697bdbe16d37f97f68f08325dc1528")
    }
}

@Suite("Codificacao")
struct EncodingTests {
    @Test("Base58 e Base58Check")
    func base58() {
        #expect(Base58.bitcoin.encode(Array("Hello World!".utf8)) == "2NEpo7TZRRrLZSi2U")
        #expect(Base58.bitcoin.encode([0, 0, 0x28, 0x7f, 0xb4, 0xcd]) == "11233QC4")
        #expect(Base58.bitcoin.decode("11233QC4") == [0, 0, 0x28, 0x7f, 0xb4, 0xcd])
        #expect(Base58.bitcoin.decode("0OIl") == nil)
        // Endereco P2PKH do bloco genesis.
        let payload = Base58.bitcoin.decodeCheck("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        #expect(payload?.hex == "0062e907b15cbf27d5425399ebf6f0fb50ebb88f18")
        #expect(Base58.bitcoin.decodeCheck("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb") == nil)
    }

    @Test("Bech32 e Bech32m (BIP-173 e BIP-350)")
    func bech32() {
        let v0 = Bech32.segwitDecode(hrp: "bc", address: "BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4")
        #expect(v0?.version == 0)
        #expect(v0?.program.hex == "751e76e8199196d454941c45d1b3a323f1433bd6")
        #expect(Bech32.segwitEncode(hrp: "bc", version: 0, program: [UInt8](hex: "751e76e8199196d454941c45d1b3a323f1433bd6")!)
                == "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
        // Taproot (v1) exige Bech32m.
        let v1 = Bech32.segwitDecode(hrp: "bc", address: "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0")
        #expect(v1?.version == 1)
        // O mesmo programa v1 em Bech32 antigo precisa ser recusado.
        #expect(Bech32.segwitDecode(hrp: "bc", address: "bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7k7grplx") == nil)
        // Caixa mista e invalida.
        #expect(Bech32.decode("bc1qW508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4") == nil)
    }

    @Test("Base32 e CRC16-XModem")
    func base32() {
        #expect(Base32.encode(Array("foobar".utf8)) == "MZXW6YTBOI")
        #expect(Base32.decode("MZXW6YTBOI") == Array("foobar".utf8))
        #expect(CRC16.xmodem(Array("123456789".utf8)) == 0x31C3)
    }

    @Test("RLP (exemplos do Yellow Paper e da wiki da Ethereum)")
    func rlp() {
        #expect(RLP.bytes(Array("dog".utf8)).encoded.hex == "83646f67")
        #expect(RLP.list([.bytes(Array("cat".utf8)), .bytes(Array("dog".utf8))]).encoded.hex == "c88363617483646f67")
        #expect(RLP.bytes([]).encoded.hex == "80")
        #expect(RLP.list([]).encoded.hex == "c0")
        #expect(RLP.uint(0).encoded.hex == "80")
        #expect(RLP.uint(15).encoded.hex == "0f")
        #expect(RLP.uint(1024).encoded.hex == "820400")
        let lorem = Array("Lorem ipsum dolor sit amet, consectetur adipisicing elit".utf8)
        #expect(RLP.bytes(lorem).encoded.prefix(2).map { $0 } == [0xB8, 0x38])
    }

    @Test("BigUInt: decimal, hex, aritmetica")
    func bigUInt() {
        let max = BigUInt.uint256Max
        #expect(max.decimalString == "115792089237316195423570985008687907853269984665640564039457584007913129639935")
        #expect(BigUInt(decimal: max.decimalString) == max)
        #expect(BigUInt(hex: "0x1")! == BigUInt(1))
        #expect(BigUInt(hex: "0xde0b6b3a7640000")!.decimalString == "1000000000000000000")
        let a = BigUInt(decimal: "123456789012345678901234567890")!
        let b = BigUInt(decimal: "987654321098765432109876543210")!
        #expect((a * b).decimalString == "121932631137021795226185032733622923332237463801111263526900")
        #expect(((a * b) / b) == a)
        #expect(((a * b + 5) % b) == 5)
        #expect(a.subtractingReportingUnderflow(b) == nil)
        #expect((b - a).decimalString == "864197532086419753208641975320")
        #expect(BigUInt(0).bigEndianBytes.isEmpty)
        #expect(BigUInt(decimal: "-1") == nil)
        #expect(BigUInt(decimal: "1.5") == nil)
    }
}

@Suite("BIP-39")
struct BIP39Tests {
    // Vetores de trezor/python-mnemonic (vectors.json), passphrase "TREZOR".
    static let vectors: [(entropy: String, phrase: String, seed: String)] = [
        ("00000000000000000000000000000000",
         "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
         "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"),
        ("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
         "legal winner thank year wave sausage worth useful legal winner thank yellow",
         "2e8905819b8723fe2c1d161860e5ee1830318dbf49a83bd451cfb8440c28bd6fa457fe1296106559a3c80937a1c1069be3a3a5bd381ee6260e8d9739fce1f607"),
        ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
         "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote",
         "dd48c104698c30cfe2b6142103248622fb7bb0ff692eebb00089b32d22484e1613912f0a5b694407be899ffd31ed3992c456cdf60f5d4564b8ba3f05a69890ad"),
    ]

    @Test("Entropia para frase e frase para seed")
    func vectors() throws {
        for vector in Self.vectors {
            let entropy = SecureBytes(capacity: 32)
            entropy.replaceAll(with: [UInt8](hex: vector.entropy)!)
            let phrase = try BIP39.phrase(fromEntropy: entropy)
            #expect(phrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == vector.phrase)
            let seed = try BIP39.seed(phrase: phrase, passphrase: "TREZOR")
            #expect(seed.withUnsafeBytes { Array($0) }.hex == vector.seed)
            #expect(BIP39.validate(phrase) == .valid(language: .english))
        }
    }

    @Test("Frase gerada fecha o checksum")
    func generated() throws {
        for count in [12, 24] {
            let phrase = try BIP39.generate(wordCount: count)
            #expect(BIP39.validate(phrase) == .valid(language: .english))
            #expect(phrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }.split(separator: " ").count == count)
        }
    }
}

@Suite("Derivacao")
struct DerivationTests {
    @Test("BIP-32 vetor 1")
    func bip32() throws {
        let seed = SecureBytes(capacity: 16)
        seed.replaceAll(with: [UInt8](hex: "000102030405060708090a0b0c0d0e0f")!)
        let master = try HDKey.master(seed: seed, curve: .secp256k1)
        #expect(master.extendedPrivateKeyForTesting() == "xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi")
        #expect(try master.extendedPublicKey() == "xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8")
        let m0h = try master.derive(DerivationPath("m/0'")!)
        #expect(m0h.extendedPrivateKeyForTesting() == "xprv9uHRZZhk6KAJC1avXpDAp4MDc3sQKNxDiPvvkX8Br5ngLNv1TxvUxt4cV1rGL5hj6KCesnDYUhd7oWgT11eZG7XnxHrnYeSvkzY7d2bhkJ7")
        let deep = try master.derive(DerivationPath("m/0'/1/2'/2/1000000000")!)
        #expect(deep.extendedPrivateKeyForTesting() == "xprvA41z7zogVVwxVSgdKUHDy1SKmdb533PjDz7J6N6mV6uS3ze1ai8FHa8kmHScGpWmj4WggLyQjgPie1rFSruoUihUZREPSL39UNdE3BBDu76")
    }

    @Test("SLIP-10 Ed25519 vetor 1")
    func slip10() throws {
        let seed = SecureBytes(capacity: 16)
        seed.replaceAll(with: [UInt8](hex: "000102030405060708090a0b0c0d0e0f")!)
        let master = try HDKey.master(seed: seed, curve: .ed25519)
        #expect(master.chainCode.withUnsafeBytes { Array($0) }.hex == "90046a93de5380a72b5e45010748567d5ea02bbf6522f979e05c0d8d8ca9fffb")
        #expect(master.key.withUnsafeBytes { Array($0) }.hex == "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7")
        #expect(try master.publicKey().hex == "a4b2856bfec510abab89753fac1ac0e1112364e7d250545963f135f2a33188ed")
        let child = try master.derive(DerivationPath("m/0'/1'/2'/2'/1000000000'")!)
        #expect(child.key.withUnsafeBytes { Array($0) }.hex == "8f94d394a8e8fd6b1bc2f3f49f5c47e385281d5c17e65324b0f62483e37e8793")
        #expect(try child.publicKey().hex == "3c24da049451555d51a7014a37337aa4e12d41e485abccfa46b47dfb2af54b7a")
        #expect(throws: HDKey.Failure.nonHardenedEd25519) { try master.child(0) }
    }

    @Test("Caminhos")
    func paths() {
        #expect(DerivationPath("m/44'/60'/0'/0/0")?.description == "m/44'/60'/0'/0/0")
        #expect(DerivationPath("m/44h/501H/0'")?.description == "m/44'/501'/0'")
        #expect(DerivationPath("44'/0") == nil)
        #expect(DerivationPath("m/2147483648") == nil)
        #expect(DerivationPath("m/-1") == nil)
    }
}

@Suite("secp256k1")
struct Secp256k1Tests {
    @Test("Assinatura deterministica, low-S, recuperavel")
    func signing() throws {
        let key = SecureBytes(capacity: 32)
        key.replaceAll(with: [UInt8](repeating: 0, count: 31) + [1])
        let pub = try Secp256k1.publicKey(of: key)
        #expect(pub.hex == "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
        let digest = Hash.sha256(Array("escalibur".utf8))
        let first = try Secp256k1.signRecoverable(digest: digest, privateKey: key)
        let second = try Secp256k1.signRecoverable(digest: digest, privateKey: key)
        #expect(first.compact == second.compact)  // RFC 6979
        // low-S: s <= n/2
        let halfOrder = BigUInt(hex: "7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0")!
        #expect(BigUInt(bigEndian: first.compact.suffix(32)) <= halfOrder)
        let recovered = try Secp256k1.recover(digest: digest, compact: first.compact, recoveryID: first.recoveryID, compressed: true)
        #expect(recovered == pub)
        let der = try Secp256k1.signDER(digest: digest, privateKey: key)
        #expect(Secp256k1.verifyDER(signature: der, digest: digest, publicKey: pub))
    }
}

enum SHA3Vectors {
    static let a135 = "8094bb53c44cfb1e67b7c30447f9a1c33696d2463ecc1d9c92538913392843c9"
    static let a136 = "3fc5559f14db8e453a0a3091edbd2bc25e11528d81c66fa570a4efdcc2695ee1"
    static let a1000 = "8f3934e6f7a15698fe0f396b95d8c4440929a8fa6eae140171c068b4549fbf81"
}
