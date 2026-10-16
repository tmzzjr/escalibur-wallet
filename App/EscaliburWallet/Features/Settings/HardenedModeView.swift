import EscaliburCore
import EscaliburKeys
import SwiftUI

/// Modo reforcado (docs/seguranca.md §2.6): abrir o app, assinar e ver as palavras pedem o
/// PIN e o Face ID juntos, e o "juntos" e da criptografia. O preco, dito antes de ligar:
/// se o cadastro de rostos mudar, as carteiras deste iPhone nao abrem mais, e so as
/// palavras trazem de volta.
struct HardenedModeView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(ToastCenter.self) private var toasts
    @State private var enabling = false
    @State private var working = false
    @State private var message: String?
    /// O modo visto pelo cofre, relido depois de ligar e de desligar: o cofre nao e
    /// observavel, e a tela ficava com o estado de antes.
    @State private var on = KeyServices.root.securityMode == .hardened

    private var phraseWallets: [WalletMeta] { session.metadata.wallets.filter { !$0.isWatchOnly } }
    private var missingBackup: WalletMeta? { phraseWallets.first { !$0.hasBackup } }
    private var ready: Bool { session.biometryEnabled && missingBackup == nil && !phraseWallets.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Palette.control))
                Text("Modo reforçado").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
                Text("Abrir o app, enviar, trocar e ver as palavras passam a pedir o PIN e o \(KeyServices.biometryName) juntos. O PIN sozinho não abre nada, e o rosto sozinho também não: é a própria cifra das carteiras que pede os dois.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Space.md) {
                    point("person.badge.key", String(localized: "Quem viu o seu PIN não abre o app nem envia nada sem o seu rosto."))
                    point("exclamationmark.triangle", String(localized: "Se o cadastro de rostos deste iPhone mudar (um rosto novo, o \(KeyServices.biometryName) redefinido), as carteiras daqui não abrem mais. Só as palavras de cada carteira trazem de volta."), caution: true)
                    point("hand.raised", String(localized: "Um \(KeyServices.biometryName) que não confirma conta como tentativa, como um PIN errado."))
                    point("iphone", String(localized: "Deixe ligados, nos Ajustes do iPhone, \"Exigir atenção para o \(KeyServices.biometryName)\" e a Proteção de Aparelho Roubado."))
                }
                .padding(Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                .padding(.top, Space.lg)

                if on {
                    Label("Ligado neste iPhone", systemImage: "checkmark.circle.fill")
                        .typeStyle(.row).foregroundStyle(Palette.success).padding(.top, Space.lg)
                } else {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Para ligar").typeStyle(.row).foregroundStyle(Palette.ink)
                        requirement(session.biometryEnabled, String(localized: "\(KeyServices.biometryName) ligado neste app"))
                        requirement(missingBackup == nil && !phraseWallets.isEmpty,
                                    missingBackup.map { String(localized: "Cópia de \($0.name) conferida") } ?? String(localized: "Cópia de todas as carteiras conferida"))
                        requirement(true, String(localized: "Na hora, as palavras de cada carteira, digitadas de onde você anotou"))
                    }
                    .padding(.top, Space.lg)
                }
                if let message { Banner(kind: .failure, title: message).padding(.top, Space.md) }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                if on {
                    SecondaryButton(title: String(localized: "Desligar o modo reforçado")) { Task { await disable() } }
                        .accessibilityIdentifier("reforcado-desligar")
                } else {
                    PrimaryButton(title: String(localized: "Ligar o modo reforçado"), enabled: ready, loading: working) {
                        // A espera do A1 recusa antes de o dono digitar as frases.
                        do {
                            try AuthCoordinator.checkPINAndBiometry()
                            message = nil
                            enabling = true
                        } catch {
                            message = AuthCoordinator.refusalMessage(error) ?? String(localized: "Não foi possível ligar agora.")
                        }
                    }
                        .accessibilityIdentifier("reforcado-ligar")
                }
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { on = KeyServices.root.securityMode == .hardened }
        .fullScreenCover(isPresented: $enabling) {
            HardenedEnableFlow(wallets: phraseWallets) { done in
                enabling = false
                on = KeyServices.root.securityMode == .hardened
                if done { toasts.show(String(localized: "Modo reforçado ligado.")) }
            }
        }
    }

    private func disable() async {
        message = nil
        guard case .hardened(let pin, _)? = await auth.credential(reason: String(localized: "Desligar o modo reforçado")) else { return }
        working = true
        defer { working = false }
        defer { on = KeyServices.root.securityMode == .hardened }
        do {
            let restored = try await session.disableHardened(pin: pin)
            toasts.show(restored ? String(localized: "Modo reforçado desligado. O \(KeyServices.biometryName) continua ligado.")
                        : String(localized: "Modo reforçado desligado. O \(KeyServices.biometryName) ficou desligado; ligue de novo em Segurança."))
        } catch RootKeyVault.Failure.wrongPIN(let remaining) {
            message = AuthCoordinator.wrongPINMessage(remaining)
        } catch RootKeyVault.Failure.biometryNotConfirmed(let remaining) {
            message = AuthCoordinator.faceNotConfirmedMessage(remaining)
        } catch {
            message = AuthCoordinator.refusalMessage(error) ?? String(localized: "Não foi possível desligar agora. O modo reforçado continua ligado.")
        }
    }

    private func point(_ icon: String, _ text: String, caution: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(caution ? Palette.caution : Palette.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(caution ? Palette.caution.opacity(0.16) : Palette.control))
            Text(text).typeStyle(.body).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
    }

    private func requirement(_ met: Bool, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(met ? Palette.success : Palette.inkMuted)
            Text(text).typeStyle(.note).foregroundStyle(met ? Palette.ink : Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Ligar: a frase inteira de cada carteira (e a passphrase das que tem), digitada de onde
/// o dono anotou, o aceite do preco, e o PIN e o rosto. A frase digitada vira so a entropia
/// (`WalletSecret`), comparada dentro do cofre com a guardada, em tempo constante, antes
/// do rk.and existir. Tres palavras provavam posse, nao uma copia certa, e no modo
/// reforcado o papel e o unico caminho de volta (revisao do modo reforcado, M7).
struct HardenedEnableFlow: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    let wallets: [WalletMeta]
    let onClose: (Bool) -> Void

    @State private var typed: [UUID: WalletSecret] = [:]
    @State private var index = 0
    @State private var accepted = false
    @State private var working = false
    @State private var message: String?
    /// Muda a cada recomeco, para a tela da frase nascer limpa.
    @State private var round = 0

    private var finishedTyping: Bool { index >= wallets.count }

    var body: some View {
        NavigationStack {
            Group {
                if !finishedTyping, wallets.indices.contains(index) {
                    let wallet = wallets[index]
                    ImportPhraseView(onFinished: { close(false) }, verify: .init(
                        walletName: wallet.name, wordCount: Self.wordCount(wallet), hasPassphrase: wallet.hasPassphrase
                    ) { secret in
                        typed[wallet.id]?.wipe()
                        typed[wallet.id] = secret
                        message = nil
                        index += 1
                    })
                    .id("\(wallet.id)-\(round)")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        consent
                        if let message { Banner(kind: .failure, title: message).padding(.top, Space.md) }
                        Spacer()
                        PrimaryButton(title: String(localized: "Ligar o modo reforçado"), enabled: accepted, loading: working) { Task { await enable() } }
                            .accessibilityIdentifier("reforcado-confirmar")
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.md)
                    .padding(.bottom, Space.xs)
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

    static func wordCount(_ wallet: WalletMeta) -> Int {
        if case .phrase(let count) = wallet.kind { return count }
        return 12
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Antes de ligar").typeStyle(.title).foregroundStyle(Palette.ink)
            Button { accepted.toggle() } label: {
                HStack(alignment: .top, spacing: Space.sm) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accepted ? Palette.control : Palette.void)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(accepted ? Palette.inkSoft : Palette.edgeStrong, lineWidth: 1.5))
                        .overlay {
                            if accepted {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .padding(.top, 1)
                    Text("Entendo que, se o cadastro de rostos deste iPhone mudar, as carteiras daqui não abrem mais, e só as palavras de cada carteira trazem de volta. Os nomes, endereços salvos e ajustes daqui se perdem junto.")
                        .typeStyle(.note).foregroundStyle(accepted ? Palette.ink : Palette.inkSoft)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(Space.md)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
            }
            .buttonStyle(.plain)
            .accessibilityValue(accepted ? "Marcado" : "Desmarcado")
            .accessibilityAddTraits(accepted ? .isSelected : [])
            .accessibilityIdentifier("reforcado-aceite")
            Text("Depois, o PIN e o \(KeyServices.biometryName) duas vezes: uma para abrir, outra para conferir o modo novo antes de valer.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func enable() async {
        message = nil
        guard case .pin(let pin)? = await auth.credential(reason: String(localized: "Ligar o modo reforçado"), forcePIN: true) else { return }
        working = true
        defer { working = false }
        let checks = wallets.compactMap { wallet in typed[wallet.id].map { (id: wallet.id, name: wallet.name, secret: $0, passphrase: wallet.hasPassphrase) } }
        guard checks.count == wallets.count else { restart(); return }
        do {
            try await session.enableHardened(pin: pin) { rk in
                for check in checks {
                    let stored = try KeyServices.wallets.open(walletID: check.id, rk: rk)
                    defer { stored.wipe() }
                    // A entropia, nao as palavras: nenhuma frase vira String, e o idioma vem junto.
                    guard stored.language == check.secret.language, Hash.constantTimeEqual(stored.entropy, check.secret.entropy) else {
                        throw HardenedCheckError.mismatch(check.name)
                    }
                    if check.passphrase {
                        // As duas em NFKD: a importada ja foi gravada assim, a criada aqui pode
                        // ter os bytes do teclado (revisao do modo reforcado, M3).
                        let saved = BIP39.nfkd(stored.passphrase)
                        defer { saved.wipe() }
                        guard Hash.constantTimeEqual(saved, check.secret.passphrase) else { throw HardenedCheckError.mismatch(check.name) }
                        // Gravada fora de NFKD por uma versao anterior: restaurada pelas palavras,
                        // a conta da Cardano dela muda. Nao vale como copia (segunda revisao, N1).
                        guard Hash.constantTimeEqual(saved, stored.passphrase) else { throw HardenedCheckError.legacyPassphrase(check.name) }
                    }
                }
            }
            close(true)
        } catch HardenedCheckError.mismatch(let name) {
            message = String(localized: "O que você digitou de \(name) não confere com esta carteira. Confira no papel e comece de novo.")
            restart()
        } catch HardenedCheckError.legacyPassphrase(let name) {
            message = Self.legacyPassphraseMessage(name)
            restart()
        } catch RootKeyVault.Failure.wrongPIN(let remaining) {
            message = AuthCoordinator.wrongPINMessage(remaining)
        } catch RootKeyVault.Failure.throttled(let seconds) {
            message = String(localized: "Tentativas demais. Tente de novo em \(LockView.duration(seconds)).")
        } catch RootKeyVault.Failure.cancelled {
            message = String(localized: "O \(KeyServices.biometryName) não confirmou. O modo reforçado continua desligado.")
        } catch RootKeyVault.Failure.biometryChanged {
            message = String(localized: "O \(KeyServices.biometryName) deste iPhone mudou durante a conferência. O modo reforçado continua desligado.")
        } catch RootKeyVault.Failure.hardenedBlocked(let blocker) {
            message = Self.blockedMessage(blocker)
        } catch RootKeyVault.Failure.wiped {
            close(false)
        } catch RootKeyVault.Failure.hardenedSlotLost {
            message = String(localized: "A conferência do modo novo não abriu. Nada mudou: o modo de antes continua valendo.")
        } catch {
            message = AuthCoordinator.refusalMessage(error) ?? String(localized: "Não foi possível ligar agora. Nada mudou: o modo de antes continua valendo.")
        }
    }

    /// A carteira com passphrase acentuada criada por uma versao anterior: a copia nao a
    /// traz de volta inteira.
    static func legacyPassphraseMessage(_ name: String) -> String {
        String(localized: "A passphrase de \(name) foi gravada por uma versão anterior do app, e restaurada pelas palavras a conta da Cardano dela muda. Mova o saldo dela para outra carteira e crie a carteira com passphrase de novo.")
    }

    static func blockedMessage(_ blocker: RootKeyVault.HardenedBlocker) -> String {
        switch blocker {
        case .biometryOff: return String(localized: "Ligue o \(KeyServices.biometryName) neste app antes.")
        case .changePending: return String(localized: "Uma troca de PIN não terminou. Destrave o app com o PIN e tente de novo.")
        case .legacySlot: return String(localized: "Destrave o app com o PIN uma vez e tente de novo.")
        case .biometryUnavailable: return String(localized: "O \(KeyServices.biometryName) não está disponível agora. Tente de novo no próprio iPhone.")
        }
    }

    private func restart() {
        typed.values.forEach { $0.wipe() }
        typed = [:]
        index = 0
        accepted = false
        round += 1
    }

    private func close(_ done: Bool) {
        typed.values.forEach { $0.wipe() }
        typed = [:]
        onClose(done)
    }
}

enum HardenedCheckError: Error { case mismatch(String), legacyPassphrase(String) }
