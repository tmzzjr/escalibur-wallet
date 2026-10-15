import EscaliburChains
import EscaliburCore
import SwiftUI

/// O3 (gravar) e X2 (revelar): tres palavras por vez, num cartao sobre o baralho dos
/// proximos, que vira como flash card ao seguir (ou ao arrastar). "Ver todas de uma vez"
/// mostra a frase inteira numa placa so (pedido do dono, 15/10/2026); as protecoes sao
/// as mesmas: nada de copiar, as palavras somem quando o app sai da frente, e a captura
/// de tela e a gravacao continuam barradas (`guardedAgainstCapture`).
struct RecordWordsView: View {
    let draft: PhraseDraft
    /// Nil na criacao; o nome da carteira na revelacao (X2).
    let walletName: String?
    /// A passphrase, em buffer; vira texto so enquanto o grupo dela esta por perto.
    var passphrase: SecureBytes? = nil
    let onDone: () -> Void

    @State private var group = 0
    @State private var hidden = false
    /// A frase inteira numa placa so, em vez de tres por vez.
    @State private var showingAll = false
    /// O cartao acompanha o dedo enquanto arrasta.
    @State private var drag: CGFloat = 0
    /// As palavras do grupo na tela e dos dois vizinhos, para a pagina ja estar pronta
    /// quando o dedo arrasta. Recarregadas ao trocar de grupo, soltas ao esconder e ao
    /// sair; `body` so le daqui.
    @State private var shown: [Int: [String]] = [:]
    @Environment(\.scenePhase) private var scenePhase

