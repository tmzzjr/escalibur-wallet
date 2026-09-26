import Darwin
import Foundation

/// As regras do PIN: lista de bloqueio, escada de atraso e o relogio que sobrevive a
/// reinicio sem trancar o dono por dias.
public enum PINPolicy {
    public static let digits = 6

    /// Com poucas tentativas permitidas, e a lista de bloqueio que decide o jogo:
    /// um ladrao tenta primeiro 123456, 000000 e a data de nascimento. Esta lista
    /// cobre repeticao, sequencia, padrao de teclado e os PINs de 6 digitos mais
    /// comuns em vazamentos (Markert et al., IEEE S&P 2020, e listas publicas).
    public static func isBlocked(_ digits: [UInt8]) -> Bool {
        guard digits.count == Self.digits, digits.allSatisfy({ $0 <= 9 }) else { return true }
        let d = digits.map { Int($0) }
        // Todos iguais.
        if Set(d).count == 1 { return true }
        // Sequencia crescente ou decrescente, com volta (789012, 210987).
        let up = (1..<6).allSatisfy { (d[$0] - d[$0 - 1] + 10) % 10 == 1 }
        let down = (1..<6).allSatisfy { (d[$0 - 1] - d[$0] + 10) % 10 == 1 }
        if up || down { return true }
        // Par repetido (121212), trinca repetida (123123), dobras (112233), espelho (123321).
        if d[0] == d[2], d[2] == d[4], d[1] == d[3], d[3] == d[5] { return true }
        if d[0] == d[3], d[1] == d[4], d[2] == d[5] { return true }
        if d[0] == d[1], d[2] == d[3], d[4] == d[5] { return true }
        if d[0] == d[5], d[1] == d[4], d[2] == d[3] { return true }
        // So dois digitos distintos (111222, 100001) tem pouca entropia de fato.
        if Set(d).count == 2 { return true }
        // Datas: o primeiro palpite de quem roubou o iPhone junto com a carteira e o
        // documento. DDMMAA, MMDDAA e AAMMDD, qualquer ano.
        if isDate(d) { return true }
        // Inteiro de 6 casas: o literal com zero a esquerda (010203) vale o mesmo.
        let value = d.reduce(0) { $0 * 10 + $1 }
        return common.contains(value)
    }

    static func isDate(_ d: [Int]) -> Bool {
        let a = d[0] * 10 + d[1], b = d[2] * 10 + d[3], c = d[4] * 10 + d[5]
        func valid(day: Int, month: Int) -> Bool {
            guard (1...12).contains(month), day >= 1 else { return false }
            let lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            return day <= lengths[month - 1]
        }
        return valid(day: a, month: b) || valid(day: b, month: a) || valid(day: c, month: b)
    }

    /// PINs frequentes que as regras acima nao pegam: teclado, datas e palavras.
    private static let common: Set<Int> = [
        147258, 258369, 159753, 357159, 147852, 258456, 789456, 456789, 147369, 963852,
        741852, 852963, 159357, 753159, 951357, 124578, 102030, 010203, 112358, 131313,
        142536, 198700, 199000, 200000, 123654, 654123, 123789, 789123, 321654, 147147,
        159159, 520520, 521521, 520131, 131420, 696969, 123698, 987456, 102938, 019283,
        135790, 246810, 135791, 112211, 121314, 101010, 202020, 303030, 007007, 171717,
        181818, 191919, 252525, 282828,
    ]

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
    static var bootSession: [UInt8] {
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
    static let unknownBoot = [UInt8](repeating: 0, count: 16)
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
