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
            Step(id: "tela", title: String(localized: "Tela sem gravação nem AirPlay"), run: screen),
            Step(id: "teclado", title: String(localized: "Teclados de terceiros bloqueados"), run: keyboards),
            Step(id: "sistema", title: "iOS \(version.majorVersion).\(version.minorVersion)", run: system),
            Step(id: "copia", title: String(localized: "Nada copiado na área de transferência"), run: clipboard),
            Step(id: "leitor", title: String(localized: "Nada lendo a tela em voz alta"), run: voiceOver),
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
        #if DEBUG
        // `-checagem-falha`: o jailbreak acusado, para ver a tela de quando uma checagem falha.
        if DebugDemo.arguments.contains("-checagem-falha") {
            return .init(id: "jailbreak", title: "Sinal de jailbreak encontrado",
                         outcome: .fail("Este iPhone parece ter jailbreak. Num aparelho assim, outro app pode ler a memória e o que você digita."))
        }
        #endif
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
            // O titulo diz o que foi achado, como na area de transferencia e no leitor.
            return .init(id: "jailbreak", title: String(localized: "Sinal de jailbreak encontrado"),
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
            return .init(id: "injecao", title: String(localized: "Código injetado encontrado"),
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
        return traced
            ? .init(id: "depurador", title: String(localized: "Depurador conectado"),
                    outcome: .fail(String(localized: "Um depurador está preso ao app e pode ler a memória dele.")))
            : .init(id: "depurador", title: String(localized: "Nenhum depurador conectado"), outcome: .pass)
    }

    @MainActor
    static func screen() -> DeviceCheck {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Tela externa sem espelhar (cabo ou AirPlay estendido) abre uma sessao propria.
        let external = UIApplication.shared.openSessions.contains { $0.role == .windowExternalDisplayNonInteractive }
        let captured = scenes.contains { $0.screen.isCaptured || $0.traitCollection.sceneCaptureState == .active } || external
        // O Espelhamento do iPhone no Mac nao aparece para os apps (nao ha API, segundo o
        // suporte da Apple): a linha diz o que confere, e o aviso, o que nao da para ver
        // (auditoria 4, C7-06).
        return .init(id: "tela", title: String(localized: "Tela sem gravação nem AirPlay"),
                     outcome: captured
                        ? .fail(String(localized: "A tela está sendo gravada ou espelhada. Pare a gravação ou o AirPlay para seguir."))
                        : .caution(String(localized: "O Espelhamento do iPhone no Mac não aparece para os apps. Não use o espelhamento para digitar as palavras.")))
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
        // O titulo diz o que foi achado: "nada copiado" ao lado de um aviso de texto
        // copiado se contradizia.
        UIPasteboard.general.hasStrings
            ? .init(id: "copia", title: String(localized: "Há texto copiado"),
                    outcome: .caution(String(localized: "Se for a senha da carteira, apague depois de colar: a cópia pode ir para outros aparelhos Apple.")))
            : .init(id: "copia", title: String(localized: "Nada copiado na área de transferência"), outcome: .pass)
    }

    @MainActor
    static func voiceOver() -> DeviceCheck {
        // "Leitor de tela" sozinho nao dizia o que era conferido (pedido do dono, 16/10/2026).
        UIAccessibility.isVoiceOverRunning
            ? .init(id: "leitor", title: String(localized: "VoiceOver ligado"),
                    outcome: .caution(String(localized: "O VoiceOver lê em voz alta o que aparece na tela, inclusive as palavras. Use fone de ouvido, ou desligue em Ajustes > Acessibilidade > VoiceOver.")))
            : .init(id: "leitor", title: String(localized: "Nada lendo a tela em voz alta"), outcome: .pass)
    }
}

