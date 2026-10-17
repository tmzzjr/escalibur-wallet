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

    @Test("Qualquer PIN de 4 ou 6 digitos vale, inclusive os faceis; so a forma e conferida")
    func anyPIN() throws {
        for pin in ["111111", "123456", "000000", "250390"] {
            let (vault, _, _) = makeVault()
            let rk = try vault.setUp(pin: secure(pin))
            #expect(bytes(try vault.unlock(pin: secure(pin))) == bytes(rk))
        }
        #expect(PINPolicy.isWellFormed([1, 1, 1, 1, 1, 1]))
        #expect(PINPolicy.isWellFormed([1, 1, 1, 1]))
        // Digito fora de 0 a 9, ou tamanho diferente de 4 e de 6, nunca passa.
        #expect(!PINPolicy.isWellFormed([4, 8, 2, 9, 1, 0x2F]))
        #expect(!PINPolicy.isWellFormed([4, 8, 2, 9, 1]))
        #expect(!PINPolicy.isWellFormed([4, 8, 2]))
        #expect(!PINPolicy.isWellFormed([4, 8, 2, 9, 1, 0, 7]))
        let (vault, _, _) = makeVault()
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.setUp(pin: secure("12345a")) }
    }

    @Test("PIN de 4 digitos: grava o tamanho, abre, e o de 6 da instalacao antiga continua 6")
    func fourDigits() throws {
        let (vault, store, _) = makeVault()
        let rk = try vault.setUp(pin: secure("4829"))
        #expect(vault.pinLengths == [4])
        #expect(store.raw("pin.digitos") == Data([4]))
        #expect(bytes(try vault.unlock(pin: secure("4829"))) == bytes(rk))
        #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) { try vault.unlock(pin: secure("4828")) }
        // Slot gravado antes da escolha, sem o registro do tamanho: 6.
        try store.delete("pin.digitos")
        #expect(vault.pinLengths == [6])
        // Registro estranho nao vira um chute: a tela aceita os dois tamanhos.
        try store.add(Data([5]), account: "pin.digitos", protection: .standard, context: nil)
        #expect(vault.pinLengths == [4, 6])
        let (fresh, _, _) = makeVault()
        #expect(fresh.pinLengths == [6])
        // PIN sem forma e recusado antes de contar a tentativa.
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.unlock(pin: secure("")) }
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.unlock(pin: secure("48291")) }
        #expect(vault.failureCount() == 1)
    }

    @Test("Troca de PIN de 6 para 4 e de volta: o tamanho acompanha o slot, inclusive pendente")
    func changeLength() throws {
        let (vault, store, _) = makeVault()
        let rk = try vault.setUp(pin: secure("482916"))
        #expect(vault.pinLengths == [6])
        try vault.changePIN(rk: rk, newPIN: secure("7351"))
        #expect(vault.pinLengths == [4])
        #expect(store.raw("pin.digitos.novo") == nil)
        #expect(bytes(try vault.unlock(pin: secure("7351"))) == bytes(rk))
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlock(pin: secure("482916")) }
        try vault.changePIN(rk: rk, newPIN: secure("905128"))
        #expect(vault.pinLengths == [6])
        // Depois do ponto sem volta, so com o pendente: o tamanho e o dele.
        try vault.writePINSlot(rk: rk, pin: secure("2468"), kdf: fastKDF, suffix: ".novo")
        try store.delete("rk.pin")
        #expect(vault.pinLengths == [4])
        #expect(bytes(try vault.unlock(pin: secure("2468"))) == bytes(rk))
        #expect(vault.pinLengths == [4])
        #expect(store.raw("pin.digitos.novo") == nil)
    }

    @Test("Troca interrompida entre tamanhos: a tela aceita os dois, e os dois PINs abrem")
    func interruptedChangeAcrossLengths() throws {
        // Antigo de 4, novo de 6, com o app morto antes de apagar o antigo.
        let (vault, store, _) = makeVault()
        let rk = try vault.setUp(pin: secure("7305"))
        try vault.writePINSlot(rk: rk, pin: secure("905128"), kdf: fastKDF, suffix: ".novo")
        #expect(vault.pinLengths == [4, 6])
        // O novo conclui a troca.
        #expect(bytes(try vault.unlock(pin: secure("905128"))) == bytes(rk))
        #expect(vault.pinLengths == [6])
        #expect(store.probe("rk.pin.novo") == .absent)
        #expect(vault.failureCount() == 0)

        // O antigo desfaz a troca.
        let (other, otherStore, _) = makeVault()
        let otherRK = try other.setUp(pin: secure("7305"))
        try other.writePINSlot(rk: otherRK, pin: secure("905128"), kdf: fastKDF, suffix: ".novo")
        #expect(bytes(try other.unlock(pin: secure("7305"))) == bytes(otherRK))
        #expect(other.pinLengths == [4])
        #expect(otherStore.probe("rk.pin.novo") == .absent)
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
        vault.biometryAvailability = { .available }
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.enableBiometry(rk: rk)
        #expect(vault.isBiometryEnabled)
        #expect(bytes(try vault.unlockWithBiometry(reason: "teste")) == bytes(rk))
        try vault.disableBiometry(pin: secure("482916"), reason: "teste")
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

    @Test("A1: com o Face ID ligado, ver as palavras pede o PIN e o rosto; sem ele, o PIN")
    func pinAndBiometry() throws {
        let (vault, _, wrapper) = makeVault()
        vault.biometryAvailability = { .available }
        let rk = try vault.setUp(pin: secure("482916"))
        #expect(bytes(try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste")) == bytes(rk))

        try vault.enableBiometry(rk: rk)
        // PIN errado nem chega ao rosto, e conta tentativa.
        #expect(throws: RootKeyVault.Failure.wrongPIN(remainingBeforeWipe: nil)) {
            try vault.unlockWithPINAndBiometry(pin: secure("000001"), reason: "teste")
        }
        #expect(vault.failureCount() == 1)
        // PIN certo sem o rosto nao abre, e o slot continua.
        wrapper.refuseBiometry = true
        #expect(throws: RootKeyVault.Failure.cancelled) { try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste") }
        #expect(vault.isBiometryEnabled)
        wrapper.refuseBiometry = false
        #expect(bytes(try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste")) == bytes(rk))
        #expect(vault.failureCount() == 0)

        // Desligar pede os dois; desligado pelo dono, sem espera, volta a ser so o PIN.
        wrapper.refuseBiometry = true
        #expect(throws: RootKeyVault.Failure.cancelled) { try vault.disableBiometry(pin: secure("482916"), reason: "teste") }
        #expect(vault.isBiometryEnabled)
        wrapper.refuseBiometry = false
        try vault.disableBiometry(pin: secure("482916"), reason: "teste")
        #expect(!vault.isBiometryEnabled)
        #expect(vault.biometryHoldRemaining == 0)
        #expect(bytes(try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste")) == bytes(rk))
    }

    @Test("A1: o Face ID que cai sozinho trava ate religar, e religar comeca a espera")
    func biometryLossHold() throws {
        let (vault, store, wrapper) = makeVault()
        vault.biometryAvailability = { .available }
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.enableBiometry(rk: rk)
        // O primeiro Face ID nao espera: antes dele, o PIN ja abria tudo.
        #expect(vault.biometryHoldRemaining == 0)

        // Cadastro de rosto novo: a chave do SE some, o slot sai, a espera comeca e a marca
        // de perdido fica.
        wrapper.deleteKey(.biometry)
        #expect(throws: RootKeyVault.Failure.biometryChanged) { try vault.unlockWithBiometry(reason: "teste") }
        #expect(!vault.isBiometryEnabled)
        #expect(vault.biometryHoldRemaining > PINPolicy.biometryLossHold - 60)
        // Recusa antes do PIN: nenhuma tentativa gasta.
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste") }
        #expect(vault.failureCount() == 0)

        // Vencida a espera, sem religar, continua recusando: nunca volta sozinho a so o PIN.
        try store.update(HoldRecord(uptimeDeadline: 0, bootSession: PINPolicy.bootSession).encoded, account: "bio.espera")
        #expect(throws: RootKeyVault.Failure.biometryRequired) { try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste") }

        // Religar (com o rosto de quem for) tira a marca e comeca a espera a partir de agora.
        try vault.enableBiometry(rk: try vault.unlock(pin: secure("482916")))
        #expect(store.raw("bio.perdido") == nil)
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste") }

        // De outro boot, a espera recomeca cheia ao regravar.
        let otherBoot = [UInt8](repeating: 7, count: 16)
        try store.update(HoldRecord(uptimeDeadline: 1, bootSession: otherBoot).encoded, account: "bio.espera")
        #expect(vault.biometryHoldRemaining == PINPolicy.biometryLossHold)
        vault.rebaseAttempts()
        let rebasedData = try #require(store.raw("bio.espera"))
        let rebased = try #require(HoldRecord(rebasedData))
        #expect(rebased.bootSession == PINPolicy.bootSession)

        // Vencida, o registro sai e volta a valer PIN e rosto.
        try store.update(HoldRecord(uptimeDeadline: 0, bootSession: PINPolicy.bootSession).encoded, account: "bio.espera")
        #expect(bytes(try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste")) == bytes(rk))
        #expect(store.raw("bio.espera") == nil)
    }

    @Test("A1, revisao: religar por cima do slot do dono com o rosto de outro nao ve a frase na hora")
    func reenableOverOwnerSlot() throws {
        let (vault, store, wrapper) = makeVault()
        vault.biometryAvailability = { .available }
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.enableBiometry(rk: rk)
        // O ladrao cadastra o proprio rosto: a K_bio do dono e invalidada, o rk.bio fica.
        wrapper.deleteKey(.biometry)
        // O app continua dizendo que o Face ID esta ligado, e religar e uma queda.
        #expect(vault.isBiometryEnabled)
        try vault.enableBiometry(rk: try vault.unlock(pin: secure("482916")))
        #expect(vault.biometryHoldRemaining > PINPolicy.biometryLossHold - 60)
        #expect(throws: RootKeyVault.Failure.self) { try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste") }

        // Variante: religa e cancela a conferencia. O slot novo sai, a marca fica, e o que
        // pede PIN e rosto nao vira so o PIN.
        wrapper.deleteKey(.biometry)
        wrapper.refuseBiometry = true
        #expect(throws: RootKeyVault.Failure.cancelled) { try vault.enableBiometry(rk: try vault.unlock(pin: secure("482916"))) }
        #expect(!vault.isBiometryEnabled)
        try store.update(HoldRecord(uptimeDeadline: 0, bootSession: PINPolicy.bootSession).encoded, account: "bio.espera")
        #expect(throws: RootKeyVault.Failure.biometryRequired) { try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste") }
    }

    @Test("A1, revisao: a queda conta quando o app abre, nao quando alguem usa o Face ID")
    func lossSeenAtLaunch() throws {
        let (vault, store, wrapper) = makeVault()
        vault.biometryAvailability = { .available }
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.enableBiometry(rk: rk)
        wrapper.deleteKey(.biometry)
        vault.rebaseAttempts()
        #expect(store.raw("bio.perdido") != nil)
        #expect(!vault.isBiometryEnabled)
        #expect(vault.biometryHoldRemaining > 0)
    }

    @Test("A1: Face ID indisponivel recusa sem apagar; chaveiro mudo recusa")
    func biometryUnavailableAndUnknown() throws {
        let (vault, store, _) = makeVault()
        vault.biometryAvailability = { .gone }
        let rk = try vault.setUp(pin: secure("482916"))
        try vault.enableBiometry(rk: rk)
        #expect(throws: RootKeyVault.Failure.biometryUnavailable) { try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste") }
        // Nada caiu: o slot fica, sem espera e sem marca, e nunca vira so o PIN.
        #expect(vault.isBiometryEnabled)
        #expect(vault.biometryHoldRemaining == 0)
        #expect(store.raw("bio.perdido") == nil)
        #expect(throws: RootKeyVault.Failure.biometryUnavailable) { try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste") }

        // Registro da espera ilegivel: espera cheia, nunca zero.
        try store.add(Data([1, 2, 3]), account: "bio.espera", protection: .standard, context: nil)
        #expect(vault.biometryHoldRemaining == PINPolicy.biometryLossHold)
        try store.delete("bio.espera")

        // Chaveiro que nao responde sobre o slot do rosto, a espera ou a marca nunca vira
        // "so o PIN".
        for account in ["rk.bio", "bio.espera", "bio.perdido"] {
            store.unknown = [account]
            #expect(throws: RootKeyVault.Failure.storage) { try vault.unlockWithPINAndBiometry(pin: secure("482916"), reason: "teste") }
        }
        store.unknown = []
    }

    @Test("Escada: do nono erro em diante dobra, de 3 horas ate 7 dias")
    func throttleCeiling() {
        #expect(PINPolicy.delay(afterFailures: 8) == 3600)
        #expect(PINPolicy.delay(afterFailures: 9) == 3 * 3600)
        #expect(PINPolicy.delay(afterFailures: 10) == 6 * 3600)
        #expect(PINPolicy.delay(afterFailures: 12) == 24 * 3600)
        #expect(PINPolicy.delay(afterFailures: 15) == 7 * 24 * 3600)
        #expect(PINPolicy.delay(afterFailures: 40) == 7 * 24 * 3600)
        #expect(PINPolicy.delay(afterFailures: .max) == 7 * 24 * 3600)
        // Chutes possiveis em 30 dias e em um ano, contando a espera de cada erro.
        func guesses(within limit: TimeInterval) -> Int {
            var elapsed: TimeInterval = 0
            var count = 0
            while elapsed <= limit {
                count += 1
                elapsed += PINPolicy.delay(afterFailures: UInt32(count))
            }
            return count
        }
        #expect(guesses(within: 30 * 86400) == 18)
        #expect(guesses(within: 365 * 86400) == 66)
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
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.changePIN(rk: rk, newPIN: secure("11111")) }
        #expect(throws: RootKeyVault.Failure.malformedPIN) { try vault.changePIN(rk: rk, newPIN: secure("111a")) }
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
        // Formato 2 (auditoria 3, A1): o cadastro nao cria mais a chave antiga do
        // aparelho, e a do PIN tem senha. A trava da antiga continua: uma vez criada, ela
        // nunca e substituida em silencio.
        #expect(!wrapper.hasKey(.device) && wrapper.hasKey(.pin))
        try wrapper.createKey(.device)
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

    /// Um registro gravado em portugues pelo `save` de hoje: a RK e o id de
    /// `portugueseFixture`, entropia 00112233...eeff, sem 25a palavra. O idioma vai no
    /// codigo fixo (9). Se o enum for reordenado, ou o codigo voltar a ser a posicao em
    /// `allCases`, a frase abre em outro idioma, e a carteira com ela (auditoria 4, C7-16).
    static let portugueseRecord =
        "017a09b8bd8c8f8ee0efeb035e402150ca279c42858628ba8f7672b85bf2624d0f04ef9bcdf0e517b336ab1d328fe39991747fe0ef91192fd1178241a4516f90d7"
        + "4d1441f4d40b2de7f75c590ef7ee943657e750fe1e5503ab5790dfb4c1290b067b82883f68b47bf4debebd00f2ec09c0e3dea90874f76136add9ccf3e8b8371"
        + "4715b13995713efda6ec07fcfb843244c3cc96736520b0e3984508aba97cadce5d5d4ccec81bc867e664084d421e20acedf7b392c7e7def4f46dc6edc331e6880"
        + "048f22bc277fb5f7c098a89bc08e9a0621a40e916cb8fe7867f12bcffbe2535036e422e1d71b2b2a8b665a53ecccd9cb2c7a8cbdc905c5cb96f239326d193938"
        + "49bb0b29957773797214d180d27982cc9d89076453837377b9f5f120778f602cc985bb64eabd299bd3b62210dda3f4aa30c5e6cb2e51906631ba98c0d0381ae535"
        + "0c68a3002c78a54ff58a66679e23572ceb7a56b19bacf49d54a36ebd975b3be613410f4a24e401edf70b9e70ec1c6591a076ffdb491c4909222c56463d7ecd518"
        + "4296d52ef6879df0c5dd97bc461b15e39841dd350866ecf4dc26ce59b9336379586aa88002deb82d91e1a76d72a82847bfeb3c630bd8dcbd90b0e4bc9b857"

    @Test("Regressao C7-16: registro gravado em portugues abre em portugues, com a mesma frase")
    func portugueseFixture() throws {
        let store = MemoryStore()
        let id = try #require(UUID(uuidString: "5C7E6B0A-9D2F-4E31-8A4B-2F1D0C9E8B7A"))
        let blob = try #require(Hex.decode(Self.portugueseRecord))
        try store.add(Data(blob), account: WalletVault.account(id), protection: .standard, context: nil)
        let rk = SecureBytes(capacity: 32)
        rk.replaceAll(with: (0..<32).map { UInt8($0) &* 7 &+ 3 })
        defer { rk.wipe() }
        let secret = try WalletVault(store: store).open(walletID: id, rk: rk)
        defer { secret.wipe() }
        #expect(secret.language == .portuguese)
        #expect(secret.entropy.withUnsafeBytes { Array($0) } == (0..<16).map { UInt8($0) &* 17 })
        #expect(secret.passphrase.count == 0)
        let phrase = try secret.phrase()
        defer { phrase.wipe() }
        #expect(phrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            == "abacate joia lareira joaninha enchente colar bengala cetim pilotar feno hidratar zarpar")
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
        let result = try Signer.sign(plan, rootKey: restored, vault: vault, passphrase: nil)
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
        #expect(throws: Signer.Failure.unexpectedKey) { try Signer.sign(wrongPlan, rootKey: again, vault: vault, passphrase: nil) }

        // Plano vencido: nada e assinado.
        let old = SigningPlan(walletID: id, chain: .ethereum, review: PlanReview(kind: .send, title: "x", lines: []), transactions: [tx], createdAt: .now.addingTimeInterval(-120))
        let third = SecureBytes(capacity: 32)
        third.replaceAll(with: keep)
        #expect(throws: Signer.Failure.expired) { try Signer.sign(old, rootKey: third, vault: vault, passphrase: nil) }
    }

    @Test("Com a passphrase pedida para enviar, so a certa assina, em NFC ou NFKD")
    func signerPassphrase() throws {
        let store = MemoryStore()
        let vault = WalletVault(store: store)
        let rk = try SecureBytes.random(count: 32)
        let keep = rk.withUnsafeBytes { Array($0) }
        let id = UUID()
        // A passphrase gravada em NFKD, como a criacao grava ("ação" com o til separado).
        let raw = SecureBytes(capacity: 64)
        raw.replaceAll(with: Array("ação secreta".utf8))
        let stored = BIP39.nfkd(raw)
        let base = try WalletSecret.from(phrase: BIP39.canonical(Self.phrase), language: .english)
        let entropy = SecureBytes(capacity: base.entropy.count)
        base.entropy.withUnsafeBytes { entropy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        let secret = WalletSecret(entropy: entropy, language: base.language, passphrase: stored)
        try vault.save(secret, walletID: id, rk: rk)
        let (accounts, _) = try AccountDeriver.derive(secret)
        let eth = try #require(accounts.first { $0.chainID == "ethereum" })
        let digest = Hash.keccak256(Array("mensagem".utf8))
        let tx = FakeTransaction(chain: .ethereum, signingRequests: [
            SigningRequest(path: eth.path, curve: .secp256k1, scheme: .ecdsaRecoverable, payload: digest, expectedPublicKey: eth.publicKey),
        ])
        let plan = SigningPlan(walletID: id, chain: .ethereum, review: PlanReview(kind: .send, title: "teste", lines: []), transactions: [tx])
        func key() -> SecureBytes { let k = SecureBytes(capacity: 32); k.replaceAll(with: keep); return k }
        func typed(_ text: String) -> SecureBytes { let b = SecureBytes(capacity: 64); b.replaceAll(with: Array(text.utf8)); return b }

        // A digitada em NFC (como vem do teclado) assina.
        let given = typed("ação secreta")
        #expect(try Signer.sign(plan, rootKey: key(), vault: vault, passphrase: given).count == 1)
        #expect(given.count > 0)  // o buffer continua do chamador
        // Carteira antiga, com a passphrase gravada em NFC: a digitada (NFC) tambem confere,
        // porque as duas passam por NFKD antes de comparar.
        let legacyID = UUID()
        let legacyRaw = typed("ação secreta")
        let legacyEntropy = SecureBytes(capacity: base.entropy.count)
        base.entropy.withUnsafeBytes { legacyEntropy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        let legacy = WalletSecret(entropy: legacyEntropy, language: base.language, passphrase: legacyRaw)
        try vault.save(legacy, walletID: legacyID, rk: key())
        let (legacyAccounts, _) = try AccountDeriver.derive(legacy)
        let legacyEth = try #require(legacyAccounts.first { $0.chainID == "ethereum" })
        let legacyPlan = SigningPlan(walletID: legacyID, chain: .ethereum, review: PlanReview(kind: .send, title: "teste", lines: []), transactions: [
            FakeTransaction(chain: .ethereum, signingRequests: [
                SigningRequest(path: legacyEth.path, curve: .secp256k1, scheme: .ecdsaRecoverable, payload: digest, expectedPublicKey: legacyEth.publicKey),
            ]),
        ])
        #expect(try Signer.sign(legacyPlan, rootKey: key(), vault: vault, passphrase: typed("ação secreta")).count == 1)
        // Uma letra a menos, maiuscula diferente ou vazia: nada e assinado.
        for wrong in ["ação secret", "Ação secreta", ""] {
            #expect(throws: Signer.Failure.passphraseMismatch) {
                try Signer.sign(plan, rootKey: key(), vault: vault, passphrase: typed(wrong))
            }
        }
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
