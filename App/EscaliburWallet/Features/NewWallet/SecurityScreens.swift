import CryptoKit
import LocalAuthentication
import MachO
import SwiftUI
import UIKit

// Duas telas antes da frase (pedido do dono, 14/10/2026):
// - SecurityPromiseView: o que torna a carteira segura, antes do aceite de
//   responsabilidade, ao criar e ao importar;
// - DeviceCheckView: uma checagem de verdade do aparelho, antes de digitar a frase.

// MARK: - A promessa

/// Por que a carteira e segura, em cinco frases verificaveis, com a cena do iPhone que
/// guarda tudo sozinho: os dados chegam de fora e ficam, a nuvem e riscada, o anel de
/// cifra gira em volta e o codigo corre ao fundo.
struct SecurityPromiseView: View {
    let onContinue: () -> Void
    @State private var shown = 0

    private struct Point: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let text: String
    }

    private static let points: [Point] = [
        .init(id: 0, icon: "server.rack", title: String(localized: "Sem servidor"),
              text: String(localized: "A Escalibur não tem servidor nem conta. Ninguém do nosso lado vê, guarda ou consegue recuperar nada seu.")),
        .init(id: 1, icon: "iphone", title: String(localized: "Tudo só neste iPhone"),
              text: String(localized: "A senha da carteira nasce e fica aqui, cifrada com uma chave do Secure Enclave, o chip de segurança do iPhone. Ela nunca vai para a internet.")),
        .init(id: 2, icon: "chevron.left.forwardslash.chevron.right", title: String(localized: "Código aberto, para qualquer um auditar"),
              text: String(localized: "O código está público no GitHub. Dá para conferir, linha por linha, que a senha e as chaves nunca saem do aparelho.")),
        .init(id: 3, icon: "eye.slash", title: String(localized: "Sem rastreamento"),
              text: String(localized: "Nenhum SDK de análise, de anúncio ou de relatório de falhas. O app não conta a ninguém o que você faz.")),
        .init(id: 4, icon: "faceid", title: String(localized: "Nada sai sem você"),
              text: String(localized: "Toda transação passa pela sua revisão e pelo seu Face ID ou PIN. Sem você, ninguém assina nada.")),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VaultScene().frame(height: 300).padding(.horizontal, -Space.gutter)
                Text("Sua carteira, só sua").typeStyle(.title).foregroundStyle(Palette.ink)
                    .padding(.top, Space.md)
                Text("Antes de começar, o que protege o seu dinheiro aqui.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(Self.points) { point in
                        HStack(alignment: .top, spacing: Space.sm) {
                            Image(systemName: point.icon)
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accent)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(Palette.accent.opacity(0.14)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(point.title).typeStyle(.row).foregroundStyle(Palette.ink)
                                Text(point.text).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .opacity(shown > point.id ? 1 : 0)
                        .offset(y: shown > point.id ? 0 : 14)
                    }
                }
                .padding(.top, Space.lg)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.lg)
        }
        .safeAreaInset(edge: .bottom) {
            ActionFooter { PrimaryButton(title: String(localized: "Continuar"), enabled: shown >= Self.points.count) { onContinue() } }
        }
        .background(Palette.void.ignoresSafeArea())
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            for _ in Self.points {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { shown += 1 }
                try? await Task.sleep(for: .milliseconds(260))
            }
        }
        .accessibilityIdentifier("tela-seguranca")
    }
}

