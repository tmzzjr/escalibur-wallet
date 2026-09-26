import Darwin
import Foundation

/// As regras do PIN: a forma, a escada de atraso e o relogio que sobrevive a
/// reinicio sem trancar o dono por dias.
public enum PINPolicy {
    public static let digits = 6

    /// O PIN e do dono: qualquer combinacao de 6 digitos vale, inclusive 111111 e
    /// 123456. Decisao do dono em 2026-09-26, que retirou a lista de PINs faceis. So a
    /// forma e conferida: exatamente 6 digitos de 0 a 9. Contra quem tenta pela
    /// interface ficam a escada de atraso e, se o dono ligar, o apagar apos erros.
    public static func isWellFormed(_ digits: [UInt8]) -> Bool {
        digits.count == Self.digits && digits.allSatisfy { $0 <= 9 }
    }

    /// A escada de atraso, em segundos, depois de `failures` erros seguidos.
    public static func delay(afterFailures failures: UInt32) -> TimeInterval {
        switch failures {
        case 0...2: return 0
        case 3: return 5
        case 4: return 15
        case 5: return 60
        case 6: return 5 * 60
        case 7: return 15 * 60
        case 8: return 60 * 60
        default: return 3 * 60 * 60
        }
    }

    /// Quantos erros podem apagar tudo, a escolha do dono (ou nunca).
    public static let wipeOptions: [UInt32] = [5, 10, 15, 20]

    // MARK: Relogios

    /// Tempo desde o boot, contando o tempo dormindo, e que nao anda para tras quando
    /// alguem muda o relogio. O relogio de parede nunca entra na conta da espera:
    /// adiantar nao encurta, atrasar nao tranca o dono por um ano.
    public static var uptime: TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9
    }

    /// Identidade deste boot (`kern.bootsessionuuid`). Se mudou, o relogio monotonico
    /// recomecou do zero e o prazo gravado com ele deixou de valer. Comparar um UUID
    /// e exato; o instante do boot em ponto flutuante oscilava com ajuste de NTP.
    public static var bootSession: [UInt8] {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return unknownBoot }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return unknownBoot }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let uuid = UUID(uuidString: text) else { return unknownBoot }
        return withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    /// Sem identidade de boot, cada leitura parece um boot novo: a espera recomeca
    /// cheia. Falha para o lado do dono esperar mais, nunca menos.
    public static let unknownBoot = [UInt8](repeating: 0, count: 16)
}

/// O registro de tentativas, gravado no chaveiro.
///
/// Formato 2 (29 bytes): versao, erros (u32), prazo no relogio monotonico (f64) e a
/// identidade do boot em que o prazo foi gravado (16 bytes).
struct AttemptRecord: Equatable {
    var failures: UInt32
    var uptimeDeadline: TimeInterval
    var bootSession: [UInt8]

    static let zero = AttemptRecord(failures: 0, uptimeDeadline: 0, bootSession: PINPolicy.unknownBoot)
    private static let version: UInt8 = 2

    var encoded: Data {
        var out = Data([Self.version])
        out.append(contentsOf: failures.bigEndianByteArray)
        out.append(contentsOf: uptimeDeadline.bitPattern.bigEndianByteArray)
        out.append(contentsOf: bootSession)
        return out
    }

    init(failures: UInt32, uptimeDeadline: TimeInterval, bootSession: [UInt8]) {
        self.failures = failures
        self.uptimeDeadline = uptimeDeadline
        self.bootSession = bootSession
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        switch bytes.count {
        case 29 where bytes[0] == Self.version:
            failures = bytes[1..<5].reduce(0) { $0 << 8 | UInt32($1) }
            uptimeDeadline = Double(bitPattern: bytes[5..<13].reduce(0) { $0 << 8 | UInt64($1) })
            bootSession = Array(bytes[13..<29])
        case 28:
            // Formato 1, de antes da auditoria: so o numero de erros ainda vale. O
            // boot desconhecido faz a espera recomecar cheia no proximo acesso.
            failures = bytes[0..<4].reduce(0) { $0 << 8 | UInt32($1) }
            uptimeDeadline = 0
            bootSession = PINPolicy.unknownBoot
        default:
            return nil
        }
    }

    /// Registro do erro numero `failures`, com o prazo contado a partir de agora.
    static func after(failures: UInt32) -> AttemptRecord {
        AttemptRecord(
            failures: failures,
            uptimeDeadline: PINPolicy.uptime + PINPolicy.delay(afterFailures: failures),
            bootSession: PINPolicy.bootSession
        )
    }

    /// O prazo foi gravado em outro boot (ou num formato antigo)?
    var isFromAnotherBoot: Bool {
        failures > 0 && (bootSession == PINPolicy.unknownBoot || bootSession != PINPolicy.bootSession)
    }

    /// Quanto falta de espera. De outro boot, a resposta e a espera cheia ate alguem
    /// regravar o prazo (`RootKeyVault.rebaseAttempts`); ler nunca escreve.
    func remaining() -> TimeInterval {
        let full = PINPolicy.delay(afterFailures: failures)
        guard !isFromAnotherBoot else { return full }
        return min(full, max(0, uptimeDeadline - PINPolicy.uptime))
    }
}
