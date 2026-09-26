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
        guard digits.count == Self.digits else { return true }
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
        let text = d.map(String.init).joined()
        return common.contains(text)
    }

    /// PINs frequentes que as regras acima nao pegam: teclado, datas e palavras.
    private static let common: Set<String> = [
        "147258", "258369", "159753", "357159", "147852", "258456", "789456", "456789",
        "147369", "963852", "741852", "852963", "159357", "753159", "951357", "124578",
        "102030", "010203", "112358", "131313", "142536", "198700", "199000", "200000",
        "123654", "654123", "123789", "789123", "321654", "147147", "159159",
        "520520", "521521", "520131", "131420", "696969", "123698", "987456",
        "102938", "019283", "135790", "246810", "135791", "112211", "121314", "101010",
        "202020", "303030", "007007", "171717", "181818", "191919", "252525", "282828",
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

    /// Quantos erros apagam tudo, quando o dono liga essa opcao.
    public static let wipeThreshold: UInt32 = 10

    // MARK: Relogios

    /// Tempo desde o boot, que nao anda para tras quando alguem muda o relogio.
    static var uptime: TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9
    }

    /// O instante do ultimo boot. Se mudou, o relogio monotonico recomecou do zero,
    /// e o prazo gravado com ele deixou de fazer sentido.
    static var bootTime: TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1e6
    }
}

/// O registro de tentativas, gravado no chaveiro.
struct AttemptRecord: Equatable {
    var failures: UInt32
    var wallDeadline: TimeInterval
    var uptimeDeadline: TimeInterval
    var bootTime: TimeInterval

    static let zero = AttemptRecord(failures: 0, wallDeadline: 0, uptimeDeadline: 0, bootTime: 0)

    var encoded: Data {
        var out = Data()
        out.append(contentsOf: failures.bigEndianByteArray)
        for value in [wallDeadline, uptimeDeadline, bootTime] {
            out.append(contentsOf: value.bitPattern.bigEndianByteArray)
        }
        return out
    }

    init(failures: UInt32, wallDeadline: TimeInterval, uptimeDeadline: TimeInterval, bootTime: TimeInterval) {
        self.failures = failures
        self.wallDeadline = wallDeadline
        self.uptimeDeadline = uptimeDeadline
        self.bootTime = bootTime
    }

    init?(_ data: Data) {
        guard data.count == 28 else { return nil }
        let bytes = [UInt8](data)
        func u64(_ at: Int) -> UInt64 { bytes[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) } }
        failures = bytes[0..<4].reduce(0) { $0 << 8 | UInt32($1) }
        wallDeadline = Double(bitPattern: u64(4))
        uptimeDeadline = Double(bitPattern: u64(12))
        bootTime = Double(bitPattern: u64(20))
    }

    /// Registro do erro numero `failures`, com o prazo contado a partir de agora.
    static func after(failures: UInt32, now: Date = .now) -> AttemptRecord {
        let delay = PINPolicy.delay(afterFailures: failures)
        return AttemptRecord(
            failures: failures,
            wallDeadline: now.timeIntervalSince1970 + delay,
            uptimeDeadline: PINPolicy.uptime + delay,
            bootTime: PINPolicy.bootTime
        )
    }

    /// Quanto falta de espera. Vale o maior dos dois relogios enquanto o boot e o
    /// mesmo; mudar o relogio de parede nao encurta nada.
    func remaining(now: Date = .now) -> TimeInterval {
        let wall = wallDeadline - now.timeIntervalSince1970
        let mono = uptimeDeadline - PINPolicy.uptime
        return max(0, wall, mono)
    }
}
