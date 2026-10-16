import EscaliburChains
import EscaliburCore
import SwiftUI

/// O3 (gravar) e X2 (revelar): tres palavras por vez, num cartao sobre o baralho dos
/// proximos, que vira como flash card ao seguir (ou ao arrastar). "Ver todas de uma vez"
/// mostra a frase inteira numa chapa so (pedido do dono, 15/10/2026); as protecoes sao
/// as mesmas: as palavras somem quando o app sai da frente, e a captura de tela e a
/// gravacao continuam barradas (`guardedAgainstCapture`). Copiar, so na chapa e depois
/// do aviso (`CopyPhraseSheet`): local, e some em 1 minuto.
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
    /// A tela de aviso antes de copiar.
    @State private var askingCopy = false
    @Environment(ToastCenter.self) private var toasts
    /// As palavras do grupo na tela e dos dois vizinhos, para a pagina ja estar pronta
    /// quando o dedo arrasta. Recarregadas ao trocar de grupo, soltas ao esconder e ao
    /// sair; `body` so le daqui.
    @State private var shown: [Int: [String]] = [:]
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A chapa de "ver todas": o dedo e o iPhone inclinam ela um pouco.
    @State private var plateDrag: CGSize = .zero
    @State private var plateTilt = TiltReader()
    /// Graus de giro da chapa: para os lados e para frente/tras.
    private var plateRoll: Double { Double(plateDrag.width) / 10 + plateTilt.roll * 6 }
    private var platePitch: Double { -Double(plateDrag.height) / 12 - plateTilt.pitch * 5 }

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
                ScrollView {
                    allPlate.padding(.vertical, Space.md)
                    if !hidden {
                        SecondaryButton(title: String(localized: "Copiar"), systemImage: "doc.on.doc") { askingCopy = true }
                            .frame(maxWidth: 200)
                            .accessibilityIdentifier("copiar-palavras")
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // A chapa inclinada passa um pouco da largura: sem o recorte da rolagem, os
                // cantos nao somem quando ela vira para os lados (pedido do dono, 16/10/2026).
                .scrollClipDisabled()
                .padding(.top, Space.sm)
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
                    SecondaryButton(title: String(localized: "Anteriores"), height: Height.primary) { throwCard(-1) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                PrimaryButton(title: isLast ? (walletName == nil ? String(localized: "Já anotei as \(draft.wordCount)") : String(localized: "Fechar")) : String(localized: "Próximas")) {
                    isLast ? onDone() : throwCard(1)
                }
            }
            // Os botoes andam numa animacao curta so deles: a mola longa das cartas fazia o
            // "Proximas" encolher aos trancos (pedido do dono, 15/10/2026).
            .transaction { transaction in
                if transaction.animation != nil { transaction.animation = .easeOut(duration: 0.22) }
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
        .sheet(isPresented: $askingCopy) {
            CopyPhraseSheet {
                // Direto do rascunho: as da tela podem ter sido soltas se o app saiu da frente.
                Pasteboard.copyPhrase(draft.words(0..<draft.wordCount))
                askingCopy = false
                toasts.show(String(localized: "Palavras copiadas. Elas somem em 1 minuto."))
            }
            .presentationDetents([.large])
        }
        .onChange(of: scenePhase) { _, phase in
            // Em segundo plano as palavras escondem; voltam com um toque.
            if phase != .active { hidden = true }
        }
        // As mesmas palavras na tela por 60 s seguidos escondem sozinhas, e voltam com um
        // toque: a frase nao fica aberta numa mesa (docs/seguranca.md §6, N2).
        .task(id: "\(group)-\(showingAll)-\(hidden)") {
            guard !hidden else { return }
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { hidden = true }
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
                // Atras, o cartao fica num cinza claro e sem as palavras: antes um veu preto
                // cobria os de tras, e na troca o da frente passava pelo preto (pedido do
                // dono, 16/10/2026).
                plate(index, front: depth == 0, tone: Self.backTones[slot])
                    .frame(height: height)
                    .shadow(color: .black.opacity(depth == 0 ? 0.3 : 0), radius: 10, y: 6)
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

    /// A frase inteira, numa chapa de aco escovado como as de guardar seed (pedido do dono,
    /// 15/10/2026): as palavras gravadas em baixo-relevo, duas colunas em ordem de cima
    /// para baixo, rebites nos cantos. A chapa inclina com o dedo e com o iPhone, e o
    /// reflexo do metal anda junto; nao ha brilho correndo sozinho.
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
                                    .font(.system(size: 13, weight: .heavy).monospacedDigit())
                                    .engraved(depth: 0.8)
                                    .frame(width: 24, alignment: .leading)
                                Text(verbatim: index < words.count ? words[index] : "")
                                    .accessibilityIdentifier("palavra-\(index + 1)")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .engraved(depth: 1)
                                    .minimumScaleFactor(0.6).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(height: 40)
                        }
                    }
                }
            }
            if passphrase != nil, let secret = shown[groups - 1]?.first {
                Rectangle().fill(MetalPlate.groove).frame(height: 1.5).padding(.vertical, Space.xs)
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text("Pass").font(.system(size: 13, weight: .heavy)).engraved(depth: 0.8)
                    // Espaco visivel: um espaco a mais ou a menos ja abre outra carteira
                    // (auditoria 4, C7-02).
                    Text(verbatim: Self.visibleSpaces(secret)).font(.system(size: 20, weight: .bold, design: .monospaced)).engraved(depth: 1)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 40)
                Text(Self.passphraseCount(secret))
                    .font(.system(size: 12, weight: .semibold)).engraved(depth: 0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.lg)
        .opacity(hidden ? 0 : 1)
        .overlay {
            if hidden {
                Button { hidden = false } label: {
                    Text("Mostrar de novo").typeStyle(.action).foregroundStyle(MetalPlate.ink)
                        .padding(.horizontal, Space.md).frame(height: 40)
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(MetalPlate.ink, lineWidth: 1.5))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(MetalPlate(tiltX: plateRoll / 12, tiltY: platePitch / 12))
        // A espessura da chapa: a borda de aco que aparece embaixo e do lado oposto ao giro.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x8B8D95), Color(hex: 0x55575E)], startPoint: .top, endPoint: .bottom))
                .offset(x: CGFloat(-plateRoll) * 0.35, y: 5 + CGFloat(max(platePitch, -4)) * 0.3)
        )
        // Inclina um pouco com o dedo e com o iPhone, e volta ao soltar (pedido do dono,
        // 15/10/2026): a luz da chapa anda junto.
        .rotation3DEffect(.degrees(7 + platePitch), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.45)
        .rotation3DEffect(.degrees(plateRoll), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.45)
        .shadow(color: .black.opacity(0.55), radius: 18, x: CGFloat(-plateRoll), y: 16)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    plateDrag = CGSize(width: min(max(value.translation.width, -70), 70), height: min(max(value.translation.height, -70), 70))
                }
                .onEnded { _ in withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { plateDrag = .zero } }
        )
        .onAppear { if !reduceMotion { plateTilt.start() } }
        .onDisappear { plateTilt.stop() }
        .textSelection(.disabled)
        .accessibilityElement(children: .contain)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// O cartao da frente e os de tras, um pouco mais escuros a cada lugar da pilha.
    static let backTones: [Color] = [Palette.live, Color(hex: 0xDADADF), Color(hex: 0xBEBEC4), Color(hex: 0xA4A4AB)]

    private func plate(_ index: Int, front: Bool = true, tone: Color = Palette.live) -> some View {
        ZStack {
            VStack(spacing: 0) {
                let words = shown[index] ?? []
                if isPassphrase(index) {
                    passphraseRow(words.first ?? "")
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
            .opacity(hidden || !front ? 0 : 1)
            .animation(.easeOut(duration: 0.18), value: front)

            if hidden, front {
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
        .background(LacquerPlate().fill(tone))
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

    /// A passphrase inteira, sem cortar: o espaco aparece como ␣ e a contagem vem embaixo,
    /// porque um espaco a mais ou um caractere que sumiu no "..." ja abre outra carteira
    /// (revisao da auditoria 4, C7-02). Longa, quebra e encolhe em vez de cortar.
    private func passphraseRow(_ secret: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text("Pass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.plateMuted)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: Self.visibleSpaces(secret))
                    .accessibilityIdentifier("palavra-25")
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.plateInk)
                    .lineLimit(6)
                    .minimumScaleFactor(0.4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.passphraseCount(secret))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.plateMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.sm)
    }

    static func visibleSpaces(_ secret: String) -> String { secret.replacingOccurrences(of: " ", with: "␣") }

    /// A contagem, e o aviso de que a quebra de linha da tela nao e caractere: a passphrase
    /// longa quebra no meio.
    static func passphraseCount(_ secret: String) -> String {
        let count = secret.contains(" ") ? String(localized: "\(secret.count) caracteres. ␣ é um espaço.") : String(localized: "\(secret.count) caracteres.")
        return secret.count > 16 ? count + " " + String(localized: "A quebra de linha não é espaço.") : count
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

    /// Os botoes fazem o mesmo que o dedo (pedido do dono, 15/10/2026): a carta da frente
    /// sai para o lado, girando um pouco, e depois passa para o fundo da pilha enquanto a
    /// seguinte sobe. Seguir joga para a esquerda; voltar, para a direita.
    private func throwCard(_ delta: Int) {
        let target = max(0, min(groups - 1, group + delta))
        guard target != group else { return }
        if reduceMotion {
            move(delta)
            return
        }
        withAnimation(.easeIn(duration: 0.16)) { drag = delta > 0 ? -240 : 240 }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
                group = target
                drag = 0
            }
        }
    }
}

/// O4: conferir digitando 3 posicoes sorteadas, uma de cada terco da frase.
struct ConfirmWordsView: View {
    @Environment(AppSession.self) private var session
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

                WordInputField(text: $typed, isFocused: $focused, placeholder: "palavra \(positions[current] + 1)",
                               ownKeyboard: session.ownKeyboardOn, onSubmit: check)
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
                Text("Endereços prontos em \(wallet.accounts.count) redes. Guarde o papel longe do iPhone: se o iPhone sumir, o papel traz a carteira de volta, aqui ou em outros apps. Em Ajustes, na carteira, \"Abrir em outro app\" diz quais.")
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

/// A chapa de aco escovado da frase: degrade da luz para a sombra, riscos finos do
/// escovado de largura irregular, chanfro aceso em cima e escuro embaixo e quatro rebites.
/// O reflexo do escovado (uma faixa vertical) e a luz de cima seguem a inclinacao que
/// quem usa a chapa passa em `tiltX`/`tiltY`.
private struct MetalPlate: View {
    static let ink = Color(hex: 0x2E2F35)
    static let groove = Color(hex: 0x8E9098)
    /// A inclinacao, de -1 a 1: para os lados (x) e para frente/tras (y).
    var tiltX: Double = 0
    var tiltY: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            // O aco escovado, parado: o fundo, os riscos irregulares e os parafusos.
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(stops: [.init(color: Color(hex: 0xE6E7EB), location: 0), .init(color: Color(hex: 0xCFD1D6), location: 0.45),
                                     .init(color: Color(hex: 0xBABCC2), location: 1)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width * 0.3, y: size.height)))
                // O escovado de verdade: riscos de comprimento, altura e tom sorteados (sempre os
                // mesmos), nao uma grade de linhas inteiras (pedido do dono, 16/10/2026: mais
                // realista).
                var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
                func next() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Double(seed >> 11) / Double(1 << 53)
                }
                let streaks = Int(size.height * 5)
                for _ in 0..<streaks {
                    let y = CGFloat(next()) * size.height
                    let length = size.width * CGFloat(0.25 + 0.75 * next())
                    let x = CGFloat(next()) * (size.width - length * 0.5) - length * 0.25
                    let light = next() < 0.55
                    let alpha = light ? 0.06 + 0.14 * next() : 0.02 + 0.06 * next()
                    context.fill(Path(CGRect(x: x, y: y, width: length, height: CGFloat(0.35 + 0.5 * next()))),
                                 with: .color(light ? .white.opacity(alpha) : .black.opacity(alpha)))
                }
                // Parafusos de fenda cruzada nos quatro cantos, cada um num angulo.
                let corners = [CGPoint(x: 15, y: 15), CGPoint(x: size.width - 15, y: 15),
                               CGPoint(x: 15, y: size.height - 15), CGPoint(x: size.width - 15, y: size.height - 15)]
                for (index, corner) in corners.enumerated() {
                    let screw = CGRect(x: corner.x - 5.5, y: corner.y - 5.5, width: 11, height: 11)
                    context.fill(Path(ellipseIn: screw.insetBy(dx: -1.5, dy: -1.5)), with: .color(.black.opacity(0.14)))
                    context.fill(Path(ellipseIn: screw.offsetBy(dx: 0, dy: 1)), with: .color(.black.opacity(0.28)))
                    context.fill(Path(ellipseIn: screw), with: .radialGradient(
                        Gradient(colors: [Color(hex: 0xF8F8FA), Color(hex: 0xA6A8B0), Color(hex: 0x7C7E86)]),
                        center: CGPoint(x: screw.midX - 2, y: screw.midY - 2), startRadius: 0, endRadius: 8))
                    var slot = context
                    slot.translateBy(x: corner.x, y: corner.y)
                    slot.rotate(by: .degrees(Double([18, 63, 141, 102][index])))
                    for angle in [0.0, 90.0] {
                        var arm = slot
                        arm.rotate(by: .degrees(angle))
                        arm.fill(Path(roundedRect: CGRect(x: -3.6, y: -0.7, width: 7.2, height: 1.4), cornerRadius: 0.7), with: .color(Color(hex: 0x4A4C53)))
                    }
                }
                // A marca gravada embaixo, como a do fabricante numa chapa de guardar seed.
                context.draw(Text(verbatim: "ESCALIBUR").font(.system(size: 8, weight: .heavy)).kerning(2.2).foregroundColor(.black.opacity(0.22)),
                             at: CGPoint(x: size.width / 2, y: size.height - 12), anchor: .center)
            }
            // O reflexo do escovado: no aco riscado na horizontal, a luz vira uma faixa
            // vertical larga, que corre a chapa conforme ela inclina para os lados, e uma
            // segunda, mais fina, um pouco atras.
            GeometryReader { geo in
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.4), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.42, height: geo.size.height)
                    .position(x: geo.size.width * (0.5 - tiltX * 0.9), y: geo.size.height / 2)
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.22), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.12, height: geo.size.height)
                    .position(x: geo.size.width * (0.82 - tiltX * 1.3), y: geo.size.height / 2)
            }
            .blendMode(.screen)
            // A luz de cima: mais clara quando a chapa vira para cima, mais escura para baixo.
            LinearGradient(colors: [.white.opacity(max(0.05, 0.16 - tiltY * 0.12)), .clear, .black.opacity(max(0, 0.1 + tiltY * 0.08))],
                           startPoint: .top, endPoint: .bottom)
            // As bordas um pouco mais escuras, como metal de verdade sob uma luz so.
            RadialGradient(colors: [.clear, .black.opacity(0.1)], center: .center, startRadius: 120, endRadius: 360)
        }
        .clipShape(shape)
        // O chanfro: a borda de cima pega a luz (mais quando a chapa vira para cima), a de
        // baixo fica na sombra.
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(min(1, 0.85 + max(-tiltY, 0) * 0.15)), Color(hex: 0x82848C)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 2))
        .overlay(shape.inset(by: 5).stroke(Color.black.opacity(0.08), lineWidth: 1))
        .allowsHitTesting(false)
    }
}

