import SwiftUI

/// O arquivo do envelope desenhado como um cartao (pedido do dono, 15/10/2026): no topo, o
/// envelope, o nome do arquivo (ou a senha sendo digitada) e o cadeado; dentro, as
/// palavras da carteira, cifradas, em glifos que trocam como os da cifra viva
/// (`LiveCipher`). Nunca pontos no lugar das palavras: so o cifrado.
///
/// - `sealed`: so o cifrado, trocando sem parar ("Sem a senha, o arquivo e ruido").
/// - `reveal`: a historia em laco. A senha e digitada, o envelope e o cadeado abrem, as
///   palavras se decifram uma a uma, ficam um tempo e voltam a cifrar todas juntas, no
///   instante em que o cadeado fecha ("So a sua senha abre" e a tela de abrir um envelope).
/// - `denied`: alguem tenta uma senha errada: o app tenta abrir (a cifra acelera), nao abre,
///   os pontos tremem e se apagam, e o cifrado se embaralha de novo numa onda ("Sem a senha,
///   o arquivo e ruido"). O cadeado so balanca, sem cor.
/// - `opening`: o app fazendo a conta da senha de verdade: o cifrado troca mais rapido e
///   uma faixa varre o cartao.
/// - `opened`: abriu. O envelope e o cadeado abrem e o cifrado segue rolando, um por
///   palavra de verdade: palavra de exemplo nunca aparece no lugar das de verdade
///   (pedido do dono, 15/10/2026).
///
/// As palavras do `reveal` sao exemplo: doze palavras da lista BIP-39 que nao formam uma
/// frase valida (o checksum falha, conferido em `EnvelopeCipherCardTests`). Os glifos sao
/// desenho, sorteados de um contador: nada aqui sai de chave nenhuma. Com Reduzir
/// Movimento, um quadro parado de cada modo.
struct EnvelopeCipherCard: View {
    enum Mode: Equatable { case sealed, reveal, opening, opened, denied }

    let mode: Mode
    var fileName = "envelope-7F3A.esclbr"
    /// Aberto, um cifrado por palavra de verdade (12 ou 24). Antes de abrir o app nao sabe
    /// quantas sao: o cartao mostra 12.
    var wordCount = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    static let sample = ["ocean", "figure", "velvet", "canyon", "ripple", "lamp", "orbit", "meadow", "silver", "tiger", "harbor", "puzzle"]
    static let alphabet = Array("0123456789ABCDEF")

    /// A historia do `reveal`, em segundos dentro do laco.
    enum Story {
        static let period = 8.6
        static let fieldIn = 0.5
        static let typeFrom = 0.8
        static let keystroke = 0.19
        static let keys = 8
        static let unlock = 2.6
        static let revealFrom = 2.85
        static let revealStep = 0.09
        static let settle = 0.32
        static let hideFrom = 7.0
        static let fieldOut = 7.5
    }

    /// A tentativa errada do `denied`, em segundos dentro do laco.
    enum Wrong {
        static let period = 5.4
        static let fieldIn = 0.4
        static let typeFrom = 0.7
        static let keystroke = 0.15
        static let keys = 6
        /// A tentativa: a faixa varre e a cifra acelera.
        static let tryFrom = 1.75
        static let tryTime = 0.9
        static let deny = 2.65
        /// Os pontos se apagam, do ultimo para o primeiro.
        static let eraseFrom = 3.05
        static let eraseStep = 0.07
        /// A onda que embaralha o cifrado de novo, da esquerda para a direita.
        static let rippleFrom = 2.7
        static let rippleStep = 0.05
        static let fieldOut = 4.4
    }

    var body: some View {
        // So o cifrado trocando: 12 quadros por segundo; com a historia ou a faixa, 30.
        TimelineView(.animation(minimumInterval: mode == .sealed || mode == .opened ? 1.0 / 12 : 1.0 / 60, paused: reduceMotion)) { timeline in
            let now = timeline.date
            let frame = state(at: now)
            card(frame, tick: frame.fast ? UInt64(max(now.timeIntervalSinceReferenceDate * 30, 0)) : tick(at: now), scan: scan(at: now))
        }
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
        .onAppear { start = Date() }
        .accessibilityHidden(true)
    }

    // MARK: Estado de cada quadro

    struct Frame {
        /// 0 = nome do arquivo no topo, 1 = campo de senha.
        var field: Double = 0
        var keys = 0
        var caret = false
        var unlocked = false
        /// A senha recusada: 0 nada, 1 o vermelho inteiro; e o tremor do campo, em pontos.
        var denied = 0.0
        var shake: CGFloat = 0
        /// A cifra mais rapida enquanto o app tenta a senha.
        var fast = false
        /// O balanco do cadeado, em graus.
        var lockSwing = 0.0
        /// Por palavra: o brilho da onda que embaralha de novo.
        var ripple = Array(repeating: 0.0, count: 12)
        /// Por palavra: 0 cifrada, 1 decifrada (palavra) ou aberta (visto).
        var shown = Array(repeating: 0.0, count: 12)
    }

