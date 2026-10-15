import CryptoKit
import LocalAuthentication
import MachO
import SwiftUI
import UIKit

// A checagem do aparelho antes de digitar a frase (pedido do dono, 14/10/2026). O que
// torna a carteira segura passou para o tour depois do primeiro PIN (WelcomeTour,
// 15/10/2026).

// MARK: - A checagem do aparelho

/// Uma verificacao real do aparelho, feita no proprio iPhone, sem rede.
struct DeviceCheck: Identifiable, Equatable {
    enum Outcome: Equatable {
        case pass
        /// Merece atencao, nao impede.
        case caution(String)
        /// Impede seguir (tela gravada) ou exige o "sim" do dono (jailbreak).
        case fail(String)
    }

    let id: String
    let title: String
    let outcome: Outcome

    /// Um item da checagem: o nome aparece antes, e a verificacao roda de verdade so na
    /// hora em que a linha dele gira na tela (pedido do dono, 15/10/2026: a conferencia
    /// tem de ser factual, nao um resultado pronto revelado devagar).
    struct Step {
        let id: String
        let title: String
        let run: @MainActor () -> DeviceCheck
    }

    @MainActor
    static var steps: [Step] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [
            Step(id: "codigo", title: String(localized: "Código do iPhone ativo"), run: passcode),
            Step(id: "enclave", title: String(localized: "Secure Enclave disponível"), run: secureEnclave),
            Step(id: "jailbreak", title: String(localized: "Nenhum sinal de jailbreak"), run: jailbreak),
            Step(id: "injecao", title: String(localized: "Nenhum código injetado encontrado"), run: injection),
            Step(id: "depurador", title: String(localized: "Nenhum depurador conectado"), run: debugger),
            Step(id: "origem", title: String(localized: "Instalado pela App Store ou TestFlight"), run: origin),
            Step(id: "tela", title: String(localized: "Tela sem gravação nem espelhamento"), run: screen),
            Step(id: "teclado", title: String(localized: "Teclados de terceiros bloqueados"), run: keyboards),
            Step(id: "sistema", title: "iOS \(version.majorVersion).\(version.minorVersion)", run: system),
            Step(id: "copia", title: String(localized: "Área de transferência"), run: clipboard),
            Step(id: "leitor", title: String(localized: "Leitor de tela"), run: voiceOver),
        ]
    }

    /// Roda todas de uma vez (testes). Nada aqui sai do aparelho.
    @MainActor
    static func runAll() -> [DeviceCheck] { steps.map { $0.run() } }

    /// App Store e TestFlight entregam o app reassinado pela Apple, sem perfil de
    /// provisionamento dentro. Com perfil, o app foi instalado por outro caminho
    /// (reassinado, lateral), e o codigo pode nao ser o publicado.
    static func origin() -> DeviceCheck {
        #if DEBUG
        return .init(id: "origem", title: "Instalado pela App Store ou TestFlight", outcome: .caution("Build de teste, instalado pelo Xcode."))
        #else
        let sideloaded = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        return .init(id: "origem", title: String(localized: "Instalado pela App Store ou TestFlight"),
                     outcome: sideloaded ? .caution(String(localized: "Este app não veio da App Store nem do TestFlight. Instale a Escalibur só pela App Store.")) : .pass)
        #endif
    }

    @MainActor
    static func passcode() -> DeviceCheck {
        var error: NSError?
        let set = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        return .init(id: "codigo", title: String(localized: "Código do iPhone ativo"),
                     outcome: set ? .pass : .fail(String(localized: "Sem código, a proteção de dados do iOS não cifra os arquivos do app. Ative em Ajustes > Face ID e Código.")))
    }

    static func secureEnclave() -> DeviceCheck {
        .init(id: "enclave", title: String(localized: "Secure Enclave disponível"),
              outcome: SecureEnclave.isAvailable ? .pass : .caution(String(localized: "Este aparelho não tem o chip de segurança disponível agora.")))
    }

    /// Os caminhos e a escrita fora da caixa de areia que so existem num iPhone com
    /// jailbreak.
    static func jailbreak() -> DeviceCheck {
        #if targetEnvironment(simulator)
        return .init(id: "jailbreak", title: String(localized: "Nenhum sinal de jailbreak"), outcome: .caution(String(localized: "Simulador: a checagem só vale num iPhone de verdade.")))
        #else
        // No Mac, `/bin/bash` e `/usr/sbin/sshd` existem de fabrica: o aviso seria falso.
        if DeviceIntegrity.onMac {
            return .init(id: "jailbreak", title: String(localized: "Nenhum sinal de jailbreak"), outcome: .caution(String(localized: "No Mac, a checagem só vale num iPhone de verdade.")))
        }
        let paths = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app", "/bin/bash", "/usr/sbin/sshd",
                     "/etc/apt", "/private/var/lib/apt", "/usr/bin/ssh", "/var/jb", "/private/preboot/jb", "/.bootstrapped"]
        let found = paths.first { FileManager.default.fileExists(atPath: $0) }
        // Num jailbreak com raiz gravavel, pastas do sistema viram links simbolicos.
        let linked = ["/Applications", "/Library/Ringtones", "/Library/Wallpaper", "/usr/arm-apple-darwin9", "/usr/include", "/usr/libexec", "/usr/share"]
            .contains { (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSymbolicLink }
        let probe = "/private/escalibur-\(UUID().uuidString)"
        let writable = (try? "x".write(toFile: probe, atomically: false, encoding: .utf8)) != nil
        if writable { try? FileManager.default.removeItem(atPath: probe) }
        guard found == nil, !writable, !linked else {
            return .init(id: "jailbreak", title: String(localized: "Nenhum sinal de jailbreak"),
                         outcome: .fail(String(localized: "Este iPhone parece ter jailbreak. Num aparelho assim, outro app pode ler a memória e o que você digita.")))
        }
        return .init(id: "jailbreak", title: String(localized: "Nenhum sinal de jailbreak"), outcome: .pass)
        #endif
    }

    /// Bibliotecas de injecao carregadas no processo (Frida, Substrate e afins).
    static func injection() -> DeviceCheck {
        let marks = ["frida", "substrate", "substitute", "libhooker", "cycript", "sslkillswitch", "tweakinject", "ellekit"]
        var hit: String?
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let name = String(cString: raw).lowercased()
            if let mark = marks.first(where: { name.contains($0) }) {
                hit = mark
                break
            }
        }
        let inserted = ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] != nil
        guard hit == nil, !inserted else {
            return .init(id: "injecao", title: String(localized: "Nenhum código injetado encontrado"),
                         outcome: .fail(String(localized: "Há uma biblioteca de interceptação carregada no app (\(hit ?? "DYLD_INSERT_LIBRARIES")). Alguém pode estar lendo o que a tela mostra.")))
        }
        return .init(id: "injecao", title: String(localized: "Nenhum código injetado encontrado"), outcome: .pass)
    }

    /// `P_TRACED`: um depurador preso ao processo.
    static func debugger() -> DeviceCheck {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let traced = sysctl(&mib, 4, &info, &size, nil, 0) == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
        #if DEBUG
        if traced { return .init(id: "depurador", title: "Nenhum depurador conectado", outcome: .caution("Build de teste rodando pelo Xcode.")) }
        #endif
        return .init(id: "depurador", title: String(localized: "Nenhum depurador conectado"),
                     outcome: traced ? .fail(String(localized: "Um depurador está preso ao app e pode ler a memória dele.")) : .pass)
    }

    @MainActor
    static func screen() -> DeviceCheck {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Tela externa sem espelhar (cabo ou AirPlay estendido) abre uma sessao propria.
        let external = UIApplication.shared.openSessions.contains { $0.role == .windowExternalDisplayNonInteractive }
        let captured = scenes.contains { $0.screen.isCaptured || $0.traitCollection.sceneCaptureState == .active } || external
        return .init(id: "tela", title: String(localized: "Tela sem gravação nem espelhamento"),
                     outcome: captured ? .fail(String(localized: "A tela está sendo gravada ou espelhada. Pare a gravação ou o AirPlay para seguir.")) : .pass)
    }

    static func keyboards() -> DeviceCheck {
        // O app recusa todo teclado de terceiros (PlatformGuards): so o da Apple digita aqui.
        .init(id: "teclado", title: String(localized: "Teclados de terceiros bloqueados"), outcome: .pass)
    }

    /// O iOS contra a versao com que este build foi feito: abaixo dela, o aparelho pode
    /// estar sem correcoes de seguranca que ja existem.
    static func system() -> DeviceCheck {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(version.majorVersion).\(version.minorVersion)"
        let behind = (version.majorVersion, version.minorVersion) < (26, 5)
        return .init(id: "sistema", title: "iOS \(current)",
                     outcome: behind ? .caution(String(localized: "Existe iOS mais novo, com correções de segurança. Atualize quando puder.")) : .pass)
    }

    @MainActor
    static func clipboard() -> DeviceCheck {
        .init(id: "copia", title: String(localized: "Área de transferência"),
              outcome: UIPasteboard.general.hasStrings
                ? .caution(String(localized: "Há texto copiado. Se for a senha da carteira, apague depois de colar: a cópia pode ir para outros aparelhos Apple."))
                : .pass)
    }

    @MainActor
    static func voiceOver() -> DeviceCheck {
        .init(id: "leitor", title: String(localized: "Leitor de tela"),
              outcome: UIAccessibility.isVoiceOverRunning ? .caution(String(localized: "O VoiceOver está ligado e lê as palavras em voz alta. Use fone de ouvido.")) : .pass)
    }
}

