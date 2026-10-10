import Foundation
import Testing
@testable import EscaliburKeys

/// "PIN digitado neste boot": a identidade do boot e o tempo desde o boot.
@Suite("Registro do PIN neste boot")
struct PINBootRecordTests {
    static let boot = PINPolicy.boottimeMark + [0, 0, 0, 0, 0x10, 0, 0, 0]

    @Test("Mesmo boot e tempo andando para frente: vale")
    func sameBoot() {
        let saved = PINPolicy.pinRecord(boot: Self.boot, uptime: 3_600)
        #expect(saved.count == 24)
        #expect(PINPolicy.pinRecordValid(saved, boot: Self.boot, uptime: 3_600))
        #expect(PINPolicy.pinRecordValid(saved, boot: Self.boot, uptime: 90_000))
    }

    @Test("Reiniciou e acertou a hora para o boot antigo: o tempo desde o boot voltou, nao vale")
    func forgedClockAfterRestart() {
        let saved = PINPolicy.pinRecord(boot: Self.boot, uptime: 3_600)
        #expect(!PINPolicy.pinRecordValid(saved, boot: Self.boot, uptime: 120))
    }

    @Test("Outro boot, registro antigo de 16 bytes ou lixo: nao vale")
    func refused() {
        let saved = PINPolicy.pinRecord(boot: Self.boot, uptime: 10)
        let other = PINPolicy.boottimeMark + [0, 0, 0, 0, 0x20, 0, 0, 0]
        #expect(!PINPolicy.pinRecordValid(saved, boot: other, uptime: 100))
        #expect(!PINPolicy.pinRecordValid(Self.boot, boot: Self.boot, uptime: 100))
        #expect(!PINPolicy.pinRecordValid(Self.boot + [UInt8](repeating: 0xFF, count: 8), boot: Self.boot, uptime: 100))
        #expect(!PINPolicy.pinRecordValid(PINPolicy.pinRecord(boot: PINPolicy.unknownBoot, uptime: 1), boot: PINPolicy.unknownBoot, uptime: 5))
    }
}