    private let perGroup = 3
    private let rowHeight: CGFloat = 84
    private var groups: Int { draft.wordCount / perGroup + (passphrase == nil ? 0 : 1) }
    private func isPassphrase(_ index: Int) -> Bool { passphrase != nil && index == groups - 1 }
    private var isLast: Bool { showingAll || group == groups - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(walletName == nil ? "Grave a senha da carteira" : "Senha da carteira")
                .typeStyle(.title).foregroundStyle(Palette.ink)
            Text(subtitle)
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
                .contentTransition(.numericText())

            if showingAll {
                ScrollView { allPlate }
                    .scrollBounceBehavior(.basedOnSize)
                    .padding(.top, Space.lg)
            } else {
                cards.padding(.top, Space.lg)
                pageIndicator.padding(.top, Space.md)
            }
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showingAll.toggle() }
            } label: {
                Label(showingAll ? String(localized: "Ver três por vez") : String(localized: "Ver todas de uma vez"),
                      systemImage: showingAll ? "rectangle.stack" : "square.grid.2x2")
                    .typeStyle(.row).foregroundStyle(Palette.inkSoft)
                    .frame(maxWidth: .infinity).frame(minHeight: Height.touch)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ver-todas-palavras")

            if !showingAll, isPassphrase(group) {
                Text("Sem ela, as palavras acima abrem uma carteira diferente e vazia.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
            }
            Spacer()
            HStack(spacing: Space.sm) {
                if group > 0, !showingAll {
                    SecondaryButton(title: String(localized: "Anteriores"), height: Height.primary) { move(-1) }
                }
                PrimaryButton(title: isLast ? (walletName == nil ? String(localized: "Já anotei as \(draft.wordCount)") : String(localized: "Fechar")) : String(localized: "Próximas")) {
                    isLast ? onDone() : move(1)
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xs)
        .background(Palette.void.ignoresSafeArea())
        .guardedAgainstCapture()
        .onChange(of: group, initial: true) { _, _ in load() }
        .onChange(of: hidden) { _, _ in load() }
        .onChange(of: showingAll) { _, _ in load() }
        .onDisappear { shown = [:] }
        .onChange(of: scenePhase) { _, phase in
            // Em segundo plano as palavras escondem; voltam com um toque.
            if phase != .active { hidden = true }
        }
    }

    /// Carrega o grupo atual e os vizinhos (ou todos, na placa inteira); tudo o mais sai
    /// da memoria.
    private func load() {
        guard !hidden else {
            shown = [:]
            return
        }
        var next: [Int: [String]] = [:]
        let range = showingAll ? 0...(groups - 1) : max(0, group - 1)...min(groups - 1, group + 1)
        for index in range {
            next[index] = shown[index] ?? words(of: index)
        }
        shown = next
    }

    private func words(of index: Int) -> [String] {
        if isPassphrase(index) {
            return passphrase.map { secret in [secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }] } ?? []
        }
        let start = index * perGroup
        return draft.words(start..<min(start + perGroup, draft.wordCount))
    }

    private var subtitle: String {
        if showingAll {
            let prefix = walletName.map { "\($0) · " } ?? ""
            return String(localized: "\(prefix)As \(draft.wordCount) palavras, em ordem")
        }
        if isPassphrase(group) { return String(localized: "Passphrase") }
        let first = group * perGroup + 1
        let last = min(first + perGroup - 1, draft.wordCount)
        let prefix = walletName.map { "\($0) · " } ?? ""
        return String(localized: "\(prefix)Palavras \(first) a \(last) de \(draft.wordCount)")
    }

    /// O baralho: cada grupo e um cartao da pilha, o atual na frente e os proximos atras,
    /// um pouco abaixo e menores. Seguir passa o cartao da frente para o fundo da pilha (ele
    /// desce e some atras dos outros) e o seguinte sobe para a frente; voltar traz o do
    /// fundo de volta. Arrastar o cartao da frente faz o mesmo, com ele seguindo o dedo.
    private var cards: some View {
        let height = CGFloat(perGroup) * rowHeight + 2 * Space.xs
        return ZStack {
            ForEach(0..<groups, id: \.self) { index in
                let depth = (index - group + groups) % groups
                // Lugar na pilha: 0 na frente, 1 e 2 os proximos, 3 o fundo, onde fica o
                // cartao que acabou de passar. Os do meio de uma pilha longa ficam no fundo,
                // escondidos.
                let last = depth == groups - 1 && groups > 3
                let slot = depth == 0 ? 0 : (last ? 3 : min(depth, 3))
                let visible = depth <= 2 || last
                let place = CGFloat(slot)
                plate(index)
                    .frame(height: height)
                    // Atras, so a borda do cartao aparece; as palavras dele ficam cobertas.
                    .overlay(LacquerPlate().fill(Palette.void.opacity([0, 0.45, 0.65, 0.8][slot])))
                    .scaleEffect(1 - 0.06 * place, anchor: .bottom)
                    .offset(x: depth == 0 ? drag : 0, y: 10 * place)
                    .rotationEffect(.degrees(depth == 0 ? Double(drag) / 25 : 0), anchor: .bottom)
                    .opacity(visible ? 1 : 0)
                    .zIndex(-Double(depth))
                    .allowsHitTesting(depth == 0)
                    .accessibilityHidden(depth != 0)
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in drag = value.translation.width }
                            .onEnded { value in
                                let width = value.translation.width
                                if width < -70, group < groups - 1 {
                                    move(1)
                                } else if width > 70, group > 0 {
                                    move(-1)
                                }
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { drag = 0 }
                            }
                    )
            }
        }
        .frame(height: height + 32, alignment: .top)
        .accessibilityIdentifier("placa-palavras")
    }

    /// A frase inteira: duas colunas, em ordem de cima para baixo, e a passphrase embaixo.
    private var allPlate: some View {
        let count = draft.wordCount
        let half = (count + 1) / 2
        let words = (0..<groups).flatMap { isPassphrase($0) ? [] : (shown[$0] ?? []) }
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Space.md) {
                ForEach(0..<2, id: \.self) { column in
                    VStack(spacing: 0) {
                        ForEach(column * half..<min(count, (column + 1) * half), id: \.self) { index in
                            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Palette.plateMuted)
                                    .frame(width: 24, alignment: .leading)
                                Text(verbatim: index < words.count ? words[index] : "")
                                    .accessibilityIdentifier("palavra-\(index + 1)")
                                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Palette.plateInk)
                                    .minimumScaleFactor(0.6).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(height: 40)
                        }
                    }
                }
            }
            if passphrase != nil, let secret = shown[groups - 1]?.first {
                Rectangle().fill(Palette.plateRule).frame(height: 1).padding(.vertical, Space.xs)
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text("Pass").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.plateMuted)
                    Text(verbatim: secret).font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.plateInk).minimumScaleFactor(0.5).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 40)
            }
        }
        .padding(Space.base)
        .opacity(hidden ? 0 : 1)
        .overlay {
            if hidden {
                Button { hidden = false } label: {
                    Text("Mostrar de novo").typeStyle(.action).foregroundStyle(Palette.plateInk)
                        .padding(.horizontal, Space.md).frame(height: 40)
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.plateInk, lineWidth: 1.5))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(LacquerPlate().fill(Palette.live))
        .clipShape(LacquerPlate())
        .textSelection(.disabled)
        .accessibilityElement(children: .contain)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func plate(_ index: Int) -> some View {
        ZStack {
            VStack(spacing: 0) {
                let words = shown[index] ?? []
                if isPassphrase(index) {
                    plateRow(index: nil, word: words.first ?? "")
                } else {
                    let start = index * perGroup
                    ForEach(Array(words.enumerated()), id: \.offset) { offset, word in
                        plateRow(index: start + offset + 1, word: word)
                        if offset < words.count - 1 {
                            Rectangle().fill(Palette.plateRule).frame(height: 1).padding(.leading, Space.base)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Space.xs)
            .opacity(hidden ? 0 : 1)

            if hidden {
                VStack(spacing: Space.sm) {
                    Text("Escondidas para ninguém ler por cima do seu ombro.")
                        .typeStyle(.body).foregroundStyle(Palette.plateInk).multilineTextAlignment(.center)
                    Button {
                        hidden = false
                    } label: {
                        Text("Mostrar de novo").typeStyle(.action).foregroundStyle(Palette.plateInk)
                            .padding(.horizontal, Space.md).frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.plateInk, lineWidth: 1.5))
                    }
                }
                .padding(Space.md)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LacquerPlate().fill(Palette.live))
        .clipShape(LacquerPlate())
        .textSelection(.disabled)
        .accessibilityElement(children: .contain)
    }

    /// Indicador discreto: um traco por grupo, o atual mais longo. No VoiceOver e um
    /// controle ajustavel (deslizar para cima ou para baixo troca o grupo).
    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<groups, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == group ? Palette.purple : Palette.edgeStrong)
                    .frame(width: index == group ? 18 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.select, value: group)
        .accessibilityElement()
        .accessibilityLabel("Grupo de palavras")
        .accessibilityValue("\(group + 1) de \(groups)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
    }

    private func plateRow(index: Int?, word: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(index.map { String(format: "%02d", $0) } ?? "Pass")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.plateMuted)
                .frame(width: index == nil ? 44 : 34, alignment: .leading)
            Text(verbatim: word)
                .accessibilityIdentifier(index.map { "palavra-\($0)" } ?? "palavra-25")
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.plateInk)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.base)
        .frame(height: rowHeight)
    }

    private func move(_ delta: Int) {
        let target = max(0, min(groups - 1, group + delta))
        guard target != group else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            group = target
        }
    }
}

