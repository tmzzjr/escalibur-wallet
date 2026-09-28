import Foundation
import Testing
@testable import EscaliburKeys
import EscaliburChains
import EscaliburCore

/// Da frase ao endereco da Sui contra os vetores do SDK oficial em TypeScript
/// (MystenLabs/ts-sdks, commit 013ea22520d668ec8259c8c4535f3b344b82ce66,
/// `packages/sui/test/unit/cryptography/ed25519-keypair.test.ts`, `TEST_CASES`):
/// `Ed25519Keypair.deriveKeypair(frase)` usa m/44'/784'/0'/0'/0', o caminho da Slush e da
/// Trust Wallet. Se um destes quebrar, a mesma frase abriria outra conta aqui.
@Suite("Sui a partir da frase")
struct SuiDerivationTests {
    static let vectors: [(phrase: String, address: String)] = [
        ("film crazy soon outside stand loop subway crumble thrive popular green nuclear struggle pistol arm wife phrase warfare march wheat nephew ask sunny firm",
         "0xa2d14fad60c56049ecf75246a481934691214ce413e6a8ae2fe6834c173a6133"),
        ("require decline left thought grid priority false tiny gasp angle royal system attack beef setup reward aunt skill wasp tray vital bounce inflict level",
         "0x1ada6e6f3f3e4055096f606c746690f1108fcc2ca479055cc434a3e1d3f758aa"),
        ("organ crash swim stick traffic remember army arctic mesh slice swear summer police vast chaos cradle squirrel hood useless evidence pet hub soap lake",
         "0xe69e896ca10f5a77732769803cc2b5707f0ab9d4407afb5e4b4464b89769af14"),
    ]

    @Test("Vetores do SDK oficial: caminho padrao m/44'/784'/0'/0'/0'")
    func officialVectors() throws {
        #expect(DefaultPaths.path(for: .sui).description == "m/44'/784'/0'/0'/0'")
        #expect(DefaultPaths.path(for: .sui, account: 2).description == "m/44'/784'/2'/0'/0'")
        for vector in Self.vectors {
            #expect(try AddressVectorTests.address(vector.phrase, .sui) == vector.address)
        }
    }

    @Test("A conta da carteira nova sai do mesmo caminho, e a chave da o endereco")
    func accountDeriver() throws {
        let secret = try WalletSecret.from(phrase: BIP39.canonical(Self.vectors[0].phrase), language: .english)
        defer { secret.wipe() }
        let (accounts, _) = try AccountDeriver.derive(secret, chains: [.sui])
        let account = try #require(accounts.first)
        #expect(account.address == Self.vectors[0].address)
        #expect(account.path == DerivationPath("m/44'/784'/0'/0'/0'"))
        #expect(try SuiAddress(ed25519PublicKey: account.publicKey).hex == account.address)
    }

    @Test("Chave privada do wallet-core da o remetente dos vetores transmitidos")
    func trustWalletKey() throws {
        // trustwallet/wallet-core, rust/tw_tests/tests/chains/sui/test_cases.rs:
        // PRIVATE_KEY_54E80D76 e SENDER_54E80D76.
        let seed = SecureBytes(capacity: 32)
        defer { seed.wipe() }
        seed.replaceAll(with: [UInt8](hex: "7e6682f7bf479ef0f627823cffd4e1a940a7af33e5fb39d9e0f631d2ecc5daff")!)
        let key = try Ed25519.publicKey(of: seed)
        #expect(try Address.from(publicKey: key, chain: .sui) == "0x54e80d76d790c277f5a44f3ce92f53d26f5894892bf395dee6375988876be6b2")
    }
}
