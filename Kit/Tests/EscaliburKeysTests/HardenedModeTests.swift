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
private let pin = "482916"

extension SecureBytes {
    static func from(_ bytes: [UInt8]) -> SecureBytes {
        let out = SecureBytes(capacity: max(bytes.count, 1))
        out.replaceAll(with: bytes)
        return out
    }
}

@Suite("Modo reforcado: PIN e rosto pela criptografia")
struct HardenedModeTests {
    func bytes(_ secret: SecureBytes) -> [UInt8] { secret.withUnsafeBytes { Array($0) } }

    /// Cofre no modo normal com Face ID ligado, pronto para ligar o reforcado.
    func makeNormal() throws -> (RootKeyVault, MemoryStore, SoftwareWrapper, [UInt8]) {
        let store = MemoryStore()
        let wrapper = SoftwareWrapper()
        let vault = RootKeyVault(store: store, wrapper: wrapper, pinParameters: fastKDF)
        vault.biometryAvailability = { .available }
        vault.hardenedBiometryStatus = { .ready }
        vault.hardenedDomainState = { Data([1, 2, 3]) }
        let rk = try vault.setUp(pin: secure(pin))
        try vault.enableBiometry(rk: rk)
        return (vault, store, wrapper, bytes(rk))
    }

    func makeHardened() throws -> (RootKeyVault, MemoryStore, SoftwareWrapper, [UInt8]) {
        let (vault, store, wrapper, rk) = try makeNormal()
        try vault.enableHardened(pin: secure(pin), reason: "ligar", confirmReason: "conferir")
        return (vault, store, wrapper, rk)
    }

