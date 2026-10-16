import EscaliburCore
import EscaliburKeys
import SwiftUI

/// "Quando o Face ID mudar" do modo reforcado (docs/seguranca.md §2.6), como a tela diz cada
/// politica. Com o Touch ID, "rosto" vira "digital".
extension RootKeyVault.HardenedFaceChange {
    var title: String {
        switch self {
        case .continue: return String(localized: "Continuar normal")
        case .wait: return String(localized: "Esperar 24 horas")
        case .lock: return String(localized: "Bloquear as carteiras")
        }
    }

    /// A frase honesta de cada opcao, na lista das tres.
    var summary: String {
        let finger = KeyServices.usesFingerprint
        switch self {
        case .continue:
            return finger ? String(localized: "Uma digital nova abre as carteiras com o PIN, na hora.")
                : String(localized: "Um rosto novo abre as carteiras com o PIN, na hora.")
        case .wait:
            return finger ? String(localized: "Uma digital nova abre o app e mostra o saldo. O resto espera 24 horas.")
                : String(localized: "Um rosto novo abre o app e mostra o saldo. O resto espera 24 horas.")
        case .lock:
            return finger ? String(localized: "Uma digital nova fecha as carteiras daqui de vez. Só as palavras trazem de volta.")
                : String(localized: "Um rosto novo fecha as carteiras daqui de vez. Só as palavras trazem de volta.")
        }
    }

    /// O que muda com ela, em "O que muda" do modo reforcado.
    var consequence: String {
        let name = KeyServices.biometryName
        let finger = KeyServices.usesFingerprint
        switch self {
        case .continue:
            return finger
                ? String(localized: "Se o \(name) deste iPhone mudar, as carteiras continuam abrindo com o PIN e a digital nova. Quem sabe o seu PIN e o código do iPhone poderia cadastrar a própria digital: para isso, ligue a Proteção de Aparelho Roubado, ou escolha esperar 24 horas ou bloquear as carteiras.")
                : String(localized: "Se o \(name) deste iPhone mudar, as carteiras continuam abrindo com o PIN e o rosto novo. Quem sabe o seu PIN e o código do iPhone poderia cadastrar o próprio rosto: para isso, ligue a Proteção de Aparelho Roubado, ou escolha esperar 24 horas ou bloquear as carteiras.")
        case .wait:
            return HardenedWaitNote.text
        case .lock:
            return String(localized: "Se o \(name) deste iPhone mudar, as carteiras daqui fecham de vez, e só as palavras de cada carteira trazem de volta.")
        }
    }

    var icon: String {
        switch self {
        case .continue: return "arrow.forward.circle"
        case .wait: return "hourglass"
        case .lock: return "lock"
        }
    }

    /// Para os testes de interface.
    var identifier: String {
        switch self {
        case .continue: return "continuar"
        case .wait: return "esperar"
        case .lock: return "bloquear"
        }
    }
}

/// As tres politicas, uma embaixo da outra, cada uma com a frase dela. Escolher e de quem
/// usa: a tela "Quando o Face ID mudar" e o ultimo passo de ligar.
struct HardenedFaceChangeOptions: View {
    let choice: RootKeyVault.HardenedFaceChange
    var working: RootKeyVault.HardenedFaceChange? = nil
    let onSelect: (RootKeyVault.HardenedFaceChange) -> Void

    var body: some View {
        VStack(spacing: Space.sm) {
            ForEach(RootKeyVault.HardenedFaceChange.allCases, id: \.self) { policy in
                option(policy)
            }
        }
    }

    private func option(_ policy: RootKeyVault.HardenedFaceChange) -> some View {
        let selected = choice == policy
        return Button { onSelect(policy) } label: {
            HStack(alignment: .top, spacing: Space.sm) {
                Image(systemName: policy.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Palette.control))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Text(policy.title).typeStyle(.row).foregroundStyle(Palette.ink)
                        if policy == .continue {
                            Text("Padrão").typeStyle(.label).foregroundStyle(Palette.inkSoft)
                                .padding(.horizontal, 6).frame(height: 20)
                                .background(Capsule().fill(Palette.control))
                        }
                    }
                    Text(policy.summary).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 1)
                Spacer(minLength: Space.xs)
                Group {
                    if working == policy {
                        ProgressView().tint(Palette.inkSoft)
                    } else {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(selected ? Palette.ink : Palette.edgeStrong)
                    }
                }
                .frame(width: 24, height: 36)
            }
            .padding(Space.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(selected ? Palette.inkSoft : Palette.edge, lineWidth: 1))
            )
            .contentShape(Rectangle())
            .animation(Motion.select, value: selected)
        }
        .buttonStyle(.plain)
        .disabled(working != nil)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reforcado-politica-\(policy.identifier)")
    }
}

