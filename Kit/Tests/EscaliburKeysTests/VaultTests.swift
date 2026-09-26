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
    func makeVault() -> (RootKeyVault, MemoryStore, SoftwareWrapper) {
        let store = MemoryStore()
        let wrapper = SoftwareWrapper()
        return (RootKeyVault(store: store, wrapper: wrapper, pinParameters: fastKDF), store, wrapper)
    }

    func bytes(_ secret: SecureBytes) -> [UInt8] { secret.withUnsafeBytes { Array($0) } }

    @Test("PIN certo devolve a mesma RK; PIN errado e recusado pelo armazenamento")
    func pinRoundTrip() throws {
        let (vault, _, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        #expect(vault.isSetUp)
        #expect(bytes(try vault.unlock(pin: secure("482916"))) == bytes(rk))
        #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlock(pin: secure("482917")) }
    }

    @Test("Camada interna: sem a senha de aplicativo valendo, o PIN errado continua sem abrir")
    func innerLayer() throws {
        let (vault, store, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        // O pior caso do spike: o chaveiro entrega o item a quem pedir.
        store.enforcesApplicationPassword = false
        #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlock(pin: secure("482917")) }
        #expect(bytes(try vault.unlock(pin: secure("482916"))) == bytes(rk))
        // O item copiado nao contem a RK em claro em lugar nenhum.
        let raw = try #require(store.raw("rk.pin"))
        let key = bytes(rk)
        #expect(!(0...(raw.count - key.count)).contains { Array(raw[$0..<($0 + key.count)]) == key })
    }

    @Test("Qualquer PIN de 6 digitos vale, inclusive os faceis; so a forma e conferida")
    func anyPIN() throws {
        for pin in ["111111", "123456", "000000", "250390"] {
            let (vault, _, _) = makeVault()
            let rk = try vault.setUp(pin: secure(pin))
            #expect(bytes(try vault.unlock(pin: secure(pin))) == bytes(rk))
        }
        #expect(PINPolicy.isWellFormed([1, 1, 1, 1, 1, 1]))
        // Digito fora de 0 a 9, ou tamanho diferente de 6, nunca passa.
        #expect(!PINPolicy.isWellFormed([4, 8, 2, 9, 1, 0x2F]))
        #expect(!PINPolicy.isWellFormed([4, 8, 2, 9, 1]))
        let (vault, _, _) = makeVault()
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.setUp(pin: secure("12345a")) }
    }

    @Test("Escada de atraso: o terceiro erro ja espera, e o acerto zera")
    func throttle() throws {
        let (vault, _, _) = makeVault()
        _ = try vault.setUp(pin: secure("482916"))
        _ = try? vault.unlock(pin: secure("000001"))
        _ = try? vault.unlock(pin: secure("000002"))
        #expect(vault.throttleRemaining() == 0)
        _ = try? vault.unlock(pin: secure("000003"))
        #expect(vault.throttleRemaining() > 0)
        // Durante a espera, nem o PIN certo e avaliado.
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlock(pin: secure("482916")) }
        #expect(vault.failureCount() == 3)
    }

    @Test("Prazo de outro boot: ler nao grava, e a espera recomeca cheia ao regravar")
    func rebootRebase() throws {
        let (vault, store, _) = makeVault()
        _ = try vault.setUp(pin: secure("482916"))
        let otherBoot = [UInt8](repeating: 7, count: 16)
        let stale = AttemptRecord(failures: 5, uptimeDeadline: 1, bootSession: otherBoot)
        try store.update(stale.encoded, account: "pin.tentativas")
        #expect(vault.throttleRemaining() == PINPolicy.delay(afterFailures: 5))
        #expect(store.raw("pin.tentativas") == stale.encoded)
        vault.rebaseAttempts()
        let rebasedData = try #require(store.raw("pin.tentativas"))
        let rebased = try #require(AttemptRecord(rebasedData))
        #expect(rebased.failures == 5)
        #expect(rebased.bootSession == PINPolicy.bootSession)
        #expect(vault.throttleRemaining() > 55 && vault.throttleRemaining() <= 60)
    }

    @Test("Registro de tentativas no formato antigo ainda guarda o numero de erros")
    func legacyAttempts() throws {
        var legacy = Data(UInt32(4).bigEndianByteArray)
        legacy.append(Data(count: 24))
        let record = try #require(AttemptRecord(legacy))
        #expect(record.failures == 4)
        #expect(record.isFromAnotherBoot)
        #expect(AttemptRecord(Data(count: 10)) == nil)
    }

    @Test("Apagar apos 10 erros destroi tudo")
    func wipeAfterErrors() throws {
        let (vault, store, wrapper) = makeVault()
        _ = try vault.setUp(pin: secure("482916"))
        try vault.setWipeAfterErrors(10)
        // Encurta o teste gravando nove erros sem espera, como se o tempo tivesse passado.
        try store.update(AttemptRecord(failures: 9, uptimeDeadline: 0, bootSession: PINPolicy.bootSession).encoded, account: "pin.tentativas")
        #expect(throws: RootKeyVault.Failure.wiped) { try vault.unlock(pin: secure("000001")) }
        #expect(!vault.isSetUp)
        #expect(!wrapper.hasKey(.device))
    }

    @Test("Biometria liga, destranca e desliga sem tocar o PIN")
    func biometry() throws {
        let (vault, _, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.enableBiometry(rk: rk)
        #expect(vault.isBiometryEnabled)
        #expect(bytes(try vault.unlockWithBiometry(reason: "teste")) == bytes(rk))
        vault.disableBiometry()
        #expect(!vault.isBiometryEnabled)
        #expect(throws: RootKeyVault.Failure.biometryNotEnabled) { try vault.unlockWithBiometry(reason: "teste") }
        #expect(bytes(try vault.unlock(pin: secure("482916"))) == bytes(rk))
    }

    @Test("Face ID recusado nao apaga o atalho; Face ID aceito nao zera os erros de PIN")
    func biometryFailures() throws {
        let (vault, _, wrapper) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.enableBiometry(rk: rk)
        wrapper.refuseBiometry = true
        #expect(throws: RootKeyVault.Failure.cancelled) { try vault.unlockWithBiometry(reason: "teste") }
        #expect(vault.isBiometryEnabled)

        wrapper.refuseBiometry = false
        _ = try? vault.unlock(pin: secure("000001"))
        _ = try? vault.unlock(pin: secure("000002"))
        #expect(vault.failureCount() == 2)
        _ = try vault.unlockWithBiometry(reason: "teste")
        // Rosto apresentado a forca nao compra chutes de PIN (auditoria 2, B4).
        #expect(vault.failureCount() == 2)

        // A chave do SE sumiu (cadastro de rosto novo): o slot e apagado.
        wrapper.deleteKey(.biometry)
        #expect(throws: RootKeyVault.Failure.biometryChanged) { try vault.unlockWithBiometry(reason: "teste") }
        #expect(!vault.isBiometryEnabled)
    }

    @Test("Depois de reiniciar, o Face ID espera o PIN")
    func pinAfterRestart() throws {
        let (vault, store, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.enableBiometry(rk: rk)
        #expect(vault.pinEnteredThisBoot)
        _ = try vault.unlockWithBiometry(reason: "teste")
        // Simula outro boot: o registro guarda a identidade de um boot anterior.
        try store.update(Data([UInt8](repeating: 9, count: 16)), account: "pin.boot")
        #expect(!vault.pinEnteredThisBoot)
        #expect(throws: RootKeyVault.Failure.pinRequiredAfterRestart) { try vault.unlockWithBiometry(reason: "teste") }
        _ = try vault.unlock(pin: secure("482916"))
        #expect(bytes(try vault.unlockWithBiometry(reason: "teste")) == bytes(rk))
    }

    @Test("Apagar depois de N erros: escolha do dono, e o registro antigo vale 10")
    func wipeChoices() throws {
        let (vault, store, _) = makeVault()
        _ = try vault.setUp(pin: secure("482916"))
        #expect(vault.wipeThreshold == nil)
        try vault.setWipeAfterErrors(5)
        #expect(vault.wipeThreshold == 5)
        #expect(throws: RootKeyVault.Failure.storage) { try vault.setWipeAfterErrors(7) }
        try vault.setWipeAfterErrors(nil)
        #expect(vault.wipeThreshold == nil)
        try store.add(Data([1]), account: "pin.apagar", protection: .standard, context: nil)
        #expect(vault.wipeThreshold == 10)
        try vault.setWipeAfterErrors(5)
        try store.update(AttemptRecord(failures: 4, uptimeDeadline: 0, bootSession: PINPolicy.bootSession).encoded, account: "pin.tentativas")
        #expect(throws: RootKeyVault.Failure.wiped) { try vault.unlock(pin: secure("000001")) }
    }

    @Test("Troca de PIN preserva a RK e aposenta o PIN antigo")
    func changePIN() throws {
        let (vault, store, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.changePIN(rk: rk, newPIN: secure("730584"))
        #expect(bytes(try vault.unlock(pin: secure("730584"))) == bytes(rk))
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlock(pin: secure("482916")) }
        #expect(store.probe("rk.pin.novo") == .absent)
        // PIN facil tambem vale na troca; so a forma e recusada.
        try vault.changePIN(rk: rk, newPIN: secure("111111"))
        #expect(bytes(try vault.unlock(pin: secure("111111"))) == bytes(rk))
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.changePIN(rk: rk, newPIN: secure("1111")) }
    }

    @Test("Troca interrompida antes do ponto sem volta: o PIN antigo desfaz, o novo conclui")
    func interruptedChangeBeforeCommit() throws {
        do {
            let (vault, store, _) = makeVault()
            let rk = try vault.setUp(pin: secure("482916"))
            try vault.writePINSlot(rk: rk, pin: secure("730584"), kdf: fastKDF, suffix: ".novo")
            #expect(bytes(try vault.unlock(pin: secure("482916"))) == bytes(rk))
            #expect(store.probe("rk.pin.novo") == .absent)
            #expect(throws: RootKeyVault.Failure.self) { try vault.unlock(pin: secure("730584")) }
        }
        do {
            let (vault, store, _) = makeVault()
            let rk = try vault.setUp(pin: secure("482916"))
            try vault.writePINSlot(rk: rk, pin: secure("730584"), kdf: fastKDF, suffix: ".novo")
            #expect(bytes(try vault.unlock(pin: secure("730584"))) == bytes(rk))
            #expect(store.probe("rk.pin.novo") == .absent)
            #expect(bytes(try vault.unlock(pin: secure("730584"))) == bytes(rk))
            #expect(throws: RootKeyVault.Failure.self) { try vault.unlock(pin: secure("482916")) }
        }
    }

    @Test("Troca interrompida depois do ponto sem volta: so o PIN novo, e o principal volta")
    func interruptedChangeAfterCommit() throws {
        let (vault, store, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.writePINSlot(rk: rk, pin: secure("730584"), kdf: fastKDF, suffix: ".novo")
        try store.delete("rk.pin")
        try store.delete("pin.kdf")
        #expect(vault.isSetUp)
        // Trocar de novo agora e recusado: o desbloqueio resolve primeiro.
        #expect(throws: RootKeyVault.Failure.storage) { try vault.changePIN(rk: rk, newPIN: secure("594031")) }
        #expect(bytes(try vault.unlock(pin: secure("730584"))) == bytes(rk))
        #expect(store.probe("rk.pin") == .present)
        #expect(store.probe("rk.pin.novo") == .absent)
    }

    @Test("Cadastro: recusa com slot existente, recusa com chaveiro mudo, limpa orfaos")
    func setUpGuards() throws {
        let (vault, store, wrapper) = makeVault()
        _ = try vault.setUp(pin: secure("482916"))
        #expect(throws: RootKeyVault.Failure.alreadySetUp) { try vault.setUp(pin: secure("730584")) }
        #expect(throws: EnclaveError.self) { try wrapper.createKey(.device) }

        let (mute, muteStore, _) = makeVault()
        muteStore.unknown = ["rk.pin"]
        #expect(mute.isSetUp)
        #expect(throws: RootKeyVault.Failure.storage) { try mute.setUp(pin: secure("482916")) }

        // Cadastro interrompido: K_dev e contador sem nenhum slot. O proximo cadastro segue.
        let (orphan, orphanStore, orphanWrapper) = makeVault()
        try orphanWrapper.createKey(.device)
        try orphanStore.add(Data([1]), account: "pin.tentativas", protection: .standard, context: nil)
        #expect(!orphan.isSetUp)
        let rk = try orphan.setUp(pin: secure("482916"))
        #expect(bytes(try orphan.unlock(pin: secure("482916"))) == bytes(rk))
        _ = store
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
