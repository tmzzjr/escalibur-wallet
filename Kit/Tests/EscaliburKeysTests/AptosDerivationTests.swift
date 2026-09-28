import Foundation
import Testing
@testable import EscaliburKeys
import EscaliburChains
import EscaliburCore

/// Da frase ao endereco da Aptos contra os vetores publicados de quem ja abre a conta:
/// - SDK oficial em TypeScript (aptos-labs/aptos-ts-sdk, commit
///   15f4d351731c494f7da6f1a40c81d159ee31ce8c, `packages/ts-sdk/tests/unit/helper.ts`,
///   `wallet` e `zeroWallet`), o que a Petra usa;
/// - wallet-core da Trust Wallet (commit d40d24a63d92619167903369308bf0e2f7eb3a59,
///   `tests/chains/Aptos/TWAptosAddressTests.cpp`, a mesma frase e o mesmo endereco, e
///   `tests/common/CoinAddressDerivationTests.cpp`, a chave 0x46...46).
/// Se um destes quebrar, a mesma frase abriria outra conta aqui.
@Suite("Aptos a partir da frase")
struct AptosDerivationTests {
    static let phrase = "shoot island position soft burden budget tooth cruel issue economy destroy above"

    @Test("Vetor do SDK oficial e da Trust Wallet: m/44'/637'/0'/0'/0'")
    func officialVector() throws {
        #expect(DefaultPaths.path(for: .aptos).description == "m/44'/637'/0'/0'/0'")
        #expect(DefaultPaths.path(for: .aptos, account: 3).description == "m/44'/637'/3'/0'/0'")
        #expect(try AddressVectorTests.address(Self.phrase, .aptos) == "0x07968dab936c1bad187c60ce4082f307d030d780e91e694ae03aef16aba73f30")
    }

    @Test("Chave privada e publica do vetor, e o endereco com zero na frente (zeroWallet)")
    func keysAndLeadingZero() throws {
        let seed = try BIP39.seed(phrase: BIP39.canonical(Self.phrase), passphrase: "")
        defer { seed.wipe() }
        let master = try HDKey.master(seed: seed, curve: .ed25519)
        defer { master.wipe() }
        let key = try master.derive(DefaultPaths.path(for: .aptos))
        defer { key.wipe() }
        #expect(key.key.withUnsafeBytes { Hex.encode(Array($0)) } == "5d996aa76b3212142792d9130796cd2e11e3c445a93118c08414df4f66bc60ec")
        #expect(Hex.encode(try key.publicKey()) == "ea526ba1710343d953461ff68641f1b7df5f23b9042ffa2d2a798d3adb3f3d6c")
        // O endereco comeca com 0x00: a forma longa mantem os zeros.
        #expect(try AddressVectorTests.address(Self.phrase, .aptos, path: "m/44'/637'/0'/0'/44'")
            == "0x00fe71257b6b4caca517ef4c9979ada97aa2e2688e950654a40ff82e98f68163")
    }

    @Test("A conta da carteira nova sai do mesmo caminho, e a chave da o endereco")
    func accountDeriver() throws {
        let secret = try WalletSecret.from(phrase: BIP39.canonical(Self.phrase), language: .english)
        defer { secret.wipe() }
        let (accounts, _) = try AccountDeriver.derive(secret, chains: [.aptos])
        let account = try #require(accounts.first)
        #expect(account.address == "0x07968dab936c1bad187c60ce4082f307d030d780e91e694ae03aef16aba73f30")
        #expect(account.path == DerivationPath("m/44'/637'/0'/0'/0'"))
        #expect(try AptosAddress(ed25519PublicKey: account.publicKey).hex == account.address)
    }

    @Test("Chave 0x46...46 do wallet-core da o endereco da tabela de derivacao")
    func trustWalletDummyKey() throws {
        let seed = SecureBytes(capacity: 32)
        defer { seed.wipe() }
        seed.replaceAll(with: [UInt8](repeating: 0x46, count: 32))
        let key = try Ed25519.publicKey(of: seed)
        #expect(try Address.from(publicKey: key, chain: .aptos) == "0xce2fd04ac9efa74f17595e5785e847a2399d7e637f5e8179244f76191f653276")
    }
}
