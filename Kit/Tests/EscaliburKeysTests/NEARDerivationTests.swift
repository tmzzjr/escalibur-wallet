import Foundation
import Testing
@testable import EscaliburKeys
import EscaliburChains
import EscaliburCore

/// Da frase a conta NEAR contra dois vetores publicados, de implementacoes diferentes:
/// - wallet-core da Trust Wallet, `tests/common/HDWallet/HDWalletTests.cpp`, caso
///   `NearKey`: m/44'/397'/0', chave privada 35e0d963... e conta b8d5df25...;
/// - near-seed-phrase (a biblioteca da MyNearWallet e do near-cli),
///   `test/index.test.js`, "parse seed phrase": a chave publica
///   ed25519:r4yuiZE45mzeZAENDEF2pWeFBJkW8mQYGx3rU46zCqh, no mesmo caminho
///   (`KEY_DERIVATION_PATH = "m/44'/397'/0'"`).
/// As contas 1 e a frase "abandon ... about" sairam de uma implementacao independente
/// (SLIP-10 com o hmac e o Ed25519 do Python, conferida contra os dois vetores acima).
/// Se este teste quebrar, a mesma frase abriria aqui outra conta que na MyNearWallet e
/// na Trust Wallet.
@Suite("NEAR a partir da frase")
struct NEARDerivationTests {
    static let trust = "owner erupt swamp room swift final allow unaware hint identify figure cotton"
    static let trustAccount = "b8d5df25047841365008f30fb6b30dd820e9a84d869f05623d114e96831f2fbf"
    static let shoot = "shoot island position soft burden budget tooth cruel issue economy destroy above"

    @Test("Vetores do wallet-core e do near-seed-phrase: caminho padrao m/44'/397'/0'")
    func publishedVectors() throws {
        #expect(DefaultPaths.path(for: .near).description == "m/44'/397'/0'")
        #expect(try AddressVectorTests.address(Self.trust, .near) == Self.trustAccount)
        let shoot = try AddressVectorTests.address(Self.shoot, .near)
        #expect("ed25519:" + Base58.bitcoin.encode(try #require([UInt8](hex: shoot))) == "ed25519:r4yuiZE45mzeZAENDEF2pWeFBJkW8mQYGx3rU46zCqh")
        #expect(shoot == "0c91f6106ff835c0195d5388565a2d69e25038a7e23d26198f85caf6594117ec")
        #expect(try AddressVectorTests.address(Self.shoot, .near, path: "m/44'/397'/1'") == "51a7d85c450ac1931677f4bfe5b63ec82b37679e553f2adc14b50be68ac4993b")
        #expect(try AddressVectorTests.address(AddressVectorTests.abandon, .near) == "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412")
        #expect(try AddressVectorTests.address(Self.trust, .near, passphrase: "TREZOR") == "6fec97a16cd9bd143b858df02df18388d4b0da53a70c38da83137f39b2132972")
    }

    @Test("A chave privada e a do wallet-core")
    func privateKey() throws {
        let seed = try BIP39.seed(phrase: BIP39.canonical(Self.trust), passphrase: "")
        defer { seed.wipe() }
        let master = try HDKey.master(seed: seed, curve: .ed25519)
        let key = try master.derive(DefaultPaths.path(for: .near))
        defer { key.wipe(); master.wipe() }
        #expect(key.key.withUnsafeBytes { Hex.encode($0) } == "35e0d9631bd538d5569266abf6be7a9a403ebfda92ddd49b3268e35360a6c2dd")
    }

    @Test("A conta da carteira nova sai do mesmo caminho, e a chave da a conta")
    func accountDeriver() throws {
        let secret = try WalletSecret.from(phrase: BIP39.canonical(Self.trust), language: .english)
        defer { secret.wipe() }
        let (accounts, _) = try AccountDeriver.derive(secret, chains: [.near])
        let account = try #require(accounts.first)
        #expect(account.address == Self.trustAccount && account.chainID == "near")
        #expect(account.path == DerivationPath("m/44'/397'/0'"))
        #expect(Hex.encode(account.publicKey) == account.address)
    }

    @Test("Assinador: plano da NEAR assinado com a chave SLIP-10, transacao que verifica")
    func signer() throws {
        let vault = WalletVault(store: MemoryStore())
        let rk = try SecureBytes.random(count: 32)
        let keep = rk.withUnsafeBytes { Array($0) }
        let id = UUID()
        let secret = try WalletSecret.from(phrase: BIP39.canonical(Self.trust), language: .english)
        try vault.save(secret, walletID: id, rk: rk)
        let (accounts, _) = try AccountDeriver.derive(secret, chains: [.near])
        let account = try #require(accounts.first)
        let rules = NEARProtocolRules(
            chainID: "mainnet", gasPrice: 100_000_000, minGasPurchasePrice: 1_000_000_000,
            accountCreationCharge: BigUInt(7) * BigUInt.power(of: 10, 21), storageAmountPerByte: BigUInt.power(of: 10, 19),
            actionReceipt: NEARActionFee(sendNotSir: 108_059_500_000, execution: 108_059_500_000),
            transfer: NEARActionFee(sendNotSir: 115_123_062_500, execution: 115_123_062_500),
            createAccount: NEARActionFee(sendNotSir: 500_000_000_000, execution: 7_200_000_000_000),
            addFullAccessKey: NEARActionFee(sendNotSir: 101_765_125_000, execution: 101_765_125_000)
        )
        let state = NEARChainState(
            checkpoint: NEARCheckpoint(height: 217_581_805, hash: [UInt8](repeating: 9, count: 32)),
            sender: NEARAccountState(amount: NEARRules.oneNEAR * 2, storageUsage: 182),
            accessKey: NEARAccessKeyState(nonce: 217_000_000_000_004, fullAccess: true),
            destination: NEARAccountState(amount: 1, storageUsage: 182), rules: rules
        )
        let plan = try NEARPlanner.planSend(
            walletID: id, owner: NEAROwner(path: account.path, publicKey: account.publicKey), to: "madturk.near",
            amount: NEARRules.oneNEAR, state: state
        )
        let restored = SecureBytes(capacity: 32)
        restored.replaceAll(with: keep)
        let signed = try #require(try Signer.sign(plan, rootKey: restored, vault: vault).first)
        let parsed = try NEARSignedTransaction.parse(signed)
        #expect(parsed.fields.signer.text == account.address && parsed.fields.receiver.text == "madturk.near")
        #expect(parsed.fields.nonce == 217_000_000_000_005 && parsed.fields.deposit == NEARRules.oneNEAR)
        #expect(Ed25519.verify(signature: parsed.signature, message: try parsed.fields.hash(), publicKey: account.publicKey))
        #expect(signed.id == Base58.bitcoin.encode(try parsed.fields.hash()))

        // O caminho de outra conta com a chave desta: nada e assinado.
        let wrong = try NEARPlanner.planSend(
            walletID: id, owner: NEAROwner(path: DerivationPath("m/44'/397'/1'")!, publicKey: account.publicKey),
            to: "madturk.near", amount: NEARRules.oneNEAR, state: state
        )
        let again = SecureBytes(capacity: 32)
        again.replaceAll(with: keep)
        #expect(throws: Signer.Failure.unexpectedKey) { try Signer.sign(wrong, rootKey: again, vault: vault) }
    }
}
