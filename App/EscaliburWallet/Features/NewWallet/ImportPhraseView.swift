import EscaliburChains
import EscaliburCore
import EscaliburKeys
import SwiftUI
import UIKit

/// As palavras em digitacao, uma por posicao, cada uma num buffer seguro.
@MainActor
@Observable
final class PhraseEntry {
    private(set) var slots: [SecureBytes] = []
    var count = 12 { didSet { resize() } }
    var active = 0
    var revision = 0

    init() { resize() }

    private func resize() {
        while slots.count < count { slots.append(SecureBytes(capacity: 32)) }
        if slots.count > count {
            slots[count...].forEach { $0.wipe() }
            slots.removeLast(slots.count - count)
        }
        active = min(active, count - 1)
        revision += 1
    }

    func set(_ word: String, at index: Int) {
        let canonical = Array(Mnemonic.canonicalize(word).utf8.prefix(32))
        slots[index].replaceAll(with: canonical)
        revision += 1
    }

    func word(at index: Int) -> String {
        slots[index].withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }

    func isFilled(_ index: Int) -> Bool { slots[index].count > 0 }
    var filledCount: Int { slots.filter { $0.count > 0 }.count }

    /// Distribui uma frase colada pelas posicoes.
    func paste(_ text: String) {
        let words = Mnemonic.words(in: text)
        if Mnemonic.validWordCounts.contains(words.count) { count = words.count }
        for (index, word) in words.prefix(count).enumerated() { set(word, at: index) }
        active = min(words.count, count - 1)
    }

    /// A frase inteira num buffer seguro, na forma canonica.
    func phrase() -> SecureBytes {
        let out = SecureBytes(capacity: count * 33)
        for (index, slot) in slots.enumerated() {
            if index > 0 { out.append(0x20) }
            slot.withUnsafeBytes { out.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        }
        return out
    }

    func wipe() {
        slots.forEach { $0.wipe() }
        revision += 1
    }
}

/// O6: importar com a senha da carteira.
struct ImportPhraseView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    let onFinished: () -> Void

