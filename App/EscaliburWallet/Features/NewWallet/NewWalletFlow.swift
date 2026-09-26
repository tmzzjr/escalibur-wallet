import EscaliburCore
import EscaliburKeys
import SwiftUI

/// A frase de uma carteira recem-criada, enquanto o dono anota e confere.
/// Buffer seguro; as palavras so viram `String` no grupo de 3 que esta na tela.
@MainActor
@Observable
final class PhraseDraft {
    let phrase: SecureBytes
    let wordCount: Int

    init(wordCount: Int) throws {
        phrase = try BIP39.generate(wordCount: wordCount)
        self.wordCount = wordCount
    }

    init(phrase: SecureBytes, wordCount: Int) {
        self.phrase = phrase
        self.wordCount = wordCount
    }

    /// As palavras de `range` (base 0), tiradas direto dos bytes: so as tres da placa
    /// viram `String`, nunca a frase inteira. Quem chama guarda em estado da tela e
    /// solta ao trocar de grupo; nunca chamar de dentro de `body`.
    func words(_ range: Range<Int>) -> [String] {
        phrase.withUnsafeBytes { raw in
            let spans = Self.spans(raw)
            return range.compactMap { spans.indices.contains($0) ? String(decoding: raw[spans[$0]], as: UTF8.self) : nil }
        }
    }

    /// A palavra digitada confere com a da posicao? Comparacao em tempo constante
    /// sobre os bytes canonicos.
    func matches(_ typed: String, at index: Int) -> Bool {
        var candidate = Array(Mnemonic.canonicalize(typed).utf8)
        defer { candidate.resetBytes() }
        return phrase.withUnsafeBytes { raw in
            let spans = Self.spans(raw)
            guard spans.indices.contains(index) else { return false }
            var word = Array(raw[spans[index]])
            defer { word.resetBytes() }
            return Hash.constantTimeEqual(word, candidate)
        }
    }

    /// Onde comeca e termina cada palavra da frase canonica (um espaco entre elas).
    private static func spans(_ raw: UnsafeRawBufferPointer) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for index in 0...raw.count where index == raw.count || raw[index] == 0x20 {
            if index > start { out.append(start..<index) }
            start = index + 1
        }
        return out
    }

    func wipe() { phrase.wipe() }
}

/// O2 a O5: da decisao de criar ate a carteira com copia conferida.
struct NewWalletFlow: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let isFirstWallet: Bool
    let onFinished: () -> Void

    @State private var step: Step = .before
    @State private var wordCount = 12
    @State private var draft: PhraseDraft?
    @State private var wallet: WalletMeta?
    @State private var saving = false
    @State private var error: String?

    enum Step { case before, record, confirm, created }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .before: before
                case .record:
                    if let draft {
                        RecordWordsView(draft: draft, walletName: nil) { step = .confirm }
                    }
                case .confirm:
                    if let draft {
                        ConfirmWordsView(draft: draft, onBack: { step = .record }) { confirmed() }
                    }
                case .created:
                    if let wallet { WalletCreatedView(wallet: wallet, isFirst: isFirstWallet, onFinish: finish) }
                }
            }
            .background(Palette.void.ignoresSafeArea())
            .toolbar {
                if step != .created {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { cancel() } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                        }
                        .accessibilityLabel("Fechar")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var before: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Antes de ver as palavras").typeStyle(.title).foregroundStyle(Palette.ink)
            Text("A senha da carteira são \(wordCount) palavras, em ordem. Quem tiver as palavras tem o saldo. Sem elas, ninguém recupera a carteira, nem a Escalibur.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.md) {
                fact("clock", "Leva cerca de 2 minutos.")
                fact("pencil.and.scribble", "Anote no papel, à mão. Captura de tela vai para a Fototeca e sobe para o iCloud.")
                fact("eye.slash", "Aparecem 3 palavras por vez, por 60 segundos.")
            }
            .padding(.top, Space.lg)
            if let error {
                Banner(kind: .failure, title: error).padding(.top, Space.md)
            }
            Spacer()
            Segmented(options: [(12, "12 palavras"), (24, "24 palavras")], selection: $wordCount)
                .frame(width: 220)
            Text("12 bastam. 24 dá a mesma proteção na prática e dobra o que anotar.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xs)
                .padding(.bottom, Space.lg)
            PrimaryButton(title: "Mostrar as palavras", loading: saving) { Task { await start() } }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xs)
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular)).foregroundStyle(Palette.inkSoft).frame(width: 24)
            Text(text).typeStyle(.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A carteira e guardada **antes** de mostrar as palavras: se o dono sair no
    /// meio, ela existe marcada "Sem copia", e receber fica bloqueado ate conferir.
    private func start() async {
        saving = true
        defer { saving = false }
        error = nil
        do {
            let newDraft = try PhraseDraft(wordCount: wordCount)
            let copy = SecureBytes(capacity: newDraft.phrase.capacity)
            newDraft.phrase.withUnsafeBytes { copy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
            let secret = try WalletSecret.from(phrase: copy, language: .english)
            copy.wipe()
            guard let credential = await auth.credential(reason: "Guardar a carteira nova neste iPhone") else {
                secret.wipe()
                newDraft.wipe()
                return
            }
            let name = session.metadata.wallets.isEmpty ? "Carteira principal" : "Carteira \(session.metadata.wallets.count + 1)"
            wallet = try await session.addWallet(secret: secret, name: name, origin: .created, wordCount: wordCount, backupConfirmed: false, credential: credential)
            draft = newDraft
            step = .record
        } catch {
            self.error = "Não foi possível guardar a carteira. Tente de novo."
        }
    }

    private func confirmed() {
        guard var wallet else { return }
        wallet.backupConfirmedAt = .now
        session.update(wallet)
        self.wallet = wallet
        draft?.wipe()
        draft = nil
        step = .created
    }

    private func cancel() {
        draft?.wipe()
        draft = nil
        dismiss()
        onFinished()
    }

    private func finish() {
        draft?.wipe()
        dismiss()
        onFinished()
    }
}
