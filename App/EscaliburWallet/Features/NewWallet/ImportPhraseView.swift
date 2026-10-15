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

    /// Os dois leem `revision`: o conteudo dos buffers muda sem o SwiftUI ver, e e a
    /// revisao que avisa as telas (o Importar seguia ligado depois de Limpar).
    func isFilled(_ index: Int) -> Bool { _ = revision; return slots[index].count > 0 }
    var filledCount: Int { _ = revision; return slots.filter { $0.count > 0 }.count }

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
    /// A cifra viva: o que aparece no lugar de cada palavra (`LiveCipher`).
    @State private var cipher = LiveCipher()
    @State private var reveal = false
    @State private var usesPassphrase = false
    @State private var passphrase = SecureBytes(capacity: 256)
    @State private var passphraseLength = 0
    /// Segurar o dedo numa das duas mostra as duas.
    @State private var revealPassphrase = false
    @State private var passphraseAgain = SecureBytes(capacity: 256)
    @State private var passphraseAgainLength = 0
    @State private var message: String?
    @State private var pasteNotice = false
    @State private var working = false
    @State private var focused = false
    @State private var confirmClear = false
    /// A carteira ja montada, esperando o dono conferir os enderecos.
    @State private var pending: (secret: WalletSecret, preview: ImportPreview)?

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
        // O ZStack fica de pe na troca entre o formulario e a conferencia: so sair da
        // tela de importar dispara o onDisappear dele. Antes a limpeza estava no
        // formulario, e a troca para a conferencia apagava o segredo recem-montado; o
        // Guardar recebia uma carteira vazia (entropia com tamanho fora do padrao).
        ZStack {
            if let pending {
                ImportPreviewView(preview: pending.preview, hasPassphrase: pending.secret.passphrase.count > 0, saving: working,
                                  onSave: { Task { await save() } }, onBack: discardPending)
                    .guardedAgainstCapture()
            } else {
                form
            }
        }
        .onDisappear {
            pending?.secret.wipe()
            entry.wipe()
            passphrase.wipe()
            passphraseAgain.wipe()
        }
    }

    private var form: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: Space.xs) {
                        Text("Importar com a senha da carteira").typeStyle(.title).foregroundStyle(Palette.ink)
                        Text("Toque numa posição e digite a palavra. Ninguém da Escalibur pede estas palavras.")
                            .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lock.shield.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                            Text("Tela protegida: cada letra é cifrada na hora, com uma chave que só existe enquanto esta tela está aberta, e captura e gravação de tela ficam bloqueadas. Segure uma palavra para conferir.")
                                .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(Space.sm)
                        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                        .padding(.top, Space.xs)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                    Segmented(options: Mnemonic.validWordCounts.map { ($0, "\($0)") },
                              selection: Binding(get: { entry.count }, set: { entry.count = $0; typed = "" }))
                        .padding(.top, Space.lg)
                    Text("palavras na senha").typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xxs)

                    pasteCard.padding(.top, Space.md)

                    if pasteNotice {
                        Text("Colado. A área de transferência foi limpa agora, mas pode já ter sincronizado com outros aparelhos Apple.")
                            .typeStyle(.note).foregroundStyle(Palette.caution).padding(.top, Space.xs)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    grid.padding(.top, Space.md)

                    HStack {
                        if entry.filledCount > 0 {
                            TertiaryButton(title: String(localized: "Limpar")) { confirmClear = true }
                                .accessibilityIdentifier("limpar-palavras")
                        }
                        Spacer()
                        TertiaryButton(title: reveal ? String(localized: "Esconder palavras") : String(localized: "Mostrar palavras")) { reveal.toggle() }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Toggle(isOn: $usesPassphrase) {
                            Text("Esta carteira usa passphrase").typeStyle(.body).foregroundStyle(Palette.ink)
                        }
                        .tint(Palette.accent)
                        if usesPassphrase {
                            Text("Com a passphrase errada, a carteira abre vazia e sem aviso nenhum. Por isso ela é digitada duas vezes. Segure o dedo num campo para conferir as duas.")
                                .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                                .fixedSize(horizontal: false, vertical: true)
                            PasswordBox(buffer: passphrase, length: $passphraseLength, placeholder: String(localized: "Passphrase"), reveal: $revealPassphrase).padding(.top, Space.sm)
                            PasswordBox(buffer: passphraseAgain, length: $passphraseAgainLength, placeholder: String(localized: "Repita a passphrase"), reveal: $revealPassphrase).padding(.top, Space.xs)
                        }
                        if let message {
                            Banner(kind: .failure, title: message).padding(.top, Space.md)
                        }
                    }
                    .padding(.top, Space.md)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
                .padding(.bottom, Space.md)
            }
            .onChange(of: entry.active) { _, index in
                guard focused else { return }
                withAnimation(Motion.fade) { proxy.scrollTo(index, anchor: .center) }
            }
            .onChange(of: focused) { _, isOn in
                guard isOn else { return }
                withAnimation(Motion.fade) { proxy.scrollTo(entry.active, anchor: .center) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if focused {
                suggestionBar
            } else {
                ActionFooter {
                    PrimaryButton(title: String(localized: "Importar"), enabled: entry.filledCount == entry.count, loading: working) {
                        Task { await importWallet() }
                    }
                }
            }
        }
        .onChange(of: typed) { _, value in
            cipher.seal(entry.active, text: Mnemonic.canonicalize(value))
            absorb(value)
        }
        .onChange(of: entry.revision) { _, _ in resealAll() }
        .onAppear {
            #if DEBUG
            // `-tela frase`: a frase publica de teste do BIP-39 nas 11 primeiras posicoes e a
            // 12a em digitacao, para conferir a cifra viva na tela.
            if DebugDemo.screen == "frase", entry.filledCount == 0 {
                entry.paste(Array(repeating: "abandon", count: 11).joined(separator: " "))
                entry.active = 11
                focused = true
                typed = "abo"
            }
            #endif
            resealAll()
        }
        .alert("Apagar as palavras digitadas?", isPresented: $confirmClear) {
            Button("Apagar", role: .destructive) { clearAll() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As \(entry.filledCount) palavras saem desta tela. Você digita de novo, a partir da primeira.")
        }
        .background(Palette.void.ignoresSafeArea())
        .statusBarBackdrop()
        .guardedAgainstCapture()
    }

    /// Colar a frase inteira. O PasteButton do sistema le a area de transferencia sem o
    /// pedido de permissao do iOS, por isso fica ele, num cartao com o resto do desenho.
    private var pasteCard: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Palette.control))
            VStack(alignment: .leading, spacing: 2) {
                Text("Tem a senha copiada?").typeStyle(.row).foregroundStyle(Palette.ink)
                Text("Cola as palavras todas de uma vez.").typeStyle(.note).foregroundStyle(Palette.inkSoft)
            }
            Spacer(minLength: Space.xs)
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in fill(with: text) }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            .tint(Palette.brand)
        }
        .padding(Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
    }

    private var grid: some View {
        let columns = [GridItem(.flexible(), spacing: Space.xs), GridItem(.flexible(), spacing: Space.xs)]
        return LazyVGrid(columns: columns, spacing: Space.xs) {
            ForEach(0..<entry.count, id: \.self) { index in
                PhraseSlot(index: index, display: slotText(index), isActive: focused && entry.active == index,
                           text: textBinding(index), isFocused: focusBinding(index),
                           word: { [entry] in entry.word(at: index) },
                           sealed: sealedGlyphs(index), typing: typingGlyphs(index)) { submit() }
                    .id(index)
            }
        }
    }

    /// O que aparece numa posicao que nao esta sendo digitada: nada, a forma cifrada ou
    /// a palavra. `revision` entra aqui para a grade acompanhar o que foi gravado nos
    /// buffers.
    private func slotText(_ index: Int) -> String? {
        _ = entry.revision
        guard entry.isFilled(index) else { return nil }
        return reveal ? entry.word(at: index) : "•••••"
    }

    /// A palavra confirmada, cifrada: sempre 4 glifos, que nao contam o tamanho dela.
    private func sealedGlyphs(_ index: Int) -> ((UInt64) -> String)? {
        _ = entry.revision
        guard entry.isFilled(index), !reveal, !(focused && entry.active == index) else { return nil }
        let cipher = self.cipher
        return { tick in cipher.glyphs(index, count: 4, tick: tick) }
    }

    /// A palavra em digitacao, cifrada: um glifo por letra.
    private func typingGlyphs(_ index: Int) -> ((UInt64) -> String)? {
        guard focused, entry.active == index, !typed.isEmpty else { return nil }
        let cipher = self.cipher
        let count = typed.count
        return { tick in cipher.glyphs(index, count: count, tick: tick) }
    }

    /// Cifra de novo cada posicao preenchida (colar, confirmar, limpar) e a em digitacao.
    private func resealAll() {
        for index in 0..<entry.count {
            if focused, index == entry.active, !typed.isEmpty { continue }
            if entry.isFilled(index) { cipher.seal(index, buffer: entry.slots[index]) } else { cipher.clear(index) }
        }
    }

    /// So a posicao em digitacao tem texto no campo; as palavras ja gravadas ficam so
    /// nos buffers seguros, nunca no texto de um UITextField.
    private func textBinding(_ index: Int) -> Binding<String> {
        Binding(get: { entry.active == index ? typed : "" },
                set: { if entry.active == index { typed = $0 } })
    }

    /// O foco anda de uma posicao para a outra sem o teclado descer: a que perde o foco
    /// so desliga o teclado se ainda for a posicao ativa.
    private func focusBinding(_ index: Int) -> Binding<Bool> {
        Binding(get: { focused && entry.active == index },
                set: { isOn in
                    if isOn {
                        if entry.active != index { entry.active = index; typed = "" }
                        focused = true
                    } else if entry.active == index {
                        focused = false
                    }
                })
    }

    /// Acima do teclado: as palavras da lista que comecam com o que foi digitado. A
    /// primeira e a que o Seguinte do teclado escolhe.
    private var suggestionBar: some View {
        HStack(spacing: Space.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    if typed.isEmpty {
                        Text("Palavra \(entry.active + 1) de \(entry.count)").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    } else if suggestions.isEmpty {
                        Text("Nenhuma palavra da lista começa assim.").typeStyle(.note).foregroundStyle(Palette.caution)
                    } else {
                        ForEach(Array(suggestions.enumerated()), id: \.element) { offset, word in
                            Chip(title: word, selected: offset == 0) { commit(word) }
                        }
                    }
                }
            }
            TertiaryButton(title: String(localized: "Pronto")) { focused = false }
        }
        .padding(.horizontal, Space.gutter)
        .frame(height: 56)
        .background(Palette.body.ignoresSafeArea(edges: .horizontal))
    }

    /// O que chega no campo: espaco fecha a palavra; varias palavras de uma vez (colar
    /// pelo menu do campo) preenchem a senha inteira.
    private func absorb(_ value: String) {
        guard !value.isEmpty else { return }
        if Mnemonic.words(in: value).count > 1 {
            fill(with: value)
        } else if value.last?.isWhitespace == true {
            commit(value)
        }
    }

    private func clearAll() {
        typed = ""
        focused = false
        entry.wipe()
        entry.active = 0
        pasteNotice = false
        message = nil
    }

    private func fill(with text: String) {
        typed = ""
        entry.paste(text)
        UIPasteboard.general.items = []
        pasteNotice = true
        message = nil
        focused = false
    }

    /// O Seguinte do teclado: a palavra digitada se ela existe na lista, senao a primeira
    /// sugestao.
    private func submit() {
        let clean = Mnemonic.canonicalize(typed)
        if suggestions.contains(clean) || suggestions.isEmpty { commit(typed) } else if let first = suggestions.first { commit(first) }
    }

    private func commit(_ word: String) {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
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
                let same = Hash.constantTimeEqual(passphrase, passphraseAgain)
                guard same, passphraseLength > 0 else {
                    message = String(localized: "As duas versões da passphrase não conferem.")
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
                do {
                    pending = (secret, try await ImportPreview.make(secret))
                } catch {
                    secret.wipe()
                    throw error
                }
            } catch {
                message = String(localized: "Não foi possível importar a carteira.") + Self.debugDetail(error)
            }
        case .wrongLength(let count):
            message = String(localized: "Faltam palavras: \(count) de \(entry.count).")
        case .unknownWords(let positions, _):
            let first = (positions.first ?? 0) + 1
            message = String(localized: "A palavra \(first) não existe na lista. Confira no papel.")
        case .checksumFailed:
            message = String(localized: "Todas as palavras existem, mas a conferência da frase não fecha. Alguma está trocada ou fora de ordem. Confira no papel.")
        case .mixedLanguages:
            message = String(localized: "As palavras são de idiomas diferentes. Confira no papel.")
        case .ambiguousLanguage:
            message = String(localized: "Esta frase vale em mais de um idioma, e a escolha muda a carteira. Importe pela versão em inglês da frase.")
        }
        phrase.wipe()
    }

    /// Guarda depois da conferencia. A RK so existe dentro de `addWallet`.
    private func save() async {
        guard let pending else { return }
        working = true
        defer { working = false }
        do {
            let name = session.metadata.wallets.isEmpty ? String(localized: "Carteira principal") : String(localized: "Carteira \(session.metadata.wallets.count + 1)")
            let words = entry.count
            // Desistiu da confirmacao: a conferencia dos enderecos continua na tela.
            guard try await auth.retrying(reason: String(localized: "Guardar a carteira importada neste iPhone"), { credential in
                try await session.addWallet(secret: pending.secret, name: name, origin: .importedPhrase, wordCount: words,
                                            backupConfirmed: true, credential: credential)
            }) != nil else { return }
            self.pending = nil
            entry.wipe()
            onFinished()
        } catch let walletError as WalletError {
            discardPending()
            message = walletError.errorDescription
        } catch {
            discardPending()
            message = String(localized: "Não foi possível importar a carteira.") + Self.debugDetail(error)
        }
    }

    /// So na compilacao de desenvolvimento: o motivo tecnico junto da mensagem, para
    /// achar a causa de uma falha relatada no aparelho.
    static func debugDetail(_ error: Any) -> String {
        #if DEBUG
        return " [\(String(describing: error).prefix(160))]"
        #else
        return ""
        #endif
    }

    private func discardPending() {
        pending?.secret.wipe()
        pending = nil
    }
}