    @State private var entry = PhraseEntry()
    @State private var typed = ""
    @State private var reveal = false
    @State private var usesPassphrase = false
    @State private var passphrase = SecureBytes(capacity: 256)
    @State private var passphraseLength = 0
    @State private var passphraseAgain = SecureBytes(capacity: 256)
    @State private var passphraseAgainLength = 0
    @State private var message: String?
    @State private var pasteNotice = false
    @State private var working = false
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let prefix = Mnemonic.canonicalize(typed)
        guard prefix.count >= 1 else { return [] }
        var found: [String] = []
        for language in [BIP39Language.english, .portuguese, .spanish] {
            if let list = try? WordlistStore.shared.wordlist(for: language) {
                found += list.completions(forPrefix: prefix, limit: 4).filter { !found.contains($0) }
            }
            if found.count >= 4 { break }
        }
        return Array(found.prefix(4))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Importar com a senha da carteira").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Digite as palavras na ordem. Ninguém da Escalibur pede estas palavras.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.xs) {
                    ForEach(Mnemonic.validWordCounts, id: \.self) { n in
                        Chip(title: "\(n)", selected: entry.count == n) { entry.count = n }
                    }
                    Spacer()
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in
                            entry.paste(text)
                            UIPasteboard.general.items = []
                            pasteNotice = true
                        }
                    }
                    .buttonBorderShape(.roundedRectangle(radius: Radius.chip))
                    .labelStyle(.titleOnly)
                    .tint(Palette.rail)
                }
                .padding(.top, Space.md)

                if pasteNotice {
                    Text("Colado. A área de transferência foi limpa agora, mas pode já ter sincronizado com outros aparelhos Apple.")
                        .typeStyle(.note).foregroundStyle(Palette.caution).padding(.top, Space.xs)
                        .fixedSize(horizontal: false, vertical: true)
                }

                grid.padding(.top, Space.md)

                HStack {
                    Spacer()
                    TertiaryButton(title: reveal ? "Esconder palavras" : "Mostrar palavras") { reveal.toggle() }
                }

                wordInput.padding(.top, Space.xs)

                Toggle(isOn: $usesPassphrase) {
                    Text("Esta carteira usa 25ª palavra").typeStyle(.body).foregroundStyle(Palette.ink)
                }
                .tint(Palette.up)
                .padding(.top, Space.lg)
                if usesPassphrase {
                    Text("Com a 25ª palavra errada, a carteira abre vazia e sem aviso nenhum. Por isso ela é digitada duas vezes.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                        .fixedSize(horizontal: false, vertical: true)
                    PasswordBox(buffer: passphrase, length: $passphraseLength, placeholder: "25ª palavra").padding(.top, Space.sm)
                    PasswordBox(buffer: passphraseAgain, length: $passphraseAgainLength, placeholder: "Repita a 25ª palavra").padding(.top, Space.xs)
                }

                if let message {
                    Banner(kind: .failure, title: message).padding(.top, Space.md)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                PrimaryButton(title: "Importar", enabled: entry.filledCount == entry.count, loading: working) {
                    Task { await importWallet() }
                }
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .guardedAgainstCapture()
        .onDisappear {
            entry.wipe()
            passphrase.wipe()
            passphraseAgain.wipe()
        }
    }

    private var grid: some View {
        let columns = [GridItem(.flexible(), spacing: Space.xs), GridItem(.flexible(), spacing: Space.xs)]
        return LazyVGrid(columns: columns, spacing: Space.xs) {
            ForEach(0..<entry.count, id: \.self) { index in
                Button { entry.active = index; typed = ""; focused = true } label: {
                    HStack(spacing: Space.xs) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.inkMuted)
                        Text(verbatim: slotText(index))
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(entry.isFilled(index) ? Palette.ink : Palette.inkDead)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.sm)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(Palette.body)
                            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                .stroke(entry.active == index ? Palette.edgeStrong : Palette.edge, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .id(entry.revision)
    }

    private func slotText(_ index: Int) -> String {
        guard entry.isFilled(index) else { return "palavra" }
        return reveal ? entry.word(at: index) : "•••••"
    }

    private var wordInput: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            TextField("", text: $typed, prompt: Text("Palavra \(entry.active + 1)").foregroundColor(Palette.inkDead))
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .textContentType(nil)
                .focused($focused)
                .submitLabel(.next)
                .onSubmit { commit(typed) }
                .padding(.horizontal, Space.md)
                .frame(height: Height.field)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(focused ? Palette.edgeStrong : Palette.edge, lineWidth: 1)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(suggestions, id: \.self) { word in Chip(title: word) { commit(word) } }
                }
            }
            .frame(height: Height.chip)
        }
    }

    private func commit(_ word: String) {
        let clean = word.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        entry.set(clean, at: entry.active)
        typed = ""
        message = nil
        if entry.active < entry.count - 1 { entry.active += 1 } else { focused = false }
    }

    private func importWallet() async {
        message = nil
        let phrase = entry.phrase()
        switch BIP39.validate(phrase) {
        case .valid(let language):
            if usesPassphrase {
                let same = passphrase.withUnsafeBytes { a in passphraseAgain.withUnsafeBytes { b in Hash.constantTimeEqual(Array(a), Array(b)) } }
                guard same, passphraseLength > 0 else {
                    message = "As duas versões da 25ª palavra não conferem."
                    phrase.wipe()
                    return
                }
            }
            working = true
            defer { working = false }
            do {
                let pass = SecureBytes(capacity: 256)
                if usesPassphrase { passphrase.withUnsafeBytes { pass.append(contentsOf: $0.bindMemory(to: UInt8.self)) } }
                let secret = try WalletSecret.from(phrase: phrase, language: language, passphrase: pass)
                phrase.wipe()
                guard let credential = await auth.credential(reason: "Guardar a carteira importada neste iPhone") else { return }
                let name = "Carteira \(session.metadata.wallets.count + 1)"
                _ = try await session.addWallet(secret: secret, name: session.metadata.wallets.isEmpty ? "Carteira principal" : name,
                                                origin: .importedPhrase, wordCount: entry.count, backupConfirmed: true, credential: credential)
                entry.wipe()
                onFinished()
            } catch let walletError as WalletError {
                message = walletError.errorDescription
            } catch {
                message = "Não foi possível importar a carteira."
            }
        case .wrongLength(let count):
            message = "Faltam palavras: \(count) de \(entry.count)."
        case .unknownWords(let positions, _):
            let first = (positions.first ?? 0) + 1
            message = "A palavra \(first) não existe na lista. Confira no papel."
        case .checksumFailed:
            message = "Todas as palavras existem, mas a conferência da frase não fecha. Alguma está trocada ou fora de ordem. Confira no papel."
        case .mixedLanguages:
            message = "As palavras são de idiomas diferentes. Confira no papel."
        case .ambiguousLanguage:
            message = "Esta frase vale em mais de um idioma, e a escolha muda a carteira. Importe pela versão em inglês da frase."
        }
        phrase.wipe()
    }
}

/// O8: observar um endereco, sem poder enviar.
struct WatchAddressView: View {
    @Environment(AppSession.self) private var session
    let onFinished: () -> Void
    @State private var address = ""
    @State private var name = "Carteira fria"
    @State private var error: String?

    private var detected: Chain? { Address.guessChain(address.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Observar um endereço").typeStyle(.title).foregroundStyle(Palette.ink)
            Text("Endereço").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
            TextField("", text: $address, axis: .vertical)
                .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(Space.md)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                .padding(.top, Space.xs)
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in address = strings.first ?? "" }
            }
            .labelStyle(.titleOnly).tint(Palette.rail).padding(.top, Space.xs)
            if let detected {
                Text(detected.family == .evm
                     ? "Endereço EVM: vale em Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain e Avalanche."
                     : "Endereço \(detected.name)")
                    .typeStyle(.note).foregroundStyle(Palette.up).padding(.top, Space.sm)
            } else if !address.isEmpty {
                Text("Não reconheci este endereço em nenhuma rede ligada. Confira se copiou inteiro.")
                    .typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.sm)
            }
            Text("Nome").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
            TextField("", text: $name)
                .typeStyle(.row).foregroundStyle(Palette.ink)
                .padding(.horizontal, Space.md).frame(height: Height.field)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                .padding(.top, Space.xs)
            Text("Desta carteira você vê saldo e histórico. Enviar e trocar ficam desligados.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.sm)
            Spacer()
            PrimaryButton(title: "Observar", enabled: detected != nil) { save() }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xs)
        .background(Palette.void.ignoresSafeArea())
    }

    private func save() {
        guard let chain = detected, case .success(let destination) = Address.validate(address, for: chain) else { return }
        do {
            _ = try session.addWatchWallet(chain: chain, address: destination.address, name: String(name.prefix(40)))
            onFinished()
        } catch {
            self.error = "Não foi possível guardar."
        }
    }
}
