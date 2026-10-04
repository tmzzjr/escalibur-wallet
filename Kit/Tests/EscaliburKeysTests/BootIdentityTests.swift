import Testing
@testable import EscaliburKeys

/// A identidade do boot no iPhone vem do `kern.boottime`, porque a sandbox recusa o
/// `kern.bootsessionuuid` (EPERM, medido no aparelho). Sem isto o Face ID nunca ligava:
/// o cofre via "boot desconhecido" e tratava o PIN como nao digitado.
@Suite("Identidade do boot")
struct BootIdentityTests {
    static func boottime(_ micros: UInt64) -> [UInt8] {
        PINPolicy.boottimeMark + (0..<8).map { UInt8(truncatingIfNeeded: micros >> (56 - 8 * $0)) }
    }

    let booted: UInt64 = 1_790_287_125_373_899

    @Test("Este processo tem identidade de boot conhecida, e ela e do mesmo boot que ela mesma")
    func currentIsKnown() {
        let now = PINPolicy.bootSession
        #expect(now != PINPolicy.unknownBoot)
        #expect(PINPolicy.isSameBoot(now, PINPolicy.bootSession))
    }

    @Test("Instante do boot: oscilacao de ajuste de hora e o mesmo boot; nos dois sentidos")
    func boottimeWobble() {
        #expect(PINPolicy.isSameBoot(Self.boottime(booted), Self.boottime(booted + 3_000)))
        #expect(PINPolicy.isSameBoot(Self.boottime(booted + 9_999_999), Self.boottime(booted)))
        #expect(PINPolicy.isSameBoot(Self.boottime(booted), Self.boottime(booted + 10_000_000)))
    }

    @Test("Reiniciar move o instante do boot por mais que a folga: boot novo")
    func reboot() {
        #expect(!PINPolicy.isSameBoot(Self.boottime(booted), Self.boottime(booted + 10_000_001)))
        // Reiniciado um minuto depois de ligar, o caso mais curto que existe na pratica.
        #expect(!PINPolicy.isSameBoot(Self.boottime(booted), Self.boottime(booted + 60_000_000)))
    }

    @Test("UUID compara byte a byte; formas diferentes e boot desconhecido nunca sao o mesmo boot")
    func formsAndUnknown() {
        let uuid: [UInt8] = Array(1...16)
        var other = uuid
        other[15] ^= 1
        #expect(PINPolicy.isSameBoot(uuid, uuid))
        #expect(!PINPolicy.isSameBoot(uuid, other))
        #expect(!PINPolicy.isSameBoot(uuid, Self.boottime(booted)))
        #expect(!PINPolicy.isSameBoot(PINPolicy.unknownBoot, PINPolicy.unknownBoot))
        #expect(!PINPolicy.isSameBoot(Self.boottime(booted), PINPolicy.unknownBoot))
        #expect(!PINPolicy.isSameBoot([], Self.boottime(booted)))
    }

    @Test("Tentativas gravadas neste boot pelo instante do boot nao recomecam a espera")
    func attemptRecordUsesTolerance() {
        let record = AttemptRecord(failures: 3, uptimeDeadline: PINPolicy.uptime + 30, bootSession: PINPolicy.bootSession)
        #expect(!record.isFromAnotherBoot)
        #expect(record.remaining() > 0 && record.remaining() <= 30)
        let stale = AttemptRecord(failures: 3, uptimeDeadline: 1, bootSession: PINPolicy.unknownBoot)
        #expect(stale.isFromAnotherBoot)
    }
}