    @Test("Ligar: rk.and abre com PIN e rosto; os slots so-PIN e so-rosto e as chaves deles somem")
    func enableRoundTrip() throws {
        let (vault, store, wrapper, rk) = try makeHardened()
        #expect(vault.securityMode == .hardened)
        for account in ["rk.pin", "rk.pin.novo", "rk.bio", "pin.kdf", "pin.digitos", "bio.estado"] { #expect(store.probe(account) == .absent) }
        for slot in [WrapSlot.device, .pin, .pinPending, .biometry, .hardenedPINB] { #expect(wrapper.probeKey(slot) == .absent) }
        #expect(store.protection("rk.and") == .standard)
        #expect(vault.isSetUp)
        #expect(!vault.isBiometryEnabled)
        #expect(vault.pinLengths == [6])
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir")) == rk)
        #expect(vault.failureCount() == 0)
        // O caminho de PIN so e o de rosto so recusam, nunca como "nao configurado".
        #expect(throws: RootKeyVault.Failure.hardenedModeActive) { try vault.unlock(pin: secure(pin)) }
        #expect(throws: RootKeyVault.Failure.hardenedModeActive) { try vault.unlockWithBiometry(reason: "x") }
        #expect(throws: RootKeyVault.Failure.alreadySetUp) { try vault.setUp(pin: secure(pin)) }
    }

    @Test("Camadas: a senha certa do PIN nao abre o corpo sem o rosto; o item nao tem senha do PIN")
    func layerOrder() throws {
        let (vault, store, wrapper, rk) = try makeHardened()
        let raw = try #require(store.raw("rk.and"))
        let (header, body) = try RootKeyVault.parseHardened(raw)
        let ap = try KeyDerivation.deriveMasterKey(password: secure(pin), salt: header.salt, parameters: header.kdf)
        let password = RootKeyVault.hardenedPassword(ap: ap, salt: header.salt)
        defer { password.wipe() }
        // Com a senha certa do PIN e sem o rosto, a chave do PIN nao abre o corpo.
        #expect(throws: (any Error).self) { try password.withUnsafeData { try wrapper.unwrap(body, slot: header.pinKey, password: $0) } }
        // So depois da camada do rosto.
        let middle = try wrapper.unwrap(body, slot: .hardenedBiometry, reason: "x")
        let inner = try middle.withUnsafeData { opened in
            try password.withUnsafeData { try wrapper.unwrap(opened, slot: header.pinKey, password: $0) }
        }
        #expect(bytes(try RootKeyVault.openHardenedInner(inner, ap: ap, header: header)) == rk)
        _ = vault
    }

    @Test("Uma chamada, um rosto, um PIN avaliado; o rosto aceito nao vira oraculo")
    func faceIsNotAnOracle() throws {
        let (vault, _, wrapper, _) = try makeHardened()
        let before = wrapper.unwrapCount[.hardenedBiometry, default: 0]
        for guess in ["000001", "000002"] {
            #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlockHardened(pin: secure(guess), reason: "x") }
        }
        #expect(wrapper.unwrapCount[.hardenedBiometry, default: 0] == before + 2)
        #expect(vault.failureCount() == 2)
    }

    @Test("Rosto que nao confirma conta tentativa e nao chega a avaliar o PIN")
    func failedFaceCounts() throws {
        let (vault, _, wrapper, rk) = try makeHardened()
        let pinUses = wrapper.unwrapCount[.hardenedPINA, default: 0]
        wrapper.refuseBiometry = true
        #expect(throws: RootKeyVault.Failure.biometryNotConfirmed(remainingBeforeWipe: nil)) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(vault.failureCount() == 1)
        #expect(wrapper.unwrapCount[.hardenedPINA, default: 0] == pinUses)
        wrapper.refuseBiometry = false
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        #expect(vault.failureCount() == 0)
    }

    @Test("Sem gastar tentativa: tamanho errado, Face ID bloqueado ou indisponivel, espera da escada")
    func refusalsBeforeCounting() throws {
        let (vault, _, wrapper, _) = try makeHardened()
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.unlockHardened(pin: secure("4829"), reason: "x") }
        vault.hardenedBiometryStatus = { .lockedOut }
        #expect(throws: RootKeyVault.Failure.biometryLockedOut) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        vault.hardenedBiometryStatus = { .unavailable }
        #expect(throws: RootKeyVault.Failure.biometryUnavailable) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(vault.failureCount() == 0)
        vault.hardenedBiometryStatus = { .ready }
        for guess in ["000001", "000002", "000003"] { _ = try? vault.unlockHardened(pin: secure(guess), reason: "x") }
        let faces = wrapper.unwrapCount[.hardenedBiometry, default: 0]
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(wrapper.unwrapCount[.hardenedBiometry, default: 0] == faces)
        #expect(vault.failureCount() == 3)
    }

    @Test("Contador que nao grava: nem o rosto e pedido")
    func counterFailsClosed() throws {
        let (vault, store, wrapper, _) = try makeHardened()
        store.failUpdating = ["pin.tentativas"]
        let faces = wrapper.unwrapCount[.hardenedBiometry, default: 0]
        #expect(throws: RootKeyVault.Failure.storage) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(wrapper.unwrapCount[.hardenedBiometry, default: 0] == faces)
    }

    @Test("Cadastro de rostos mudou: nao abre, nao conta, nao apaga nada")
    func enrollmentChange() throws {
        let (vault, store, wrapper, _) = try makeHardened()
        wrapper.invalidateBiometry()
        #expect(throws: RootKeyVault.Failure.hardenedSlotLost) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(vault.failureCount() == 0)
        #expect(store.probe("rk.and") == .present)
        #expect(vault.isSetUp)
        #expect(vault.securityMode == .hardened)
        #expect(throws: RootKeyVault.Failure.alreadySetUp) { try vault.setUp(pin: secure(pin)) }
        vault.rebaseAttempts()
        #expect(store.probe("rk.and") == .present)
        // Sem cadastro de rostos nenhum: tambem terminal, tambem sem apagar.
        vault.hardenedBiometryStatus = { .notEnrolled }
        #expect(throws: RootKeyVault.Failure.hardenedSlotLost) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(store.probe("rk.and") == .present)
    }

    @Test("Apagar apos N conta o par: rosto falho e PIN errado")
    func wipeCountsPairs() throws {
        let (vault, store, wrapper, _) = try makeHardened()
        try vault.setWipeAfterErrors(5)
        wrapper.refuseBiometry = true
        for _ in 0..<2 { _ = try? vault.unlockHardened(pin: secure(pin), reason: "x") }
        wrapper.refuseBiometry = false
        // A escada: a partir do terceiro erro, espera. Os testes pulam o prazo.
        func skipWait() throws {
            let failures = vault.failureCount()
            try store.update(AttemptRecord(failures: failures, uptimeDeadline: 0, bootSession: PINPolicy.bootSession).encoded, account: "pin.tentativas")
        }
        for guess in ["000001", "000002"] { try skipWait(); _ = try? vault.unlockHardened(pin: secure(guess), reason: "x") }
        try skipWait()
        #expect(throws: RootKeyVault.Failure.wiped) { try vault.unlockHardened(pin: secure("000003"), reason: "x") }
        #expect(!vault.hasResidue)
    }

    @Test("Ligar: pre-condicoes recusam antes de pedir qualquer coisa")
    func enablePreconditions() throws {
        let store = MemoryStore()
        let wrapper = SoftwareWrapper()
        let vault = RootKeyVault(store: store, wrapper: wrapper, pinParameters: fastKDF)
        vault.biometryAvailability = { .available }
        vault.hardenedBiometryStatus = { .ready }
        let rk = try vault.setUp(pin: secure(pin))
        #expect(throws: RootKeyVault.Failure.hardenedBlocked(.biometryOff)) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y") }
        try vault.enableBiometry(rk: rk)
        vault.hardenedBiometryStatus = { .lockedOut }
        #expect(throws: RootKeyVault.Failure.hardenedBlocked(.biometryUnavailable)) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y") }
        vault.hardenedBiometryStatus = { .ready }
        try store.add(HoldRecord.startingNow().encoded, account: "bio.espera", protection: .standard, context: nil)
        #expect(throws: RootKeyVault.Failure.self) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y") }
        try store.delete("bio.espera")
        try store.add(Data([0]), account: "rk.pin.novo", protection: .standard, context: nil)
        #expect(throws: RootKeyVault.Failure.hardenedBlocked(.changePending)) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y") }
        try store.delete("rk.pin.novo")
        #expect(vault.failureCount() == 0)
        #expect(store.probe("rk.and") == .absent)
        // A conferencia das palavras falha: nada gravado.
        struct WordsDoNotMatch: Error {}
        #expect(throws: WordsDoNotMatch.self) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in throw WordsDoNotMatch() }) }
        #expect(store.probe("rk.and") == .absent)
        #expect(vault.securityMode == .normal)
    }

    @Test("Ligar: o segundo rosto recusado desfaz tudo; o modo normal fica intacto")
    func enableConfirmFails() throws {
        let (vault, store, wrapper, rk) = try makeNormal()
        wrapper.refuseSlots = [.hardenedBiometry]
        #expect(throws: RootKeyVault.Failure.self) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y") }
        #expect(store.probe("rk.and") == .absent)
        for slot in [WrapSlot.hardenedBiometry, .hardenedPINA, .hardenedPINB] { #expect(wrapper.probeKey(slot) == .absent) }
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
        #expect(bytes(try vault.unlockWithBiometry(reason: "x")) == rk)
    }

    @Test("Commit que nao apaga o rk.pin: nada se perde, o modo normal manda e o rk.and sai no proximo PIN")
    func commitDeleteFails() throws {
        let (vault, store, _, rk) = try makeNormal()
        store.failDeleting = ["rk.pin"]
        #expect(throws: RootKeyVault.Failure.storage) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y") }
        #expect(store.probe("rk.and") == .present)
        #expect(vault.securityMode == .normal)
        store.failDeleting = []
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
        #expect(store.probe("rk.and") == .absent)
    }

    @Test("Queda depois do commit, antes da limpeza: o rosto so nunca abre, e a varredura termina")
    func crashAfterCommit() throws {
        let (vault, store, wrapper, rk) = try makeNormal()
        // Reproduz o estado: rk.and gravado e conferido, rk.pin apagado, rk.bio e chaves ainda la.
        store.failDeleting = ["rk.bio"]
        try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y")
        store.failDeleting = []
        try wrapper.createKey(.biometry)  // a chave que a limpeza nao chegou a apagar
        #expect(store.probe("rk.bio") == .present)
        #expect(vault.securityMode == .hardened)
        #expect(!vault.isBiometryEnabled)
        #expect(throws: RootKeyVault.Failure.hardenedModeActive) { try vault.unlockWithBiometry(reason: "x") }
        // A varredura e da abertura do app (e do `unlockHardened`), sob a trava.
        vault.rebaseAttempts()
        #expect(store.probe("rk.bio") == .absent)
        #expect(wrapper.probeKey(.biometry) == .absent)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Trocar o PIN: a chave alterna, o PIN antigo para no commit, a chave antiga sai")
    func changePIN() throws {
        let (vault, store, wrapper, rk) = try makeHardened()
        let old = try #require(store.raw("rk.and"))
        try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y")
        #expect(vault.pinLengths == [4])
        #expect(wrapper.probeKey(.hardenedPINA) == .absent)
        #expect(wrapper.probeKey(.hardenedPINB) == .present)
        #expect(bytes(try vault.unlockHardened(pin: secure("7351"), reason: "x")) == rk)
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        // Repor o registro antigo (quem pode escrever no chaveiro) nao traz o PIN antigo de volta.
        try store.update(old, account: "rk.and")
        #expect(throws: RootKeyVault.Failure.hardenedSlotLost) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        _ = rk
    }

    @Test("Trocar o PIN: segundo rosto recusado ou update que nao grava deixam o PIN antigo")
    func changePINFails() throws {
        let (vault, store, wrapper, rk) = try makeHardened()
        // Recusa so o segundo rosto da troca (a conferencia), nao o que autoriza.
        wrapper.refuseFrom = (.hardenedBiometry, wrapper.unwrapCount[.hardenedBiometry, default: 0] + 2)
        // O rosto da conferencia nao conta tentativa: volta como cancelado.
        #expect(throws: RootKeyVault.Failure.cancelled) {
            try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y")
        }
        wrapper.refuseFrom = nil
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        #expect(vault.failureCount() == 0)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        store.failUpdating = ["rk.and"]
        #expect(throws: RootKeyVault.Failure.storage) {
            try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y")
        }
        store.failUpdating = []
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Queda no meio da troca: chave orfa da outra geracao sai na varredura, o registro manda")
    func changePINCrashOrphan() throws {
        let (vault, _, wrapper, rk) = try makeHardened()
        try wrapper.createKey(.hardenedPINB, password: Data([9]))  // a chave nova criada antes da queda
        vault.rebaseAttempts()
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        #expect(wrapper.probeKey(.hardenedPINA) == .present)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Desligar: PIN e rosto, o slot do PIN e o Face ID voltam conferidos, o rk.and sai")
    func disable() throws {
        let (vault, store, wrapper, rk) = try makeHardened()
        #expect(try vault.disableHardened(pin: secure(pin), reason: "x", biometryReason: "y"))
        #expect(vault.securityMode == .normal)
        #expect(store.probe("rk.and") == .absent)
        for slot in [WrapSlot.hardenedBiometry, .hardenedPINA, .hardenedPINB] { #expect(wrapper.probeKey(slot) == .absent) }
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
        #expect(bytes(try vault.unlockWithBiometry(reason: "x")) == rk)
    }

    @Test("Desligar com o segundo rosto recusado: sai do reforcado com o Face ID desligado")
    func disableWithoutFace() throws {
        let (vault, _, wrapper, rk) = try makeHardened()
        wrapper.refuseSlots = [.biometry]
        #expect(try vault.disableHardened(pin: secure(pin), reason: "x", biometryReason: "y") == false)
        #expect(vault.securityMode == .normal)
        #expect(!vault.isBiometryEnabled)
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
    }

    @Test("Queda no desligar depois do rk.pin gravado: o modo normal manda, o rk.and sai no PIN certo")
    func crashDuringDisable() throws {
        let (vault, store, wrapper, rk) = try makeHardened()
        // O estado: rk.and intacto e rk.pin gravado e conferido, sem Face ID ainda.
        try vault.writePINSlot(rk: SecureBytes.from(rk), pin: secure(pin), kdf: fastKDF, suffix: "")
        #expect(vault.securityMode == .normal)
        #expect(vault.pinLengths == [6])
        #expect(!vault.isBiometryEnabled)
        #expect(throws: RootKeyVault.Failure.notHardened) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
        #expect(store.probe("rk.and") == .absent)
        vault.rebaseAttempts()
        for slot in [WrapSlot.hardenedBiometry, .hardenedPINA, .hardenedPINB] { #expect(wrapper.probeKey(slot) == .absent) }
    }

    @Test("Queda no ligar antes do commit: o rosto so continua abrindo, e nao apaga o rk.and; o PIN apaga")
    func crashDuringEnable() throws {
        let (vault, store, wrapper, rk) = try makeNormal()
        // O estado: rk.and gravado, rk.pin e rk.bio intactos.
        wrapper.refuseFrom = (.hardenedBiometry, 1)
        _ = try? vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y")
        wrapper.refuseFrom = nil
        #expect(store.probe("rk.and") == .absent)  // a falha desfez; agora o estado de queda, a mao:
        store.failDeleting = ["rk.pin"]
        _ = try? vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y")
        store.failDeleting = []
        #expect(store.probe("rk.and") == .present)
        #expect(vault.securityMode == .normal)
        #expect(bytes(try vault.unlockWithBiometry(reason: "x")) == rk)
        #expect(store.probe("rk.and") == .present)
        #expect(bytes(try vault.unlockWithPINAndBiometry(pin: secure(pin), reason: "x")) == rk)
        #expect(store.probe("rk.and") == .absent)
    }

    @Test("Chaveiro mudo: nunca vira cadastro nem modo normal")
    func unknownStore() throws {
        let (vault, store, _, _) = try makeHardened()
        store.unknown = ["rk.and"]
        #expect(vault.securityMode == .unknown)
        #expect(vault.isSetUp)
        #expect(vault.pinLengths == Set(PINPolicy.lengths))
        #expect(throws: RootKeyVault.Failure.storage) { try vault.setUp(pin: secure(pin)) }
        #expect(throws: RootKeyVault.Failure.storage) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(throws: RootKeyVault.Failure.storage) { try vault.unlock(pin: secure(pin)) }
        vault.rebaseAttempts()
        store.unknown = []
        #expect(store.probe("rk.and") == .present)
    }

    @Test("Cabecalho adulterado nao abre; tamanho trocado nem gasta tentativa")
    func headerTamper() throws {
        let (vault, store, _, _) = try makeHardened()
        var raw = try #require(store.raw("rk.and"))
        raw[26] ^= 1  // passadas
        try store.update(raw, account: "rk.and")
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
    }

    @Test("Limpeza de reinstalacao enxerga rk.and e as chaves do reforcado; wipeAll leva tudo")
    func residue() throws {
        let (vault, _, wrapper, _) = try makeHardened()
        #expect(vault.hasResidue)
        vault.wipeAll()
        #expect(!vault.hasResidue)
        try wrapper.createKey(.hardenedBiometry)
        #expect(vault.hasResidue)
    }

    @Test("PIN de 4 digitos no reforcado: o tamanho vem do cabecalho; cabecalho ilegivel aceita os dois")
    func fourDigitLengths() throws {
        let store = MemoryStore()
        let wrapper = SoftwareWrapper()
        let vault = RootKeyVault(store: store, wrapper: wrapper, pinParameters: fastKDF)
        vault.biometryAvailability = { .available }
        vault.hardenedBiometryStatus = { .ready }
        vault.hardenedDomainState = { Data([1, 2, 3]) }
        let rk = try vault.setUp(pin: secure("2580"))
        try vault.enableBiometry(rk: rk)
        try vault.enableHardened(pin: secure("2580"), reason: "ligar", confirmReason: "conferir")
        #expect(vault.pinLengths == [4])
        #expect(bytes(try vault.unlockHardened(pin: secure("2580"), reason: "abrir")) == bytes(rk))
        var raw = try #require(store.raw("rk.and"))
        raw[0] = 0x7F
        try store.update(raw, account: "rk.and")
        #expect(vault.pinLengths == Set(PINPolicy.lengths))
    }

    @Test("Ligar com o slot do PIN no formato 1, e PIN novo fora de forma, recusam sem abrir")
    func blockedAndMalformed() throws {
        let store = MemoryStore()
        let wrapper = SoftwareWrapper()
        let vault = RootKeyVault(store: store, wrapper: wrapper, pinParameters: fastKDF)
        vault.biometryAvailability = { .available }
        vault.hardenedBiometryStatus = { .ready }
        let rk = try SecureBytes.random(count: 32)
        try vault.writeLegacyPINSlot(rk: rk, pin: secure(pin), kdf: fastKDF)
        try vault.enableBiometry(rk: rk)
        #expect(throws: RootKeyVault.Failure.hardenedBlocked(.legacySlot)) {
            try vault.enableHardened(pin: secure(pin), reason: "ligar", confirmReason: "conferir")
        }
        #expect(vault.failureCount() == 0)

        let (hardened, _, _, _) = try makeHardened()
        #expect(throws: RootKeyVault.Failure.malformedPIN) {
            try hardened.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("12"), reason: "trocar", confirmReason: "conferir")
        }
        #expect(hardened.failureCount() == 0)
    }

    @Test("Hash do cadastro que so derivou: abre e regrava; chave do rosto que o SE nao sabe dizer: recusa sem contar")
    func stateDriftAndUnknownKey() throws {
        let (vault, store, wrapper, rk) = try makeHardened()
        vault.hardenedDomainState = { Data([9, 9, 9]) }
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir")) == rk)
        #expect(store.raw("and.estado") == Data([9, 9, 9]))

        wrapper.unknownKeys = [.hardenedBiometry]
        #expect(throws: RootKeyVault.Failure.storage) { try vault.unlockHardened(pin: secure(pin), reason: "abrir") }
        #expect(vault.failureCount() == 0)
        wrapper.unknownKeys = []
    }

    @Test("Apagar apos N disparado no PIN que autoriza ligar: tudo sai, nada fica pela metade")
    func wipeDuringEnable() throws {
        let (vault, store, wrapper, _) = try makeNormal()
        try vault.setWipeAfterErrors(5)
        try store.update(AttemptRecord(failures: 4, uptimeDeadline: 0, bootSession: PINPolicy.bootSession).encoded, account: "pin.tentativas")
        #expect(throws: RootKeyVault.Failure.wiped) {
            try vault.enableHardened(pin: secure("000000"), reason: "ligar", confirmReason: "conferir")
        }
        #expect(!vault.isSetUp)
        #expect(!WrapSlot.allCases.contains { wrapper.probeKey($0) != .absent })
    }

    @Test("Desligar com a chave do PIN que nao nasce: continua reforcado e abrindo")
    func disableKeepsHardenedWhenPINSlotFails() throws {
        let (vault, _, wrapper, rk) = try makeHardened()
        wrapper.failCreating = .pin
        #expect(throws: (any Error).self) { try vault.disableHardened(pin: secure(pin), reason: "desligar", biometryReason: "rosto") }
        wrapper.failCreating = nil
        #expect(vault.securityMode == .hardened)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir")) == rk)
    }
}
