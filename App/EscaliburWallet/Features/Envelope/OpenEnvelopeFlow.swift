import EscaliburCore
import EscaliburKeys
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// O tipo do envelope, declarado no Info.plist.
    /// O tipo e da Escalibur, declarado como dela (exportado, dono): antes so importado com
    /// prioridade Alternate, e outro app podia ficar com o "Abrir com" do envelope
    /// (auditoria 4, C7-18).
    static let escaliburEnvelope = UTType(exportedAs: "app.escalibur.envelope")
}

/// Le um envelope vindo de fora com as regras de arquivo hostil: tamanho conferido
/// antes de ler, leitura limitada, e a copia que o iOS deixa em Documents/Inbox
/// (AirDrop, "Abrir com") apagada logo depois, porque ela entraria no backup.
enum EnvelopeFile {
    enum Failure: Error { case notEnvelope, unreadable }

    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == Envelope.fileLength else { throw Failure.notEnvelope }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: Envelope.fileLength + 1), data.count == Envelope.fileLength else {
            throw Failure.unreadable
        }
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        return data
    }

    /// Varre copias esquecidas a cada abertura do app.
    static func sweepInbox() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = documents.appendingPathComponent("Inbox")
        try? FileManager.default.removeItem(at: inbox)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("envelopes"))
    }
}

