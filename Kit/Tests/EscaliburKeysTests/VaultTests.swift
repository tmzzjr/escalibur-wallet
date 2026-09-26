import CryptoKit
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburCore
@testable import EscaliburKeys

private func secure(_ text: String) -> SecureBytes {
    let bytes = SecureBytes(capacity: max(text.utf8.count, 1))
    bytes.replaceAll(with: Array(text.utf8))
    return bytes
}

/// Parametros minimos aceitos, para os testes nao levarem segundos por PIN.
private let fastKDF = KDFParameters(memoryKiB: 64 * 1024, passes: 2, lanes: 1)

@Suite("Chave raiz: PIN, atraso, biometria")
struct RootKeyVaultTests {
    func makeVault() -> (RootKeyVault, MemoryStore) {
        let store = MemoryStore()
        return (RootKeyVault(store: store, wrapper: SoftwareWrapper()), store)
    }

    @Test("PIN certo devolve a mesma RK; PIN errado e recusado pelo armazenamento")
    func pinRoundTrip() throws {
        let (vault, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"), kdf: fastKDF)
        let original = rk.withUnsafeBytes { Array($0) }
        #expect(vault.isSetUp)
        let again = try vault.unlock(pin: secure("482916"))
        #expect(again.withUnsafeBytes { Array($0) } == original)
        #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlock(pin: secure("482917")) }
    }

    @Test("PIN da lista de bloqueio e recusado")
    func blocklist() {
        let (vault, _) = makeVault()
        for pin in ["123456", "000000", "121212", "654321", "112233", "147258", "890123"] {
            #expect(throws: RootKeyVault.Failure.blockedPIN) { try vault.setUp(pin: secure(pin), kdf: fastKDF) }
        }
        #expect(!PINPolicy.isBlocked([4, 8, 2, 9, 1, 6]))
    }

    @Test("Escada de atraso: o terceiro erro ja espera, e o acerto zera")
    func throttle() throws {
        let (vault, _) = makeVault()
        _ = try vault.setUp(pin: secure("482916"), kdf: fastKDF)
        _ = try? vault.unlock(pin: secure("000001"))
        _ = try? vault.unlock(pin: secure("000002"))
        #expect(vault.throttleRemaining() == 0)
        _ = try? vault.unlock(pin: secure("000003"))
        #expect(vault.throttleRemaining() > 0)
        // Durante a espera, nem o PIN certo e avaliado.
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlock(pin: secure("482916")) }
        #expect(vault.failureCount() == 3)
    }

    @Test("Apagar apos 10 erros destroi tudo")
    func wipeAfterErrors() throws {
        let (vault, store) = makeVault()
        _ = try vault.setUp(pin: secure("482916"), kdf: fastKDF)
        try vault.setWipeAfterErrors(true)
        // Encurta o teste gravando nove erros sem espera, como se o tempo tivesse passado.
        try store.update(AttemptRecord(failures: 9, wallDeadline: 0, uptimeDeadline: 0, bootTime: PINPolicy.bootTime).encoded, account: "pin.tentativas")
        #expect(throws: RootKeyVault.Failure.wiped) { try vault.unlock(pin: secure("000001")) }
        #expect(!vault.isSetUp)
    }

    @Test("Biometria liga, destranca e desliga sem tocar o PIN")
    func biometry() throws {
        let (vault, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"), kdf: fastKDF)
        let original = rk.withUnsafeBytes { Array($0) }
        try vault.enableBiometry(rk: rk)
        #expect(vault.isBiometryEnabled)
        let viaFace = try vault.unlockWithBiometry(reason: "teste")
        #expect(viaFace.withUnsafeBytes { Array($0) } == original)
        vault.disableBiometry()
        #expect(!vault.isBiometryEnabled)
        #expect(throws: RootKeyVault.Failure.biometryNotEnabled) { try vault.unlockWithBiometry(reason: "teste") }
        #expect(try vault.unlock(pin: secure("482916")).withUnsafeBytes { Array($0) } == original)
    }

    @Test("Troca de PIN preserva a RK e aposenta o PIN antigo")
    func changePIN() throws {
        let (vault, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"), kdf: fastKDF)
        let original = rk.withUnsafeBytes { Array($0) }
        try vault.changePIN(rk: rk, newPIN: secure("730584"))
        #expect(try vault.unlock(pin: secure("730584")).withUnsafeBytes { Array($0) } == original)
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlock(pin: secure("482916")) }
    }
}

@Suite("Cofre da carteira e assinador")
struct WalletVaultTests {
    static let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    @Test("Registro guarda entropia e 25a palavra; a RK errada nao abre")
    func record() throws {
        let vault = WalletVault(store: MemoryStore())
        let rk = try SecureBytes.random(count: 32)
        let id = UUID()
        let secret = try WalletSecret.from(phrase: BIP39.canonical(Self.phrase), language: .english, passphrase: secure("TREZOR"))
        try vault.save(secret, walletID: id, rk: rk)
        let opened = try vault.open(walletID: id, rk: rk)
        #expect(opened.entropy.withUnsafeBytes { Array($0) } == [UInt8](repeating: 0, count: 16))
        #expect(opened.passphrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == "TREZOR")
        #expect(try opened.seed().withUnsafeBytes { Array($0) }.hex.hasPrefix("c55257c360c07c72"))
        #expect(throws: WalletVault.Failure.corrupted) { try vault.open(walletID: id, rk: try SecureBytes.random(count: 32)) }
    }