/// A checagem, antes de digitar a frase: cada item roda na hora em que a linha dele
/// gira, com o resultado logo ao lado, e no fim o horario exato da conferencia. Quem volta
/// desta tela e entra de novo ve "Conferindo de novo", com o horario da anterior: e uma
/// checagem nova, feita naquele instante. Voltar da tela de digitar nao refaz (a
/// conferencia continua valendo ali).
struct DeviceCheckView: View {
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var steps: [DeviceCheck.Step] = []
    @State private var results: [DeviceCheck] = []
    @State private var acceptedRisk = false
    @State private var started = false
    @State private var previous: Date?
    @State private var checkedAt: Date?

    /// A ultima conferencia terminada nesta abertura do app.
    @MainActor static var lastChecked: Date?

    private var finished: Bool { !steps.isEmpty && results.count >= steps.count }
    private var blocking: [DeviceCheck] { results.filter { if case .fail = $0.outcome { return true }; return false } }
    private var screenBlocked: Bool { blocking.contains { $0.id == "tela" || $0.id == "codigo" } }
    private var canContinue: Bool { finished && !screenBlocked && (blocking.isEmpty || acceptedRisk) }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits).second(.twoDigits).locale(Fmt.locale))
    }

    private var title: String {
        if finished { return blocking.isEmpty ? String(localized: "Aparelho conferido") : String(localized: "Atenção antes de seguir") }
        return previous == nil ? String(localized: "Conferindo este iPhone") : String(localized: "Conferindo de novo")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScanRing(progress: steps.isEmpty ? 0 : Double(results.count) / Double(steps.count), done: finished,
                         alert: finished && !blocking.isEmpty)
                    .frame(height: 220).frame(maxWidth: .infinity)
                Text(title)
                    .typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.sm)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("checagem-titulo")
                Text(finished ? String(localized: "Tudo foi checado aqui, sem internet, e nada sai do aparelho. Um jailbreak escondido pode passar sem aparecer.")
                     : (results.count < steps.count ? String(localized: "Checando: \(steps[results.count].title)") : String(localized: "Preparando a checagem")))
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
                    .fixedSize(horizontal: false, vertical: true)
                if let previous, !finished {
                    stamp(String(localized: "A anterior foi às \(Self.clock(previous)). Esta é nova, item por item, agora."), icon: "arrow.clockwise")
                }
                if let checkedAt, finished {
                    stamp(previous == nil ? String(localized: "Conferido às \(Self.clock(checkedAt))")
                                          : String(localized: "Conferido de novo às \(Self.clock(checkedAt))"), icon: "clock")
                        .accessibilityIdentifier("checagem-horario")
                }
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        row(step, result: index < results.count ? results[index] : nil, running: index == results.count && !finished)
                    }
                }
                .padding(.top, Space.md)
                if finished, !blocking.isEmpty, !screenBlocked {
                    Toggle(isOn: $acceptedRisk) {
                        Text("Entendo o risco e quero seguir mesmo assim").typeStyle(.row).foregroundStyle(Palette.ink)
                    }
                    .tint(Palette.accent)
                    .padding(.top, Space.md)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.lg)
        }
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                if finished, screenBlocked {
                    SecondaryButton(title: String(localized: "Checar de novo")) { Task { await run() } }
                }
                SlideToConfirm(title: finished ? String(localized: "Deslize para digitar as palavras") : String(localized: "Conferindo"),
                               enabled: canContinue) { onContinue() }
                    .accessibilityIdentifier("deslizar-digitar")
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .background(ContentSwipeBackDisabled().frame(width: 0, height: 0))
        // So na primeira vez desta tela: voltar da tela de digitar nao refaz.
        .task {
            guard !started else { return }
            await run()
        }
    }

    private func stamp(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text).typeStyle(.note).monospacedDigit()
        }
        .foregroundStyle(Palette.inkSoft)
        .padding(.top, Space.xs)
    }

    private func run() async {
        started = true
        previous = Self.lastChecked
        checkedAt = nil
        acceptedRisk = false
        results = []
        steps = DeviceCheck.steps
        for step in steps {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 60 : 520))
            guard !Task.isCancelled else { return }
            // A verificacao roda aqui, no instante em que a linha dela termina de girar.
            let result = step.run()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { results.append(result) }
        }
        let now = Date()
        checkedAt = now
        Self.lastChecked = now
    }

    private func row(_ step: DeviceCheck.Step, result: DeviceCheck?, running: Bool) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Group {
                if let result {
                    switch result.outcome {
                    case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                    case .caution: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.caution)
                    case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.down)
                    }
                } else if running {
                    ProgressView().controlSize(.small).tint(Palette.success).frame(width: 20, height: 20)
                } else {
                    Circle().stroke(Palette.edge, lineWidth: 1.5).frame(width: 20, height: 20)
                }
            }
            .font(.system(size: 20))
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(result?.title ?? step.title).typeStyle(.row).foregroundStyle(result == nil && !running ? Palette.inkMuted : Palette.ink)
                if let result {
                    switch result.outcome {
                    case .pass: EmptyView()
                    case .caution(let text), .fail(let text):
                        Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xs)
    }
}

