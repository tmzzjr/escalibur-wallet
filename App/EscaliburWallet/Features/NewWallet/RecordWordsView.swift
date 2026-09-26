import EscaliburCore
import SwiftUI

/// O3 (gravar) e X2 (revelar): tres palavras por vez, sessenta segundos por grupo,
/// na placa clara. Nada de copiar, nada de "mostrar todas".
struct RecordWordsView: View {
    let draft: PhraseDraft
    /// Nil na criacao; o nome da carteira na revelacao (X2).
    let walletName: String?
    var passphrase: String? = nil
    let onDone: () -> Void

    @State private var group = 0
    @State private var secondsLeft = 60
    @State private var hidden = false
    @Environment(\.scenePhase) private var scenePhase

    private let perGroup = 3
    private let window = 60
    private var groups: Int { draft.wordCount / perGroup + (passphrase == nil ? 0 : 1) }
    private var isPassphraseGroup: Bool { passphrase != nil && group == groups - 1 }
    private var isLast: Bool { group == groups - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(walletName == nil ? "Grave a senha da carteira" : "Senha da carteira")
                .typeStyle(.title).foregroundStyle(Palette.ink)
            Text(subtitle)
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)

            plate.padding(.top, Space.lg)

            if isPassphraseGroup {
                Text("Sem ela, as palavras acima abrem uma carteira diferente e vazia.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
            }
            Spacer()
            HStack(spacing: Space.sm) {
                if group > 0 {
                    SecondaryButton(title: "Anteriores", height: Height.primary) { move(-1) }
                }
                PrimaryButton(title: isLast ? (walletName == nil ? "Já anotei as \(draft.wordCount)" : "Fechar") : "Próximas") {
                    isLast ? onDone() : move(1)
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xs)
        .background(Palette.void.ignoresSafeArea())
        .guardedAgainstCapture()
        .task(id: group) { await countdown() }
        .onChange(of: scenePhase) { _, phase in
            // Em segundo plano as palavras escondem e o tempo reinicia.
            if phase != .active { hidden = true; secondsLeft = window }
        }
    }

    private var subtitle: String {
        if isPassphraseGroup { return "25ª palavra" }
        let first = group * perGroup + 1
        let last = min(first + perGroup - 1, draft.wordCount)
        let prefix = walletName.map { "\($0) · " } ?? ""
        return "\(prefix)Palavras \(first) a \(last) de \(draft.wordCount)"
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Palette.plateBurn)
                    .frame(width: geometry.size.width * CGFloat(window - secondsLeft) / CGFloat(window), height: 4)
            }
            .frame(height: 4)

            ZStack {
                VStack(spacing: 0) {
                    if isPassphraseGroup {
                        plateRow(index: nil, word: passphrase ?? "")
                    } else {
                        let start = group * perGroup
                        let words = draft.words(start..<min(start + perGroup, draft.wordCount))
                        ForEach(Array(words.enumerated()), id: \.offset) { offset, word in
                            plateRow(index: start + offset + 1, word: word)
                            if offset < words.count - 1 {
                                Rectangle().fill(Palette.plateRule).frame(height: 1).padding(.leading, Space.base)
                            }
                        }
                    }
                }
                .opacity(hidden ? 0 : 1)

                if hidden {
                    VStack(spacing: Space.sm) {
                        Text("Escondidas para ninguém ler por cima do seu ombro.")
                            .typeStyle(.body).foregroundStyle(Palette.plateInk).multilineTextAlignment(.center)
                        Button {
                            hidden = false
                            secondsLeft = window
                        } label: {
                            Text("Mostrar de novo").typeStyle(.action).foregroundStyle(Palette.plateInk)
                                .padding(.horizontal, Space.md).frame(height: 40)
                                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.plateInk, lineWidth: 1.5))
                        }
                    }
                    .padding(Space.md)
                }
            }
            .frame(minHeight: 3 * 84)

            HStack {
                Spacer()
                Text(hidden ? " " : "Esconde em \(secondsLeft) s")
                    .typeStyle(.note).foregroundStyle(Palette.plateMuted)
            }
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.sm)
        }
        .background(LacquerPlate().fill(Palette.live))
        .clipShape(LacquerPlate())
        .textSelection(.disabled)
        .accessibilityElement(children: .contain)
    }

    private func plateRow(index: Int?, word: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(index.map { String(format: "%02d", $0) } ?? "25ª")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.plateMuted)
                .frame(width: 34, alignment: .leading)
            Text(verbatim: word)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.plateInk)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.base)
        .frame(height: 84)
    }

    private func move(_ delta: Int) {
        withAnimation(Motion.crossfade) {
            group = max(0, min(groups - 1, group + delta))
            hidden = false
            secondsLeft = window
        }
    }

    private func countdown() async {
        secondsLeft = window
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !hidden else { continue }
            secondsLeft -= 1
            if secondsLeft <= 0 { hidden = true }
        }
    }
}

/// O4: conferir digitando 3 posicoes sorteadas, uma de cada terco da frase.
struct ConfirmWordsView: View {
    let draft: PhraseDraft
    let onBack: () -> Void
    let onConfirmed: () -> Void

    @State private var positions: [Int] = []
    @State private var current = 0
    @State private var typed = ""
    @State private var error: String?
    @State private var misses: [Int: Int] = [:]
    @FocusState private var focused: Bool

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

                TextField("", text: $typed, prompt: Text("palavra \(positions[current] + 1)").foregroundColor(Palette.inkDead))
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .textContentType(nil)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(check)
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
                        TertiaryButton(title: "Ver as palavras de novo", action: onBack)
                    }
                }
            }
            Spacer()
            PrimaryButton(title: "Confirmar", enabled: !typed.isEmpty, action: check)
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
            error = "Não é a palavra \(position + 1). Confira a posição \(position + 1) no seu papel."
        }
    }
}

/// O5: carteira criada, com nome editavel.
struct WalletCreatedView: View {
    @Environment(AppSession.self) private var session
    @State var wallet: WalletMeta
    let isFirst: Bool
    let onFinish: () -> Void
    @State private var name = ""
    @State private var sealing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Palette.up)
            Text("Carteira criada").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
            Text("Endereços prontos em \(wallet.accounts.count) redes. Guarde o papel longe do iPhone: se o iPhone sumir, o papel traz a carteira de volta, aqui ou em qualquer carteira BIP-39.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nome da carteira").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
            TextField("", text: $name)
                .typeStyle(.row).foregroundStyle(Palette.ink)
                .padding(.horizontal, Space.md).frame(height: Height.field)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                .padding(.top, Space.xs)
            Spacer()
            SecondaryButton(title: "Guardar também num envelope Escalibur") { sealing = true }
            PrimaryButton(title: "Ir para a carteira") { save(); onFinish() }.padding(.top, Space.sm)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.xs)
        .background(Palette.void.ignoresSafeArea())
        .onAppear { name = wallet.name }
        .sensoryFeedback(.success, trigger: true)
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
