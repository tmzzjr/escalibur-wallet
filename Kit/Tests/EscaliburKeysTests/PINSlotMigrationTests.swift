import CryptoKit
import Foundation
import Testing
@testable import EscaliburCore
@testable import EscaliburKeys

private func secure(_ text: String) -> SecureBytes {
    let bytes = SecureBytes(capacity: max(text.utf8.count, 1))
    bytes.replaceAll(with: Array(text.utf8))
    return bytes
}

private let fastKDF = KDFParameters(memoryKiB: 64 * 1024, passes: 2, lanes: 1)

/// Formato 2 do slot do PIN (auditoria 3, A1): a chave do SE so desembrulha com a senha
/// derivada do PIN; o formato 1 migra no primeiro PIN certo, sem nunca deixar o dono
/// sem um slot que abre.
@Suite("Slot do PIN com senha no Secure Enclave")
struct PINSlotMigrationTests {
    func makeVault() -> (RootKeyVault, MemoryStore, SoftwareWrapper) {
        let store = MemoryStore()
        let wrapper = SoftwareWrapper()
        return (RootKeyVault(store: store, wrapper: wrapper, pinParameters: fastKDF), store, wrapper)
    }

    func bytes(_ secret: SecureBytes) -> [UInt8] { secret.withUnsafeBytes { Array($0) } }

    @Test("Cadastro novo ja nasce no formato 2, sem a chave antiga do aparelho")
    func newSetUp() throws {
        let (vault, _, wrapper) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        #expect(vault.slotVersion(suffix: "") == 2)
        #expect(wrapper.hasKey(.pin) && !wrapper.hasKey(.device) && !wrapper.hasKey(.pinPending))
        #expect(wrapper.password(.pin) != nil)
        #expect(bytes(try vault.unlock(pin: secure("482916"))) == bytes(rk))
    }

    @Test("O SE recusa a senha de um PIN errado, mesmo com o chaveiro e a camada interna fora do caminho")
    func enclaveRefusesWrongPIN() throws {
        let (vault, store, _) = makeVault()
        _ = try vault.setUp(pin: secure("482916"))
        store.enforcesApplicationPassword = false
        #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlock(pin: secure("111111")) }
    }

    @Test("Formato 1 migra no primeiro PIN certo: abre igual, a chave antiga sai")
    func migration() throws {
        let (vault, store, wrapper) = makeVault()
        let rk = try SecureBytes.random(count: 32)
        try vault.writeLegacyPINSlot(rk: rk, pin: secure("482916"), kdf: fastKDF)
        #expect(vault.slotVersion(suffix: "") == 1 && wrapper.hasKey(.device))

        #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlock(pin: secure("000000")) }
        #expect(vault.slotVersion(suffix: "") == 1, "PIN errado nao migra nada")

        #expect(bytes(try vault.unlock(pin: secure("482916"))) == bytes(rk))
        #expect(vault.slotVersion(suffix: "") == 2)
        #expect(!wrapper.hasKey(.device) && wrapper.hasKey(.pin) && !wrapper.hasKey(.pinPending))
        #expect(store.probe("rk.pin.novo") == .absent)
        #expect(bytes(try vault.unlock(pin: secure("482916"))) == bytes(rk))
        #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlock(pin: secure("482917")) }
    }

    @Test("Migracao interrompida (o SE nao cria a chave nova): o slot antigo continua abrindo")
    func interruptedMigration() throws {
        let (vault, _, wrapper) = makeVault()
        let rk = try SecureBytes.random(count: 32)
        try vault.writeLegacyPINSlot(rk: rk, pin: secure("482916"), kdf: fastKDF)
        wrapper.failCreating = .pinPending
        #expect(bytes(try vault.unlock(pin: secure("482916"))) == bytes(rk))
        #expect(vault.slotVersion(suffix: "") == 1 && wrapper.hasKey(.device))
        // Na proxima abertura, com o SE normal, a migracao acontece.
        wrapper.failCreating = nil
        #expect(bytes(try vault.unlock(pin: secure("482916"))) == bytes(rk))
        #expect(vault.slotVersion(suffix: "") == 2 && !wrapper.hasKey(.device))
    }

    @Test("Troca de PIN no formato 2: a chave do SE e trocada junto, o PIN antigo nao abre mais")
    func changePIN() throws {
        let (vault, _, wrapper) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        let before = wrapper.password(.pin)
        try vault.changePIN(rk: rk, newPIN: secure("135790"))
        #expect(wrapper.password(.pin) != before)
        #expect(!wrapper.hasKey(.pinPending))
        #expect(bytes(try vault.unlock(pin: secure("135790"))) == bytes(rk))
        #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlock(pin: secure("482916")) }
    }

    @Test("Apagar tudo leva as chaves do PIN no SE")
    func wipe() throws {
        let (vault, _, wrapper) = makeVault()
        _ = try vault.setUp(pin: secure("482916"))
        vault.wipeAll()
        #expect(!wrapper.hasKey(.pin) && !wrapper.hasKey(.pinPending) && !wrapper.hasKey(.device))
    }
}