/// A explicacao curta da espera, ao escolher "Esperar 24 horas".
struct HardenedWaitNote: View {
    static var text: String {
        KeyServices.usesFingerprint
            ? String(localized: "Se o \(KeyServices.biometryName) mudar, as carteiras continuam aqui. Por 24 horas, só dá para ver o saldo: enviar, trocar, ver as palavras e mudar a segurança esperam. É o tempo contra quem sabe o código do iPhone e cadastrou a própria digital.")
            : String(localized: "Se o \(KeyServices.biometryName) mudar, as carteiras continuam aqui. Por 24 horas, só dá para ver o saldo: enviar, trocar, ver as palavras e mudar a segurança esperam. É o tempo contra quem sabe o código do iPhone e cadastrou o próprio rosto.")
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "hourglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(Self.text).typeStyle(.note).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
        .accessibilityElement(children: .combine)
    }
}

/// "Quando o Face ID mudar": as tres opcoes. Desligado, so a escolha para ligar; ligado,
/// mudar pede o PIN e o rosto, e o rosto de novo para conferir. "Bloquear as carteiras" abre a
/// tela dele, com a animacao e o aceite.
struct HardenedFaceChangeView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(ToastCenter.self) private var toasts
    @Binding var choice: RootKeyVault.HardenedFaceChange
    @Binding var lockAccepted: Bool
    let on: Bool
    let wallets: [WalletMeta]

    @State private var locking = false
    @State private var working: RootKeyVault.HardenedFaceChange?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Quando o \(KeyServices.biometryName) mudar").typeStyle(.title).foregroundStyle(Palette.ink)
                Text(KeyServices.usesFingerprint
                     ? String(localized: "Uma digital nova ou apagada muda o cadastro do Touch ID deste iPhone. Escolha o que acontece com as carteiras daqui.")
                     : String(localized: "Um rosto novo, a aparência alternativa ou o \(KeyServices.biometryName) redefinido mudam o cadastro deste iPhone. Escolha o que acontece com as carteiras daqui."))
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
                if on, session.hardenedHold > 0 {
                    Banner(kind: .caution, title: AuthCoordinator.hardenedHoldMessage(session.hardenedHold))
                        .padding(.top, Space.md)
                }

                HardenedFaceChangeOptions(choice: choice, working: working) { policy in Task { await select(policy) } }
                    .padding(.top, Space.lg)
                if choice == .wait { HardenedWaitNote().padding(.top, Space.sm) }

                Text(KeyServices.usesFingerprint
                     ? String(localized: "Contra quem não sabe o código do iPhone, as três protegem igual: cadastrar uma digital pede o código. Com a Proteção de Aparelho Roubado ligada e o atraso de segurança em Sempre, cadastrar uma digital pede a sua digital e uma hora de espera, e as três também ficam iguais.")
                     : String(localized: "Contra quem não sabe o código do iPhone, as três protegem igual: cadastrar um rosto pede o código. Com a Proteção de Aparelho Roubado ligada e o atraso de segurança em Sempre, cadastrar um rosto pede o seu rosto e uma hora de espera, e as três também ficam iguais."))
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.lg)
                    .fixedSize(horizontal: false, vertical: true)
                if let message { Banner(kind: .failure, title: message).padding(.top, Space.md) }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.refreshHardenedHold() }
        .fullScreenCover(isPresented: $locking) {
            HardenedLockFlow(on: on, wallets: wallets) { done in
                locking = false
                guard done else { return }
                choice = .lock
                if on {
                    session.refreshHardenedHold()
                    toasts.show(Self.doneMessage(.lock))
                } else {
                    lockAccepted = true
                }
            }
        }
    }

    static func doneMessage(_ policy: RootKeyVault.HardenedFaceChange) -> String {
        String(localized: "Quando o \(KeyServices.biometryName) mudar: \(policy.title).")
    }

    private func select(_ policy: RootKeyVault.HardenedFaceChange) async {
        guard policy != choice, working == nil else { return }
        message = nil
        if policy == .lock {
            locking = true
            return
        }
        guard on else {
            choice = policy
            lockAccepted = false
            return
        }
        // Na espera de "Esperar 24 horas", mudar a politica espera: recusa antes do teclado.
        do {
            try KeyServices.root.checkHardenedAllowed()
        } catch {
            message = AuthCoordinator.refusalMessage(error)
            return
        }
        guard case .hardened(let pin, _)? = await auth.credential(reason: String(localized: "Mudar o que acontece quando o \(KeyServices.biometryName) mudar")) else { return }
        working = policy
        defer { working = nil }
        do {
            try await session.setHardenedFaceChange(policy, pin: pin)
            choice = policy
            session.refreshHardenedHold()
            toasts.show(Self.doneMessage(policy))
        } catch {
            message = Self.failureMessage(error)
        }
    }

    /// Antes do commit, qualquer falha deixa a politica de antes valendo.
    static func failureMessage(_ error: Error) -> String? {
        switch error as? RootKeyVault.Failure {
        case .wrongPIN(let remaining)?: return AuthCoordinator.wrongPINMessage(remaining)
        case .biometryNotConfirmed(let remaining)?: return AuthCoordinator.faceNotConfirmedMessage(remaining)
        case .throttled(let seconds)?: return String(localized: "Tentativas demais. Tente de novo em \(LockView.duration(seconds)).")
        case .cancelled?: return String(localized: "O \(KeyServices.biometryName) não confirmou. Nada mudou.")
        case .biometryChanged?: return String(localized: "O \(KeyServices.biometryName) deste iPhone mudou durante a conferência. Nada mudou.")
        case .wiped?: return nil
        default:
            return AuthCoordinator.refusalMessage(error) ?? String(localized: "Não foi possível mudar agora. Nada mudou: o que valia continua valendo.")
        }
    }
}