/// Texto gravado no metal: o sulco escuro, com a sombra por dentro em cima e a luz batendo
/// na borda de baixo.
private extension View {
    func engraved(depth: CGFloat) -> some View {
        self.foregroundStyle(MetalPlate.ink.opacity(0.9).shadow(.inner(color: .black.opacity(0.55), radius: 0.5, x: 0, y: depth)))
            .shadow(color: .white.opacity(0.8), radius: 0, x: 0, y: depth)
            .shadow(color: .black.opacity(0.14), radius: 0, x: 0, y: -depth * 0.6)
    }
}

/// Antes de copiar a frase: o que pode dar errado, tres "estou ciente" e so entao o
/// botao. A copia fica so neste iPhone (nao vai para o Mac) e some em 1 minuto.
private struct CopyPhraseSheet: View {
    let onCopy: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged: Set<Int> = []

    static let statements = [
        String(localized: "qualquer app que eu abrir pode ler o que está copiado"),
        String(localized: "colar as palavras num site, chat ou nota pode custar o saldo"),
        String(localized: "a Escalibur nunca pede as palavras"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClipboardCountdown()
                .frame(maxWidth: .infinity)
                .padding(.top, Space.lg)
            Text("Copiar a senha da carteira?")
                .typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
            Text("A cópia fica só neste iPhone, não passa para o Mac e some sozinha em 1 minuto. Anotar no papel continua sendo o mais seguro.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
            Text("Estou ciente que:").typeStyle(.row).foregroundStyle(Palette.ink).padding(.top, Space.lg)
            VStack(spacing: 0) {
                ForEach(Array(Self.statements.enumerated()), id: \.offset) { index, statement in
                    Button {
                        if acknowledged.contains(index) { acknowledged.remove(index) } else { acknowledged.insert(index) }
                    } label: {
                        HStack(spacing: Space.sm) {
                            ZStack {
                                Circle().stroke(acknowledged.contains(index) ? Palette.success : Palette.inkMuted, lineWidth: 1.5)
                                if acknowledged.contains(index) {
                                    Circle().fill(Palette.success)
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.void)
                                }
                            }
                            .frame(width: 22, height: 22)
                            Text(statement).typeStyle(.body).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: Height.rowCompact)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ciente-copia-\(index)")
                    .sensoryFeedback(.selection, trigger: acknowledged.contains(index))
                }
            }
            Spacer(minLength: Space.lg)
            PrimaryButton(title: String(localized: "Copiar as palavras"), enabled: acknowledged.count == Self.statements.count) { onCopy() }
                .accessibilityIdentifier("confirmar-copia")
            TertiaryButton(title: String(localized: "Agora não")) { dismiss() }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.xs)
        .background(Palette.void.ignoresSafeArea())
        .guardedAgainstCapture()
    }
}

/// A cena da copia, em pixels (pedido do dono, 16/10/2026, no estilo do `SlideToConfirm`):
/// tres palavras, so em pixels cinza que cifram, entram na prancheta; um anel de pixels em
/// volta do relogio conta o minuto, apagando um por um; no fim os pixels das palavras se
/// desfazem para cima e somem. Em ciclo, para dizer o que a tela diz: a copia vive pouco e
/// so aqui. Com Reduzir Movimento, a prancheta cheia e o anel inteiro, parados.
private struct ClipboardCountdown: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    static let period = 5.2
    /// Quantos pixels por palavra, e o anel.
    static let lengths = [9, 7, 8]
    static let ring = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 1.4 : timeline.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.period)
            let clock = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            // 0 a 1,2 s: as palavras entram; 1,3 a 4,0 s: o anel conta; 4,0 a 4,9 s: somem.
            let left = Self.clamp((t - 1.3) / 2.7)
            let dissolve = Self.clamp((t - 4.0) / 0.9)
            ZStack(alignment: .topTrailing) {
                board(t: t, clock: clock, dissolve: dissolve)
                ring(left: reduceMotion ? 0 : left, fade: dissolve)
                    .offset(x: 22, y: -20)
            }
            .frame(width: 140, height: 112)
        }
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }

    private func board(t: Double, clock: Double, dissolve: Double) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 1))
            // O prendedor da prancheta.
            Capsule().fill(Palette.control).frame(width: 46, height: 12)
                .overlay(Capsule().stroke(Palette.edgeStrong, lineWidth: 1))
                .offset(y: -6)
            Canvas { context, size in
                for (line, count) in Self.lengths.enumerated() {
                    let enter = Self.ease(Self.clamp((t - 0.15 - Double(line) * 0.22) / 0.45))
                    let y = 28 + CGFloat(line) * 17
                    // O numero da palavra, como na chapa.
                    context.fill(Path(roundedRect: CGRect(x: 16, y: y + 1, width: 8, height: 5), cornerRadius: 1.5),
                                 with: .color(Palette.inkMuted.opacity(enter * (1 - dissolve))))
                    for index in 0..<count {
                        let id = line * 16 + index
                        let rise = dissolve * (14 + 24 * PixelFill.noise(id, 5, 0x91))
                        let drift = dissolve * (PixelFill.noise(id, 6, 0x92) - 0.5) * 16
                        let alpha = enter * (1 - Self.clamp(dissolve * 1.3 - PixelFill.noise(id, 7, 0x93) * 0.3))
                        guard alpha > 0.01 else { continue }
                        let x = 30 + CGFloat(index) * 7 - CGFloat(1 - enter) * 24 + CGFloat(drift)
                        let side = 5.4 * (1 - 0.4 * CGFloat(dissolve))
                        context.fill(Path(roundedRect: CGRect(x: x, y: y - CGFloat(rise), width: side, height: side), cornerRadius: 1.2),
                                     with: .color(PixelFill.gray(Self.tone(id, clock: clock)).opacity(alpha)))
                    }
                }
            }
        }
        .frame(width: 116, height: 100)
    }

    /// O relogio de 1 minuto, com o anel de pixels apagando conforme o tempo passa.
    private func ring(left: Double, fade: Double) -> some View {
        let remaining = 1 - left
        return ZStack {
            Circle().fill(Palette.void)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let lit = Int((remaining * Double(Self.ring)).rounded(.up))
                for index in 0..<Self.ring {
                    let angle = Double(index) / Double(Self.ring) * 2 * .pi - .pi / 2
                    let point = CGPoint(x: center.x + 19 * CGFloat(cos(angle)), y: center.y + 19 * CGFloat(sin(angle)))
                    let square = CGRect(x: point.x - 1.8, y: point.y - 1.8, width: 3.6, height: 3.6)
                    context.fill(Path(roundedRect: square, cornerRadius: 0.9),
                                 with: .color(index < lit ? Palette.ink : Palette.edgeStrong))
                }
            }
            Text(verbatim: Self.clock(remaining))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.ink)
        }
        .frame(width: 48, height: 48)
        .opacity(1 - fade * 0.6)
    }

    /// 1:00 ate 0:00, no ritmo do anel.
    static func clock(_ remaining: Double) -> String {
        let seconds = Int((remaining * 60).rounded(.up))
        return seconds >= 60 ? "1:00" : String(format: "0:%02d", seconds)
    }

    private static func tone(_ id: Int, clock: Double) -> Double {
        let phase = PixelFill.noise(id, 4, 0x55)
        let beat = clock * 6 * (0.6 + 0.8 * phase) + phase * 8
        let step = beat.rounded(.down)
        let blend = (beat - step) * (beat - step) * (3 - 2 * (beat - step))
        let a = PixelFill.noise(id, 4, Int(step)), b = PixelFill.noise(id, 4, Int(step) + 1)
        return 0.38 + 0.4 * (a + (b - a) * blend)
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    private static func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}