/// V2: abrir um envelope, importar a carteira ou so ver as palavras.
struct OpenEnvelopeFlow: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    let initialURL: URL?
    let onClose: () -> Void

    @State private var picking = false
    @State private var howItWorks = false
    @State private var fileName: String?
    @State private var data: Data?
    @State private var password = SecureBytes(capacity: 256)
    @State private var passwordLength = 0
    /// A senha digitada vira cifra viva; segurar o dedo no campo mostra o que foi digitado.
    @State private var cipher = LiveCipher()
    @State private var revealPassword = false
    @State private var opening = false
    @State private var estimate = 3
    /// Envelope que pede mais de 10 s de conta: o dono confirma antes (auditoria do
    /// envelope, 14/10/2026, A4). Um cabecalho hostil prenderia a tela sem aviso.
    @State private var confirmingHeavy = false
    @State private var heavyConfirmed = false
    @State private var error: String?
    @State private var opened: Envelope.Contents?
    @State private var revealDraft: PhraseDraft?
    @State private var importing = false
    /// Carteira montada a partir do envelope, esperando o dono conferir os enderecos.
    @State private var pending: (secret: WalletSecret, preview: ImportPreview, name: String, words: Int)?

    var body: some View {
        NavigationStack {
            Group {
                if let pending {
                    ImportPreviewView(preview: pending.preview, hasPassphrase: pending.secret.passphrase.count > 0, source: .envelope, saving: importing,
                                      onSave: { foreign in Task { await save(tronForeign: foreign) } }, onBack: discardPending)
                } else if let revealDraft, let opened {
                    RecordWordsView(draft: revealDraft, walletName: opened.label.isEmpty ? String(localized: "Envelope") : opened.label,
                                    passphrase: opened.passphrase.count > 0 ? opened.passphrase : nil) {
                        close()
                    }
                } else if opening || opened != nil {
                    openStage
                } else if data != nil {
                    passwordView
                } else {
                    chooseView
                }
            }
            .padding(.horizontal, revealDraft == nil ? Space.gutter : 0)
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
        .alert("Este envelope pede uma conta pesada", isPresented: $confirmingHeavy) {
            Button("Abrir mesmo assim") {
                heavyConfirmed = true
                Task { await open() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Abrir leva cerca de \(estimate) segundos com a tela parada. Um envelope lacrado pela Escalibur leva de 1 a 3. Se você não sabe de onde veio este arquivo, não abra.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.escaliburEnvelope, .data]) { result in
            if case .success(let url) = result { load(url) }
        }
        .onAppear { if let initialURL { load(initialURL) } }
    }

    /// O texto no centro, embaixo da ilustracao, e o "Como funciona" (pedido do dono,
    /// 14/10/2026). A ilustracao e a do "So a sua senha abre": a senha digitada abre o
    /// envelope e revela as palavras (de exemplo).
    private var chooseView: some View {
        VStack(spacing: 0) {
            // Um pouco mais para baixo, com o texto, como no "Como funciona".
            EnvelopeCipherCard(mode: .reveal).padding(.top, Space.sm + 32).padding(.bottom, Space.xl)
            Text("Abrir um envelope").typeStyle(.title).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text("Escolha o arquivo .esclbr no app Arquivos. O original continua onde está.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button { howItWorks = true } label: {
                Label("Como funciona", systemImage: "play.circle").typeStyle(.label).foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.sm).frame(height: 34)
                    .background(Capsule(style: .continuous).fill(Palette.rail))
            }
            .buttonStyle(.plain)
            .padding(.top, Space.md)
            .accessibilityIdentifier("envelope-como-funciona")
            if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            Spacer()
            PrimaryButton(title: String(localized: "Escolher arquivo")) { picking = true }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $howItWorks) { EnvelopeHowItWorks() }
        #if DEBUG
        .onAppear { if DebugDemo.screen == "envelope-como" { howItWorks = true } }
        #endif
    }

    private var passwordView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fileName {
                Text(fileName).typeStyle(.monoSmall).foregroundStyle(Palette.inkMuted)
            }
            Text("Senha do envelope").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.xs)
            Text("A senha escolhida quando o envelope foi lacrado. No app Escalibur, é a senha do cofre.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            PasswordBox(buffer: password, length: $passwordLength, placeholder: String(localized: "Senha do envelope"),
                        reveal: $revealPassword, onSubmit: { Task { await open() } }, glyphs: passwordGlyphs)
                .padding(.top, Space.lg)
                .onChange(of: passwordLength) { _, _ in cipher.seal(0, buffer: password) }
            Text("Segure o dedo no campo para ver o que digitou.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xs)
            if let error {
                Text(error).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            PrimaryButton(title: String(localized: "Abrir envelope"), enabled: passwordLength > 0, loading: opening) { Task { await open() } }
        }
    }

    /// Abrindo e aberto dividem a ilustracao: o arquivo com o cifrado trocando enquanto o
    /// app faz a conta e, aberto, um visto no lugar de cada palavra (nunca as de exemplo).
    private var openStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            EnvelopeCipherCard(mode: opened == nil ? .opening : .opened, fileName: fileName ?? "envelope.esclbr",
                               wordCount: opened.map(Self.wordCount) ?? 12)
                .padding(.top, Space.sm).padding(.bottom, Space.xl)
            if let opened {
                openedContent(opened)
            } else {
                Text("Abrindo o envelope").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Leva \(Fmt.aboutSeconds(Double(estimate))), e cada tentativa custa o mesmo para quem tentar adivinhar.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    /// Quantas palavras o envelope guarda, contando os espacos nos bytes (sem montar texto).
    static func wordCount(_ contents: Envelope.Contents) -> Int {
        contents.phrase.withUnsafeBytes { raw in raw.filter { $0 == 0x20 }.count + 1 }
    }

    @ViewBuilder
    private func openedContent(_ contents: Envelope.Contents) -> some View {
        let words = Self.wordCount(contents)
        (contents.label.isEmpty ? Text("Envelope aberto") : Text(verbatim: contents.label))
            .typeStyle(.title).foregroundStyle(Palette.ink)
        Text(String(localized: "\(words) palavras, lista em \(Fmt.languageName(contents.language))") + (contents.passphrase.count > 0 ? String(localized: " · com passphrase") : ""))
            .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
        if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
        Spacer()
        PrimaryButton(title: String(localized: "Importar esta carteira"), loading: importing) { Task { await importWallet(contents, words: words) } }
        SecondaryButton(title: String(localized: "Só ver as palavras")) { reveal(contents, words: words) }.padding(.top, Space.sm)
    }

    // MARK: Acoes

    private func load(_ url: URL) {
        error = nil
        do {
            let bytes = try EnvelopeFile.read(url)
            _ = try Envelope.inspect(bytes)
            fileName = url.lastPathComponent
            data = bytes
            Task.detached {
                let seconds = (try? Envelope.inspect(bytes).estimatedSeconds) ?? 3
                await MainActor.run { estimate = max(1, Int(seconds.rounded())) }
            }
        } catch Envelope.Failure.boundToDevice {
            error = String(localized: "Este envelope foi lacrado preso ao iPhone que o criou e só abre no app Escalibur daquele aparelho.")
        } catch Envelope.Failure.tooExpensiveForThisDevice(let mib) {
            error = Self.memoryMessage(mib)
        } catch EnvelopeFile.Failure.unreadable {
            error = String(localized: "Não foi possível ler o arquivo inteiro. Se ele está no iCloud, espere o download terminar e tente de novo.")
        } catch Envelope.Failure.notAnEnvelope, EnvelopeFile.Failure.notEnvelope {
            error = String(localized: "Este arquivo não é um envelope Escalibur. Envelopes terminam em .esclbr e têm 16.504 bytes.")
        } catch {
            self.error = String(localized: "Não foi possível ler o arquivo. Confira se ele ainda está no mesmo lugar e tente de novo.")
        }
    }

    static func memoryMessage(_ mib: Int) -> String {
        String(localized: "Este envelope exige \(mib) MiB por tentativa, e este iPhone não consegue reservar tanto agora. Feche outros apps e tente de novo. A senha não chegou a ser testada.")
    }

    private func open() async {
        guard let data, passwordLength > 0, !opening else { return }
        if estimate > 10, !heavyConfirmed {
            confirmingHeavy = true
            return
        }
        opening = true
        error = nil
        let password = self.password
        do {
            let contents = try await Offload.run {
                defer { password.wipe() }
                return try Envelope.open(data, password: password)
            }
            passwordLength = 0
            opened = contents
        } catch Envelope.Failure.slip39Share {
            error = String(localized: "Este envelope guarda uma parte SLIP-39. Uma parte sozinha não abre carteira, e esta versão ainda não junta partes.")
        } catch Envelope.Failure.invalidPhrase {
            error = String(localized: "Este envelope está danificado e não abre. Se você tem outra cópia do arquivo, use a outra.")
        } catch Envelope.Failure.unknownLanguage {
            error = String(localized: "O envelope abriu, mas a senha da carteira dentro dele está num idioma que esta versão não reconhece.")
        } catch Envelope.Failure.tooExpensiveForThisDevice(let mib) {
            error = Self.memoryMessage(mib)
        } catch Envelope.Failure.cannotOpen {
            self.password.wipe()
            passwordLength = 0
            self.error = String(localized: "Não abriu. Confira a senha, com maiúsculas, acentos e espaços, e tente de novo.")
        } catch {
            self.password.wipe()
            passwordLength = 0
            self.error = String(localized: "Não foi possível abrir este envelope agora. Tente de novo.")
        }
        opening = false
    }

    private func importWallet(_ contents: Envelope.Contents, words: Int) async {
        importing = true
        defer { importing = false }
        do {
            let phraseCopy = SecureBytes(capacity: contents.phrase.capacity)
            contents.phrase.withUnsafeBytes { phraseCopy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
            let passCopy = SecureBytes(capacity: max(contents.passphrase.count, 1))
            contents.passphrase.withUnsafeBytes { passCopy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
            let secret = try WalletSecret.from(phrase: phraseCopy, language: contents.language, passphrase: passCopy)
            phraseCopy.wipe()
            do {
                let preview = try await ImportPreview.make(secret)
                let name = contents.label.isEmpty ? String(localized: "Carteira \(session.metadata.wallets.count + 1)") : contents.label
                pending = (secret, preview, name, words)
            } catch {
                secret.wipe()
                throw error
            }
        } catch let walletError as WalletError {
            error = walletError.errorDescription
        } catch {
            self.error = String(localized: "Não foi possível importar a carteira.")
        }
    }

    private func reveal(_ contents: Envelope.Contents, words: Int) {
        let copy = SecureBytes(capacity: contents.phrase.capacity)
        contents.phrase.withUnsafeBytes { copy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        revealDraft = PhraseDraft(phrase: copy, wordCount: words)
    }

    /// Guarda depois da conferencia dos enderecos.
    private func save(tronForeign: Bool) async {
        guard let pending else { return }
        importing = true
        defer { importing = false }
        do {
            // O envelope pode ter vindo de outra pessoa, com o nome que ela escolheu: a
            // carteira dele nunca passa a ser a carteira em uso sozinha (auditoria 4, C7-05).
            let first = session.metadata.wallets.isEmpty
            guard try await auth.retrying(reason: String(localized: "Guardar a carteira do envelope neste iPhone"), { credential in
                try await session.addWallet(secret: pending.secret, name: pending.name, origin: .importedEnvelope,
                                            wordCount: pending.words, backupConfirmed: true, select: first, tronForeignControl: tronForeign,
                                            credential: credential)
            }) != nil else { return }
            self.pending = nil
            close()
        } catch let walletError as WalletError {
            discardPending()
            error = walletError.errorDescription
        } catch {
            discardPending()
            self.error = String(localized: "Não foi possível importar a carteira.")
        }
    }

    private func discardPending() {
        pending?.secret.wipe()
        pending = nil
    }

    private var passwordGlyphs: ((UInt64) -> String)? {
        guard passwordLength > 0 else { return nil }
        let cipher = self.cipher
        let count = passwordLength
        return { tick in cipher.glyphs(0, count: count, tick: tick) }
    }

    private func close() {
        cipher.clearAll()
        password.wipe()
        opened?.wipe()
        revealDraft?.wipe()
        pending?.secret.wipe()
        onClose()
    }
}