/// "Bloquear as carteiras": a animacao em quatro quadros, o que vale, e o aceite. Desligado, o
/// aceite e a escolha para ligar (as palavras vem no fluxo de ligar); ligado, depois do aceite,
/// a frase inteira de cada carteira, e o PIN e o rosto duas vezes. Com a trava, o papel e o
/// unico caminho de volta: so ir para ela pede as palavras.
struct HardenedLockFlow: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    let on: Bool
    let wallets: [WalletMeta]
    let onClose: (Bool) -> Void

    @State private var accepted = false
    @State private var typing = false
    @State private var typed: [UUID: WalletSecret] = [:]
    @State private var index = 0
    @State private var working = false
    @State private var message: String?
    /// Muda a cada recomeco, para a tela da frase nascer limpa.
    @State private var round = 0

    static var consentText: String {
        String(localized: "Entendo que, se o \(KeyServices.biometryName) deste iPhone mudar, as carteiras daqui fecham de vez, e só as palavras de cada carteira trazem de volta. Os nomes, endereços salvos e ajustes daqui se perdem junto.")
    }

    var body: some View {
        NavigationStack {
            Group {
                if typing, wallets.indices.contains(index) {
                    let wallet = wallets[index]
                    ImportPhraseView(onFinished: { close(false) }, verify: .init(
                        walletName: wallet.name, wordCount: HardenedEnableFlow.wordCount(wallet), hasPassphrase: wallet.hasPassphrase
                    ) { secret in
                        typed[wallet.id]?.wipe()
                        typed[wallet.id] = secret
                        message = nil
                        index += 1
                        if index >= wallets.count {
                            typing = false
                            Task { await apply() }
                        }
                    })
                    .id("\(wallet.id)-\(round)")
                } else {
                    intro
                }
            }
            .background(Palette.void.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { close(false) } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                    }
                    .accessibilityLabel("Fechar")
                }
            }
        }
        .interactiveDismissDisabled()
        .guardedAgainstCapture()
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HardenedLockStory()
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xs)
                Text("Bloquear as carteiras").typeStyle(.title).foregroundStyle(Palette.ink)
                    .padding(.top, Space.lg)
                Text(KeyServices.usesFingerprint
                     ? String(localized: "Vale para qualquer mudança no Touch ID, inclusive as suas: uma digital nova ou apagada. Para voltar, você apaga as carteiras deste iPhone e importa cada uma pelas palavras. Os nomes, os endereços salvos e os ajustes daqui se perdem.")
                     : String(localized: "Vale para qualquer mudança no \(KeyServices.biometryName), inclusive as suas: um rosto novo, a aparência alternativa, o \(KeyServices.biometryName) redefinido. Para voltar, você apaga as carteiras deste iPhone e importa cada uma pelas palavras. Os nomes, os endereços salvos e os ajustes daqui se perdem."))
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Na hora, as palavras de cada carteira, digitadas de onde você anotou. Depois, o PIN e o \(KeyServices.biometryName) duas vezes.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.md)
                    .fixedSize(horizontal: false, vertical: true)
                ConsentCheckbox(checked: $accepted, text: Self.consentText)
                    .padding(.top, Space.lg)
                    .accessibilityIdentifier("reforcado-bloquear-aceite")
                if let message { Banner(kind: .failure, title: message).padding(.top, Space.md) }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                PrimaryButton(title: String(localized: "Bloquear as carteiras"), enabled: accepted, loading: working) { start() }
                    .accessibilityIdentifier("reforcado-bloquear-confirmar")
            }
        }
    }

    private func start() {
        message = nil
        // Desligado: so a escolha. As palavras, o PIN e o rosto vem no fluxo de ligar.
        guard on else {
            onClose(true)
            return
        }
        do {
            try KeyServices.root.checkHardenedAllowed()
        } catch {
            message = AuthCoordinator.refusalMessage(error)
            return
        }
        // As frases ja digitadas (o PIN errado na tentativa anterior) valem: so o PIN de novo.
        if HardenedPhraseCheck.collect(wallets, typed: typed).count == wallets.count {
            Task { await apply() }
            return
        }
        restart()
        typing = true
    }

    private func apply() async {
        guard case .hardened(let pin, _)? = await auth.credential(reason: String(localized: "Bloquear as carteiras")) else { return }
        working = true
        defer { working = false }
        let checks = HardenedPhraseCheck.collect(wallets, typed: typed)
        guard checks.count == wallets.count else {
            pin.wipe()
            restart()
            return
        }
        do {
            try await session.setHardenedFaceChange(.lock, pin: pin) { rk in try HardenedPhraseCheck.run(checks, rk: rk) }
            close(true)
        } catch HardenedCheckError.mismatch(let name) {
            message = String(localized: "O que você digitou de \(name) não confere com esta carteira. Confira no papel e comece de novo.")
            restart()
        } catch HardenedCheckError.legacyPassphrase(let name) {
            message = HardenedEnableFlow.legacyPassphraseMessage(name)
            restart()
        } catch RootKeyVault.Failure.wiped {
            close(false)
        } catch {
            message = HardenedFaceChangeView.failureMessage(error)
        }
    }

    private func restart() {
        typed.values.forEach { $0.wipe() }
        typed = [:]
        index = 0
        round += 1
    }

    private func close(_ done: Bool) {
        typed.values.forEach { $0.wipe() }
        typed = [:]
        onClose(done)
    }
}

