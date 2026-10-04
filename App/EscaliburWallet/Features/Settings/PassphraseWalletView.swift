import EscaliburCore
import SwiftUI

/// S3: criar a carteira da 25ª palavra a partir da carteira selecionada. A frase nao
/// aparece: o cofre abre, deriva a carteira nova e grava, com uma confirmacao so.
struct PassphraseWalletView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let base: WalletMeta

    @State private var passphrase = SecureBytes(capacity: 256)
    @State private var passphraseLength = 0
    @State private var again = SecureBytes(capacity: 256)
    @State private var againLength = 0
    @State private var name = ""
    @State private var message: String?
    @State private var working = false

    private var wordCount: Int {
        if case .phrase(let count) = base.kind { return count }
        return 12
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Palette.control))
                VStack(spacing: Space.xs) {
                    Text("Carteira com passphrase").typeStyle(.title).foregroundStyle(Palette.ink)
                    Text("Uma senha extra, escolhida por você. Junto com a senha de \(base.name), ela abre outra carteira, com outros endereços.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .padding(.top, Space.md)

                VStack(alignment: .leading, spacing: Space.md) {
                    PassphrasePoint(icon: "eye.slash", text: "Quem achar só as \(wordCount) palavras vê a carteira de sempre, não esta.")
                    PassphrasePoint(icon: "pencil.and.list.clipboard", text: "Anote a passphrase longe das \(wordCount). Para abrir esta carteira em outro aparelho, você vai precisar das duas.")
                    PassphrasePoint(icon: "exclamationmark.triangle", text: "Esquecer a passphrase é perder o que estiver nesta carteira. Ninguém recupera, nem a Escalibur.", caution: true)
                }
                .padding(Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                .padding(.top, Space.lg)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Passphrase").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    PasswordBox(buffer: passphrase, length: $passphraseLength, placeholder: "Passphrase")
                    PasswordBox(buffer: again, length: $againLength, placeholder: "Repita a passphrase") { Task { await create() } }
                    Text("Diferença de maiúscula, acento ou espaço já abre outra carteira.")
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
                .padding(.top, Space.lg)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                PrimaryButton(title: "Abrir carteira", enabled: passphraseLength > 0 && againLength > 0, loading: working) {
                    Task { await create() }
                }
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .guardedAgainstCapture()
        .onAppear { if name.isEmpty { name = "\(base.name) com passphrase" } }
        .onDisappear {
            passphrase.wipe()
            again.wipe()
        }
    }

    private func create() async {
        guard !working, passphraseLength > 0 else { return }
        message = nil
        guard Hash.constantTimeEqual(passphrase, again) else {
            message = "As duas versões da passphrase não conferem."
            return
        }
        working = true
        defer { working = false }
        guard let credential = await auth.credential(reason: "Criar a carteira com passphrase") else { return }
        // O cofre fica com uma copia: os campos continuam donos dos seus buffers.
        let copy = SecureBytes(capacity: passphrase.count)
        passphrase.withUnsafeBytes { copy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        do {
            _ = try await session.addPassphraseWallet(base: base, passphrase: copy, name: title.isEmpty ? "\(base.name) com passphrase" : title,
                                                      credential: credential)
            passphrase.wipe()
            again.wipe()
            dismiss()
        } catch let error as WalletError {
            message = error.errorDescription
        } catch {
            message = "Não foi possível criar a carteira agora."
        }
    }
}

/// Um ponto da explicacao: icone do assunto e uma frase; o alerta em cor de cuidado.
private struct PassphrasePoint: View {
    let icon: String
    let text: String
    var caution = false

    var body: some View {
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
}