/// O4: conferir digitando 3 posicoes sorteadas, uma de cada terco da frase.
struct ConfirmWordsView: View {
    let draft: PhraseDraft
    let onBack: () -> Void
    /// Sair sem conferir: a carteira fica marcada "Sem copia". Nil onde nao se aplica.
    var onLater: (() -> Void)? = nil
    let onConfirmed: () -> Void

    @State private var positions: [Int] = []
    @State private var current = 0
    @State private var typed = ""
    @State private var error: String?
    @State private var misses: [Int: Int] = [:]
    @State private var focused = false

    private var suggestions: [String] {
        guard typed.count >= 2, let list = try? WordlistStore.shared.wordlist(for: .english) else { return [] }
        return list.completions(forPrefix: Mnemonic.canonicalize(typed), limit: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Confirme a senha da carteira").typeStyle(.title).foregroundStyle(Palette.ink)
            if !positions.isEmpty {
                Text("Digite a palavra \(positions[current] + 1)")
                    .typeStyle(.heading).foregroundStyle(Palette.ink).padding(.top, Space.lg)
                Text("\(current + 1) de \(positions.count)").typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xxs)

                WordInputField(text: $typed, isFocused: $focused, placeholder: "palavra \(positions[current] + 1)", onSubmit: check)
                    .padding(.horizontal, Space.md)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(focused ? Palette.edgeStrong : Palette.edge, lineWidth: 1)))
                    .padding(.top, Space.md)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) {
                        ForEach(suggestions, id: \.self) { word in
                            Chip(title: word) { typed = word; check() }
                        }
                    }
                }
                .frame(height: Height.chip)
                .padding(.top, Space.sm)

                if let error {
                    Text(error).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.sm)
                        .fixedSize(horizontal: false, vertical: true)
                    if (misses[positions[current]] ?? 0) >= 2 {
                        TertiaryButton(title: String(localized: "Ver as palavras de novo"), action: onBack)
                    }
                }
            }
            Spacer()
            PrimaryButton(title: String(localized: "Confirmar"), enabled: !typed.isEmpty, action: check)
            if let onLater {
                TertiaryButton(title: String(localized: "Anotar e confirmar depois"), action: onLater)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xxs)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xs)
        .background(Palette.void.ignoresSafeArea())
        .onAppear {
            if positions.isEmpty { positions = Self.pick(draft.wordCount) }
            focused = true
        }
        .sensoryFeedback(.success, trigger: current)
    }

    /// Uma posicao sorteada de cada terco (quatro em 24 palavras), pelo gerador do
    /// sistema.
    static func pick(_ count: Int) -> [Int] {
        let parts = count == 24 ? 4 : 3
        let size = count / parts
        return (0..<parts).map { part in
            var byte: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            return part * size + Int(byte) % size
        }
    }

    private func check() {
        let position = positions[current]
        if draft.matches(typed, at: position) {
            typed = ""
            error = nil
            if current + 1 < positions.count { current += 1 } else { onConfirmed() }
        } else {
            misses[position, default: 0] += 1
            error = String(localized: "Não é a palavra \(position + 1). Confira a posição \(position + 1) no seu papel.")
        }
    }
}

