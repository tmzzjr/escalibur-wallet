import EscaliburCore
import SwiftUI

/// S3: criar a carteira da 25ª palavra a partir da carteira selecionada. A frase nao
/// aparece: o cofre abre, deriva a carteira nova e grava, com uma confirmacao so. Em tres
/// passos (pedido do dono, 16/10/2026): o que e, a checagem do aparelho e so entao os
/// campos da passphrase.
struct PassphraseWalletView: View {
    @Environment(\.dismiss) private var dismiss
    let base: WalletMeta

    @State private var checking = false
    @State private var entering = false
    /// A carteira abriu: as duas telas de cima saem sem animacao e esta sai ao reaparecer.
    @State private var opened = false

    private var wordCount: Int {
        if case .phrase(let count) = base.kind { return count }
        return 12
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // O cofre de pixels: outra carteira, trancada pelo que so voce sabe.
                PixelVault()
                VStack(spacing: Space.xs) {
                    Text("Carteira com passphrase").typeStyle(.title).foregroundStyle(Palette.ink)
                    Text("Uma senha extra, escolhida por você. Junto com a senha de \(base.name), ela abre outra carteira, com outros endereços.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .padding(.top, Space.md)

                VStack(alignment: .leading, spacing: Space.md) {
                    PassphrasePoint(icon: "eye.slash", text: String(localized: "Quem achar só as \(wordCount) palavras vê a carteira de sempre, não esta. Dentro deste app, quem tem o PIN vê as duas na lista de carteiras."))
                    PassphrasePoint(icon: "pencil.and.list.clipboard", text: String(localized: "Anote a passphrase longe das \(wordCount). Para abrir esta carteira em outro aparelho, você vai precisar das duas."))
                    // Na mesma cor dos outros pontos (pedido do dono, 16/10/2026).
                    PassphrasePoint(icon: "exclamationmark.triangle", text: String(localized: "Esquecer a passphrase é perder o acesso a esta carteira. Ninguém recupera, nem a Escalibur."))
                }
                .padding(Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                .padding(.top, Space.lg)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                PrimaryButton(title: String(localized: "Continuar")) { checking = true }
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if opened { dismiss() } }
        .navigationDestination(isPresented: $checking) {
            DeviceCheckView(slideTitle: String(localized: "Deslize para digitar a passphrase"),
                            consent: String(localized: "Estou ciente de que este iPhone falhou na verificação de integridade e de que digitar a passphrase aqui pode expor a carteira. Quero seguir mesmo assim.")) {
                entering = true
            }
            .navigationDestination(isPresented: $entering) {
                // Aberta a carteira, volta de uma vez para onde o caminho comecou.
                PassphraseEntryView(base: base) {
                    opened = true
                    var quiet = Transaction()
                    quiet.disablesAnimations = true
                    withTransaction(quiet) { checking = false }
                }
            }
        }
    }
}

/// O ultimo passo: os dois campos da passphrase e o nome da carteira nova.
struct PassphraseEntryView: View {
    @Environment(AppSession.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(AuthCoordinator.self) private var auth
    let base: WalletMeta
    let onDone: () -> Void

    @State private var passphrase = SecureBytes(capacity: 256)
    @State private var passphraseLength = 0
    /// Segurar o dedo numa das duas mostra as duas.
    @State private var revealPassphrase = false
    @State private var again = SecureBytes(capacity: 256)
    @State private var againLength = 0
    @State private var name = ""
    @State private var message: String?
    @State private var working = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Digite a passphrase").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Escreva igual ao que você anotou. Diferença de maiúscula, acento ou espaço já abre outra carteira.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Space.md)
                Text("Passphrase").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                PasswordBox(buffer: passphrase, length: $passphraseLength, placeholder: String(localized: "Passphrase"), reveal: $revealPassphrase)
                PasswordBox(buffer: again, length: $againLength, placeholder: String(localized: "Repita a passphrase"), reveal: $revealPassphrase) { Task { await create() } }
                    .id("repita")
                Text("Segure o dedo num campo para conferir as duas.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nome").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                TextField("", text: $name)
                    .typeStyle(.row).foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.md).frame(height: Height.field)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                if let message {
                    Banner(kind: .failure, title: message).padding(.top, Space.sm)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
        .scrollDismissesKeyboard(.interactively)
        // Com o teclado aberto, o botao de baixo cobria a repeticao: ao comecar a digitar a
        // passphrase, a tela sobe ate ela (visto no teste de interface).
        .onChange(of: passphraseLength) { old, new in
            if old == 0, new > 0 { withAnimation(Motion.fade) { proxy.scrollTo("repita", anchor: .center) } }
        }
        }
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                PrimaryButton(title: String(localized: "Abrir carteira"), enabled: passphraseLength > 0 && againLength > 0, loading: working) {
                    Task { await create() }
                }
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .guardedAgainstCapture()
        .onAppear { if name.isEmpty { name = String(localized: "\(base.name) com passphrase") } }
        .onDisappear {
            passphrase.wipe()
            again.wipe()
        }
    }

    private func create() async {
        guard !working, passphraseLength > 0 else { return }
        message = nil
        guard Hash.constantTimeEqual(passphrase, again) else {
            message = String(localized: "As duas versões da passphrase não conferem.")
            return
        }
        guard PassphraseWalletView.isWritable(passphrase) else {
            message = String(localized: "A passphrase tem um caractere invisível ou um espaço diferente do espaço comum. Escreva de novo, só com letras, números, símbolos e espaço comum: é o que dá para anotar no papel.")
            return
        }
        working = true
        defer { working = false }
        // O cofre fica com uma copia: os campos continuam donos dos seus buffers.
        let copy = SecureBytes(capacity: passphrase.count)
        passphrase.withUnsafeBytes { copy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        defer { copy.wipe() }
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let walletName = title.isEmpty ? String(localized: "\(base.name) com passphrase") : title
        let before = Set(session.metadata.wallets.map(\.id))
        do {
            guard let opened = try await auth.retrying(reason: String(localized: "Abrir a carteira com passphrase"), { credential in
                try await session.addPassphraseWallet(base: base, passphrase: copy, name: walletName, credential: credential)
            }) else { return }
            passphrase.wipe()
            again.wipe()
            // A mesma frase com a mesma passphrase e a mesma carteira: ela ja estava aqui.
            if before.contains(opened.id) {
                toasts.show(String(localized: "Esta carteira já está aberta, como \(opened.name). Ela passa a ser a carteira em uso."))
            }
            onDone()
        } catch let error as WalletError {
            message = error.errorDescription
        } catch {
            message = String(localized: "Não foi possível criar a carteira agora.")
        }
    }
}

extension PassphraseWalletView {
    /// A passphrase cabe no papel? Caractere de controle, de formato (largura zero,
    /// bidirecional), separador de linha, uso privado ou um espaco que nao e o comum nao
    /// aparecem, ou aparecem iguais a outros, e quem anota perde a carteira (revisao da
    /// auditoria 4, C7-02). Lido escalar por escalar direto do buffer, sem virar String.
    static func isWritable(_ secret: SecureBytes) -> Bool {
        secret.withUnsafeBytes { raw in
            var iterator = raw.makeIterator()
            var decoder = Unicode.UTF8()
            while true {
                switch decoder.decode(&iterator) {
                case .scalarValue(let scalar):
                    switch scalar.properties.generalCategory {
                    case .format, .control, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                        return false
                    case .spaceSeparator where scalar != " ":
                        return false
                    default:
                        continue
                    }
                case .emptyInput: return true
                case .error: return false
                }
            }
        }
    }
}

/// Um ponto da explicacao: icone do assunto e uma frase.
private struct PassphrasePoint: View {
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
