import EscaliburCore
import EscaliburKeys
import SwiftUI

/// X1 e X2: revelar a senha da carteira. Tambem e o caminho de "Gravar agora"
/// (fazer a copia que faltou), que termina na conferencia digitada.
struct RevealFlow: View {
    enum Purpose { case reveal, backup }

    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    let wallet: WalletMeta
    let purpose: Purpose
    let onClose: () -> Void

    @State private var draft: PhraseDraft?
    @State private var passphrase: String?
    @State private var confirming = false
    @State private var working = false
    @State private var error: String?
    @State private var acknowledged: Set<Int> = []

    var body: some View {
        NavigationStack {
            Group {
                if let draft, confirming {
                    ConfirmWordsView(draft: draft, onBack: { confirming = false }) { confirmed() }
                } else if let draft {
                    RecordWordsView(draft: draft, walletName: purpose == .reveal ? wallet.name : nil, passphrase: passphrase) {
                        if purpose == .backup { confirming = true } else { finish() }
                    }
                } else {
                    warning
                }
            }
            .background(Palette.void.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { finish() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                    }
                    .accessibilityLabel("Fechar")
                }
            }
        }
        .interactiveDismissDisabled()
        .guardedAgainstCapture()
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ninguém da Escalibur vai pedir estas palavras")
                .typeStyle(.title).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Suporte, gerente de exchange, recuperação de conta: quem pede a senha da carteira está tentando roubar o saldo.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(Self.statements.enumerated()), id: \.offset) { index, statement in
                    Button {
                        if acknowledged.contains(index) { acknowledged.remove(index) } else { acknowledged.insert(index) }
                    } label: {
                        HStack(spacing: Space.sm) {
                            ZStack {
                                Circle().stroke(acknowledged.contains(index) ? Palette.ink : Palette.inkMuted, lineWidth: 1.5)
                                if acknowledged.contains(index) {
                                    Circle().fill(Palette.ink)
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.onLive)
                                }
                            }
                            .frame(width: 22, height: 22)
                            Text(statement).typeStyle(.body).foregroundStyle(Palette.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: Height.rowCompact)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: acknowledged.contains(index))
                }
            }
            .padding(.top, Space.lg)
            if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            Spacer()
            PrimaryButton(title: "Ver as palavras", enabled: acknowledged.count == Self.statements.count, loading: working) {
                Task { await open() }
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xs)
    }

    static let statements = [
        "Quem tem as palavras tem o saldo.",
        "A Escalibur nunca pede as palavras.",
        "Vou ver sozinho, longe de câmeras.",
    ]

    private func open() async {
        working = true
        defer { working = false }
        error = nil
        let id = wallet.id
        do {
            guard await VoiceGate.shared.confirm(.reveal, session: session) else { return }
            let result: (SecureBytes, String?)? = try await auth.perform(session, reason: "Ver a senha de \(wallet.name)") { rk in
                let secret = try KeyServices.wallets.open(walletID: id, rk: rk)
                defer { secret.wipe() }
                let pass = secret.passphrase.count > 0 ? secret.passphrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } : nil
                return (try secret.phrase(), pass)
            }
            guard let (phrase, pass) = result else { return }
            let words = phrase.withUnsafeBytes { raw in raw.filter { $0 == 0x20 }.count + 1 }
            passphrase = pass
            draft = PhraseDraft(phrase: phrase, wordCount: words)
        } catch {
            self.error = "Não foi possível abrir a carteira agora."
        }
    }

    private func confirmed() {
        var updated = wallet
        updated.backupConfirmedAt = .now
        session.update(updated)
        finish()
    }

    private func finish() {
        if draft != nil {
            var updated = session.metadata.wallets.first { $0.id == wallet.id } ?? wallet
            updated.lastRevealedAt = .now
            session.update(updated)
        }
        draft?.wipe()
        draft = nil
        onClose()
    }
}