/// A animacao de "Bloquear as carteiras", em quatro quadros com os discos do emblema: o PIN e
/// o rosto abrem as carteiras; outro rosto entra no lugar; o cadeado fecha sobre as carteiras
/// apagadas; o papel das palavras traz de volta. Os glifos ficam fora do VoiceOver, e as
/// legendas sao lidas. Com Reduzir Movimento (ou o VoiceOver ligado), os quatro quadros ficam
/// parados, um embaixo do outro, cada um com a legenda dele.
struct HardenedLockStory: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var frame = 0

    static var captions: [String] {
        let name = KeyServices.biometryName
        if KeyServices.usesFingerprint {
            return [
                String(localized: "A sua digital e o PIN abrem as carteiras."),
                String(localized: "Alguém cadastra outra digital, ou apaga uma das suas."),
                String(localized: "As carteiras daqui fecham de vez. Ninguém abre, nem a Escalibur."),
                String(localized: "Só as palavras de cada carteira trazem de volta."),
            ]
        }
        return [
            String(localized: "O seu rosto e o PIN abrem as carteiras."),
            String(localized: "Alguém cadastra outro rosto, ou o \(name) é redefinido."),
            String(localized: "As carteiras daqui fecham de vez. Ninguém abre, nem a Escalibur."),
            String(localized: "Só as palavras de cada carteira trazem de volta."),
        ]
    }

    var body: some View {
        if reduceMotion || voiceOver { still } else { animated }
    }

    private var animated: some View {
        let captions = Self.captions
        return VStack(spacing: Space.md) {
            HardenedLockStage(frame: frame)
                .frame(width: HardenedLockStage.size.width, height: HardenedLockStage.size.height)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index == frame ? Palette.ink : Palette.edgeStrong)
                        .frame(width: index == frame ? 16 : 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            // As quatro legendas no mesmo lugar, so a do quadro visivel: a altura e a da maior, e
            // o texto embaixo nao pula.
            ZStack {
                ForEach(captions.indices, id: \.self) { index in
                    Text(captions[index])
                        .typeStyle(.body).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(index == frame ? 1 : 0)
                        .accessibilityHidden(index != frame)
                }
            }
            .frame(maxWidth: 300)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2800))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { frame = (frame + 1) % 4 }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: frame) { _, new in new == 2 }
    }

    private var still: some View {
        let captions = Self.captions
        return VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(captions.indices, id: \.self) { index in
                HStack(spacing: Space.md) {
                    HardenedLockStage(frame: index)
                        .frame(width: HardenedLockStage.size.width, height: HardenedLockStage.size.height)
                        .scaleEffect(0.5)
                        .frame(width: HardenedLockStage.size.width / 2, height: HardenedLockStage.size.height / 2)
                        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                        .accessibilityHidden(true)
                    Text(captions[index])
                        .typeStyle(.body).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Um quadro da animacao. As pecas sao as mesmas nos quatro; o quadro decide onde cada uma
/// esta e com que forca aparece, e a mola entre eles faz o movimento.
struct HardenedLockStage: View {
    static let size = CGSize(width: 240, height: 150)
    let frame: Int

    private var strangerIcon: String { KeyServices.usesFingerprint ? "touchid" : "face.dashed" }

    var body: some View {
        ZStack {
            wallets.offset(y: 46)
            // O PIN, sempre no mesmo lugar; apagado quando o cofre fecha, fora no papel.
            HardenedDisc(icon: "circle.grid.3x3.fill", size: 62)
                .offset(x: -34, y: -22)
                .opacity(frame == 2 ? 0.3 : (frame == 3 ? 0 : 1))
            // O rosto do dono sobe e some no segundo quadro.
            HardenedDisc(icon: KeyServices.biometryIcon, size: 62)
                .offset(x: 34, y: frame == 0 ? -22 : -84)
                .opacity(frame == 0 ? 1 : 0)
            // O outro rosto entra pelo lado, no lugar dele, com o contorno de aviso.
            HardenedDisc(icon: strangerIcon, size: 62, tint: Palette.caution, ring: Palette.caution.opacity(0.6))
                .offset(x: frame == 0 ? 120 : 34, y: -22)
                .opacity(frame == 1 ? 1 : (frame == 2 ? 0.3 : 0))
            // O cadeado aberto entre os dois, quando o PIN e o rosto abrem.
            badge("lock.open.fill")
                .offset(y: -22)
                .opacity(frame == 0 ? 1 : 0)
                .scaleEffect(frame == 0 ? 1 : 0.5)
            // O cadeado que fecha sobre as carteiras.
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.void)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Palette.ink))
                .overlay(Circle().stroke(Palette.void, lineWidth: 3))
                .offset(y: frame == 2 ? 40 : 6)
                .scaleEffect(frame == 2 ? 1 : 1.5)
                .opacity(frame == 2 ? 1 : 0)
            // O papel das palavras, que desce no lugar dos discos.
            paper
                .offset(y: frame == 3 ? -22 : -70)
                .opacity(frame == 3 ? 1 : 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    private func badge(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Palette.ink)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Palette.edgeStrong))
            .overlay(Circle().stroke(Palette.void, lineWidth: 3))
    }

    /// Tres carteiras: vivas, apagadas sob o cadeado, e de volta com o papel.
    private var wallets: some View {
        let dead = frame == 2
        return HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(dead ? Palette.rail : Palette.control)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(dead ? Palette.inkDead : Palette.edgeStrong, lineWidth: 1))
                    .overlay(alignment: .bottomLeading) {
                        Capsule().fill(dead ? Palette.inkDead : Palette.inkSoft).frame(width: 18, height: 3).padding(7)
                    }
                    .frame(width: 44, height: 28)
            }
        }
        .opacity(dead ? 0.5 : 1)
    }

    /// O papel onde o dono anotou as palavras.
    private var paper: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Palette.plateRule)
            .frame(width: 70, height: 56)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([38, 30, 42, 26], id: \.self) { width in
                        Capsule().fill(Palette.plateMuted).frame(width: CGFloat(width), height: 3)
                    }
                }
                .padding(10)
            }
            .rotationEffect(.degrees(frame == 3 ? -4 : -12))
    }
}