/// A cena: o iPhone com a espada no meio, ondas de protecao saindo dele, um anel de
/// glifos cifrados girando, dados entrando de todos os lados e ficando, a nuvem riscada
/// e codigo correndo ao fundo. Com "reduzir movimento", parada.
struct VaultScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 3.0 : timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2 + 6)
                Self.codeRain(&context, size: size, t: t)
                Self.shields(&context, center: center, t: t)
                Self.particles(&context, size: size, center: center, t: t)
                Self.glyphRing(&context, center: center, radius: min(size.width, size.height) * 0.42, t: t)
                Self.cloud(&context, at: CGPoint(x: size.width * 0.82, y: size.height * 0.2), t: t)
            }
            .overlay {
                PhoneWithSword()
                    .scaleEffect(reduceMotion ? 1 : min(1, 0.6 + t * 0.8))
                    .shadow(color: Palette.accent.opacity(0.35 + 0.15 * sin(t * 2.4)), radius: 28)
            }
        }
        .accessibilityHidden(true)
    }

    /// Colunas de hexadecimal descendo devagar, quase apagadas: o codigo aberto.
    static func codeRain(_ context: inout GraphicsContext, size: CGSize, t: Double) {
        let columns = Int(size.width / 22)
        for column in 0..<columns {
            let speed = 18 + Double((column * 37) % 23)
            let x = CGFloat(column) * 22 + 11
            for row in 0..<14 {
                let y = (Double(row) * 26 + t * speed).truncatingRemainder(dividingBy: Double(size.height) + 40) - 20
                let seed = (column * 131 + row * 17 + Int(t * 3)) % 16
                let glyph = String(LiveCipher.alphabet[seed])
                let fade = 0.05 + 0.07 * (1 - Double(row) / 14)
                context.draw(Text(glyph).font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Palette.inkMuted.opacity(fade)), at: CGPoint(x: x, y: y))
            }
        }
    }

    /// Ondas de protecao saindo do iPhone.
    static func shields(_ context: inout GraphicsContext, center: CGPoint, t: Double) {
        for wave in 0..<3 {
            let phase = (t * 0.45 + Double(wave) / 3).truncatingRemainder(dividingBy: 1)
            let radius = 60 + phase * 120
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(Palette.accent.opacity(0.35 * (1 - phase))), lineWidth: 1.5)
        }
    }

    /// Pontos que vem de fora e entram no iPhone: o que e seu chega e fica.
    static func particles(_ context: inout GraphicsContext, size: CGSize, center: CGPoint, t: Double) {
        for index in 0..<28 {
            let angle = Double(index) * 2.399963  // angulo de ouro: espalha sem padrao
            let cycle = 2.6 + Double(index % 5) * 0.35
            let phase = ((t + Double(index) * 0.21) / cycle).truncatingRemainder(dividingBy: 1)
            let distance = (1 - phase) * Double(max(size.width, size.height)) * 0.55
            let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance * 0.75)
            let radius = 1.6 + 1.4 * (1 - phase)
            let alpha = phase < 0.85 ? min(1, phase * 3) : (1 - phase) / 0.15
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(Palette.accent.opacity(0.75 * alpha)))
        }
    }

    /// O anel de glifos cifrados, girando.
    static func glyphRing(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, t: Double) {
        let count = 36
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * .pi + t * 0.35
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * 0.88)
            let seed = (index * 7 + Int(t * 12)) % 16
            let bright = 0.25 + 0.55 * (0.5 + 0.5 * sin(angle * 3 - t * 2))
            context.draw(Text(String(LiveCipher.alphabet[seed])).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(Palette.accent.opacity(bright)), at: point)
        }
    }

    /// A nuvem riscada: o traco vem e a nuvem apaga. Sem servidor.
    static func cloud(_ context: inout GraphicsContext, at point: CGPoint, t: Double) {
        let cycle = t.truncatingRemainder(dividingBy: 4.0)
        let slash = min(1, max(0, (cycle - 0.4) / 0.6))
        let fade = cycle > 2.8 ? max(0, 1 - (cycle - 2.8) / 1.2) : 1
        let symbol = context.resolve(Image(systemName: "cloud"))
        context.opacity = 0.55 * fade
        context.draw(symbol, in: CGRect(x: point.x - 18, y: point.y - 13, width: 36, height: 26))
        context.opacity = fade
        var line = Path()
        line.move(to: CGPoint(x: point.x - 20, y: point.y - 17))
        line.addLine(to: CGPoint(x: point.x - 20 + 40 * slash, y: point.y - 17 + 34 * slash))
        context.stroke(line, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        context.opacity = 1
    }
}

/// O iPhone com o selo do app na tela.
private struct PhoneWithSword: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 2))
                .frame(width: 96, height: 172)
            Capsule().fill(Palette.void).frame(width: 30, height: 8).offset(y: -74)
            WalletBadge(size: 58)
            Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.inkSoft).offset(y: 58)
        }
    }
}

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

    /// Roda todas. Nada aqui sai do aparelho.
    @MainActor
    static func runAll() -> [DeviceCheck] {
        [passcode(), secureEnclave(), jailbreak(), injection(), debugger(), screen(), keyboards(), system(), clipboard(), voiceOver()]
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
        return .init(id: "jailbreak", title: String(localized: "Sem jailbreak"), outcome: .caution(String(localized: "Simulador: a checagem só vale num iPhone de verdade.")))
        #else
        // No Mac, `/bin/bash` e `/usr/sbin/sshd` existem de fabrica: o aviso seria falso.
        if DeviceIntegrity.onMac {
            return .init(id: "jailbreak", title: String(localized: "Sem jailbreak"), outcome: .caution(String(localized: "No Mac, a checagem só vale num iPhone de verdade.")))
        }
        let paths = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app", "/bin/bash", "/usr/sbin/sshd",
                     "/etc/apt", "/private/var/lib/apt", "/usr/bin/ssh", "/var/jb", "/private/preboot/jb", "/.bootstrapped"]
        let found = paths.first { FileManager.default.fileExists(atPath: $0) }
        let probe = "/private/escalibur-\(UUID().uuidString)"
        let writable = (try? "x".write(toFile: probe, atomically: false, encoding: .utf8)) != nil
        if writable { try? FileManager.default.removeItem(atPath: probe) }
        guard found == nil, !writable else {
            return .init(id: "jailbreak", title: String(localized: "Sem jailbreak"),
                         outcome: .fail(String(localized: "Este iPhone parece ter jailbreak. Num aparelho assim, outro app pode ler a memória e o que você digita.")))
        }
        return .init(id: "jailbreak", title: String(localized: "Sem jailbreak"), outcome: .pass)
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
            return .init(id: "injecao", title: String(localized: "Nenhum código injetado no app"),
                         outcome: .fail(String(localized: "Há uma biblioteca de interceptação carregada no app (\(hit ?? "DYLD_INSERT_LIBRARIES")). Alguém pode estar lendo o que a tela mostra.")))
        }
        return .init(id: "injecao", title: String(localized: "Nenhum código injetado no app"), outcome: .pass)
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
        .init(id: "teclado", title: String(localized: "Só o teclado da Apple"), outcome: .pass)
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

