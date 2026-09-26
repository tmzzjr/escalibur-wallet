import EscaliburCore
import EscaliburKeys
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var passphrase = ""
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
        case .sealing: sealingStep
        case .done: done
        }
    }

    // MARK: Etapas

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Guardar num envelope Escalibur").typeStyle(.title).foregroundStyle(Palette.ink)
            Text("O envelope é um arquivo cifrado com a senha da carteira dentro. Ele abre no app Escalibur, aqui, ou no decifrador aberto num computador, com uma senha só dele.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            Spacer()
            PrimaryButton(title: "Continuar", loading: working) { Task { await unlockPhrase() } }
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
                PasswordBox(buffer: password, length: $passwordLength, placeholder: "Senha do envelope") { proceedFromCreate() }
                    .padding(.top, Space.lg)
                costLine.padding(.top, Space.sm)
                TertiaryButton(title: "Usar 6 palavras sorteadas") {
                    password.wipe()
                    passwordLength = 0
                    error = nil
                    customPassword = false
                }
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
                Text("Seis palavras sorteadas neste iPhone. Com o arquivo nas mãos, o crime organizado levaria \(PasswordCost.describe(PasswordCost.seconds(bits: 66, kdf: kdf))) para adivinhar.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Anote em outro lugar, longe do papel da senha da carteira.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
                HStack(spacing: Space.sm) {
                    TertiaryButton(title: "Sortear outras") { suggest() }
                    TertiaryButton(title: "Prefiro criar a minha") {
                        error = nil
                        customPassword = true
                    }
                }
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

    private var costLine: some View {
        let bits = passwordLength == 0 ? 0 : PasswordStrength.bits(password)
        let seconds = PasswordCost.seconds(bits: bits, kdf: kdf)
        let weak = passwordLength > 0 && bits < PasswordStrength.minimumBits
        return VStack(alignment: .leading, spacing: Space.xxs) {
            Text(passwordLength == 0
                 ? "Digite para ver quanto custa adivinhar."
                 : "Com este arquivo nas mãos, o crime organizado levaria \(PasswordCost.describe(seconds)) para adivinhar esta senha.")
                .typeStyle(.note)
                .foregroundStyle(weak ? Palette.down : Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if weak {
                Text("Abaixo do mínimo para um envelope. Use uma frase mais longa ou 6 palavras sorteadas.")
                    .typeStyle(.note).foregroundStyle(Palette.down)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    private var sealingStep: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Spacer()
            ProgressView().tint(Palette.ink)
            Text("Lacrando. Leva cerca de \(max(1, Int(KDFCalibration.estimatedSeconds(for: kdf).rounded()))) segundos neste iPhone.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft)
            Spacer()
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Palette.up)
            Text("Envelope lacrado").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
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
            Text("Abre no app Escalibur, aqui, ou no decifrador aberto num computador.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.sm)
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
            let result: (SecureBytes, String)? = try await auth.perform(session, reason: "Lacrar a senha de \(wallet.name) num envelope", requirePIN: true) { rk in
                let secret = try KeyServices.wallets.open(walletID: id, rk: rk)
                defer { secret.wipe() }
                let phrase = try secret.phrase()
                let passphrase = secret.passphrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
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
        case .weak(let bits):
            error = "Com o arquivo nas mãos, o crime organizado levaria \(PasswordCost.describe(PasswordCost.seconds(bits: bits, kdf: kdf))) para adivinhar esta senha. Use 6 palavras sorteadas ou uma frase mais longa."
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
            self.phrase = nil
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
        password.wipe()
        repeatPassword.wipe()
        if let sealed { try? FileManager.default.removeItem(at: sealed.url) }
        onClose()
    }
}
