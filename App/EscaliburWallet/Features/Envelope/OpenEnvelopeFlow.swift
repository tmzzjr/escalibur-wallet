import EscaliburCore
import EscaliburKeys
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// O tipo do envelope, declarado no Info.plist.
    static let escaliburEnvelope = UTType(exportedAs: "com.thomazjr.escalibur.envelope")
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
    @State private var fileName: String?
    @State private var data: Data?
    @State private var password = SecureBytes(capacity: 256)
    @State private var passwordLength = 0
    @State private var opening = false
    @State private var estimate = 3
    @State private var error: String?
    @State private var opened: Envelope.Contents?
    @State private var revealDraft: PhraseDraft?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if let revealDraft, let opened {
                    RecordWordsView(draft: revealDraft, walletName: opened.label.isEmpty ? "Envelope" : opened.label,
                                    passphrase: opened.passphrase.count > 0 ? opened.passphrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } : nil) {
                        close()
                    }
                } else if let opened {
                    openedView(opened)
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
        .fileImporter(isPresented: $picking, allowedContentTypes: [.escaliburEnvelope, .data]) { result in
            if case .success(let url) = result { load(url) }
        }
        .onAppear { if let initialURL { load(initialURL) } }
    }

    private var chooseView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Abrir um envelope").typeStyle(.title).foregroundStyle(Palette.ink)
            Text("Escolha o arquivo .esclbr no app Arquivos. O original continua onde está.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            Spacer()
            PrimaryButton(title: "Escolher arquivo") { picking = true }
        }
    }

    private var passwordView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fileName {
                Text(fileName).typeStyle(.monoSmall).foregroundStyle(Palette.inkMuted)
            }
            Text("Senha do envelope").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.xs)
            Text("A senha escolhida quando o envelope foi lacrado. No app Escalibur, é a senha do cofre.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            PasswordBox(buffer: password, length: $passwordLength, placeholder: "Senha do envelope") { Task { await open() } }
                .padding(.top, Space.lg)
            if let error {
                Text(error).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            }
            if opening {
                Text("Abrindo. Leva cerca de \(estimate) segundos, e cada tentativa custa o mesmo para quem tentar adivinhar.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            PrimaryButton(title: "Abrir envelope", enabled: passwordLength > 0, loading: opening) { Task { await open() } }
        }
    }

    private func openedView(_ contents: Envelope.Contents) -> some View {
        let words = contents.phrase.withUnsafeBytes { raw in raw.filter { $0 == 0x20 }.count + 1 }
        return VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "envelope.open").font(.system(size: 34, weight: .regular)).foregroundStyle(Palette.ink)
            Text(verbatim: contents.label.isEmpty ? "Envelope aberto" : contents.label)
                .typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
            Text("\(words) palavras, lista em \(contents.language.displayName.lowercased())" + (contents.passphrase.count > 0 ? " · com 25ª palavra" : ""))
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
            if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            Spacer()
            PrimaryButton(title: "Importar esta carteira", loading: importing) { Task { await importWallet(contents, words: words) } }
            SecondaryButton(title: "Só ver as palavras") { reveal(contents, words: words) }.padding(.top, Space.sm)
        }
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
            error = "Este envelope foi lacrado preso ao iPhone que o criou e só abre no app Escalibur daquele aparelho."
        } catch Envelope.Failure.tooExpensiveForThisDevice(let mib) {
            error = "Este envelope exige \(mib) MiB por tentativa, e este iPhone não consegue reservar tanto agora. Feche outros apps e tente de novo. A senha não chegou a ser testada."
        } catch {
            self.error = "Este arquivo não é um envelope Escalibur. Envelopes terminam em .esclbr e têm 16.504 bytes."
        }
    }

    private func open() async {
        guard let data, passwordLength > 0, !opening else { return }
        opening = true
        error = nil
        let password = self.password
        do {
            let contents = try await Task.detached(priority: .userInitiated) {
                defer { password.wipe() }
                return try Envelope.open(data, password: password)
            }.value
            passwordLength = 0
            opened = contents
        } catch Envelope.Failure.slip39Share {
            error = "Este envelope guarda uma parte SLIP-39. Uma parte sozinha não abre carteira, e esta versão ainda não junta partes."
        } catch Envelope.Failure.invalidPhrase {
            error = "Este envelope está danificado e não abre. Se você tem outra cópia do arquivo, use a outra."
        } catch {
            self.password.wipe()
            passwordLength = 0
            self.error = "Não abriu. Confira a senha, com maiúsculas, acentos e espaços, e tente de novo."
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
            guard let credential = await auth.credential(reason: "Guardar a carteira do envelope neste iPhone") else { return }
            let name = contents.label.isEmpty ? "Carteira \(session.metadata.wallets.count + 1)" : contents.label
            _ = try await session.addWallet(secret: secret, name: name, origin: .importedEnvelope, wordCount: words, backupConfirmed: true, credential: credential)
            close()
        } catch let walletError as WalletError {
            error = walletError.errorDescription
        } catch {
            self.error = "Não foi possível importar a carteira."
        }
    }

    private func reveal(_ contents: Envelope.Contents, words: Int) {
        let copy = SecureBytes(capacity: contents.phrase.capacity)
        contents.phrase.withUnsafeBytes { copy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        revealDraft = PhraseDraft(phrase: copy, wordCount: words)
    }

    private func close() {
        password.wipe()
        opened?.wipe()
        revealDraft?.wipe()
        onClose()
    }
}
