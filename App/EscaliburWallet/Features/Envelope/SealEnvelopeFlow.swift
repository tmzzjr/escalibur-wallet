import EscaliburCore
import EscaliburKeys
import SwiftUI
import UniformTypeIdentifiers

/// V1: lacrar a senha de uma carteira num envelope Escalibur.
///
/// O envelope sai no formato `.esclbr` v1 do Escalibur, byte a byte, e abre no app
/// Escalibur e aqui. O decifrador para computador saiu do app (pedido do dono,
/// 14/10/2026); o de referencia em Python ficou em `tools/referencia`, so para os
/// testes conferirem a cifra.
struct SealEnvelopeFlow: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    let wallet: WalletMeta
    let onClose: () -> Void

    @State private var step: Step = .intro
    /// Em que parte do lacre estamos, para a tela dizer: 0 a senha fica cara de adivinhar
    /// (o Argon2, quase todo o tempo), 1 cifra a senha da carteira, 2 grava o arquivo.
    @State private var sealPart = 0
    @State private var sealStarted = Date()
    @State private var phrase: SecureBytes?
    @State private var passphrase: SecureBytes?
    @State private var password = SecureBytes(capacity: 256)
    @State private var passwordLength = 0
    @State private var repeatPassword = SecureBytes(capacity: 256)
    @State private var repeatLength = 0
    @State private var label = ""
    @State private var suggestion: [String] = []
    /// As posicoes das palavras sorteadas: a senha e montada direto no buffer seguro.
    @State private var suggestionIndices: [Int] = []
    @State private var customPassword = false
    /// A senha e a sorteada pelo app (vale a entropia do sorteio, 66 bits).
    @State private var usingSuggestion = false
    /// O "sim" explicito do dono para uma senha abaixo de forte.
    @State private var acceptedRisk = false
    @State private var riskBits: Double?
    @State private var weakSealed = false
    /// A forca medida fora da thread principal, depois que o dono para de digitar: o
    /// medidor percorre listas grandes, e a digitacao nao espera por ele.
    @State private var measured: (length: Int, bits: Double)?
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
            // Na mesma prioridade do lacre: em `.utility` o iOS mede nos nucleos de
            // eficiencia e a calibracao escolhe menos passes do que cabem.
            kdf = await Task.detached(priority: .userInitiated) { KDFCalibration.calibrate() }.value
            #if DEBUG
            // `-tela lacrando`: o lacre de mentira, para ver a tela (nada e cifrado).
            if DebugDemo.screen == "lacrando" {
                sealStarted = .now
                step = .sealing
                try? await Task.sleep(for: .seconds(KDFCalibration.estimatedSeconds(for: kdf)))
                sealPart = 1
                try? await Task.sleep(for: .milliseconds(450))
                sealPart = 2
                sealed = SealedFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("envelope-7F3A.esclbr"), name: "envelope-7F3A.esclbr")
                try? await Task.sleep(for: .milliseconds(450))
                step = .done
            }
            #endif
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
                // Cada frase cabe em duas linhas no iPhone de 6,3 polegadas (pedido do dono,
                // 15/10/2026). O decifrador e o tools/referencia/decifrar.py, publico.
                EnvelopePoint(icon: "lock.doc", text: String(localized: "A senha da carteira vira um arquivo criptografado, aqui no iPhone."))
                EnvelopePoint(icon: "key", text: String(localized: "Só você cria a senha do arquivo. Ela nunca sai deste iPhone."))
                EnvelopePoint(icon: "eye.slash", text: String(localized: "O arquivo não passa por nós. Sem a sua senha, ninguém abre."))
                EnvelopePoint(icon: "externaldrive", text: String(localized: "Guarde onde quiser. Descriptografe no app ou no decifrador aberto."))
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
            PrimaryButton(title: String(localized: "Continuar"), loading: working) { Task { await unlockPhrase() } }
                .padding(.top, Space.xs)
                .background(Palette.void)
        }
    }

    /// O caminho padrao e o forte: seis palavras sorteadas. A senha propria e livre, com
    /// no minimo 4 caracteres; abaixo de forte, a tela diz em quanto tempo ela cai e
    /// pede o "sim" (pedido do dono e auditoria do envelope, 14/10/2026).
    private var create: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Crie a senha do envelope").typeStyle(.title).foregroundStyle(Palette.ink)
            Text("Só ela abre o envelope, em qualquer aparelho. Não é o PIN e não pode ser a senha da carteira. Não existe redefinir.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            if customPassword {
                PasswordBox(buffer: password, length: $passwordLength, placeholder: String(localized: "Senha do envelope"), focusOnAppear: true) { proceedFromCreate() }
                    .padding(.top, Space.lg)
                strengthLine.padding(.top, Space.sm)
                EnvelopeOptionButton(title: String(localized: "Usar 6 palavras sorteadas"), icon: "dice") {
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
                    EnvelopeOptionButton(title: String(localized: "Sortear outras"), icon: "dice") {
                        withAnimation(Motion.fade) { suggest() }
                    }
                    EnvelopeOptionButton(title: String(localized: "Criar a minha"), icon: "pencil") {
                        error = nil
                        usingSuggestion = false
                        customPassword = true
                        Task.detached(priority: .utility) { PasswordStrength.preload() }
                    }
                }
                .padding(.top, Space.md)
            }
            if let error { Text(error).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.xs).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            if customPassword {
                PrimaryButton(title: String(localized: "Continuar"), enabled: passwordLength > 0) { proceedFromCreate() }
            } else {
                PrimaryButton(title: String(localized: "Anotei, continuar"), enabled: !suggestionIndices.isEmpty) {
                    // O buffer sai direto das posicoes. As palavras na tela sao String (para
                    // mostrar, nao tem outro jeito: risco aceito no 6) e saem da memoria do
                    // app assim que a tela segue (pentest de 14/10/2026).
                    guard (try? PasswordStrength.write(suggestionIndices, into: password)) != nil else { return }
                    passwordLength = password.count
                    usingSuggestion = true
                    suggestion = []
                    proceedFromCreate()
                }
            }
        }
        .onAppear { if suggestion.isEmpty { suggest() } }
        .sheet(isPresented: Binding(get: { riskBits != nil }, set: { if !$0 { riskBits = nil } })) {
            if let bits = riskBits { riskSheet(bits: bits) }
        }
    }

    /// O risco de uma senha abaixo de forte, dito com o tempo, antes do lacre.
    private func riskSheet(bits: Double) -> some View {
        let band = PasswordCost.band(bits: bits, kdf: kdf)
        let crime = PasswordCost.describe(PasswordCost.seconds(bits: bits, kdf: kdf))
        let state = PasswordCost.describe(PasswordCost.stateSeconds(bits: bits, kdf: kdf))
        return VStack(alignment: .leading, spacing: 0) {
            Image(systemName: band == .fair ? "exclamationmark.shield" : "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .semibold)).foregroundStyle(band == .fair ? Palette.ink : Palette.down)
            Text(band == .fair ? "Um governo abriria em \(state)" : "Esta senha cai em \(crime)")
                .typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
            Text("Quem tiver uma cópia do arquivo (nuvem, e-mail, AirDrop) testa senhas no próprio computador, sem limite e sem você saber. Seis palavras sorteadas aguentam milhões de anos.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            if band == .veryWeak {
                Text("Se usar mesmo assim, guarde o arquivo num pendrive ou no seu computador, nunca na nuvem nem por e-mail.")
                    .typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            PrimaryButton(title: String(localized: "Usar 6 palavras sorteadas")) {
                riskBits = nil
                password.wipe()
                passwordLength = 0
                customPassword = false
                usingSuggestion = false
                suggest()
            }
            HoldButton(title: band.needsHold ? String(localized: "Segure para usar mesmo assim") : String(localized: "Usar mesmo assim"), holdSeconds: band.needsHold ? 2 : 0) {
                riskBits = nil
                acceptedRisk = true
                error = nil
                step = .repeatIt
            }
            .padding(.top, Space.sm)
        }
        .padding(Space.gutter)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.body)
        .accessibilityIdentifier("senha-fraca")
    }

    /// Ao vivo, enquanto o dono digita: em quanto tempo a senha cai, com os parametros
    /// reais deste envelope.
    @ViewBuilder
    private var strengthLine: some View {
        let short = passwordLength > 0 && PasswordStrength.scalarCount(password) < PasswordStrength.minimumLength
        let digits = passwordLength > 0 && password.withUnsafeBytes { $0.allSatisfy { (0x30...0x39).contains($0) } }
        VStack(alignment: .leading, spacing: 4) {
            if passwordLength == 0 {
                Text("Qualquer senha com pelo menos 4 caracteres. Quanto mais longa e menos óbvia, mais tempo ela aguenta. Não use a senha da carteira.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft)
            } else if short {
                Text("No mínimo 4 caracteres.").typeStyle(.note).foregroundStyle(Palette.down)
            } else if let measured, measured.length == passwordLength {
                let band = PasswordCost.band(bits: measured.bits, kdf: kdf)
                Text(PasswordCost.text(bits: measured.bits, kdf: kdf)).typeStyle(.note)
                    .foregroundStyle(band == .veryWeak ? Palette.down : band == .weak ? Palette.caution : band == .fair ? Palette.ink : Palette.accent)
                if digits {
                    Text("Não use o código do iPhone nem o PIN do app: quem já viu você digitar abre o envelope.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
            } else {
                Text("Medindo a senha…").typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .task(id: passwordLength) { await measure() }
    }

    /// Mede numa copia do buffer, fora da thread principal, meio segundo depois da
    /// ultima tecla. A copia e zerada na saida.
    private func measure() async {
        guard passwordLength > 0 else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        let copy = SecureBytes(capacity: max(password.count, 1))
        password.withUnsafeBytes { copy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        let length = passwordLength
        let bits = await Task.detached(priority: .userInitiated) {
            defer { copy.wipe() }
            return PasswordStrength.bits(copy)
        }.value
        guard !Task.isCancelled else { return }
        measured = (length, bits)
    }

    private var repeatStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Repita a senha do envelope").typeStyle(.title).foregroundStyle(Palette.ink)
            PasswordBox(buffer: repeatPassword, length: $repeatLength, placeholder: String(localized: "Senha do envelope")) { Task { await seal() } }
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
            PrimaryButton(title: String(localized: "Lacrar envelope"), enabled: repeatLength > 0) { Task { await seal() } }
        }
    }

    /// Lacrando e lacrado dividem a ilustracao, para a aba fechar na mesma cena em
    /// que os blocos estavam caindo. Tudo centrado: a ilustracao, o que esta acontecendo
    /// e, no fim, o arquivo.
    private var sealStage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.md)
            EnvelopeChain(mode: step == .done ? .sealed : .working).padding(.bottom, Space.lg)
            if step == .done {
                VStack(spacing: Space.sm) {
                    Text("Envelope lacrado").typeStyle(.title).foregroundStyle(Palette.ink)
                    if let sealed {
                        HStack(spacing: Space.xs) {
                            Image(systemName: "lock.doc").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                            Text(verbatim: sealed.name).font(TypeStyle.mono.font).foregroundStyle(Palette.ink).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    Text("O arquivo não diz de quem é nem o que guarda. Guarde o arquivo e a senha em lugares diferentes: quem tiver os dois tem a carteira.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .offset(y: 8)))
                if weakSealed {
                    Banner(kind: .caution, title: String(localized: "Senha muito fraca: guarde o arquivo num pendrive ou no seu computador, nunca na nuvem nem por e-mail."))
                        .padding(.top, Space.md)
                }
                Spacer(minLength: Space.md)
                if let sealed {
                    ShareLink(item: sealed.url) {
                        Text("Salvar ou enviar o arquivo").typeStyle(.action)
                            .frame(maxWidth: .infinity).frame(height: Height.primary)
                    }
                    .buttonStyle(PrimaryStyle())
                }
                Text("Para abrir: Ajustes, Abrir um envelope, neste ou em outro iPhone com o app.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).multilineTextAlignment(.center)
                    .padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: Space.sm) {
                    Text("Lacrando o envelope").typeStyle(.title).foregroundStyle(Palette.ink)
                    Text(sealPartText)
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                        .contentTransition(.opacity)
                        .animation(Motion.fade, value: sealPart)
                    SealProgress(started: sealStarted, estimate: KDFCalibration.estimatedSeconds(for: kdf), finished: sealPart > 0)
                        .frame(width: 220)
                        .padding(.top, Space.sm)
                    Text("Leva \(Fmt.aboutSeconds(KDFCalibration.estimatedSeconds(for: kdf))), só neste iPhone, sem internet.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
                .multilineTextAlignment(.center)
                Spacer(minLength: Space.md)
                Text("A senha do envelope não sai deste iPhone.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).multilineTextAlignment(.center)
                    .padding(.bottom, Space.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: step)
        .sensoryFeedback(.success, trigger: sealed?.id)
    }

    private var sealPartText: String {
        switch sealPart {
        case 0: return String(localized: "Deixando a senha difícil de adivinhar")
        case 1: return String(localized: "Cifrando a senha da carteira")
        default: return String(localized: "Gravando o arquivo")
        }
    }

    // MARK: Acoes

    private func unlockPhrase() async {
        working = true
        defer { working = false }
        error = nil
        let id = wallet.id
        do {
            guard await VoiceGate.shared.confirm(.envelope, session: session) else { return }
            let result: (SecureBytes, SecureBytes)? = try await auth.perform(session, reason: String(localized: "Lacrar a senha de \(wallet.name) num envelope"), requirePIN: true) { rk in
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
            self.error = String(localized: "Não foi possível abrir a carteira agora.")
        }
    }

    private func suggest() {
        suggestionIndices = (try? PasswordStrength.suggestionIndices(avoiding: phrase)) ?? []
        let list = try? WordlistStore.shared.wordlist(for: .english)
        suggestion = suggestionIndices.compactMap { list?.words[$0] }
    }

    private func proceedFromCreate() {
        guard passwordLength > 0 else { return }
        acceptedRisk = false
        if usingSuggestion {
            error = nil
            step = .repeatIt
            return
        }
        // Palavras da propria frase anulam o backup (o papel da frase abriria o envelope):
        // isso nao e questao de forca, e continua recusado.
        if let phrase, PasswordStrength.reusesPhrase(password, phrase: phrase) {
            error = String(localized: "Esta senha usa palavras da própria carteira. Quem achar o papel abre o envelope. Escolha outra.")
            return
        }
        switch PasswordStrength.verdict(password) {
        case .tooShort:
            error = String(localized: "Use pelo menos 4 caracteres.")
        case .strong:
            // O medidor depende do custo do Argon2 deste iPhone: abaixo de forte nele, pede
            // o "sim" como as outras. Antes, 60 bits saiam como "bom" no medidor e lacravam
            // sem o aviso (pentest de 14/10/2026).
            let bits = PasswordStrength.bits(password)
            if PasswordCost.band(bits: bits, kdf: kdf) != .strong {
                error = nil
                riskBits = bits
                return
            }
            error = nil
            step = .repeatIt
        case .digitsOnly(let bits), .weak(let bits):
            error = nil
            riskBits = bits
        }
    }

    private func seal() async {
        let same = Hash.constantTimeEqual(password, repeatPassword)
        guard same else {
            error = String(localized: "As duas não conferem. Digite a senha do envelope de novo.")
            repeatPassword.wipe()
            repeatLength = 0
            return
        }
        guard let phrase else { return }
        error = nil
        sealPart = 0
        sealStarted = .now
        step = .sealing
        let (password, label, passphrase, kdf) = (self.password, String(self.label.prefix(64)), self.passphrase, self.kdf)
        let generated: Double? = usingSuggestion ? PasswordStrength.suggestionBits() : nil
        let accepted = acceptedRisk
        // Para a tela final: senha muito fraca, o arquivo fica fora da nuvem.
        weakSealed = !usingSuggestion && PasswordCost.band(bits: PasswordStrength.bits(password), kdf: kdf) == .veryWeak
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Envelope.seal(phrase: phrase, passphrase: passphrase, label: label, password: password, parameters: kdf,
                                  generatedBits: generated, acceptedRisk: accepted)
            }.value
            password.wipe()
            repeatPassword.wipe()
            phrase.wipe()
            passphrase?.wipe()
            self.phrase = nil
            self.passphrase = nil
            // A cifra e a gravacao levam milissegundos: a tela mostra cada uma por um
            // instante, para o dono ver o que aconteceu, e so entao o envelope fecha.
            sealPart = 1
            try? await Task.sleep(for: .milliseconds(450))
            sealPart = 2
            sealed = try write(data)
            var updated = wallet
            updated.envelopeSealedAt = .now
            session.update(updated)
            try? await Task.sleep(for: .milliseconds(450))
            step = .done
        } catch Envelope.Failure.notEnoughMemory {
            self.error = String(localized: "Pouca memória livre agora. Feche outros apps e tente de novo.")
            step = .repeatIt
        } catch {
            self.error = String(localized: "Não foi possível lacrar o envelope.")
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

/// A barra do lacre: anda pelo tempo que este iPhone costuma levar e para em 92% ate o
/// Argon2 terminar de verdade; dai enche. O tempo e estimado, o fim nao.
private struct SealProgress: View {
    let started: Date
    let estimate: Double
    let finished: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: finished)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(started)
            let raw = min(max(elapsed / max(estimate, 0.5), 0), 1)
            // Desacelera perto do fim: 1 - (1 - t)^2, ate 92%.
            let fraction = finished ? 1 : 0.92 * (1 - (1 - raw) * (1 - raw))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.edge)
                    Capsule().fill(Palette.accent)
                        .frame(width: max(6, geo.size.width * fraction))
                        .animation(.easeOut(duration: 0.3), value: finished)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Lacrando"))
    }
}
