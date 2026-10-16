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
    @State private var askingLater = false

    /// `pledge` e o aceite de responsabilidade; `check`, a conferencia do aparelho, igual a
    /// de antes de digitar as palavras ao importar (pedido do dono, 15/10/2026). So depois
    /// dela a frase nasce e aparece.
    enum Step { case before, pledge, check, record, confirm, created }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .before: before
                case .pledge:
                    ResponsibilityView(continueTitle: String(localized: "Conferir o aparelho")) { step = .check }
                case .check:
                    DeviceCheckView(slideTitle: String(localized: "Deslize para ver as palavras")) { Task { await start() } }
                case .record:
                    if let draft {
                        RecordWordsView(draft: draft, walletName: nil) { step = .confirm }
                    }
                case .confirm:
                    if let draft {
                        ConfirmWordsView(draft: draft, onBack: { step = .record }, onLater: { askingLater = true }) { confirmed() }
                    }
                case .created:
                    if let wallet { WalletCreatedView(wallet: wallet, isFirst: isFirstWallet, onFinish: finish) }
                }
            }
            .background(Palette.void.ignoresSafeArea())
            .toolbar {
                if step == .pledge || step == .check || step == .confirm {
                    // Voltar um passo: a carteira em criacao e as palavras continuam.
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            switch step {
                            case .pledge: step = .before
                            case .check: step = .pledge
                            default: step = .record
                            }
                        } label: {
                            Image(systemName: "chevron.backward").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                        }
                        .accessibilityLabel("Voltar")
                    }
                } else if step != .created {
                    // Com a carteira ja guardada e sem copia, fechar passa pelo aviso.
                    ToolbarItem(placement: .topBarLeading) {
                        Button { if wallet == nil { cancel() } else { askingLater = true } } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                        }
                        .accessibilityLabel("Fechar")
                    }
                }
            }
            .alert("Confirmar depois?", isPresented: $askingLater) {
                Button("Voltar e anotar", role: .cancel) {}
                Button("Confirmar depois", role: .destructive) { cancel() }
            } message: {
                Text("Sem a senha da carteira anotada, perder o iPhone é perder os ativos. Até você confirmar, a carteira fica marcada Palavras não confirmadas e não recebe.")
            }
        }
        .interactiveDismissDisabled()
    }

    /// Antes das palavras (pedido do dono, 15/10/2026: mais bonita e com animacao): a
    /// folha de papel sendo preenchida a mao, linha por linha, e o que vale saber, no
    /// mesmo desenho do "So voce tem a chave". O botao fica preso embaixo; no iPhone
    /// pequeno o texto rola por tras dele.
    private var before: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PaperScribble(words: wordCount)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xs)
                Text("Antes de ver as palavras").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.lg)
                Text("A senha da carteira são \(wordCount) palavras, em ordem. Quem tiver as palavras tem o saldo. Sem elas, ninguém recupera a carteira, nem a Escalibur.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Space.md) {
                    point("pencil.and.scribble", String(localized: "No papel, à mão"),
                          String(localized: "Captura de tela vai para a Fototeca e sobe para o iCloud."))
                    point("clock", String(localized: "Uns 2 minutos"),
                          String(localized: "Três palavras por vez. Arraste o cartão ou toque em Próximas."))
                    point("iphone.slash", String(localized: "Fora do backup do iPhone"),
                          String(localized: "Num iPhone novo, só as palavras ou um envelope trazem a carteira de volta."))
                }
                .padding(.top, Space.lg)
                if let error {
                    Banner(kind: .failure, title: error).padding(.top, Space.md)
                }
                VStack(spacing: Space.xs) {
                    Segmented(options: [(12, String(localized: "12 palavras")), (24, String(localized: "24 palavras"))], selection: $wordCount)
                        .frame(width: 220)
                    Text("12 bastam. 24 dá a mesma proteção na prática e dobra o que anotar.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.md)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            ActionFooter { PrimaryButton(title: String(localized: "Continuar")) { error = nil; step = .pledge } }
        }
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Palette.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                Text(detail).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
            let name = session.metadata.wallets.isEmpty ? String(localized: "Carteira principal") : String(localized: "Carteira \(session.metadata.wallets.count + 1)")
            let words = wordCount
            guard let saved = try await auth.retrying(reason: String(localized: "Guardar a carteira nova neste iPhone"), { credential in
                try await session.addWallet(secret: secret, name: name, origin: .created, wordCount: words, backupConfirmed: false, credential: credential)
            }) else {
                secret.wipe()
                newDraft.wipe()
                return
            }
            wallet = saved
            draft = newDraft
            step = .record
        } catch {
            self.error = String(localized: "Não foi possível guardar a carteira. Tente de novo.")
            step = .before
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

/// A folha de anotar as palavras (pedido do dono, 15/10/2026): papel claro com as linhas
/// numeradas, em duas colunas, preenchidas uma a uma com um risco de letra a mao, e o lapis
/// correndo junto. Cheia, ela segura um instante, apaga e recomeca. Nenhuma palavra de
/// verdade: so o risco. Com Reduzir Movimento, a folha cheia e parada.
private struct PaperScribble: View {
    let words: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        let perRow = words > 12 ? 0.16 : 0.3
        let writing = Double(words) * perRow
        let period = writing + 1.6
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? writing + 0.5 : timeline.date.timeIntervalSince(start).truncatingRemainder(dividingBy: period)
            let fade = reduceMotion ? 0 : min(max((t - writing - 1.1) / 0.4, 0), 1)
            Canvas { context, size in
                draw(&context, size: size, t: t, perRow: perRow, fade: fade)
            }
        }
        .frame(width: 270, height: 178)
        .rotationEffect(.degrees(-2))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 10)
        .onAppear { start = Date() }
        .onChange(of: words) { _, _ in start = Date() }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, t: Double, perRow: Double, fade: Double) {
        let paper = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10, style: .continuous)
        context.fill(paper, with: .color(Palette.live))
        let rows = (words + 1) / 2
        let top: CGFloat = 16, bottom: CGFloat = 12
        let rowHeight = (size.height - top - bottom) / CGFloat(rows)
        let columnWidth = (size.width - 24) / 2
        var pencil: CGPoint?
        for index in 0..<words {
            let column = index / rows, row = index % rows
            let x = 14 + CGFloat(column) * (columnWidth + 4)
            let baseline = top + (CGFloat(row) + 0.78) * rowHeight
            // A linha do caderno e o numero.
            context.fill(Path(CGRect(x: x + 20, y: baseline + 2, width: columnWidth - 26, height: 0.8)), with: .color(Palette.plateRule))
            context.draw(Text(verbatim: "\(index + 1)").font(.system(size: words > 12 ? 7.5 : 9, weight: .semibold).monospacedDigit())
                            .foregroundColor(Palette.plateMuted), at: CGPoint(x: x + 8, y: baseline - rowHeight * 0.18))
            // O risco: uma letra a mao inventada, larguras diferentes por linha.
            let progress = min(max((t - Double(index) * perRow) / perRow, 0), 1)
            guard progress > 0 else { continue }
            let length = (columnWidth - 40) * CGFloat(0.55 + 0.4 * Double((index * 37) % 10) / 10)
            var scribble = Path()
            let steps = 28
            let drawn = Int(Double(steps) * progress)
            var last = CGPoint(x: x + 24, y: baseline - 2)
            scribble.move(to: last)
            for step in 0...drawn {
                let u = CGFloat(step) / CGFloat(steps)
                let wave = sin(Double(u) * 22 + Double(index)) * 0.5 + sin(Double(u) * 9 + Double(index) * 2) * 0.5
                last = CGPoint(x: x + 24 + length * u, y: baseline - 2 - CGFloat(wave) * rowHeight * (words > 12 ? 0.16 : 0.2))
                scribble.addLine(to: last)
            }
            context.stroke(scribble, with: .color(Palette.plateInk.opacity(0.85 * (1 - fade))),
                           style: StrokeStyle(lineWidth: words > 12 ? 1.1 : 1.5, lineCap: .round, lineJoin: .round))
            if progress < 1 { pencil = last }
        }
        // O lapis, com a ponta onde o risco esta.
        if let pencil, fade == 0 {
            context.draw(Text(Image(systemName: "pencil")).font(.system(size: 18, weight: .semibold)).foregroundColor(Palette.plateInk),
                         at: CGPoint(x: pencil.x + 7, y: pencil.y - 8))
        }
    }
}