    private func state(at now: Date) -> Frame {
        var f = Frame()
        switch mode {
        case .sealed, .opening:
            return f
        case .opened:
            f.unlocked = true
            f.shown = Array(repeating: 0, count: wordCount)
            return f
        case .denied:
            if reduceMotion {
                f.field = 1
                f.keys = Wrong.keys
                f.denied = 1
                return f
            }
            let t = now.timeIntervalSince(start).truncatingRemainder(dividingBy: Wrong.period)
            f.field = Self.smooth((t - Wrong.fieldIn) / 0.25) * (1 - Self.smooth((t - Wrong.fieldOut) / 0.3))
            let typed = min(max(Int((t - Wrong.typeFrom) / Wrong.keystroke) + 1, 0), Wrong.keys)
            let erased = t < Wrong.eraseFrom ? 0 : min(Int((t - Wrong.eraseFrom) / Wrong.eraseStep) + 1, Wrong.keys)
            f.keys = max(typed - erased, 0)
            f.caret = f.field > 0.5 && (t < Wrong.tryFrom || t > Wrong.eraseFrom + 0.5) && Int(t * 2.4) % 2 == 0
            // A tentativa: a cifra acelera um instante, sem faixa varrendo (pedido do dono,
            // 16/10/2026).
            let trying = (t - Wrong.tryFrom) / Wrong.tryTime
            f.fast = trying >= 0 && trying < 1
            let since = t - Wrong.deny
            f.denied = since < 0 ? 0 : Self.smooth(since / 0.1) * (1 - Self.smooth((t - Wrong.eraseFrom) / 0.2))
            // O tremor de quem errou: tres idas e voltas que acabam; o cadeado balanca junto.
            f.shake = since > 0 && since < 0.45 ? CGFloat(sin(since * 40) * 7 * (1 - since / 0.45)) : 0
            f.lockSwing = since > 0 && since < 0.5 ? sin(since * 30) * 14 * (1 - since / 0.5) : 0
            // A onda: cada palavra brilha um instante e troca a cifra, em ordem.
            f.ripple = (0..<12).map { i in
                let local = t - Wrong.rippleFrom - Double(i) * Wrong.rippleStep
                return local < 0 || local > 0.35 ? 0 : sin(local / 0.35 * .pi)
            }
            return f
        case .reveal:
            if reduceMotion {
                f.field = 1
                f.keys = Story.keys
                f.unlocked = true
                f.shown = Array(repeating: 1, count: 12)
                return f
            }
            let t = now.timeIntervalSince(start).truncatingRemainder(dividingBy: Story.period)
            f.field = Self.smooth((t - Story.fieldIn) / 0.25) * (1 - Self.smooth((t - Story.fieldOut) / 0.3))
            f.keys = t < Story.hideFrom ? min(max(Int((t - Story.typeFrom) / Story.keystroke) + 1, 0), Story.keys) : 0
            f.caret = f.field > 0.5 && t < Story.unlock && Int(t * 2.4) % 2 == 0
            // O cadeado fecha e todas as palavras voltam a cifrar no mesmo instante (pedido do
            // dono, 16/10/2026: antes elas sumiam uma a uma).
            f.unlocked = t >= Story.unlock && t < Story.hideFrom
            let hide = Self.smooth((t - Story.hideFrom) / 0.16)
            f.shown = (0..<12).map { i in
                Self.smooth((t - Story.revealFrom - Double(i) * Story.revealStep) / Story.settle) * (1 - hide)
            }
            return f
        }
    }

    /// Os glifos trocam a 12 quadros por segundo, como a cifra viva; fazendo a conta, a 24.
    private func tick(at now: Date) -> UInt64 {
        if reduceMotion { return 0 }
        return UInt64(max(now.timeIntervalSinceReferenceDate * (mode == .opening ? 24 : 12), 0))
    }

    /// A faixa que varre o cartao enquanto o app faz a conta (0 a 1, de cima para baixo).
    private func scan(at now: Date) -> Double? {
        guard mode == .opening, !reduceMotion else { return nil }
        return now.timeIntervalSince(start).truncatingRemainder(dividingBy: 1.4) / 1.4
    }

    // MARK: Desenho

