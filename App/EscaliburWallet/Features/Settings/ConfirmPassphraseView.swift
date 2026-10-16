import EscaliburCore
import EscaliburKeys
import SwiftUI

/// Conferir a passphrase de uma carteira com passphrase (auditoria 4, C7-02). Antes, a
/// carteira nascia como "copia confirmada" herdada da carteira de base, e a passphrase
/// nunca era conferida: se o dono nao a tivesse anotado certo, o saldo ficava preso. Agora
/// ela so recebe depois de o dono digitar a passphrase de novo, longe da tela onde a
/// escolheu, de onde a anotou.
///
/// Com `expected` (a passphrase que acabou de aparecer na revelacao), confere aqui mesmo;
/// sem ele, o cofre abre a carteira e compara, com a presenca de sempre.
struct ConfirmPassphraseView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    let wallet: WalletMeta
    var expected: SecureBytes? = nil
    let onClose: () -> Void

    @State private var typed = SecureBytes(capacity: 256)
    @State private var typedLength = 0
    @State private var reveal = false
    @State private var message: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Confira a passphrase").typeStyle(.title).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Digite a passphrase de \(wallet.name) a partir de onde você anotou. Diferença de maiúscula, acento ou espaço já abre outra carteira, e o que chegar nesta se perde.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                PasswordBox(buffer: typed, length: $typedLength, placeholder: String(localized: "Passphrase"), focusOnAppear: true, reveal: $reveal) {
                    Task { await check() }
                }
                .padding(.top, Space.lg)
                .accessibilityIdentifier("conferir-passphrase")
                Text("Segure o dedo no campo para ver o que digitou.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xs)
                if let message { Banner(kind: .failure, title: message).padding(.top, Space.md) }
                Spacer()
                PrimaryButton(title: String(localized: "Conferir"), enabled: typedLength > 0, loading: working) {
                    Task { await check() }
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
            .padding(.bottom, Space.xs)
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
        .onDisappear { typed.wipe() }
    }

    private func check() async {
        guard !working, typedLength > 0 else { return }
        message = nil
        working = true
        defer { working = false }
        let matches: Bool
        if let expected {
            matches = Hash.constantTimeEqual(expected, typed)
        } else {
            // O cofre fica com uma copia: o campo continua dono do buffer dele.
            let copy = SecureBytes(capacity: typed.count)
            typed.withUnsafeBytes { copy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
            defer { copy.wipe() }
            let id = wallet.id
            do {
                // O PIN, nunca so o rosto: com o rosto do dono apresentado a forca, a conferencia
                // viraria um chute de passphrase por Face ID.
                guard let result = try await auth.perform(session, reason: String(localized: "Conferir a passphrase de \(wallet.name)"), presence: .pin, { rk in
                    let secret = try KeyServices.wallets.open(walletID: id, rk: rk)
                    defer { secret.wipe() }
                    return Hash.constantTimeEqual(secret.passphrase, copy)
                }) else { return }
                matches = result
            } catch {
                message = String(localized: "Não foi possível abrir a carteira agora.")
                return
            }
        }
        guard matches else {
            message = String(localized: "Não confere com a passphrase desta carteira. Confira o que você anotou, letra por letra.")
            return
        }
        var updated = session.metadata.wallets.first { $0.id == wallet.id } ?? wallet
        updated.passphraseConfirmedAt = .now
        session.update(updated)
        close()
    }

    private func close() {
        typed.wipe()
        onClose()
    }
}

/// O "Gravar agora" de uma carteira que ainda nao recebe: so a passphrase, quando as
/// palavras ja estao conferidas e ela nao; senao a revelacao com a conferencia das
/// palavras (e da passphrase logo depois, na mesma revelacao).
struct BackupNowFlow: View {
    let wallet: WalletMeta
    let onClose: () -> Void

    var body: some View {
        if wallet.wordsConfirmed, !wallet.passphraseConfirmed {
            ConfirmPassphraseView(wallet: wallet, onClose: onClose)
        } else {
            RevealFlow(wallet: wallet, purpose: .backup, onClose: onClose)
        }
    }
}
