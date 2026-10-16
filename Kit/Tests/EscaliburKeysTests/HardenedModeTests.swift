import CryptoKit
import Foundation
import Security
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
/// O hash do cadastro de rostos do dono, e o de um cadastro trocado.
private let ownerFace = Data([1, 2, 3])
private let newFace = Data([4, 5, 6])

typealias Policy = RootKeyVault.HardenedFaceChange

extension SecureBytes {
    static func from(_ bytes: [UInt8]) -> SecureBytes {
        let out = SecureBytes(capacity: max(bytes.count, 1))
        out.replaceAll(with: bytes)
        return out
    }
}

/// Uma troca de politica, para os testes que valem em cada direcao.
struct Transition: Sendable, CustomStringConvertible {
    let from: Policy
    let to: Policy
    var description: String { "\(from) -> \(to)" }

    static let all: [Transition] = Policy.allCases.flatMap { from in Policy.allCases.filter { $0 != from }.map { Transition(from: from, to: $0) } }
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
        vault.hardenedDomainState = { ownerFace }
        let rk = try vault.setUp(pin: secure(pin))
        try vault.enableBiometry(rk: rk)
        return (vault, store, wrapper, bytes(rk))
    }

    func makeHardened(_ policy: Policy = .continue) throws -> (RootKeyVault, MemoryStore, SoftwareWrapper, [UInt8]) {
        let (vault, store, wrapper, rk) = try makeNormal()
        try vault.enableHardened(pin: secure(pin), reason: "ligar", confirmReason: "conferir", faceChange: policy, check: { _ in })
        return (vault, store, wrapper, rk)
    }

    /// O cadastro de rostos mudou: as chaves `.biometryCurrentSet` morrem e o hash e outro. A
    /// `kand.qualquer` continua.
    func changeEnrollment(_ vault: RootKeyVault, _ wrapper: SoftwareWrapper, to state: Data = newFace) {
        wrapper.invalidateBiometry()
        vault.hardenedDomainState = { state }
    }

    /// A espera do `.wait` gravada vencida, para o cadastro `state`.
    func expireHold(_ store: MemoryStore, state: Data = newFace) throws {
        let expired = HardenedHold(hold: HoldRecord(uptimeDeadline: PINPolicy.uptime - 1, bootSession: PINPolicy.bootSession), state: state)
        try store.update(expired.encoded, account: "and.espera")
    }

    /// A espera do `.wait` como esta gravada.
    func savedHold(_ store: MemoryStore) -> HardenedHold? { store.raw("and.espera").flatMap { HardenedHold($0) } }

    func expectKeys(_ wrapper: SoftwareWrapper, for policy: Policy) {
        for slot in [WrapSlot.hardenedBiometry, .hardenedBiometryAny] {
            #expect(wrapper.probeKey(slot) == (policy.layers.contains(slot) ? .present : .absent), "\(slot) em \(policy)")
        }
    }

    // MARK: As tres politicas

    @Test("Ligar: rk.and abre com PIN e rosto; os slots so-PIN e so-rosto e as chaves deles somem", arguments: Policy.allCases)
    func enableRoundTrip(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        #expect(vault.securityMode == .hardened)
        #expect(vault.hardenedFaceChange == policy)
        for account in ["rk.pin", "rk.pin.novo", "rk.bio", "pin.kdf", "pin.digitos", "bio.estado", "and.espera"] { #expect(store.probe(account) == .absent) }
        for slot in [WrapSlot.device, .pin, .pinPending, .biometry, .hardenedPINB] { #expect(wrapper.probeKey(slot) == .absent) }
        expectKeys(wrapper, for: policy)
        #expect(store.protection("rk.and") == .standard)
        let raw = try #require(store.raw("rk.and"))
        #expect(raw[0] == 4)
        #expect(raw[3] == policy.layerCode)
        #expect(vault.isSetUp)
        #expect(!vault.isBiometryEnabled)
        #expect(vault.pinLengths == [6])
        #expect(vault.hardenedHoldRemaining == 0)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir")) == rk)
        #expect(vault.failureCount() == 0)
        // O caminho de PIN so e o de rosto so recusam, nunca como "nao configurado".
        #expect(throws: RootKeyVault.Failure.hardenedModeActive) { try vault.unlock(pin: secure(pin)) }
        #expect(throws: RootKeyVault.Failure.hardenedModeActive) { try vault.unlockWithBiometry(reason: "x") }
        #expect(throws: RootKeyVault.Failure.alreadySetUp) { try vault.setUp(pin: secure(pin)) }
    }

    @Test("Ligar sem dizer a politica: Continuar normal")
    func defaultPolicy() throws {
        let (vault, _, wrapper, _) = try makeNormal()
        try vault.enableHardened(pin: secure(pin), reason: "ligar", confirmReason: "conferir", check: { _ in })
        #expect(vault.hardenedFaceChange == .continue)
        #expect(wrapper.probeKey(.hardenedBiometry) == .absent)
    }

    @Test("Camadas: a senha certa do PIN nao abre o corpo sem o rosto; cada camada guarda o mesmo miolo", arguments: Policy.allCases)
    func layerOrder(policy: Policy) throws {
        let (_, store, wrapper, rk) = try makeHardened(policy)
        let record = try HardenedRecord.parse(try #require(store.raw("rk.and")))
        let header = record.header
        #expect(Set(record.layers.keys) == Set(policy.layers))
        let ap = try KeyDerivation.deriveMasterKey(password: secure(pin), salt: header.salt, parameters: header.kdf)
        let password = RootKeyVault.hardenedPassword(ap: ap, salt: header.salt)
        defer { password.wipe() }
        var middles: [[UInt8]] = []
        for (slot, layer) in record.layers {
            // Com a senha certa do PIN e sem o rosto, a chave do PIN nao abre o corpo.
            #expect(throws: (any Error).self) { try password.withUnsafeData { try wrapper.unwrap(layer, slot: header.pinKey, password: $0) } }
            middles.append(bytes(try wrapper.unwrap(layer, slot: slot, reason: "x")))
        }
        #expect(Set(middles.map { Data($0) }).count == 1)
        let middle = SecureBytes.from(middles[0])
        let inner = try middle.withUnsafeData { opened in
            try password.withUnsafeData { try wrapper.unwrap(opened, slot: header.pinKey, password: $0) }
        }
        #expect(bytes(try RootKeyVault.openHardenedInner(inner, ap: ap, header: header)) == rk)
    }

    @Test("Uma chamada, um rosto, um PIN avaliado; o rosto aceito nao vira oraculo", arguments: Policy.allCases)
    func faceIsNotAnOracle(policy: Policy) throws {
        let (vault, _, wrapper, _) = try makeHardened(policy)
        let before = wrapper.faces
        for guess in ["000001", "000002"] {
            #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlockHardened(pin: secure(guess), reason: "x") }
        }
        #expect(wrapper.faces == before + 2)
        #expect(vault.failureCount() == 2)
    }

    @Test("Rosto que nao confirma conta tentativa e nao chega a avaliar o PIN", arguments: Policy.allCases)
    func failedFaceCounts(policy: Policy) throws {
        let (vault, _, wrapper, rk) = try makeHardened(policy)
        let pinUses = wrapper.unwrapCount[.hardenedPINA, default: 0]
        wrapper.refuseBiometry = true
        #expect(throws: RootKeyVault.Failure.biometryNotConfirmed(remainingBeforeWipe: nil)) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(vault.failureCount() == 1)
        #expect(wrapper.unwrapCount[.hardenedPINA, default: 0] == pinUses)
        wrapper.refuseBiometry = false
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        #expect(vault.failureCount() == 0)
    }

    @Test("Sem gastar tentativa: tamanho errado, Face ID bloqueado ou indisponivel, espera da escada", arguments: Policy.allCases)
    func refusalsBeforeCounting(policy: Policy) throws {
        let (vault, _, wrapper, _) = try makeHardened(policy)
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.unlockHardened(pin: secure("4829"), reason: "x") }
        vault.hardenedBiometryStatus = { .lockedOut }
        #expect(throws: RootKeyVault.Failure.biometryLockedOut) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        vault.hardenedBiometryStatus = { .unavailable }
        #expect(throws: RootKeyVault.Failure.biometryUnavailable) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(vault.failureCount() == 0)
        vault.hardenedBiometryStatus = { .ready }
        for guess in ["000001", "000002", "000003"] { _ = try? vault.unlockHardened(pin: secure(guess), reason: "x") }
        let faces = wrapper.faces
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(wrapper.faces == faces)
        #expect(vault.failureCount() == 3)
    }

    @Test("Sem rosto cadastrado: na trava o cofre se perde; nas outras recusa sem contar e sem apagar", arguments: Policy.allCases)
    func notEnrolled(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        vault.hardenedBiometryStatus = { .notEnrolled }
        let expected: RootKeyVault.Failure = policy == .lock ? .hardenedSlotLost : .biometryNotEnrolled
        #expect(throws: expected) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(vault.failureCount() == 0)
        #expect(store.probe("rk.and") == .present)
        vault.rebaseAttempts()
        expectKeys(wrapper, for: policy)
        vault.hardenedBiometryStatus = { .ready }
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Contador que nao grava: nem o rosto e pedido", arguments: Policy.allCases)
    func counterFailsClosed(policy: Policy) throws {
        let (vault, store, wrapper, _) = try makeHardened(policy)
        store.failUpdating = ["pin.tentativas"]
        let faces = wrapper.faces
        #expect(throws: RootKeyVault.Failure.storage) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(wrapper.faces == faces)
    }

    @Test("Apagar apos N conta o par: rosto falho e PIN errado", arguments: Policy.allCases)
    func wipeCountsPairs(policy: Policy) throws {
        let (vault, store, wrapper, _) = try makeHardened(policy)
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
        #expect(throws: RootKeyVault.Failure.hardenedBlocked(.biometryOff)) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in }) }
        try vault.enableBiometry(rk: rk)
        vault.hardenedBiometryStatus = { .lockedOut }
        #expect(throws: RootKeyVault.Failure.hardenedBlocked(.biometryUnavailable)) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in }) }
        vault.hardenedBiometryStatus = { .ready }
        try store.add(HoldRecord.startingNow().encoded, account: "bio.espera", protection: .standard, context: nil)
        #expect(throws: RootKeyVault.Failure.self) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in }) }
        try store.delete("bio.espera")
        try store.add(Data([0]), account: "rk.pin.novo", protection: .standard, context: nil)
        #expect(throws: RootKeyVault.Failure.hardenedBlocked(.changePending)) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in }) }
        try store.delete("rk.pin.novo")
        #expect(vault.failureCount() == 0)
        #expect(store.probe("rk.and") == .absent)
        // A conferencia das palavras falha: nada gravado.
        struct WordsDoNotMatch: Error {}
        #expect(throws: WordsDoNotMatch.self) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in throw WordsDoNotMatch() }) }
        #expect(store.probe("rk.and") == .absent)
        #expect(vault.securityMode == .normal)
    }

    @Test("Ligar: o segundo rosto recusado desfaz tudo; o modo normal fica intacto", arguments: Policy.allCases)
    func enableConfirmFails(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeNormal()
        wrapper.refuseSlots = [policy.faceKey]
        #expect(throws: RootKeyVault.Failure.self) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", faceChange: policy, check: { _ in }) }
        wrapper.refuseSlots = []
        #expect(store.probe("rk.and") == .absent)
        for slot in RootKeyVault.hardenedKeys { #expect(wrapper.probeKey(slot) == .absent) }
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
        #expect(bytes(try vault.unlockWithBiometry(reason: "x")) == rk)
    }

    @Test("Ligar com a vigia que nao abre: Esperar 24 horas nao liga")
    func enableWaitWatchFails() throws {
        let (vault, store, wrapper, _) = try makeNormal()
        wrapper.watchUnknown = true
        vault.hardenedDomainState = { nil }
        #expect(throws: RootKeyVault.Failure.storage) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", faceChange: .wait, check: { _ in }) }
        #expect(store.probe("rk.and") == .absent)
        #expect(vault.securityMode == .normal)
    }

    @Test("Commit que nao apaga o rk.pin: nada se perde, o modo normal manda e o rk.and sai no proximo PIN", arguments: Policy.allCases)
    func commitDeleteFails(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeNormal()
        store.failDeleting = ["rk.pin"]
        #expect(throws: RootKeyVault.Failure.storage) { try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", faceChange: policy, check: { _ in }) }
        #expect(store.probe("rk.and") == .present)
        #expect(vault.securityMode == .normal)
        store.failDeleting = []
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
        #expect(store.probe("rk.and") == .absent)
        for slot in RootKeyVault.hardenedKeys { #expect(wrapper.probeKey(slot) == .absent) }
    }

    @Test("Queda depois do commit, antes da limpeza: o rosto so nunca abre, e a varredura termina", arguments: Policy.allCases)
    func crashAfterCommit(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeNormal()
        // Reproduz o estado: rk.and gravado e conferido, rk.pin apagado, rk.bio e chaves ainda la.
        store.failDeleting = ["rk.bio"]
        try vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", faceChange: policy, check: { _ in })
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

    @Test("Trocar o PIN: a chave alterna, a politica e as chaves de fora ficam, o PIN antigo para no commit", arguments: Policy.allCases)
    func changePIN(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        let old = try #require(store.raw("rk.and"))
        try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y")
        #expect(vault.pinLengths == [4])
        #expect(vault.hardenedFaceChange == policy)
        #expect(wrapper.probeKey(.hardenedPINA) == .absent)
        #expect(wrapper.probeKey(.hardenedPINB) == .present)
        expectKeys(wrapper, for: policy)
        #expect(bytes(try vault.unlockHardened(pin: secure("7351"), reason: "x")) == rk)
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        // Repor o registro antigo (quem pode escrever no chaveiro) nao traz o PIN antigo de volta.
        try store.update(old, account: "rk.and")
        #expect(throws: RootKeyVault.Failure.hardenedSlotLost) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
    }

    @Test("Trocar o PIN: segundo rosto recusado ou update que nao grava deixam o PIN antigo", arguments: Policy.allCases)
    func changePINFails(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        // Recusa so o segundo rosto da troca (a conferencia), nao o que autoriza.
        wrapper.refuseFaceFrom = wrapper.faces + 2
        // O rosto da conferencia nao conta tentativa: volta como cancelado.
        #expect(throws: RootKeyVault.Failure.cancelled) {
            try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y")
        }
        wrapper.refuseFaceFrom = nil
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        expectKeys(wrapper, for: policy)
        #expect(vault.failureCount() == 0)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        store.failUpdating = ["rk.and"]
        #expect(throws: RootKeyVault.Failure.storage) {
            try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y")
        }
        store.failUpdating = []
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        expectKeys(wrapper, for: policy)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Queda no meio da troca: chave orfa da outra geracao sai na varredura, o registro manda", arguments: Policy.allCases)
    func changePINCrashOrphan(policy: Policy) throws {
        let (vault, _, wrapper, rk) = try makeHardened(policy)
        try wrapper.createKey(.hardenedPINB, password: Data([9]))  // a chave nova criada antes da queda
        // A volta ao app nao le o cabecalho sem autenticar: a orfa fica ate a proxima abertura.
        vault.rebaseAttempts()
        #expect(wrapper.probeKey(.hardenedPINB) == .present)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        #expect(wrapper.probeKey(.hardenedPINA) == .present)
    }

    @Test("Desligar: PIN e rosto, o slot do PIN e o Face ID voltam conferidos, o rk.and sai", arguments: Policy.allCases)
    func disable(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        #expect(try vault.disableHardened(pin: secure(pin), reason: "x", biometryReason: "y"))
        #expect(vault.securityMode == .normal)
        #expect(vault.hardenedFaceChange == nil)
        for account in ["rk.and", "and.estado", "and.espera", "bio.perdido"] { #expect(store.probe(account) == .absent) }
        for slot in RootKeyVault.hardenedKeys { #expect(wrapper.probeKey(slot) == .absent) }
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
        #expect(bytes(try vault.unlockWithBiometry(reason: "x")) == rk)
        // O mesmo cadastro: o Face ID volta sem a espera do A1.
        #expect(vault.biometryHoldRemaining == 0)
        try vault.checkPINAndBiometryAllowed()
    }

    @Test("Desligar com o segundo rosto recusado: sai do reforcado com o Face ID desligado", arguments: Policy.allCases)
    func disableWithoutFace(policy: Policy) throws {
        let (vault, _, wrapper, rk) = try makeHardened(policy)
        wrapper.refuseSlots = [.biometry]
        #expect(try vault.disableHardened(pin: secure(pin), reason: "x", biometryReason: "y") == false)
        #expect(vault.securityMode == .normal)
        #expect(!vault.isBiometryEnabled)
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
        try vault.checkPINAndBiometryAllowed()
    }

    @Test("Queda no desligar depois do rk.pin gravado: o modo normal manda, o rk.and e as chaves dele saem no PIN certo", arguments: Policy.allCases)
    func crashDuringDisable(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        // O estado: rk.and intacto e rk.pin gravado e conferido, sem Face ID ainda.
        try vault.writePINSlot(rk: SecureBytes.from(rk), pin: secure(pin), kdf: fastKDF, suffix: "")
        #expect(vault.securityMode == .normal)
        #expect(vault.pinLengths == [6])
        #expect(!vault.isBiometryEnabled)
        #expect(throws: RootKeyVault.Failure.notHardened) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)
        #expect(store.probe("rk.and") == .absent)
        vault.rebaseAttempts()
        for slot in RootKeyVault.hardenedKeys { #expect(wrapper.probeKey(slot) == .absent) }
    }

    @Test("Modo normal sem rk.and: a varredura leva kand.qualquer, kand.bio, kand.pin, and.estado e and.espera")
    func normalSweep() throws {
        let (vault, store, wrapper, _) = try makeNormal()
        for slot in RootKeyVault.hardenedKeys where slot.usesPassword { try wrapper.createKey(slot, password: Data([1])) }
        for slot in RootKeyVault.hardenedKeys where !slot.usesPassword { try wrapper.createKey(slot) }
        try store.add(Data([1]), account: "and.estado", protection: .standard, context: nil)
        try store.add(HardenedHold(hold: .startingNow(), state: newFace).encoded, account: "and.espera", protection: .standard, context: nil)
        vault.rebaseAttempts()
        for slot in RootKeyVault.hardenedKeys { #expect(wrapper.probeKey(slot) == .absent) }
        #expect(store.probe("and.estado") == .absent)
        #expect(store.probe("and.espera") == .absent)
        #expect(wrapper.probeKey(.biometry) == .present)
    }

    @Test("Queda no ligar antes do commit: o rosto so continua abrindo, e nao apaga o rk.and; o PIN apaga", arguments: Policy.allCases)
    func crashDuringEnable(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeNormal()
        // O estado: rk.and gravado, rk.pin e rk.bio intactos.
        wrapper.refuseFrom = (policy.faceKey, 1)
        _ = try? vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", faceChange: policy, check: { _ in })
        wrapper.refuseFrom = nil
        #expect(store.probe("rk.and") == .absent)  // a falha desfez; agora o estado de queda, a mao:
        store.failDeleting = ["rk.pin"]
        _ = try? vault.enableHardened(pin: secure(pin), reason: "x", confirmReason: "y", faceChange: policy, check: { _ in })
        store.failDeleting = []
        #expect(store.probe("rk.and") == .present)
        #expect(vault.securityMode == .normal)
        #expect(bytes(try vault.unlockWithBiometry(reason: "x")) == rk)
        #expect(store.probe("rk.and") == .present)
        #expect(bytes(try vault.unlockWithPINAndBiometry(pin: secure(pin), reason: "x")) == rk)
        #expect(store.probe("rk.and") == .absent)
    }

    @Test("Chaveiro mudo: nunca vira cadastro nem modo normal, e a espera e a cheia", arguments: Policy.allCases)
    func unknownStore(policy: Policy) throws {
        let (vault, store, _, _) = try makeHardened(policy)
        store.unknown = ["rk.and"]
        #expect(vault.securityMode == .unknown)
        #expect(vault.isSetUp)
        #expect(vault.pinLengths == Set(PINPolicy.lengths))
        #expect(vault.hardenedHoldRemaining == PINPolicy.biometryLossHold)
        #expect(throws: RootKeyVault.Failure.storage) { try vault.setUp(pin: secure(pin)) }
        #expect(throws: RootKeyVault.Failure.storage) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
        #expect(throws: RootKeyVault.Failure.storage) { try vault.unlock(pin: secure(pin)) }
        vault.rebaseAttempts()
        store.unknown = []
        #expect(store.probe("rk.and") == .present)
    }

    @Test("Cabecalho adulterado nao abre", arguments: Policy.allCases)
    func headerTamper(policy: Policy) throws {
        let (vault, store, _, _) = try makeHardened(policy)
        var raw = try #require(store.raw("rk.and"))
        raw[26] ^= 1  // passadas
        try store.update(raw, account: "rk.and")
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
    }

    @Test("Camadas que nao batem com o corpo, ou valor fora de 1 a 3: .storage, sem contar e sem tocar nas chaves", arguments: Policy.allCases)
    func layersMismatch(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        let good = try #require(store.raw("rk.and"))
        var variants: [Data] = []
        // Um valor que pede outro numero de camadas que o corpo tem, ou nenhum valor valido. A
        // troca entre 1 e 2 (o mesmo numero de camadas) passa pela leitura; e o teste
        // `layerSwapKeepsKeys` que fixa o que acontece com ela.
        for code: UInt8 in [0, 1, 2, 3, 4, 0xFF] where Policy(layerCode: code)?.layers.count != policy.layers.count {
            var raw = good
            raw[3] = code
            variants.append(raw)
        }
        variants.append(good + Data([0]))
        variants.append(good.dropLast())
        variants.append(good.prefix(HardenedHeader.length))
        for raw in variants {
            try store.update(raw, account: "rk.and")
            #expect(throws: RootKeyVault.Failure.storage) { try vault.unlockHardened(pin: secure(pin), reason: "x") }
            #expect(vault.hardenedFaceChange == nil)
            vault.rebaseAttempts()
            #expect(wrapper.probeKey(.hardenedPINA) == .present)
            for slot in policy.layers { #expect(wrapper.probeKey(slot) == .present) }
        }
        #expect(vault.failureCount() == 0)
        try store.update(good, account: "rk.and")
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Cabecalho trocado sem autenticar (camadas entre 1 e 2, ou a geracao do PIN): nao abre, e nem a volta ao app nem a abertura apagam uma chave em vigor",
          arguments: Policy.allCases)
    func layerSwapKeepsKeys(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        let good = try #require(store.raw("rk.and"))
        var variants: [Data] = []
        // A troca entre 1 e 2 tem o mesmo numero de camadas: a leitura aceita, e so o AAD (que
        // so a abertura confere) diz que o cabecalho nao e o gravado.
        if policy != .wait {
            var swapped = good
            swapped[3] = policy == .lock ? 2 : 1
            variants.append(swapped)
        }
        var otherPIN = good
        otherPIN[2] ^= 1
        variants.append(otherPIN)
        for raw in variants {
            try store.update(raw, account: "rk.and")
            vault.rebaseAttempts()
            #expect(throws: RootKeyVault.Failure.self) { try vault.unlockHardened(pin: secure(pin), reason: "x", use: .openApp) }
            vault.rebaseAttempts()
            #expect(wrapper.probeKey(.hardenedPINA) == .present)
            expectKeys(wrapper, for: policy)
            try store.update(good, account: "rk.and")
            try store.update(AttemptRecord.zero.encoded, account: "pin.tentativas")
            #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x", use: .openApp)) == rk)
        }
    }

    @Test("Limpeza de reinstalacao enxerga rk.and e as chaves do reforcado; wipeAll leva tudo", arguments: Policy.allCases)
    func residue(policy: Policy) throws {
        let (vault, _, wrapper, _) = try makeHardened(policy)
        #expect(vault.hasResidue)
        vault.wipeAll()
        #expect(!vault.hasResidue)
        try wrapper.createKey(.hardenedBiometryAny)
        #expect(vault.hasResidue)
        vault.wipeAll()
        #expect(!vault.hasResidue)
    }

    @Test("PIN de 4 digitos no reforcado: o tamanho vem do cabecalho; cabecalho ilegivel aceita os dois")
    func fourDigitLengths() throws {
        let store = MemoryStore()
        let wrapper = SoftwareWrapper()
        let vault = RootKeyVault(store: store, wrapper: wrapper, pinParameters: fastKDF)
        vault.biometryAvailability = { .available }
        vault.hardenedBiometryStatus = { .ready }
        vault.hardenedDomainState = { ownerFace }
        let rk = try vault.setUp(pin: secure("2580"))
        try vault.enableBiometry(rk: rk)
        try vault.enableHardened(pin: secure("2580"), reason: "ligar", confirmReason: "conferir", check: { _ in })
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
            try vault.enableHardened(pin: secure(pin), reason: "ligar", confirmReason: "conferir", check: { _ in })
        }
        #expect(vault.failureCount() == 0)

        let (hardened, _, _, _) = try makeHardened()
        #expect(throws: RootKeyVault.Failure.malformedPIN) {
            try hardened.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("12"), reason: "trocar", confirmReason: "conferir")
        }
        #expect(hardened.failureCount() == 0)
    }

    @Test("Hash do cadastro que so derivou: na trava abre e regrava; chave do rosto que o SE nao sabe dizer: recusa sem contar", arguments: Policy.allCases)
    func stateDriftAndUnknownKey(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        vault.hardenedDomainState = { Data([9, 9, 9]) }
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir")) == rk)
        // Na trava e na espera a kand.bio provou o cadastro: o hash e regravado. No continuar
        // normal nada prova o cadastro, e o hash gravado fica (e o que diz se houve troca).
        #expect(store.raw("and.estado") == (policy == .continue ? ownerFace : Data([9, 9, 9])))
        #expect(vault.hardenedHoldRemaining == 0)

        wrapper.unknownKeys = [policy.faceKey]
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
            try vault.enableHardened(pin: secure("000000"), reason: "ligar", confirmReason: "conferir", check: { _ in })
        }
        #expect(!vault.isSetUp)
        #expect(!WrapSlot.allCases.contains { wrapper.probeKey($0) != .absent })
    }

    @Test("Desligar com a chave do PIN que nao nasce: continua reforcado e abrindo", arguments: Policy.allCases)
    func disableKeepsHardenedWhenPINSlotFails(policy: Policy) throws {
        let (vault, _, wrapper, rk) = try makeHardened(policy)
        wrapper.failCreating = .pin
        #expect(throws: (any Error).self) { try vault.disableHardened(pin: secure(pin), reason: "desligar", biometryReason: "rosto") }
        wrapper.failCreating = nil
        #expect(vault.securityMode == .hardened)
        #expect(vault.hardenedFaceChange == policy)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir")) == rk)
    }

    // MARK: Rosto novo

    @Test("Continuar normal: rosto novo abre tudo na hora, e trocar o PIN tambem")
    func continueNewFaceOpensAll() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.continue)
        changeEnrollment(vault, wrapper)
        let faces = wrapper.faces
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)) == rk)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
        #expect(wrapper.faces == faces + 2)
        #expect(vault.hardenedHoldRemaining == 0)
        try vault.checkHardenedAllowed()
        try vault.checkPINAndBiometryAllowed()
        #expect(store.probe("and.espera") == .absent)
        #expect(wrapper.probeKey(.hardenedBiometry) == .absent)
        try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y")
        #expect(bytes(try vault.unlockHardened(pin: secure("7351"), reason: "x")) == rk)
    }

    @Test("Bloquear as carteiras: a kand.qualquer nunca existe, e rosto novo perde o cofre sem apagar nada")
    func lockNewFaceLosesVault() throws {
        let (vault, store, wrapper, _) = try makeHardened(.lock)
        #expect(wrapper.probeKey(.hardenedBiometryAny) == .absent)
        try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y")
        #expect(wrapper.probeKey(.hardenedBiometryAny) == .absent)
        changeEnrollment(vault, wrapper)
        #expect(throws: RootKeyVault.Failure.hardenedSlotLost) { try vault.unlockHardened(pin: secure("7351"), reason: "x", use: .openApp) }
        #expect(vault.failureCount() == 0)
        #expect(store.probe("rk.and") == .present)
        #expect(vault.isSetUp)
        #expect(vault.securityMode == .hardened)
        #expect(vault.hardenedEnrollmentChanged)
        #expect(throws: RootKeyVault.Failure.alreadySetUp) { try vault.setUp(pin: secure(pin)) }
        vault.rebaseAttempts()
        #expect(store.probe("rk.and") == .present)
        #expect(wrapper.probeKey(.hardenedBiometryAny) == .absent)
    }

    @Test("Esperar 24 horas: rosto novo abre o app, a espera comeca, o contador zera, e o resto recusa sem rosto e sem contar")
    func waitOpenAppStartsHold() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.wait)
        _ = try? vault.unlockHardened(pin: secure("000001"), reason: "x")
        #expect(vault.failureCount() == 1)
        changeEnrollment(vault, wrapper)
        var faces = wrapper.faces
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)) == rk)
        #expect(wrapper.faces == faces + 1)
        #expect(vault.failureCount() == 0)
        let hold = try #require(savedHold(store))
        #expect(hold.state == newFace)
        #expect(vault.hardenedHoldRemaining > PINPolicy.biometryLossHold - 60)
        // O hash do cadastro conhecido nao e regravado com o do rosto novo.
        #expect(store.raw("and.estado") == ownerFace)
        #expect(throws: RootKeyVault.Failure.self) { try vault.checkHardenedAllowed() }
        do {
            try vault.checkPINAndBiometryAllowed()
            Issue.record("a espera deveria recusar")
        } catch RootKeyVault.Failure.biometryHold(let seconds) {
            #expect(seconds > PINPolicy.biometryLossHold - 60)
        }

        // Tudo que nao e abrir o app recusa antes do rosto, sem contar e sem mexer em nada.
        faces = wrapper.faces
        let record = try #require(store.raw("rk.and"))
        func refused(_ body: () throws -> Void) {
            do {
                try body()
                Issue.record("deveria esperar")
            } catch RootKeyVault.Failure.biometryHold {
            } catch {
                Issue.record("esperava biometryHold, veio \(error)")
            }
        }
        refused { _ = try vault.unlockHardened(pin: secure(pin), reason: "enviar") }
        refused { _ = try vault.unlockHardened(pin: secure("000002"), reason: "enviar") }
        refused { _ = try vault.disableHardened(pin: secure(pin), reason: "x", biometryReason: "y") }
        refused { try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y") }
        for target in [Policy.continue, .lock] {
            refused { try vault.setHardenedFaceChange(target, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in }) }
        }
        #expect(wrapper.faces == faces)
        #expect(vault.failureCount() == 0)
        #expect(store.raw("rk.and") == record)
        #expect(vault.securityMode == .hardened)

        // Abrir o app de novo na espera: abre, e a espera nao recomeca.
        let before = store.raw("and.espera")
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)) == rk)
        #expect(store.raw("and.espera") == before)
    }

    @Test("Esperar 24 horas: a troca vista numa operacao recusa depois do rosto, com a espera gravada e o contador zerado")
    func waitFirstSightingOnOperation() throws {
        let (vault, store, wrapper, _) = try makeHardened(.wait)
        changeEnrollment(vault, wrapper)
        let faces = wrapper.faces
        do {
            _ = try vault.unlockHardened(pin: secure(pin), reason: "enviar")
            Issue.record("deveria esperar")
        } catch RootKeyVault.Failure.biometryHold(let seconds) {
            #expect(seconds == PINPolicy.biometryLossHold)
        }
        #expect(wrapper.faces == faces + 1)
        #expect(store.probe("and.espera") == .present)
        #expect(vault.failureCount() == 0)
    }

    @Test("Esperar 24 horas: espera que nao grava da .storage e nao abre; gravada depois, abre o app")
    func waitHoldNotWritten() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.wait)
        changeEnrollment(vault, wrapper)
        store.failAdding = ["and.espera"]
        #expect(throws: RootKeyVault.Failure.storage) { try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp) }
        #expect(store.probe("and.espera") == .absent)
        store.failAdding = []
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)) == rk)
        #expect(store.probe("and.espera") == .present)
    }

    @Test("Esperar 24 horas: vencida, a vigia realinha para o cadastro de agora e tudo volta, um rosto por chamada")
    func waitExpiredRealigns() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.wait)
        changeEnrollment(vault, wrapper)
        _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
        try expireHold(store)
        #expect(vault.hardenedHoldRemaining == 0)
        try vault.checkHardenedAllowed()
        var faces = wrapper.faces
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
        #expect(wrapper.faces == faces + 1)
        #expect(store.probe("and.espera") == .absent)
        #expect(store.raw("and.estado") == newFace)
        #expect(wrapper.probeKey(.hardenedBiometry) == .present)
        #expect(vault.hardenedFaceChange == .wait)
        // A vigia nova abre na mesma sessao: nenhuma espera, e um rosto so.
        faces = wrapper.faces
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
        #expect(wrapper.faces == faces + 1)
        #expect(store.probe("and.espera") == .absent)
        // E a vigia nova acompanha o cadastro de agora: outra troca, outra espera.
        changeEnrollment(vault, wrapper, to: Data([7, 7, 7]))
        #expect(throws: RootKeyVault.Failure.biometryHold(seconds: PINPolicy.biometryLossHold)) { try vault.unlockHardened(pin: secure(pin), reason: "enviar") }
    }

    @Test("Esperar 24 horas: vencida para um cadastro, e outro rosto cadastrado depois, comeca outra espera em vez de realinhar")
    func waitExpiredForOtherEnrollment() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.wait)
        changeEnrollment(vault, wrapper)
        _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
        try expireHold(store)
        // Ninguem abriu o app depois do prazo; alguem cadastra outro rosto.
        changeEnrollment(vault, wrapper, to: Data([7, 7, 7]))
        #expect(throws: RootKeyVault.Failure.biometryHold(seconds: PINPolicy.biometryLossHold)) { try vault.unlockHardened(pin: secure(pin), reason: "enviar") }
        let hold = try #require(savedHold(store))
        #expect(hold.state == Data([7, 7, 7]))
        #expect(hold.remaining > PINPolicy.biometryLossHold - 60)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)) == rk)
    }

    @Test("Esperar 24 horas: realinhamento interrompido em cada passo termina na proxima abertura")
    func waitRealignInterrupted() throws {
        // Cada passo que pode parar: o update do rk.and (a kand.bio nova ja criada), o hash
        // regravado, a espera apagada.
        for failing in [(updating: Set(["rk.and"]), deleting: Set<String>()),
                        (updating: Set<String>(), deleting: Set(["and.estado", "and.espera"])),
                        (updating: Set<String>(), deleting: Set(["and.espera"]))] {
            let (vault, store, wrapper, rk) = try makeHardened(.wait)
            changeEnrollment(vault, wrapper)
            _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
            try expireHold(store)
            store.failUpdating = failing.updating
            store.failDeleting = failing.deleting
            #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
            #expect(store.probe("and.espera") == .present)
            store.failUpdating = []
            store.failDeleting = []
            // A kand.qualquer nunca foi tocada: abre, e a proxima abertura termina.
            #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
            #expect(store.probe("and.espera") == .absent)
            #expect(store.raw("and.estado") == newFace)
            let faces = wrapper.faces
            #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
            #expect(wrapper.faces == faces + 1)
            #expect(store.probe("and.espera") == .absent)
        }
    }

    @Test("Esperar 24 horas: espera gravada em outro boot recomeca cheia, para o mesmo cadastro")
    func waitHoldOtherBoot() throws {
        let (vault, store, wrapper, _) = try makeHardened(.wait)
        changeEnrollment(vault, wrapper)
        _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
        let stale = HardenedHold(hold: HoldRecord(uptimeDeadline: 1, bootSession: PINPolicy.unknownBoot), state: newFace)
        try store.update(stale.encoded, account: "and.espera")
        #expect(vault.hardenedHoldRemaining == PINPolicy.biometryLossHold)
        vault.rebaseAttempts()
        let rebased = try #require(savedHold(store))
        #expect(!rebased.hold.isFromAnotherBoot)
        #expect(rebased.state == newFace)
        #expect(rebased.remaining > PINPolicy.biometryLossHold - 60)
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlockHardened(pin: secure(pin), reason: "enviar") }
        // Ilegivel: tambem a espera cheia.
        try store.update(Data([1, 2]), account: "and.espera")
        #expect(vault.hardenedHoldRemaining == PINPolicy.biometryLossHold)
    }

    @Test("Esperar 24 horas: vigia sem resposta decide pelo hash, e sem hash conta como troca")
    func waitWatchUnknownDecidesByHash() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.wait)
        wrapper.watchUnknown = true
        let faces = wrapper.faces
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
        #expect(wrapper.faces == faces + 1)
        #expect(store.probe("and.espera") == .absent)
        // O hash de agora e outro: troca.
        vault.hardenedDomainState = { newFace }
        #expect(throws: RootKeyVault.Failure.biometryHold(seconds: PINPolicy.biometryLossHold)) { try vault.unlockHardened(pin: secure(pin), reason: "enviar") }

        let (other, otherStore, otherWrapper, _) = try makeHardened(.wait)
        otherWrapper.watchUnknown = true
        // Sem hash agora, ou sem hash gravado: na duvida, troca.
        other.hardenedDomainState = { nil }
        #expect(throws: RootKeyVault.Failure.biometryHold(seconds: PINPolicy.biometryLossHold)) { try other.unlockHardened(pin: secure(pin), reason: "enviar") }
        try otherStore.delete("and.espera")
        other.hardenedDomainState = { ownerFace }
        try otherStore.delete("and.estado")
        #expect(throws: RootKeyVault.Failure.biometryHold(seconds: PINPolicy.biometryLossHold)) { try other.unlockHardened(pin: secure(pin), reason: "enviar") }
    }

    @Test("Esperar 24 horas: a vigia que abre outro miolo e um registro adulterado")
    func waitMiddleMismatch() throws {
        let (vault, store, wrapper, _) = try makeHardened(.wait)
        var record = try HardenedRecord.parse(try #require(store.raw("rk.and")))
        record.layers[.hardenedBiometry] = try wrapper.wrap(SecureBytes.from(Array(repeating: 7, count: 40)), slot: .hardenedBiometry)
        try store.update(record.encoded, account: "rk.and")
        #expect(throws: RootKeyVault.Failure.storage) { try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp) }
        #expect(store.probe("and.espera") == .absent)
    }

    @Test("Registro v3, de antes das politicas: lido como Bloquear as carteiras, e regravado no v4 so por uma troca")
    func legacyRecordIsLock() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.lock)
        // O v3 como as versoes anteriores gravavam: 28 bytes de cabecalho e o ECIES da kand.bio,
        // com a geracao a da chave do PIN.
        let salt = Array(repeating: UInt8(5), count: 16)
        let cost = fastKDF.memoryKiB.bigEndianByteArray + fastKDF.passes.bigEndianByteArray + [fastKDF.lanes]
        let header = try #require(HardenedHeader([3, 6, 0] + salt + cost))
        #expect(header.faceChange == .lock)
        #expect(header.aad == Data(Array("escalibur-wallet/v3/rk.and".utf8) + [3, 6, 0] + salt + cost))
        func installLegacy() throws -> Data {
            let ap = try KeyDerivation.deriveMasterKey(password: secure(pin), salt: salt, parameters: fastKDF)
            let password = RootKeyVault.hardenedPassword(ap: ap, salt: salt)
            try password.withUnsafeData { try wrapper.createKey(.hardenedPINA, password: $0) }
            let inner = try RootKeyVault.sealHardenedInner(SecureBytes.from(rk), ap: ap, header: header)
            let middleData = try wrapper.wrap(inner, slot: .hardenedPINA)
            let outer = try wrapper.wrap(SecureBytes.from(Array(middleData)), slot: .hardenedBiometry)
            let legacy = Data(header.encoded) + outer
            try store.update(legacy, account: "rk.and")
            return legacy
        }
        let legacy = try installLegacy()
        #expect(vault.hardenedFaceChange == .lock)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir")) == rk)
        #expect(store.raw("rk.and") == legacy)
        // A troca de PIN regrava no v4, com a trava.
        try vault.changeHardenedPIN(currentPIN: secure(pin), newPIN: secure("7351"), reason: "x", confirmReason: "y")
        let raw = try #require(store.raw("rk.and"))
        #expect(raw[0] == 4)
        #expect(raw[3] == Policy.lock.layerCode)
        #expect(bytes(try vault.unlockHardened(pin: secure("7351"), reason: "x")) == rk)
        // E o v3 trocado por outra politica tambem sai como v4.
        _ = try installLegacy()
        try vault.setHardenedFaceChange(.continue, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in })
        #expect(vault.hardenedFaceChange == .continue)
        #expect(try #require(store.raw("rk.and"))[0] == 4)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Esperar 24 horas: outro cadastro no meio da espera a recomeca cheia, para ele, e o vencimento realinha para ele")
    func waitNewEnrollmentDuringHold() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.wait)
        changeEnrollment(vault, wrapper)
        _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
        // A espera ja andou um pouco quando o dono redefine o Face ID.
        let started = HardenedHold(hold: HoldRecord(uptimeDeadline: PINPolicy.uptime + 3600, bootSession: PINPolicy.bootSession), state: newFace)
        try store.update(started.encoded, account: "and.espera")
        #expect(vault.hardenedHoldRemaining <= 3600)
        changeEnrollment(vault, wrapper, to: Data([9, 9, 9]))
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)) == rk)
        let restarted = try #require(savedHold(store))
        #expect(restarted.state == Data([9, 9, 9]))
        #expect(vault.hardenedHoldRemaining > PINPolicy.biometryLossHold - 60)
        // O mesmo cadastro de novo, na espera: nada recomeca.
        let before = store.raw("and.espera")
        _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
        #expect(store.raw("and.espera") == before)
        // Vencida para o cadastro de agora: realinha.
        try expireHold(store, state: Data([9, 9, 9]))
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
        #expect(store.probe("and.espera") == .absent)
        #expect(store.raw("and.estado") == Data([9, 9, 9]))
    }

    @Test("Esperar 24 horas: sem o hash do cadastro no vencimento, nada abre e a espera nao recomeca; com o hash de volta, realinha")
    func waitNilStateAtExpiry() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.wait)
        changeEnrollment(vault, wrapper)
        _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
        try expireHold(store)
        let expired = store.raw("and.espera")
        vault.hardenedDomainState = { nil }
        for use in [RootKeyVault.HardenedUse.operation, .openApp] {
            #expect(throws: RootKeyVault.Failure.biometryUnavailable) { try vault.unlockHardened(pin: secure(pin), reason: "x", use: use) }
        }
        #expect(store.raw("and.espera") == expired)
        // Correndo, sem o hash, a espera fica como esta e abrir o app passa.
        vault.hardenedDomainState = { newFace }
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
        #expect(store.probe("and.espera") == .absent)
        changeEnrollment(vault, wrapper, to: Data([7, 7, 7]))
        _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
        let running = store.raw("and.espera")
        vault.hardenedDomainState = { nil }
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)) == rk)
        #expect(store.raw("and.espera") == running)
    }

    @Test("Esperar 24 horas: so a vigia aberta encerra uma espera vencida; o hash igual sozinho nao")
    func waitOnlyProofEndsHold() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.wait)
        changeEnrollment(vault, wrapper)
        _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
        try expireHold(store)
        // A vigia nao responde e o hash bate com o gravado: o mesmo cadastro, mas sem prova.
        try store.delete("and.estado")
        try store.add(newFace, account: "and.estado", protection: .standard, context: nil)
        wrapper.watchUnknown = true
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "enviar")) == rk)
        #expect(store.probe("and.espera") == .present)
        #expect(vault.hardenedHoldRemaining == 0)
    }

    @Test("A camada de fora que falha por um erro que nao vem do Face ID nao conta tentativa e nao apaga nada", arguments: Policy.allCases)
    func outerLayerFailureDoesNotCount(policy: Policy) throws {
        let (vault, store, wrapper, rk) = try makeHardened(policy)
        _ = try? vault.unlockHardened(pin: secure("000001"), reason: "x")
        #expect(vault.failureCount() == 1)
        let before = store.raw("pin.tentativas")
        wrapper.failSlots = [policy.faceKey]
        let pinUses = wrapper.unwrapCount[.hardenedPINA, default: 0]
        for use in [RootKeyVault.HardenedUse.openApp, .operation] {
            #expect(throws: RootKeyVault.Failure.hardenedFaceKeyFailed) { try vault.unlockHardened(pin: secure(pin), reason: "x", use: use) }
        }
        #expect(vault.failureCount() == 1)
        #expect(store.raw("pin.tentativas") == before)
        #expect(wrapper.unwrapCount[.hardenedPINA, default: 0] == pinUses)
        expectKeys(wrapper, for: policy)
        #expect(store.probe("rk.and") == .present)
        wrapper.failSlots = []
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        #expect(vault.failureCount() == 0)
    }

    @Test("A kand.qualquer so embrulha o miolo: o duble acusa e recusa a RK e qualquer coisa que nao seja o ECIES da kand.pin; o SE recusa 32 bytes")
    func anyOnlyWrapsMiddle() throws {
        let wrapper = SoftwareWrapper()
        try wrapper.createKey(.hardenedBiometryAny)
        let rk = try SecureBytes.random(count: 32)
        withKnownIssue("o duble registra a quebra da invariante") {
            _ = try wrapper.wrap(rk, slot: RootKeyVault.HardenedFaceChange.continue.faceKey)
        }
        withKnownIssue("o duble registra a quebra da invariante") {
            _ = try wrapper.wrap(SecureBytes.from(Array(repeating: 1, count: 160)), slot: .hardenedBiometryAny)
        }
        #expect(throws: EnclaveError.self) { try SecureEnclaveWrapper().wrap(rk, slot: .hardenedBiometryAny) }
    }

    // MARK: Desligar e o A1

    @Test("Desligar em Continuar normal com o cadastro trocado: o Face ID volta com a espera do A1")
    func disableContinueAfterChange() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.continue)
        changeEnrollment(vault, wrapper)
        #expect(try vault.disableHardened(pin: secure(pin), reason: "x", biometryReason: "y"))
        #expect(vault.isBiometryEnabled)
        #expect(vault.biometryHoldRemaining > PINPolicy.biometryLossHold - 60)
        #expect(store.probe("bio.perdido") == .absent)
        #expect(throws: RootKeyVault.Failure.self) { try vault.checkPINAndBiometryAllowed() }
        #expect(bytes(try vault.unlock(pin: secure(pin))) == rk)

        // O mesmo, com o rosto do religar recusado: Face ID desligado e a marca de perdido,
        // ate religar (que comeca a espera).
        let (other, otherStore, otherWrapper, otherRK) = try makeHardened(.continue)
        changeEnrollment(other, otherWrapper)
        otherWrapper.refuseSlots = [.biometry]
        #expect(try other.disableHardened(pin: secure(pin), reason: "x", biometryReason: "y") == false)
        otherWrapper.refuseSlots = []
        #expect(!other.isBiometryEnabled)
        #expect(otherStore.probe("bio.perdido") == .present)
        #expect(throws: RootKeyVault.Failure.biometryRequired) { try other.checkPINAndBiometryAllowed() }
        try other.enableBiometry(rk: SecureBytes.from(otherRK))
        #expect(other.biometryHoldRemaining > PINPolicy.biometryLossHold - 60)
    }

    @Test("Desligar com o mesmo cadastro, ou na espera vencida e realinhada: sem a espera do A1", arguments: Policy.allCases)
    func disableSameEnrollmentNoHold(policy: Policy) throws {
        let (vault, store, wrapper, _) = try makeHardened(policy)
        if policy == .wait {
            changeEnrollment(vault, wrapper)
            _ = try vault.unlockHardened(pin: secure(pin), reason: "abrir", use: .openApp)
            try expireHold(store)
        }
        #expect(try vault.disableHardened(pin: secure(pin), reason: "x", biometryReason: "y"))
        #expect(vault.biometryHoldRemaining == 0)
        try vault.checkPINAndBiometryAllowed()
    }

    // MARK: Trocar a politica

    @Test("Mudar a politica: o registro, as chaves e a geracao do PIN acompanham; palavras so na ida para a trava", arguments: Transition.all)
    func changePolicy(_ move: Transition) throws {
        let (vault, store, wrapper, rk) = try makeHardened(move.from)
        var checked = 0
        let faces = wrapper.faces
        try vault.setHardenedFaceChange(move.to, pin: secure(pin), reason: "x", confirmReason: "y") { opened in
            checked += 1
            #expect(self.bytes(opened) == rk)
        }
        #expect(checked == (move.to == .lock ? 1 : 0))
        #expect(wrapper.faces == faces + 2)
        #expect(vault.hardenedFaceChange == move.to)
        #expect(try #require(store.raw("rk.and"))[3] == move.to.layerCode)
        expectKeys(wrapper, for: move.to)
        #expect(wrapper.probeKey(.hardenedPINA) == .absent)
        #expect(wrapper.probeKey(.hardenedPINB) == .present)
        #expect(store.probe("and.espera") == .absent)
        #expect(store.raw("and.estado") == ownerFace)
        #expect(vault.failureCount() == 0)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        // A mesma politica nao pede nada.
        let now = wrapper.faces
        try vault.setHardenedFaceChange(move.to, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in })
        #expect(wrapper.faces == now)
    }

    @Test("Mudar a politica: palavras que nao conferem na ida para a trava nao mudam nada", arguments: Transition.all.filter { $0.to == .lock })
    func changePolicyWordsFail(_ move: Transition) throws {
        let (vault, store, wrapper, rk) = try makeHardened(move.from)
        let old = try #require(store.raw("rk.and"))
        struct WordsDoNotMatch: Error {}
        #expect(throws: WordsDoNotMatch.self) {
            try vault.setHardenedFaceChange(.lock, pin: secure(pin), reason: "x", confirmReason: "y") { _ in throw WordsDoNotMatch() }
        }
        #expect(store.raw("rk.and") == old)
        #expect(vault.hardenedFaceChange == move.from)
        expectKeys(wrapper, for: move.from)
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Mudar a politica: segundo rosto recusado ou update que nao grava mantem o registro antigo", arguments: Transition.all)
    func changePolicyFails(_ move: Transition) throws {
        let (vault, store, wrapper, rk) = try makeHardened(move.from)
        let old = try #require(store.raw("rk.and"))
        wrapper.refuseFaceFrom = wrapper.faces + 2
        #expect(throws: RootKeyVault.Failure.cancelled) { try vault.setHardenedFaceChange(move.to, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in }) }
        wrapper.refuseFaceFrom = nil
        #expect(store.raw("rk.and") == old)
        expectKeys(wrapper, for: move.from)
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        #expect(vault.failureCount() == 0)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)

        store.failUpdating = ["rk.and"]
        #expect(throws: RootKeyVault.Failure.storage) { try vault.setHardenedFaceChange(move.to, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in }) }
        store.failUpdating = []
        #expect(store.raw("rk.and") == old)
        expectKeys(wrapper, for: move.from)
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Mudar a politica: queda antes do commit, o cabecalho antigo manda e a varredura so leva o que nasceu", arguments: Transition.all)
    func changePolicyCrashBeforeCommit(_ move: Transition) throws {
        let (vault, store, wrapper, rk) = try makeHardened(move.from)
        let old = try #require(store.raw("rk.and"))
        let born = move.to.layers.filter { !move.from.layers.contains($0) }
        // A queda: as chaves novas criadas e o registro novo montado, sem o update.
        wrapper.failDeletingKeys = Set([.hardenedPINB] + born)
        wrapper.refuseFaceFrom = wrapper.faces + 2
        _ = try? vault.setHardenedFaceChange(move.to, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in })
        wrapper.refuseFaceFrom = nil
        wrapper.failDeletingKeys = []
        #expect(store.raw("rk.and") == old)
        #expect(wrapper.probeKey(.hardenedPINB) == .present)
        for slot in born { #expect(wrapper.probeKey(slot) == .present) }
        // A volta ao app nao toca nas chaves do reforcado; a abertura, com o cabecalho antigo
        // provado pelo AAD, leva o que nasceu, e o registro em vigor abre antes e depois.
        vault.rebaseAttempts()
        #expect(wrapper.probeKey(.hardenedPINB) == .present)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        #expect(wrapper.probeKey(.hardenedPINB) == .absent)
        expectKeys(wrapper, for: move.from)
        #expect(vault.hardenedFaceChange == move.from)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Mudar a politica: queda depois do commit, o cabecalho novo manda e a varredura leva o que sobrou", arguments: Transition.all)
    func changePolicyCrashAfterCommit(_ move: Transition) throws {
        let (vault, store, wrapper, rk) = try makeHardened(move.from)
        let leftover = move.from.layers.filter { !move.to.layers.contains($0) }
        // A queda: o update feito, a limpeza nao.
        wrapper.failDeletingKeys = Set([.hardenedPINA] + leftover)
        try vault.setHardenedFaceChange(move.to, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in })
        wrapper.failDeletingKeys = []
        #expect(vault.hardenedFaceChange == move.to)
        #expect(wrapper.probeKey(.hardenedPINA) == .present)
        for slot in leftover { #expect(wrapper.probeKey(slot) == .present) }
        vault.rebaseAttempts()
        #expect(wrapper.probeKey(.hardenedPINA) == .present)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        #expect(wrapper.probeKey(.hardenedPINA) == .absent)
        #expect(wrapper.probeKey(.hardenedPINB) == .present)
        expectKeys(wrapper, for: move.to)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
        _ = store
    }

    @Test("Mudar a politica: chave nova que some depois do commit volta o registro antigo", arguments: Transition.all)
    func changePolicyKeyVanishes(_ move: Transition) throws {
        let (vault, store, wrapper, rk) = try makeHardened(move.from)
        let old = try #require(store.raw("rk.and"))
        // A chave nova da geracao b some entre a conferencia e a leitura de volta: simulada
        // apagando-a quando o update grava.
        final class Vanishing: @unchecked Sendable { var armed = true }
        let vanishing = Vanishing()
        store.onUpdate = { account in
            guard account == "rk.and", vanishing.armed else { return }
            vanishing.armed = false
            wrapper.deleteKey(.hardenedPINB)
        }
        #expect(throws: RootKeyVault.Failure.storage) { try vault.setHardenedFaceChange(move.to, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in }) }
        store.onUpdate = nil
        #expect(store.raw("rk.and") == old)
        expectKeys(wrapper, for: move.from)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    @Test("Sair da trava abre pela kand.bio: com o cadastro trocado, nao sai")
    func leaveLockNeedsSameEnrollment() throws {
        let (vault, store, wrapper, _) = try makeHardened(.lock)
        let old = try #require(store.raw("rk.and"))
        changeEnrollment(vault, wrapper)
        for target in [Policy.continue, .wait] {
            #expect(throws: RootKeyVault.Failure.hardenedSlotLost) { try vault.setHardenedFaceChange(target, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in }) }
        }
        #expect(store.raw("rk.and") == old)
        #expect(wrapper.probeKey(.hardenedBiometryAny) == .absent)
    }

    @Test("Esperar 24 horas para Bloquear: a vigia do registro em vigor e reaproveitada, nunca recriada")
    func waitToLockReusesWatch() throws {
        let (vault, store, wrapper, rk) = try makeHardened(.wait)
        let before = try HardenedRecord.parse(try #require(store.raw("rk.and")))
        try vault.setHardenedFaceChange(.lock, pin: secure(pin), reason: "x", confirmReason: "y", check: { _ in })
        // A camada do registro antigo ainda abre: a kand.bio nao nasceu de novo.
        let middle = try wrapper.unwrap(try #require(before.layers[.hardenedBiometry]), slot: .hardenedBiometry, reason: nil)
        #expect(middle.count > 0)
        #expect(bytes(try vault.unlockHardened(pin: secure(pin), reason: "x")) == rk)
    }

    // MARK: A chave biometryAny

    @Test("flags(for:): so a kand.qualquer recebe biometryAny; as do rosto seguem o cadastro; as do PIN tem senha")
    func flagsPerSlot() {
        for slot in WrapSlot.allCases {
            let flags = SecureEnclaveWrapper.flags(for: slot)
            #expect(flags.contains(.privateKeyUsage))
            #expect(flags.contains(.biometryAny) == (slot == .hardenedBiometryAny), "\(slot)")
            #expect(flags.contains(.biometryCurrentSet) == slot.followsEnrollment, "\(slot)")
            #expect(flags.contains(.applicationPassword) == slot.usesPassword, "\(slot)")
            #expect(!flags.contains(.userPresence))
            #expect(!flags.contains(.devicePasscode))
            #expect(!flags.contains(.or))
        }
        #expect(WrapSlot.hardenedBiometryAny.usesBiometry)
        #expect(!WrapSlot.hardenedBiometryAny.followsEnrollment)
    }
}