/// A checagem, antes de digitar a frase: um escaneamento com cada item conferido na
/// hora, o que esta sendo checado escrito, e o resultado de cada um.
struct DeviceCheckView: View {
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var results: [DeviceCheck] = []
    @State private var revealed = 0
    @State private var acceptedRisk = false

    private var finished: Bool { !results.isEmpty && revealed >= results.count }
    private var blocking: [DeviceCheck] { results.filter { if case .fail = $0.outcome { return true }; return false } }
    private var screenBlocked: Bool { blocking.contains { $0.id == "tela" || $0.id == "codigo" } }
    private var canContinue: Bool { finished && !screenBlocked && (blocking.isEmpty || acceptedRisk) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScanRing(progress: results.isEmpty ? 0 : Double(revealed) / Double(results.count), done: finished,
                         alert: finished && !blocking.isEmpty)
                    .frame(height: 220).frame(maxWidth: .infinity)
                Text(finished ? (blocking.isEmpty ? String(localized: "Aparelho conferido") : String(localized: "Atenção antes de seguir")) : String(localized: "Conferindo este iPhone"))
                    .typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.sm)
                    .contentTransition(.opacity)
                Text(finished ? "Tudo foi checado aqui, sem internet. Nada desta checagem sai do aparelho."
                     : (revealed < results.count ? "Checando: \(results[revealed].title.lowercased())" : "Preparando a checagem"))
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, check in
                        row(check, state: index < revealed ? .done : (index == revealed ? .running : .waiting))
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
                PrimaryButton(title: finished ? String(localized: "Digitar as palavras") : String(localized: "Conferindo"), enabled: canContinue, loading: !finished) { onContinue() }
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .task { await run() }
        .accessibilityIdentifier("checagem-aparelho")
    }

    private func run() async {
        revealed = 0
        acceptedRisk = false
        results = DeviceCheck.runAll()
        // Os resultados ja sao reais; aparecem um a um para dar para ler.
        for _ in results {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 60 : 620))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { revealed += 1 }
        }
    }

    private enum RowState { case waiting, running, done }

    private func row(_ check: DeviceCheck, state: RowState) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Group {
                switch state {
                case .waiting:
                    Circle().stroke(Palette.edge, lineWidth: 1.5).frame(width: 20, height: 20)
                case .running:
                    ProgressView().controlSize(.small).tint(Palette.accent).frame(width: 20, height: 20)
                case .done:
                    switch check.outcome {
                    case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                    case .caution: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.caution)
                    case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.down)
                    }
                }
            }
            .font(.system(size: 20))
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).typeStyle(.row).foregroundStyle(state == .waiting ? Palette.inkMuted : Palette.ink)
                if state == .done {
                    switch check.outcome {
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
                    .stroke(alert ? Palette.caution : Palette.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 168, height: 168)
                    .animation(.easeOut(duration: 0.35), value: progress)
                if !done {
                    // O feixe do radar.
                    Circle()
                        .fill(AngularGradient(colors: [Palette.accent.opacity(0), Palette.accent.opacity(0.4)], center: .center,
                                              startAngle: .degrees(0), endAngle: .degrees(70)))
                        .frame(width: 150, height: 150)
                        .rotationEffect(.degrees(reduceMotion ? 0 : (t * 160).truncatingRemainder(dividingBy: 360)))
                        .mask(Circle().frame(width: 150, height: 150))
                    ForEach(0..<3, id: \.self) { wave in
                        let phase = (t * 0.6 + Double(wave) / 3).truncatingRemainder(dividingBy: 1)
                        Circle().stroke(Palette.accent.opacity(0.3 * (1 - phase)), lineWidth: 1)
                            .frame(width: 70 + phase * 130, height: 70 + phase * 130)
                    }
                }
                Image(systemName: done ? (alert ? "exclamationmark.shield.fill" : "checkmark.shield.fill") : "shield.lefthalf.filled")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(done ? (alert ? Palette.caution : Palette.accent) : Palette.ink)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(done ? 1.08 : 1)
                    .animation(.spring(response: 0.45, dampingFraction: 0.55), value: done)
            }
        }
        .accessibilityHidden(true)
    }
}
