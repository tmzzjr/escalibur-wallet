import Darwin
import Foundation

/// As regras do PIN: a forma, a escada de atraso e o relogio que sobrevive a
/// reinicio sem trancar o dono por dias.
public enum PINPolicy {
    /// O tamanho padrao, e o de todo PIN gravado antes de existir a escolha.
    public static let digits = 6

    /// Os tamanhos que o dono pode escolher (pedido do dono, 16/10/2026: 4 tambem). Com 4,
    /// sao 10^4 combinacoes em vez de 10^6: contra quem tem execucao de codigo no
    /// aparelho, minutos em vez de horas (docs/seguranca.md §2.8).
    public static let lengths = [4, 6]

    /// O PIN e do dono: qualquer combinacao de 4 ou 6 digitos vale, inclusive 1111 e
    /// 123456. Decisao do dono em 2026-09-26, que retirou a lista de PINs faceis. So a
    /// forma e conferida: 4 ou 6 digitos de 0 a 9. Contra quem tenta pela interface
    /// ficam a escada de atraso e, se o dono ligar, o apagar apos erros.
    public static func isWellFormed(_ digits: [UInt8]) -> Bool {
        lengths.contains(digits.count) && digits.allSatisfy { $0 <= 9 }
    }

    /// A escada de atraso, em segundos, depois de `failures` erros seguidos.
    ///
    /// Do nono erro em diante a espera dobra a cada erro, de 3 horas ate 7 dias (auditoria
    /// 4, C7-04). Com o teto antigo de 3 horas, quem tem o iPhone tentava cerca de 2.900
    /// PINs por ano; com o dobro, 18 em 30 dias e 66 em um ano.
    public static func delay(afterFailures failures: UInt32) -> TimeInterval {
        switch failures {
        case 0...2: return 0
        case 3: return 5
        case 4: return 15
        case 5: return 60
        case 6: return 5 * 60
        case 7: return 15 * 60
        case 8: return 60 * 60
        default:
            let doubled = 3 * 60 * 60 * pow(2, Double(min(failures - 9, 16)))
            return min(doubled, maxDelay)
        }
    }

    /// O teto da escada: 7 dias por tentativa.
    public static let maxDelay: TimeInterval = 7 * 24 * 60 * 60

    /// A espera do A1 depois que o Face ID cai sem o dono pedir (o cadastro de rostos mudou,
    /// o Face ID foi tirado do app ou do iPhone): durante ela, ver as palavras, lacrar o
    /// envelope e remover carteira ficam travados. Quem viu o codigo do iPhone e o PIN
    /// cadastra o proprio rosto e derruba o slot; sem a espera, isso trocava "PIN e rosto"
    /// por "so o PIN" na hora (auditoria 4, A1).
    public static let biometryLossHold: TimeInterval = 24 * 60 * 60

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