/// O5: carteira criada, com nome editavel. Tudo centrado: o selo com as redes da carteira
/// em volta (os enderecos que acabaram de nascer), o check verde, o nome.
struct WalletCreatedView: View {
    @Environment(AppSession.self) private var session
    @State var wallet: WalletMeta
    let isFirst: Bool
    let onFinish: () -> Void
    @State private var name = ""
    @State private var sealing = false
    @State private var done = false
    @FocusState private var editing: Bool

    /// As redes da carteira, uma moeda por logo, no maximo 12 no anel.
    private var coins: [String] {
        var seen = Set<String>()
        return wallet.accounts.compactMap { Chain.find($0.chainID)?.coingeckoID }
            .filter { seen.insert($0).inserted }
            .prefix(12).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.md)
            if !editing {
                CreatedEmblem(coins: coins)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            VStack(spacing: Space.sm) {
                Text("Carteira criada").typeStyle(.hero).foregroundStyle(Palette.ink)
                Text("Endereços prontos em \(wallet.accounts.count) redes. Guarde o papel longe do iPhone: se o iPhone sumir, o papel traz a carteira de volta, aqui ou em qualquer carteira BIP-39.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.top, Space.lg)
            VStack(spacing: Space.xs) {
                Text("Nome da carteira").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                HStack(spacing: Space.xs) {
                    TextField("", text: $name)
                        .typeStyle(.row).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .submitLabel(.done)
                        .focused($editing)
                        .onSubmit(save)
                    Image(systemName: "pencil").font(.system(size: 15)).foregroundStyle(Palette.inkMuted)
                }
                .padding(.horizontal, Space.md).frame(height: Height.field)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(editing ? Palette.edgeStrong : Palette.edge, lineWidth: 1)))
            }
            .padding(.top, Space.lg)
            Spacer(minLength: Space.md)
            PrimaryButton(title: String(localized: "Ir para a carteira")) { save(); onFinish() }
            TertiaryButton(title: String(localized: "Guardar também num envelope Escalibur")) { sealing = true }
                .frame(maxWidth: .infinity)
                .padding(.top, Space.xs)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xs)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: editing)
        .background(Palette.void.ignoresSafeArea().onTapGesture { editing = false })
        .onAppear {
            name = wallet.name
            done = true
        }
        .sensoryFeedback(.success, trigger: done)
        .fullScreenCover(isPresented: $sealing) {
            SealEnvelopeFlow(wallet: wallet) { sealing = false }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        wallet.name = String(trimmed.prefix(40))
        session.update(wallet)
    }
}

/// O selo da carteira com as redes em volta: os logos entram um a um, o check verde fecha,
/// e o anel segue girando devagar (pedido do dono, 15/10/2026). Com Reduzir Movimento, ja
/// aparece pronto e parado.
private struct CreatedEmblem: View {
    let coins: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0
    @State private var checked = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.edge, lineWidth: 1).frame(width: 176, height: 176)
            TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
                // Uma volta a cada 40 segundos; os logos ficam de pe.
                let turn = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 40) / 40 * 2 * .pi
                ZStack {
                    ForEach(Array(coins.enumerated()), id: \.offset) { index, id in
                        let angle = Double(index) / Double(max(coins.count, 1)) * 2 * .pi - .pi / 2 + turn
                        CoinLogo(coingeckoID: id, size: 30, ringColor: Palette.void)
                            .scaleEffect(shown > index ? 1 : 0.3)
                            .opacity(shown > index ? 1 : 0)
                            .offset(x: 88 * cos(angle), y: 88 * sin(angle))
                            .animation(.spring(response: 0.4, dampingFraction: 0.65), value: shown)
                    }
                }
            }
            WalletBadge(size: 84)
            Circle().fill(Palette.success)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Palette.void))
                .overlay(Circle().stroke(Palette.void, lineWidth: 3))
                .offset(x: 33, y: 33)
                .scaleEffect(checked ? 1 : 0.2)
                .opacity(checked ? 1 : 0)
                .animation(.spring(response: 0.38, dampingFraction: 0.55), value: checked)
        }
        .frame(width: 220, height: 220)
        .accessibilityHidden(true)
        .task {
            if reduceMotion {
                shown = coins.count
                checked = true
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            for _ in coins {
                shown += 1
                try? await Task.sleep(for: .milliseconds(55))
            }
            try? await Task.sleep(for: .milliseconds(120))
            checked = true
        }
    }
}
