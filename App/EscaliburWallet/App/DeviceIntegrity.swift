import Darwin
import Foundation
import MachO

/// Sinais de jailbreak e de depurador (docs/seguranca.md §7).
///
/// So aviso. Deteccao aqui e lombada: quem tem execucao de codigo contorna com
/// Frida, e um falso positivo trancaria o dono fora do proprio dinheiro. Ao detectar,
/// o app mostra uma faixa recomendando mover saldo alto para carteira de hardware.
/// Nunca bloqueia, nunca apaga, nunca avisa servidor nenhum.
enum DeviceIntegrity {
    static let suspicious: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return hasJailbreakFiles || canWriteOutsideSandbox || hasInjectedLibraries || isBeingTraced
        #endif
    }()

    private static var hasJailbreakFiles: Bool {
        ["/var/jb", "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
         "/usr/sbin/sshd", "/etc/apt", "/private/var/lib/apt", "/usr/bin/ssh"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    private static var canWriteOutsideSandbox: Bool {
        let path = "/private/escalibur-integridade"
        do {
            try Data([0]).write(to: URL(fileURLWithPath: path))
            try? FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    private static var hasInjectedLibraries: Bool {
        if ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] != nil { return true }
        let markers = ["frida", "substrate", "libhooker", "ellekit", "cycript", "substitute"]
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let lower = String(cString: name).lowercased()
            if markers.contains(where: lower.contains) { return true }
        }
        return false
    }

    private static var isBeingTraced: Bool {
        #if DEBUG
        return false
        #else
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
        #endif
    }
}