    private func card(_ f: Frame, tick: UInt64, scan: Double?) -> some View {
        VStack(spacing: Space.sm) {
            header(f)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: f.shown.count > 12 ? 4 : 3), spacing: 6) {
                ForEach(0..<f.shown.count, id: \.self) { i in
                    chip(i, shown: f.shown[i], tick: tick &+ UInt64(f.ripple.indices.contains(i) && f.ripple[i] > 0.5 ? 53 : 0),
                         glow: f.ripple.indices.contains(i) ? f.ripple[i] : 0)
                }
            }
            .overlay { if let scan { scanBand(scan) } }
        }
        .padding(Space.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                // O fundo do cartao em pixels cinza que cifram, como no deslizar e no cofre
                // (pedido do dono, 16/10/2026): aparece em volta das palavras e segue trocando
                // tambem aberto, so mais apagado.
                .overlay {
                    PixelCipherStrip(index: 0, tick: tick / 3, glow: 0)
                        .opacity(f.unlocked ? 0.25 : 0.5)
                        .padding(3)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1))
        )
    }

    private func header(_ f: Frame) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: f.unlocked ? "envelope.open.fill" : "envelope.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.control))
            ZStack(alignment: .leading) {
                Text(verbatim: fileName)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(1)
                    .opacity(1 - f.field)
                passwordField(f).opacity(f.field)
            }
            Spacer(minLength: 0)
            Image(systemName: f.unlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(f.unlocked ? Palette.success : Palette.inkSoft)
                .contentTransition(.symbolEffect(.replace))
                // Na senha errada, o cadeado so balanca: continua fechado, sem cor (pedido do
                // dono, 16/10/2026).
                .rotationEffect(.degrees(f.lockSwing), anchor: .top)
                .frame(width: 28)
        }
        .frame(height: 34)
    }

    /// A senha sendo digitada: pontos, um por tecla, e o cursor piscando logo depois do
    /// ultimo, andando com a digitacao. O campo tem a largura da senha inteira desde o
    /// comeco, para nao crescer a cada tecla.
    private func passwordField(_ f: Frame) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<f.keys, id: \.self) { _ in
                Circle().fill(f.denied > 0.3 ? Palette.down : Palette.ink).frame(width: 7, height: 7)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            RoundedRectangle(cornerRadius: 1).fill(Palette.accent).frame(width: 2, height: 16).opacity(f.caret ? 1 : 0)
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: f.keys)
        .padding(.horizontal, Space.sm)
        .frame(width: CGFloat(Story.keys) * 11 + 2 + 2 * Space.sm, height: 30, alignment: .leading)
        .background(Capsule(style: .continuous).fill(Palette.void)
            .overlay(Capsule(style: .continuous).stroke(Palette.down.opacity(f.denied), lineWidth: 1.5)))
        .offset(x: f.shake)
    }

    private func chip(_ i: Int, shown: Double, tick: UInt64, glow: Double = 0) -> some View {
        let done = shown >= 0.5
        return HStack(spacing: 5) {
            Text(verbatim: "\(i + 1)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 15, alignment: .trailing)
            ZStack(alignment: .leading) {
                Text(verbatim: Self.glyphs(i, tick: tick &+ UInt64(shown * 40)))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.inkSoft)
                    .opacity(1 - shown)
                if Self.sample.indices.contains(i) {
                    Text(verbatim: Self.sample[i]).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        .opacity(shown)
                        .scaleEffect(0.92 + 0.08 * shown, anchor: .leading)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(done ? Palette.control : Palette.void)
                .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .stroke(done ? Palette.edge : Palette.edgeStrong, lineWidth: 1))
        )
    }

    private func scanBand(_ p: Double) -> some View {
        GeometryReader { geo in
            LinearGradient(colors: [Palette.ink.opacity(0), Palette.ink.opacity(0.09), Palette.ink.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
                .offset(y: -44 + (geo.size.height + 44) * p)
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }

    // MARK: Apoio

    /// Quatro glifos por palavra, como a cifra viva mostra a palavra confirmada (que nao
    /// conta o tamanho dela). So desenho: sai de um contador (SplitMix64).
    static func glyphs(_ index: Int, tick: UInt64) -> String {
        // Palavra e quadro misturados antes de andar: sem isso, cada palavra repetia os
        // glifos da vizinha deslocados de uma casa.
        var x = mix(mix(UInt64(index &+ 1) &* 0xD6E8_FEB8_6659_FD93) ^ tick)
        return String((0..<4).map { _ in
            x = x &+ 0x9E37_79B9_7F4A_7C15
            return alphabet[Int(mix(x) % 16)]
        })
    }

    /// O misturador do SplitMix64.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// O fundo cifrado do cartao: quadradinhos cinza enchendo a area, cada um no seu compasso,
/// sorteados de um contador (so desenho).
private struct PixelCipherStrip: View {
    let index: Int
    let tick: UInt64
    var glow: Double = 0

    var body: some View {
        Canvas { context, size in
            let pitch: CGFloat = 4.4
            let cell: CGFloat = 3.4
            let columns = max(Int((size.width + pitch - cell) / pitch), 1)
            let rows = max(Int((size.height + pitch - cell) / pitch), 1)
            for row in 0..<rows {
                for column in 0..<columns {
                    let id = row * 1000 + column
                    // Cada pixel troca no proprio ritmo: um a cada 1 a 4 quadros.
                    let pace = UInt64(1 + Int(PixelFill.noise(index, id, 0x51) * 4))
                    let tone = 0.12 + 0.3 * PixelFill.noise(index, id, Int(truncatingIfNeeded: tick / pace)) + 0.3 * glow
                    let rect = CGRect(x: CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: cell, height: cell)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(PixelFill.gray(min(tone, 1))))
                }
            }
        }
    }
}