/// O escaneamento: um feixe girando sobre o escudo, o anel enchendo conforme os itens
/// ficam prontos; no fim, o escudo com o resultado.
private struct ScanRing: View {
    let progress: Double
    let done: Bool
    let alert: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || done)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(Palette.edge, lineWidth: 6).frame(width: 168, height: 168)
                Circle().trim(from: 0, to: progress)
                    .stroke(alert ? Palette.caution : Palette.success, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 168, height: 168)
                    .animation(.easeOut(duration: 0.35), value: progress)
                if !done {
                    // O feixe do radar.
                    Circle()
                        .fill(AngularGradient(colors: [Palette.success.opacity(0), Palette.success.opacity(0.35)], center: .center,
                                              startAngle: .degrees(0), endAngle: .degrees(70)))
                        .frame(width: 150, height: 150)
                        .rotationEffect(.degrees(reduceMotion ? 0 : (t * 160).truncatingRemainder(dividingBy: 360)))
                        .mask(Circle().frame(width: 150, height: 150))
                    ForEach(0..<3, id: \.self) { wave in
                        let phase = (t * 0.6 + Double(wave) / 3).truncatingRemainder(dividingBy: 1)
                        Circle().stroke(Palette.success.opacity(0.3 * (1 - phase)), lineWidth: 1)
                            .frame(width: 70 + phase * 130, height: 70 + phase * 130)
                    }
                }
                Image(systemName: done ? (alert ? "exclamationmark.shield.fill" : "checkmark.shield.fill") : "shield.lefthalf.filled")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(done ? (alert ? Palette.caution : Palette.success) : Palette.ink)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(done ? 1.08 : 1)
                    .animation(.spring(response: 0.45, dampingFraction: 0.55), value: done)
            }
        }
        .accessibilityHidden(true)
    }
}