    /// Identidade deste boot, 16 bytes. Se mudou, o relogio monotonico recomecou do zero
    /// e o prazo gravado com ele deixou de valer.
    ///
    /// No Mac e no simulador e o `kern.bootsessionuuid`, comparado byte a byte. No iPhone
    /// a sandbox recusa essa leitura (EPERM, medido num iPhone 13 Pro Max com iOS 26.3):
    /// vale o instante do boot (`kern.boottime`), marcado com `boottimeMark` e comparado
    /// com folga de `boottimeTolerance` em `isSameBoot`, porque ele oscila um pouco com o
    /// ajuste de hora pela rede.
    public static var bootSession: [UInt8] {
        if let uuid = bootSessionUUID { return withUnsafeBytes(of: uuid.uuid) { Array($0) } }
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return unknownBoot }
        let micros = UInt64(time.tv_sec) * 1_000_000 + UInt64(time.tv_usec)
        return boottimeMark + (0..<8).map { UInt8(truncatingIfNeeded: micros >> (56 - 8 * $0)) }
    }

    private static var bootSessionUUID: UUID? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return UUID(uuidString: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// Os 8 primeiros bytes de uma identidade tirada do `kern.boottime` ("ESCBOOT1").
    static let boottimeMark: [UInt8] = Array("ESCBOOT1".utf8)

    /// Reiniciar move o instante do boot pelo tempo que o iPhone ficou ligado mais o da
    /// propria reinicializacao, sempre bem mais que isto. O ajuste de hora pela rede
    /// move milissegundos. Mudar a hora a mao parece um boot novo: o PIN volta a ser
    /// pedido e a espera recomeca cheia, nunca o contrario.
    static let boottimeTolerance: UInt64 = 10_000_000

    /// As duas identidades sao do mesmo boot? Desconhecida nunca e.
    public static func isSameBoot(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == 16, b.count == 16, a != unknownBoot, b != unknownBoot else { return false }
        guard Array(a.prefix(8)) == boottimeMark, Array(b.prefix(8)) == boottimeMark else { return a == b }
        let x = a.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let y = b.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (x > y ? x - y : y - x) <= boottimeTolerance
    }

    /// Sem identidade de boot, cada leitura parece um boot novo: a espera recomeca
    /// cheia. Falha para o lado do dono esperar mais, nunca menos.
    public static let unknownBoot = [UInt8](repeating: 0, count: 16)

    /// O registro de "PIN digitado neste boot": a identidade do boot e o tempo desde o
    /// boot naquele instante (24 bytes).
    ///
    /// So o instante do boot (`kern.boottime`) deixava uma brecha: depois de reiniciar,
    /// quem acertasse a hora a mao para o boot antigo cair dentro da folga religava o Face
    /// ID sem o PIN (auditoria 3, B2). O tempo desde o boot recomeca do zero ao reiniciar
    /// e nao anda com o relogio: o registro so vale se o de agora for maior.
    public static func pinRecord(boot: [UInt8], uptime: TimeInterval) -> [UInt8] {
        boot + withUnsafeBytes(of: uptime.bitPattern.bigEndian) { Array($0) }
    }

    /// Registro antigo, de so 16 bytes, nao vale: o PIN e pedido uma vez.
    public static func pinRecordValid(_ saved: [UInt8], boot: [UInt8], uptime: TimeInterval) -> Bool {
        guard saved.count == 24 else { return false }
        let recordedUptime = TimeInterval(bitPattern: saved.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        guard recordedUptime.isFinite, recordedUptime >= 0 else { return false }
        return isSameBoot(Array(saved.prefix(16)), boot) && uptime >= recordedUptime
    }
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
        failures > 0 && !PINPolicy.isSameBoot(bootSession, PINPolicy.bootSession)
    }

    /// Quanto falta de espera. De outro boot, a resposta e a espera cheia ate alguem
    /// regravar o prazo (`RootKeyVault.rebaseAttempts`); ler nunca escreve.
    func remaining() -> TimeInterval {
        let full = PINPolicy.delay(afterFailures: failures)
        guard !isFromAnotherBoot else { return full }
        return min(full, max(0, uptimeDeadline - PINPolicy.uptime))
    }
}

/// O prazo da espera depois que o Face ID caiu (`PINPolicy.biometryLossHold`), gravado no
/// chaveiro. 25 bytes: versao, prazo no relogio monotonico (f64) e a identidade do boot.
/// Mesmo relogio do contador de tentativas: mudar a hora nao encurta, e depois de
/// reiniciar a espera recomeca cheia.
struct HoldRecord: Equatable {
    var uptimeDeadline: TimeInterval
    var bootSession: [UInt8]

    private static let version: UInt8 = 1

    static func startingNow() -> HoldRecord {
        HoldRecord(uptimeDeadline: PINPolicy.uptime + PINPolicy.biometryLossHold, bootSession: PINPolicy.bootSession)
    }

    var encoded: Data {
        var out = Data([Self.version])
        out.append(contentsOf: uptimeDeadline.bitPattern.bigEndianByteArray)
        out.append(contentsOf: bootSession)
        return out
    }

    init(uptimeDeadline: TimeInterval, bootSession: [UInt8]) {
        self.uptimeDeadline = uptimeDeadline
        self.bootSession = bootSession
    }

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == 25, bytes[0] == Self.version else { return nil }
        uptimeDeadline = Double(bitPattern: bytes[1..<9].reduce(0) { $0 << 8 | UInt64($1) })
        bootSession = Array(bytes[9..<25])
    }

    var isFromAnotherBoot: Bool { !PINPolicy.isSameBoot(bootSession, PINPolicy.bootSession) }

    func remaining() -> TimeInterval {
        let full = PINPolicy.biometryLossHold
        guard !isFromAnotherBoot, uptimeDeadline.isFinite else { return full }
        return min(full, max(0, uptimeDeadline - PINPolicy.uptime))
    }
}