/// Uma posicao da senha: o numero e, no lugar da palavra, o proprio campo de digitar.
private struct PhraseSlot: View {
    let index: Int
    let display: String?
    let isActive: Bool
    @Binding var text: String
    @Binding var isFocused: Bool
    /// Le a palavra so enquanto o dedo segura a posicao: fora disso ela fica no buffer.
    let word: () -> String
    /// A forma cifrada da palavra confirmada, e da que esta sendo digitada, por tique.
    var sealed: ((UInt64) -> String)? = nil
    var typing: ((UInt64) -> String)? = nil
    let onSubmit: () -> Void
    @State private var holding = false

    /// Os glifos trocam num relogio de 12 Hz, o mesmo com ou sem tecla.
    private func glyphRow(_ glyphs: @escaping (UInt64) -> String, color: Color) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
            Text(verbatim: glyphs(UInt64(context.date.timeIntervalSinceReferenceDate * 12)))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .allowsHitTesting(false)
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(isActive ? Palette.purple : Palette.inkMuted)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    if holding {
                        Text(verbatim: word())
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.ink).lineLimit(1).allowsHitTesting(false)
                    } else if let sealed {
                        glyphRow(sealed, color: Palette.accent)
                    } else {
                        Text(verbatim: display ?? "palavra")
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(display == nil || isActive ? Palette.inkDead : Palette.ink)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                } else if let typing {
                    // O que esta sendo digitado, cifrado: o campo de verdade fica por baixo,
                    // invisivel, so com o cursor.
                    glyphRow(typing, color: Palette.ink)
                }
                WordInputField(text: $text, isFocused: $isFocused, fontSize: 15, returnKey: .next, masked: typing != nil, onSubmit: onSubmit)
                // Posicao preenchida e fora de edicao: segurar mostra a palavra enquanto
                // o dedo esta em cima; tocar e soltar abre a posicao para corrigir.
                if !isActive, display != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.25)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .onChanged { value in if case .second(true, _) = value { holding = true } }
                                .onEnded { _ in holding = false }
                                .exclusively(before: TapGesture().onEnded { isFocused = true })
                        )
                }
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(isActive ? Palette.brand : Palette.edge, lineWidth: isActive ? 1.5 : 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(display == nil ? "Palavra \(index + 1), vazia" : "Palavra \(index + 1), preenchida")
        .accessibilityIdentifier("palavra-\(index + 1)")
    }
}
