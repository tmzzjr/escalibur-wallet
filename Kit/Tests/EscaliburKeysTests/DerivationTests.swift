import Foundation
import Testing
@testable import EscaliburKeys
import EscaliburChains
import EscaliburCore

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

    @Test("Caminho vazio e recusado, nunca devolve a chave mestra")
    func emptyPath() throws {
        let seed = SecureBytes(capacity: 16)
        seed.replaceAll(with: [UInt8](hex: "000102030405060708090a0b0c0d0e0f")!)
        let master = try HDKey.master(seed: seed, curve: .secp256k1)
        #expect(throws: HDKey.Failure.emptyPath) { try master.derive(DerivationPath(components: [])) }
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

}
