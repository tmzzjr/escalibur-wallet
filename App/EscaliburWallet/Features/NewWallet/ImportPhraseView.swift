import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
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

    /// Distribui uma frase colada pelas posicoes. Com uma contagem que nao e de frase
    /// (13 palavras, 11), nada entra: antes as primeiras 12 de 13 entravam sem aviso
    /// (auditoria 4, C7-17). Devolve quantas palavras vieram.
    @discardableResult
    func paste(_ text: String) -> Int {
        let words = Mnemonic.words(in: text)
        guard Mnemonic.validWordCounts.contains(words.count) else { return words.count }
        count = words.count
        for (index, word) in words.enumerated() { set(word, at: index) }
        active = min(words.count, count - 1)
        return words.count
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

/// O6: importar com a senha da carteira. Tambem confere uma copia: com `verify`, a frase
/// digitada nao vira carteira nova, vai para quem pediu (o modo reforcado confere a frase
/// inteira de cada carteira antes de ligar, revisao do modo reforcado, M7).
struct ImportPhraseView: View {
    /// Conferir a copia de uma carteira que ja esta aqui, com o tamanho e a passphrase dela.
    struct Verification {
        let walletName: String
        let wordCount: Int
        let hasPassphrase: Bool
        let onVerified: (WalletSecret) -> Void
    }

    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    let onFinished: () -> Void
    var verify: Verification? = nil

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
    /// O dono tocou no globo do teclado proprio: nesta tela, o teclado do iPhone.
    @State private var systemKeyboard = false
    @State private var keyboardInfo = false
    @State private var confirmSystemKeyboard = false
    /// Os idiomas em que todas as palavras ja fechadas existem: as sugestoes e o teclado
    /// seguem eles (revisao do teclado proprio, M2). Nil: qualquer um.
    @State private var languages: Set<BIP39Language>?
    /// O silencio da rede desta tela, aberto uma vez so e fechado uma vez so.
    @State private var quiet = false

    /// O teclado proprio nas posicoes da frase: escolhido em Seguranca, do modo reforcado,
    /// e sempre na conferencia das palavras para ligar o modo reforcado (revisao, M1).
    /// O teclado da Escalibur: ligado nos Ajustes, na conferencia do modo reforcado, e na
    /// primeira carteira do app, quando ainda nao deu para escolher (pedido do dono,
    /// 17/10/2026; o ajuste continua desligado de fabrica). O globo troca pelo do iPhone.
    private var ownKeyboard: Bool { (session.ownKeyboardOn || verify != nil || isFirstImport) && !systemKeyboard }
    /// Esta e a primeira carteira do app (ainda nao ha nenhuma).
    private var isFirstImport: Bool { session.metadata.wallets.isEmpty }

    /// Todas as listas, sem acento nas latinas: com o teclado proprio, "abaco" acha "ábaco".
    private var suggestions: [String] { WordLexicon.completions(typed, preferring: languages, limit: 4) }

    var body: some View {
        // O ZStack fica de pe na troca entre o formulario e a conferencia: so sair da
        // tela de importar dispara o onDisappear dele. Antes a limpeza estava no
        // formulario, e a troca para a conferencia apagava o segredo recem-montado; o
        // Guardar recebia uma carteira vazia (entropia com tamanho fora do padrao).
        ZStack {
            if let pending {
                ImportPreviewView(preview: pending.preview, hasPassphrase: pending.secret.passphrase.count > 0, saving: working,
                                  onSave: { foreign in Task { await save(tronForeign: foreign) } }, onBack: discardPending)
                    .guardedAgainstCapture()
            } else {
                form
            }
        }
        .onAppear {
            // Conferindo uma copia: o tamanho e a passphrase sao os da carteira, fixos.
            if let verify, entry.filledCount == 0 {
                entry.count = verify.wordCount
                usesPassphrase = verify.hasPassphrase
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
                        CipherEmblem().padding(.bottom, Space.xs)
                        Text(verify.map { String(localized: "Confira a cópia de \($0.walletName)") } ?? String(localized: "Importar com a senha da carteira"))
                            .typeStyle(.title).foregroundStyle(Palette.ink)
                        Text(verify == nil
                             ? String(localized: "Digite as palavras na ordem em que você anotou, uma em cada campo.")
                             : String(localized: "Digite as palavras de onde você anotou, todas, em ordem. No Super Security, essa cópia é o único caminho de volta."))
                            .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                    HStack(alignment: .center, spacing: Space.sm) {
                        if verify == nil {
                            WordCountPicker(count: Binding(get: { entry.count }, set: { entry.count = $0; typed = "" }))
                        } else {
                            Spacer()
                        }
                        // O PasteButton do sistema le a area de transferencia sem o pedido de
                        // permissao do iOS. Conferindo uma copia, nada de colar: a conferencia e
                        // do papel (segunda revisao do modo reforcado, N6).
                        if verify == nil {
                            PasteButton(payloadType: String.self) { strings in
                                guard let text = strings.first else { return }
                                Task { @MainActor in fill(with: text) }
                            }
                            .labelStyle(.titleAndIcon)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            .modifier(ClearGlassPaste())
                        }
                    }
                    .padding(.top, Space.lg)

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
                        if verify == nil {
                            Toggle(isOn: $usesPassphrase) {
                                Text("Esta carteira usa passphrase").typeStyle(.body).foregroundStyle(Palette.ink)
                            }
                            .tint(Palette.accent)
                        }
                        if usesPassphrase {
                            Text("Com a passphrase errada, a carteira abre vazia e sem aviso nenhum. Por isso ela é digitada duas vezes. Segure o dedo num campo para conferir as duas.")
                                .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                                .fixedSize(horizontal: false, vertical: true)
                            PasswordBox(buffer: passphrase, length: $passphraseLength, placeholder: String(localized: "Passphrase"), reveal: $revealPassphrase,
                                        glyphs: passphraseGlyphs(Self.passphraseSlot, count: passphraseLength))
                                .padding(.top, Space.sm)
                            PasswordBox(buffer: passphraseAgain, length: $passphraseAgainLength, placeholder: String(localized: "Repita a passphrase"), reveal: $revealPassphrase,
                                        glyphs: passphraseGlyphs(Self.passphraseAgainSlot, count: passphraseAgainLength))
                                .padding(.top, Space.xs)
                        }
                        if let message {
                            Banner(kind: .failure, title: message).padding(.top, Space.md)
                        }
                    }
                    .padding(.top, Space.md)

                    // O que a tela faz, em tres linhas curtas (pedido do dono, 16/10/2026). O texto
                    // diz so o que e verdade (auditoria 4, C7-06 e C7-12): cifradas nos campos,
                    // nao na sugestao; o espelhamento ja foi dito na checagem antes desta tela.
                    VStack(alignment: .leading, spacing: Space.md) {
                        assurance("lock.fill", String(localized: "Cifradas nos campos"),
                                  String(localized: "Segure uma palavra para conferir. As sugestões mostram a palavra para você escolher."))
                        assurance("iphone", String(localized: "Só neste iPhone"),
                                  String(localized: "O app não manda as palavras para lugar nenhum, e ninguém da Escalibur pede estas palavras."))
                        // A tela fica em silencio (`HTTPClient.beginQuiet`): nada sai do iPhone enquanto
                        // ela esta aberta, e a conferencia das palavras e toda local.
                        assurance("wifi.slash", String(localized: "Sem internet nesta tela"),
                                  String(localized: "Enquanto ela está aberta, o app não fala com rede nenhuma. A conferência é feita aqui: a última palavra traz uma soma de verificação das outras, calculada no iPhone com a lista de 2048 palavras que vem dentro do app."))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.base)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                    .padding(.top, Space.lg)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("tela-protegida")
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
                .padding(.bottom, Space.md)
            }
            // So rola o minimo para a posicao nao ficar atras do teclado: tocar numa posicao
            // que ja esta a vista nao mexe na tela (pedido do dono, 16/10/2026).
            .onChange(of: entry.active) { _, index in
                guard focused else { return }
                withAnimation(Motion.fade) { proxy.scrollTo(index, anchor: nil) }
            }
            .onChange(of: focused) { _, isOn in
                guard isOn else {
                    commitPendingWord()
                    return
                }
                withAnimation(Motion.fade) { proxy.scrollTo(entry.active, anchor: nil) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if focused {
                suggestionBar
            } else {
                ActionFooter {
                    PrimaryButton(title: verify == nil ? String(localized: "Importar") : String(localized: "Conferir"), enabled: entry.filledCount == entry.count, loading: working) {
                        Task { await importWallet() }
                    }
                    .accessibilityIdentifier(verify == nil ? "importar" : "conferir-copia")
                }
            }
        }
        .onChange(of: typed) { _, value in
            cipher.seal(entry.active, text: Mnemonic.canonicalize(value))
            absorb(value)
        }
        .onChange(of: entry.revision) { _, _ in resealAll() }
        // A passphrase e cifrada a cada tecla, como as palavras.
        .onChange(of: passphraseLength) { _, _ in cipher.seal(Self.passphraseSlot, buffer: passphrase) }
        .onChange(of: passphraseAgainLength) { _, _ in cipher.seal(Self.passphraseAgainSlot, buffer: passphraseAgain) }
        .onAppear {
            #if DEBUG
            // `-tela frase`: a frase publica de teste do BIP-39 nas 11 primeiras posicoes e a
            // 12a em digitacao, para conferir a cifra viva na tela; com `-frase-topo`, a tela
            // vazia, de cima. Colar 11 palavras nao preenche nada (C7-17): uma por uma.
            if DebugDemo.screen == "frase", entry.filledCount == 0, !DebugDemo.arguments.contains("-frase-topo") {
                for index in 0..<11 { entry.set("abandon", at: index) }
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
        // Silencio na rede so enquanto as palavras estao na tela: a conferencia dos
        // enderecos, depois, le a Tron.
        .onAppear {
            guard !quiet else { return }
            HTTPClient.shared.beginQuiet()
            quiet = true
        }
        .onDisappear {
            guard quiet else { return }
            HTTPClient.shared.endQuiet()
            quiet = false
        }
        .onChange(of: entry.revision) { _, _ in lockLanguages() }
        .onChange(of: entry.active) { _, _ in lockLanguages() }
        // O globo pergunta antes: o teclado do iPhone recebe as letras (revisao, B3).
        .alert("Usar o teclado do iPhone?", isPresented: $confirmSystemKeyboard) {
            Button("Usar o do iPhone") { systemKeyboard = true }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Só para frases em japonês, chinês ou coreano, que o Safe Keyboard não escreve. O teclado do iPhone recebe as letras que você digitar.")
        }
        .sheet(isPresented: $keyboardInfo) {
            KeyboardInfoSheet(onSystemKeyboard: { systemKeyboard = true }) { keyboardInfo = false }
        }
    }

    private func assurance(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.control))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                Text(detail).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Posicoes da cifra viva para a passphrase e a repeticao, fora das das palavras.
    static let passphraseSlot = 1000
    static let passphraseAgainSlot = 1001

    private func passphraseGlyphs(_ slot: Int, count: Int) -> ((UInt64) -> String)? {
        guard count > 0 else { return nil }
        let cipher = self.cipher
        return { tick in cipher.glyphs(slot, count: count, tick: tick) }
    }

    private var grid: some View {
        let columns = [GridItem(.flexible(), spacing: Space.xs), GridItem(.flexible(), spacing: Space.xs)]
        return LazyVGrid(columns: columns, spacing: Space.xs) {
            ForEach(0..<entry.count, id: \.self) { index in
                PhraseSlot(index: index, display: slotText(index), isActive: focused && entry.active == index,
                           text: textBinding(index), isFocused: focusBinding(index),
                           word: { [entry] in entry.word(at: index) },
                           sealed: sealedGlyphs(index), typing: typingGlyphs(index),
                           ownKeyboard: ownKeyboard, onSystemKeyboard: { confirmSystemKeyboard = true },
                           onKeyboardInfo: { focused = false; keyboardInfo = true }, languages: languages,
                           systemKeyboardType: systemKeyboard ? .default : .asciiCapable) { submit() }
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

    /// A palavra confirmada, cifrada: um glifo por letra, como na digitacao (pedido do dono,
    /// 16/10/2026; antes eram sempre 4, mas o tamanho ja aparecia enquanto ela era digitada).
    private func sealedGlyphs(_ index: Int) -> ((UInt64) -> String)? {
        _ = entry.revision
        guard entry.isFilled(index), !reveal, !(focused && entry.active == index) else { return nil }
        let cipher = self.cipher
        let count = Self.letterCount(entry.slots[index])
        return { tick in cipher.glyphs(index, count: count, tick: tick) }
    }

    /// Quantas letras a palavra tem, pelos bytes NFKD: nem os bytes de continuacao do UTF-8,
    /// nem os acentos (U+0300 a U+036F, CC 80 a CD AF) contam como letra.
    static func letterCount(_ word: SecureBytes) -> Int {
        word.withUnsafeBytes { raw in
            var count = 0
            var index = 0
            while index < raw.count {
                let byte = raw[index]
                if index + 1 < raw.count, (byte == 0xCC || (byte == 0xCD && raw[index + 1] <= 0xAF)), (0x80...0xBF).contains(raw[index + 1]) {
                    index += 2
                    continue
                }
                if byte & 0xC0 != 0x80 { count += 1 }
                index += 1
            }
            return max(count, 1)
        }
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
            // As sugestoes mostram a palavra: fora da captura.
            .protectedFromCapture()
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
        // Conferindo uma copia de N palavras, colar outro tamanho nao preenche nada.
        if let verify {
            let count = Mnemonic.words(in: text).count
            guard count == verify.wordCount else {
                UIPasteboard.general.items = []
                focused = false
                message = String(localized: "A cópia de \(verify.walletName) tem \(verify.wordCount) palavras, e o texto colado tem \(count).")
                return
            }
        }
        let pasted = entry.paste(text)
        UIPasteboard.general.items = []
        pasteNotice = true
        focused = false
        // Conferindo uma copia, o tamanho e o da carteira: colar outro tamanho nao muda.
        if let verify, Mnemonic.validWordCounts.contains(pasted), pasted != verify.wordCount { entry.count = verify.wordCount }
        message = Mnemonic.validWordCounts.contains(pasted) ? nil
            : String(localized: "O texto colado tem \(pasted) palavras, e uma frase tem 12, 15, 18, 21 ou 24. Nada foi preenchido: confira o que você copiou.")
    }

    /// O Seguinte do teclado: sempre a sugestao destacada, a primeira (a palavra exata vem
    /// antes das que so comecam assim); sem sugestao, o que foi digitado.
    private func submit() {
        if let first = suggestions.first { commit(first) } else { commit(typed) }
    }

    /// O foco saiu das posicoes (para a passphrase, ou para fora) com uma palavra digitada e
    /// completa: ela entra na posicao. Com o teclado da Escalibur, a ultima so entrava no
    /// "Seguinte", e o Conferir ficava cinza com 11 de 12 (visto no app de verdade,
    /// 17/10/2026). Palavra pela metade continua so no campo.
    private func commitPendingWord() {
        let pending = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty, let match = WordLexicon.completions(pending, preferring: languages, limit: 1).first,
              WordLexicon.fold(match) == WordLexicon.fold(pending) else { return }
        commit(match)
    }

    /// Os idiomas das palavras ja fechadas, fora a posicao em digitacao, lidos direto dos
    /// buffers seguros (segunda revisao, N2). Nenhum idioma com todas: sem preferencia, e a
    /// importacao diz o que esta errado.
    private func lockLanguages() {
        let words = entry.slots.enumerated().filter { $0.offset != entry.active }.map(\.element)
        let found = WordLexicon.languages(containing: words)
        languages = found?.isEmpty == true ? nil : found
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
        var phrase = entry.phrase()
        var verdict = BIP39.validate(phrase)
        // Digitada sem acento, a frase fecha no idioma dela trocando cada palavra pela de
        // acento (revisao do teclado proprio, M2).
        if case .valid = verdict {} else if let resolved = WordLexicon.resolve(entry.slots) {
            phrase.wipe()
            phrase = resolved.phrase
            verdict = .valid(language: resolved.language)
        }
        switch verdict {
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
                // Conferindo uma copia: a frase vai para quem pediu, sem conferencia de
                // enderecos nem carteira nova.
                if let verify {
                    verify.onVerified(secret)
                    return
                }
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
    private func save(tronForeign: Bool) async {
        guard let pending else { return }
        working = true
        defer { working = false }
        do {
            let name = session.metadata.wallets.isEmpty ? String(localized: "Carteira principal") : String(localized: "Carteira \(session.metadata.wallets.count + 1)")
            let words = entry.count
            // Desistiu da confirmacao: a conferencia dos enderecos continua na tela.
            guard try await auth.retrying(reason: String(localized: "Guardar a carteira importada neste iPhone"), { credential in
                try await session.addWallet(secret: pending.secret, name: name, origin: .importedPhrase, wordCount: words,
                                            backupConfirmed: true, tronForeignControl: tronForeign, credential: credential)
            }) != nil else { return }
            self.pending = nil
            entry.wipe()
            onFinished()
        } catch let walletError as WalletError {
            discardPending()
            message = walletError.errorDescription
        } catch {
            discardPending()
            message = AuthCoordinator.refusalMessage(error) ?? (String(localized: "Não foi possível importar a carteira.") + Self.debugDetail(error))
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
    var ownKeyboard = false
    var onSystemKeyboard: (() -> Void)?
    var onKeyboardInfo: (() -> Void)?
    var languages: Set<BIP39Language>? = nil
    var systemKeyboardType: UIKeyboardType = .asciiCapable
    let onSubmit: () -> Void
    @State private var holding = false
    @State private var pressingSince: Date?

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

    /// A palavra como aparece: a cifra da confirmada, a palavra enquanto o dedo segura, o
    /// texto de exemplo, ou a cifra do que esta sendo digitado.
    @ViewBuilder
    private var visual: some View {
        if text.isEmpty {
            if holding {
                Text(verbatim: word())
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink).lineLimit(1).allowsHitTesting(false)
            } else if let sealed {
                glyphRow(sealed, color: Palette.inkSoft)
            } else {
                Text(verbatim: display ?? String(localized: "palavra"))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(display == nil || isActive ? Palette.inkDead : Palette.ink)
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
        } else if let typing {
            // O que esta sendo digitado, cifrado: o campo de verdade fica por baixo,
            // invisivel, so com o cursor.
            glyphRow(typing, color: Palette.inkSoft)
        }
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(isActive ? Palette.inkSoft : Palette.inkMuted)
            ZStack(alignment: .leading) {
                // So o desenho da palavra fica na camada contra captura, sem toque: o campo e
                // os gestos de tocar e segurar ficam aqui fora. Com a posicao inteira la
                // dentro, tocar numa palavra anterior nao abria para corrigir (visto no app de
                // verdade, 16/10/2026).
                visual
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .protectedFromCapture(interactive: false)
                WordInputField(text: $text, isFocused: $isFocused, fontSize: 15, returnKey: .next, masked: typing != nil,
                               ownKeyboard: ownKeyboard, onSystemKeyboard: onSystemKeyboard, onKeyboardInfo: onKeyboardInfo,
                               languages: languages, systemKeyboardType: systemKeyboardType, onSubmit: onSubmit)
                // Posicao preenchida e fora de edicao: segurar mostra a palavra enquanto
                // o dedo esta em cima; tocar e soltar abre a posicao para corrigir.
                if !isActive, display != nil {
                    // Dois gestos simples: o combinado (segurar, com o toque como alternativa)
                    // deixava o toque sem efeito, e a palavra nao abria para corrigir (visto no
                    // app de verdade, 16/10/2026). Segurar mostra a palavra depois de um quarto
                    // de segundo, so enquanto o dedo esta em cima.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isFocused = true }
                        .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30, perform: {}, onPressingChanged: { pressing in
                            pressingSince = pressing ? Date() : nil
                            if !pressing { holding = false; return }
                            Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                if pressingSince != nil { holding = true }
                            }
                        })
                }
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(isActive ? Palette.inkSoft : Palette.edge, lineWidth: isActive ? 1.5 : 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(display == nil ? "Palavra \(index + 1), vazia" : "Palavra \(index + 1), preenchida")
        .accessibilityValue(isActive ? String(localized: "editando") : "")
        .accessibilityIdentifier("palavra-\(index + 1)")
    }
}

/// O Colar em vidro, sem cor (pedido do dono, 16/10/2026). O PasteButton e do sistema (so
/// assim o iOS cola sem o pedido de permissao) e nao aceita o estilo de vidro: a capsula
/// dele fica transparente, com o vidro liquido por tras; antes do iOS 26, o cinza do app.
/// O teste `ImportKeyboardTests` confere que o iOS continua aceitando o toque.
private struct ClearGlassPaste: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tint(.clear).foregroundStyle(Palette.ink)
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            content.tint(Palette.control)
        }
    }
}

/// Quantas palavras: o mesmo seletor de antes (`Segmented`), so que mais largo, com 12 e 24,
/// que sao quase todas as frases, e o "+" ao lado abre 15, 18 e 21. Escolhida uma das outras,
/// voltam duas: a escolhida e a de 24 (pedido do dono, 16/10/2026).
private struct WordCountPicker: View {
    @Binding var count: Int
    @State private var expanded = false

    private var options: [Int] {
        if expanded { return Mnemonic.validWordCounts }
        return count == 24 ? [12, 24] : [count, 24]
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Segmented(options: options.map { ($0, expanded ? "\($0)" : String(localized: "\($0) palavras")) },
                      selection: Binding(get: { count }, set: { value in
                          withAnimation(Motion.select) {
                              count = value
                              expanded = false
                          }
                      }))
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("palavras-tamanho")
            if !expanded {
                Button { withAnimation(Motion.select) { expanded = true } } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.inkSoft)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Palette.body))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Outros tamanhos de frase")
                .accessibilityIdentifier("palavras-mais")
            }
        }
    }
}