    @Test("Contas publicas derivadas uma vez batem com os vetores")
    func accounts() throws {
        let secret = try WalletSecret.from(phrase: BIP39.canonical(Self.phrase), language: .english)
        let (accounts, fingerprint) = try AccountDeriver.derive(secret)
        #expect(accounts.first { $0.chainID == "bitcoin" }?.address == "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
        #expect(accounts.first { $0.chainID == "ethereum" }?.address == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        #expect(accounts.first { $0.chainID == "solana" }?.address == "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
        #expect(accounts.first { $0.chainID == "bitcoin" }?.accountXPub != nil)
        #expect(fingerprint.hex == "73c5da0a")
    }

    /// Uma transacao de mentira que pede duas assinaturas, para exercitar o
    /// assinador sem depender de nenhuma rede.
    struct FakeTransaction: SignableTransaction {
        let chain: Chain
        let signingRequests: [SigningRequest]
        func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
            SignedTransaction(chainID: chain.id, raw: signatures.flatMap(\.bytes), encoded: "", id: "fake")
        }
    }

    @Test("Assinador confere a chave esperada, assina e verifica")
    func signer() throws {
        let store = MemoryStore()
        let vault = WalletVault(store: store)
        let rk = try SecureBytes.random(count: 32)
        let keep = rk.withUnsafeBytes { Array($0) }
        let id = UUID()
        let secret = try WalletSecret.from(phrase: BIP39.canonical(Self.phrase), language: .english)
        try vault.save(secret, walletID: id, rk: rk)
        let (accounts, _) = try AccountDeriver.derive(secret)
        let eth = try #require(accounts.first { $0.chainID == "ethereum" })
        let sol = try #require(accounts.first { $0.chainID == "solana" })
        let digest = Hash.keccak256(Array("mensagem".utf8))
        let tx = FakeTransaction(chain: .ethereum, signingRequests: [
            SigningRequest(path: eth.path, curve: .secp256k1, scheme: .ecdsaRecoverable, payload: digest, expectedPublicKey: eth.publicKey),
            SigningRequest(path: sol.path, curve: .ed25519, scheme: .ed25519, payload: Array("bytes da mensagem".utf8), expectedPublicKey: sol.publicKey),
        ])
        let plan = SigningPlan(walletID: id, chain: .ethereum, review: PlanReview(kind: .send, title: "teste", lines: []), transactions: [tx])
        let restored = SecureBytes(capacity: 32)
        restored.replaceAll(with: keep)
        let result = try Signer.sign(plan, rootKey: restored, vault: vault)
        #expect(result.count == 1)
        #expect(result[0].raw.count == 64 + 64)
        #expect(restored.count == 0)  // a RK foi zerada

        // Chave esperada errada: nada e assinado.
        let wrong = FakeTransaction(chain: .ethereum, signingRequests: [
            SigningRequest(path: eth.path, curve: .secp256k1, scheme: .ecdsaRecoverable, payload: digest, expectedPublicKey: sol.publicKey),
        ])
        let wrongPlan = SigningPlan(walletID: id, chain: .ethereum, review: PlanReview(kind: .send, title: "x", lines: []), transactions: [wrong])
        let again = SecureBytes(capacity: 32)
        again.replaceAll(with: keep)
        #expect(throws: Signer.Failure.unexpectedKey) { try Signer.sign(wrongPlan, rootKey: again, vault: vault) }

        // Plano vencido: nada e assinado.
        let old = SigningPlan(walletID: id, chain: .ethereum, review: PlanReview(kind: .send, title: "x", lines: []), transactions: [tx], createdAt: .now.addingTimeInterval(-120))
        let third = SecureBytes(capacity: 32)
        third.replaceAll(with: keep)
        #expect(throws: Signer.Failure.expired) { try Signer.sign(old, rootKey: third, vault: vault) }
    }

    @Test("Metadados cifrados com a chave de indice")
    func index() throws {
        let rk = try SecureBytes.random(count: 32)
        let key = IndexCipher.key(from: rk)
        let sealed = try IndexCipher.seal(Data("carteira principal".utf8), key: key)
        #expect(String(decoding: try IndexCipher.open(sealed, key: key), as: UTF8.self) == "carteira principal")
        #expect(throws: (any Error).self) { try IndexCipher.open(sealed, key: SymmetricKey(size: .bits256)) }
    }
}
