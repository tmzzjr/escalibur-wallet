import EscaliburCore
import EscaliburKeys
import SwiftUI
import UniformTypeIdentifiers

/// O decifrador de envelopes para computador: o `decifrar.py`, a descricao do formato
/// e o LEIA-ME, embarcados no app e travados por `recuperacao.lock`. Sem ele, o
/// envelope so abriria num app Escalibur; com ele, abre em qualquer computador com
/// Python, mesmo que o app deixe de existir.
enum RecoveryKit {
    static var files: [URL] {
        [("LEIA-ME", "txt"), ("decifrar", "py"), ("FORMATO", "md")].compactMap { Bundle.main.url(forResource: $0.0, withExtension: $0.1) }
    }
}

/// V1: lacrar a senha de uma carteira num envelope Escalibur.
///
/// O envelope sai no formato `.esclbr` v1 do Escalibur, byte a byte: abre no app
/// Escalibur, aqui, e no decifrador de referencia em Python.
struct SealEnvelopeFlow: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    let wallet: WalletMeta
    let onClose: () -> Void

    @State private var step: Step = .intro
    @State private var phrase: SecureBytes?
    @State private var passphrase: SecureBytes?
    @State private var password = SecureBytes(capacity: 256)
    @State private var passwordLength = 0
    @State private var repeatPassword = SecureBytes(capacity: 256)
    @State private var repeatLength = 0
    @State private var label = ""
    @State private var suggestion: [String] = []
    @State private var customPassword = false
    @State private var error: String?
    @State private var working = false
    @State private var sealed: SealedFile?
    /// Para mostrar custo e tempo. Comeca no piso de lacre e e trocado pela medida
    /// deste aparelho, feita fora da thread principal.
    @State private var kdf = KDFParameters(memoryKiB: KDFCalibration.sealFloorKiB, passes: 3, lanes: KDFCalibration.lanes)

    enum Step { case intro, create, repeatIt, sealing, done }

    struct SealedFile: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
    }

    var body: some View {
        NavigationStack {
            content
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
                .padding(.bottom, Space.xs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Palette.void.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { close() } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                        }
                        .accessibilityLabel("Fechar")
                    }
                }
        }
        .interactiveDismissDisabled()
        .guardedAgainstCapture()
        .task {
            kdf = await Task.detached(priority: .utility) { KDFCalibration.calibrate() }.value
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro: intro
        case .create: create
        case .repeatIt: repeatStep
        case .sealing, .done: sealStage
        }
    }

    // MARK: Etapas

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            EnvelopeChain(mode: .idle).padding(.top, Space.sm).padding(.bottom, Space.lg)
            VStack(spacing: Space.sm) {
                Text("Guardar num envelope Escalibur").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Uma cópia de segurança da senha da carteira, trancada com outra senha que só você conhece.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: Space.md) {
                EnvelopePoint(icon: "lock.doc", text: "A senha da carteira é cifrada neste iPhone e vira um arquivo.")
                EnvelopePoint(icon: "key", text: "Você escolhe a senha que abre o arquivo. Ela não sai do iPhone e ninguém mais sabe.")
                EnvelopePoint(icon: "eye.slash", text: "Nem a Escalibur consegue abrir: não temos a sua senha nem cópia do arquivo.")
                EnvelopePoint(icon: "externaldrive", text: "Guarde o arquivo onde quiser. Ele abre aqui ou no decifrador aberto, num computador.")
            }
            .padding(Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
            .padding(.top, Space.lg)
            if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            }
            .padding(.bottom, Space.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        // O botao fica preso embaixo; o texto rola por tras dele no iPhone pequeno.
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Continuar", loading: working) { Task { await unlockPhrase() } }
                .padding(.top, Space.xs)
                .background(Palette.void)
        }
    }

    /// O caminho padrao e o forte: seis palavras sorteadas. Criar a propria senha
    /// existe, mas passa pelo piso de 60 bits.
    private var create: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Crie a senha do envelope").typeStyle(.title).foregroundStyle(Palette.ink)
            Text("Só ela abre o envelope, em qualquer aparelho. Não é o PIN e não pode ser a senha da carteira. Não existe redefinir.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            if customPassword {
                PasswordBox(buffer: password, length: $passwordLength, placeholder: "Senha do envelope", focusOnAppear: true) { proceedFromCreate() }
                    .padding(.top, Space.lg)
                strengthLine.padding(.top, Space.sm)
                EnvelopeOptionButton(title: "Usar 6 palavras sorteadas", icon: "dice") {
                    password.wipe()
                    passwordLength = 0
                    error = nil
                    customPassword = false
                }
                .padding(.top, Space.md)
            } else {
                Text(verbatim: suggestion.joined(separator: " "))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.plateInk)
                    .padding(Space.base)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LacquerPlate().fill(Palette.live))
                    .padding(.top, Space.lg)
                    .textSelection(.disabled)
                    .accessibilityIdentifier("palavras-envelope")
                Text("Seis palavras sorteadas neste iPhone. Anote em outro lugar, longe do papel da senha da carteira.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.xs) {
                    EnvelopeOptionButton(title: "Sortear outras", icon: "dice") {
                        withAnimation(Motion.fade) { suggest() }
                    }
                    EnvelopeOptionButton(title: "Criar a minha", icon: "pencil") {
                        error = nil
                        customPassword = true
                    }
                }
                .padding(.top, Space.md)
            }
            if let error { Text(error).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.xs).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            if customPassword {
                PrimaryButton(title: "Continuar", enabled: passwordLength > 0) { proceedFromCreate() }
            } else {
                PrimaryButton(title: "Anotei, continuar", enabled: !suggestion.isEmpty) {
                    password.replaceAll(with: Array(suggestion.joined(separator: " ").utf8))
                    passwordLength = password.count
                    proceedFromCreate()
                }
            }
        }
        .onAppear { if suggestion.isEmpty { suggest() } }
    }

    private var strengthLine: some View {
        let bits = passwordLength == 0 ? 0 : PasswordStrength.bits(password)
        let weak = passwordLength > 0 && bits < PasswordStrength.minimumBits
        return Text(passwordLength == 0
                    ? "Uma frase longa, só sua. Não use a senha da carteira nem o PIN."
                    : weak ? "Abaixo do mínimo para um envelope. Use uma frase mais longa ou 6 palavras sorteadas."
                    : "Forte o bastante para o envelope.")
            .typeStyle(.note)
            .foregroundStyle(passwordLength == 0 ? Palette.inkSoft : weak ? Palette.down : Palette.up)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var repeatStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Repita a senha do envelope").typeStyle(.title).foregroundStyle(Palette.ink)
            PasswordBox(buffer: repeatPassword, length: $repeatLength, placeholder: "Senha do envelope") { Task { await seal() } }
                .padding(.top, Space.lg)
            if let error { Text(error).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.xs) }
            Text("Nome dentro do envelope").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
            TextField("", text: $label)
                .typeStyle(.row).foregroundStyle(Palette.ink)
                .padding(.horizontal, Space.md).frame(height: Height.field)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                .padding(.top, Space.xs)
            Text("O nome fica cifrado. O arquivo não diz de quem é.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xs)
            Spacer()
            PrimaryButton(title: "Lacrar envelope", enabled: repeatLength > 0) { Task { await seal() } }
        }
    }

    /// Lacrando e lacrado dividem a ilustracao, para a aba fechar na mesma cena em
    /// que os blocos estavam caindo.
    private var sealStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            EnvelopeChain(mode: step == .done ? .sealed : .working).padding(.top, Space.sm).padding(.bottom, Space.xl)
            if step == .done {
                Text("Envelope lacrado").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("O arquivo se chama \(sealed?.name ?? "") e não diz de quem é nem o que guarda. Guarde o arquivo e a senha em lugares diferentes: quem tiver os dois tem a carteira.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let sealed {
                    ShareLink(item: sealed.url) {
                        Text("Salvar ou enviar o arquivo").typeStyle(.action)
                            .frame(maxWidth: .infinity).frame(height: Height.primary)
                    }
                    .buttonStyle(PrimaryStyle())
                }
                ShareLink(items: RecoveryKit.files) {
                    Text("Salvar o decifrador para computador").typeStyle(.action)
                        .frame(maxWidth: .infinity).frame(height: Height.secondary)
                }
                .buttonStyle(SecondaryStyle())
                .padding(.top, Space.sm)
                Text("Abre no app Escalibur, aqui, ou num computador com o decifrador, que também fica em Ajustes, Sobre.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Lacrando o envelope").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Leva \(Fmt.aboutSeconds(KDFCalibration.estimatedSeconds(for: kdf))), só neste iPhone. A senha do envelope não sai dele.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .sensoryFeedback(.success, trigger: sealed?.id)
    }

    // MARK: Acoes

    private func unlockPhrase() async {
        working = true
        defer { working = false }
        error = nil
        let id = wallet.id
        do {
            guard await VoiceGate.shared.confirm(.envelope, session: session) else { return }
            let result: (SecureBytes, SecureBytes)? = try await auth.perform(session, reason: "Lacrar a senha de \(wallet.name) num envelope", requirePIN: true) { rk in
                let secret = try KeyServices.wallets.open(walletID: id, rk: rk)
                defer { secret.wipe() }
                let phrase = try secret.phrase()
                let passphrase = SecureBytes(capacity: max(secret.passphrase.count, 1))
                secret.passphrase.withUnsafeBytes { passphrase.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
                return (phrase, passphrase)
            }
            guard let result else { return }
            phrase = result.0
            passphrase = result.1
            label = wallet.name
            step = .create
        } catch {
            self.error = "Não foi possível abrir a carteira agora."
        }
    }

    private func suggest() {
        suggestion = (try? PasswordStrength.suggestion(avoiding: phrase)) ?? []
    }

    private func proceedFromCreate() {
        guard passwordLength > 0 else { return }
        if let phrase, PasswordStrength.reusesPhrase(password, phrase: phrase) {
            error = "Esta senha usa palavras da própria carteira. Quem achar o papel abre o envelope. Escolha outra."
            return
        }
        switch PasswordStrength.verdict(password) {
        case .strong:
            break
        case .digitsOnly:
            error = "Só números não bastam para um arquivo que pode ir para a nuvem. Use 6 palavras sorteadas ou uma frase longa."
            return
        case .weak:
            error = "Esta senha é fraca para um envelope. Use 6 palavras sorteadas ou uma frase mais longa."
            return
        }
        error = nil
        step = .repeatIt
    }

    private func seal() async {
        let same = Hash.constantTimeEqual(password, repeatPassword)
        guard same else {
            error = "As duas não conferem. Digite a senha do envelope de novo."
            repeatPassword.wipe()
            repeatLength = 0
            return
        }
        guard let phrase else { return }
        error = nil
        step = .sealing
        let (password, label, passphrase, kdf) = (self.password, String(self.label.prefix(64)), self.passphrase, self.kdf)
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Envelope.seal(phrase: phrase, passphrase: passphrase, label: label, password: password, parameters: kdf)
            }.value
            password.wipe()
            repeatPassword.wipe()
            phrase.wipe()
            passphrase?.wipe()
            self.phrase = nil
            self.passphrase = nil
            sealed = try write(data)
            var updated = wallet
            updated.envelopeSealedAt = .now
            session.update(updated)
            step = .done
        } catch Envelope.Failure.notEnoughMemory {
            self.error = "Pouca memória livre agora. Feche outros apps e tente de novo."
            step = .repeatIt
        } catch {
            self.error = "Não foi possível lacrar o envelope."
            step = .repeatIt
        }
    }

    /// O arquivo vai para tmp com protecao completa e fora do backup, e e apagado
    /// quando esta tela fecha.
    private func write(_ data: Data) throws -> SealedFile {
        var bytes = [UInt8](repeating: 0, count: 2)
        _ = SecRandomCopyBytes(kSecRandomDefault, 2, &bytes)
        let name = "envelope-\(Hex.encode(bytes).uppercased()).esclbr"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("envelopes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return SealedFile(url: url, name: name)
    }

    private func close() {
        phrase?.wipe()
        passphrase?.wipe()
        password.wipe()
        repeatPassword.wipe()
        if let sealed { try? FileManager.default.removeItem(at: sealed.url) }
        onClose()
    }
}

/// Um ponto da explicacao do envelope: icone do assunto e uma frase.
private struct EnvelopePoint: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.control))
            Text(text).typeStyle(.body).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
    }
}

/// As escolhas da senha do envelope: pilulas da mesma largura, com o icone do que fazem.
private struct EnvelopeOptionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(title).typeStyle(.action).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Capsule().fill(Palette.rail))
            .overlay(Capsule().stroke(Palette.edge, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