/// A checagem, antes de digitar a frase: cada item roda na hora em que a linha dele
/// gira, com o resultado logo ao lado, e no fim o horario exato da conferencia. Quem volta
/// desta tela e entra de novo ve "Conferindo de novo", com o horario da anterior: e uma
/// checagem nova, feita naquele instante. Voltar da tela de digitar nao refaz (a
/// conferencia continua valendo ali).
struct DeviceCheckView: View {
    /// O que o slider libera: digitar as palavras (importar) ou ver as palavras (carteira nova).
    var slideTitle = String(localized: "Deslize para digitar as palavras")
    /// Carteira nova (as palavras nascem aqui) ou importacao (as palavras sao digitadas):
    /// muda o que o dono declara ciente quando uma checagem falha.
    var creating = false
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
                // Titulo, subtitulo e horario no centro, embaixo do anel (pedido do dono, 16/10/2026).
                VStack(spacing: 0) {
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
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        row(step, result: index < results.count ? results[index] : nil, running: index == results.count && !finished)
                    }
                }
                .padding(.top, Space.md)
                // Uma checagem falhou e da para seguir: o dono declara, marcando, que sabe o que
                // falhou e o que isso arrisca (pedido do dono, 16/10/2026).
                if finished, !blocking.isEmpty, !screenBlocked {
                    ConsentCheckbox(checked: $acceptedRisk, text: creating
                        ? String(localized: "Estou ciente de que este iPhone falhou na verificação de integridade e de que gerar as palavras aqui pode expor a carteira. Quero seguir mesmo assim.")
                        : String(localized: "Estou ciente de que este iPhone falhou na verificação de integridade e de que digitar as palavras aqui pode expor a carteira. Quero seguir mesmo assim."))
                        .padding(.top, Space.md)
                        .accessibilityIdentifier("checagem-ciente")
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
                SlideToConfirm(title: finished ? slideTitle : String(localized: "Conferindo"),
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

/// O escaneamento em pixels, no estilo do `SlideToConfirm` (pedido do dono, 16/10/2026):
/// por fora, um anel de pixels que acende em verde, em ordem, conforme cada item fica
/// pronto (o mais novo acende mais claro e assenta); por dentro, pixels cinza cifrando, com
/// uma passada clara girando enquanto a checagem corre. No fim, o escudo com o resultado e
/// os pixels parados.
private struct ScanRing: View {
    let progress: Double
    let done: Bool
    let alert: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Quando cada pixel de fora acendeu, para o brilho de chegada.
    @State private var litAt: [Int: Date] = [:]

    private static let outer = 56
    private static let inner = 40

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || (done && litAt.values.allSatisfy { Date().timeIntervalSince($0) > 1 }))) { timeline in
            let now = timeline.date
            let clock = reduceMotion || done ? 0 : now.timeIntervalSinceReferenceDate
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let lit = Int((progress * Double(Self.outer)).rounded(.down))
                    let color = alert ? Palette.caution : Palette.success
                    // Por fora: o progresso.
                    for index in 0..<Self.outer {
                        let angle = Double(index) / Double(Self.outer) * 2 * .pi - .pi / 2
                        let point = CGPoint(x: center.x + 84 * CGFloat(cos(angle)), y: center.y + 84 * CGFloat(sin(angle)))
                        let square = CGRect(x: point.x - 3.25, y: point.y - 3.25, width: 6.5, height: 6.5)
                        if index < lit {
                            let age = litAt[index].map { now.timeIntervalSince($0) } ?? 10
                            let flash = reduceMotion ? 0 : exp(-max(age, 0) * 5)
                            let grown = Path(roundedRect: square.insetBy(dx: -1.2 * flash, dy: -1.2 * flash), cornerRadius: 1.6)
                            context.fill(grown, with: .color(color))
                            // O recem-aceso, mais claro, e assenta (o iOS 17 nao tem `mix`).
                            if flash > 0.01 { context.fill(grown, with: .color(.white.opacity(0.55 * flash))) }
                        } else {
                            context.fill(Path(roundedRect: square, cornerRadius: 1.6), with: .color(PixelFill.gray(Self.tone(index, ring: 0, clock: clock))))
                        }
                    }
                    // Por dentro: a cifra, com a passada girando.
                    let pass = (clock / 1.6).truncatingRemainder(dividingBy: 1) * 2 * .pi
                    for index in 0..<Self.inner {
                        let angle = Double(index) / Double(Self.inner) * 2 * .pi - .pi / 2
                        var distance = abs(angle + .pi / 2 - pass)
                        distance = min(distance, 2 * .pi - distance)
                        let glow = done ? 0 : exp(-(distance / 0.5) * (distance / 0.5))
                        let tone = Self.tone(index, ring: 1, clock: clock) + 0.4 * glow
                        let point = CGPoint(x: center.x + 66 * CGFloat(cos(angle)), y: center.y + 66 * CGFloat(sin(angle)))
                        let square = CGRect(x: point.x - 2.4, y: point.y - 2.4, width: 4.8, height: 4.8)
                        let fill = done ? color.opacity(0.35 + 0.25 * Self.tone(index, ring: 1, clock: 0)) : PixelFill.gray(tone)
                        context.fill(Path(roundedRect: square, cornerRadius: 1.2), with: .color(fill))
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
        .onChange(of: progress) { old, new in
            let from = Int((old * Double(Self.outer)).rounded(.down)), to = Int((new * Double(Self.outer)).rounded(.down))
            guard to > from else {
                if to < from { litAt = [:] }
                return
            }
            let start = Date()
            for index in from..<to { litAt[index] = start.addingTimeInterval(Double(index - from) * 0.018) }
        }
        .accessibilityHidden(true)
    }

    /// O tom cifrado de um pixel agora, como no `PixelFill`.
    private static func tone(_ index: Int, ring: Int, clock: Double) -> Double {
        let phase = PixelFill.noise(index, ring, 0x2B7F)
        let beat = clock * 6 * (0.6 + 0.8 * phase) + phase * 8
        let step = beat.rounded(.down)
        let t = beat - step
        let blend = t * t * (3 - 2 * t)
        let a = PixelFill.noise(index, ring, Int(step)), b = PixelFill.noise(index, ring, Int(step) + 1)
        return 0.16 + 0.22 * (a + (b - a) * blend)
    }
}
