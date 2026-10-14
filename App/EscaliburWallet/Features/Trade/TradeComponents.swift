import EscaliburEngines
import EscaliburChains
import EscaliburCore
import SwiftUI

/// O logo de quem executa a troca. Com logo embarcado (tools/baixar-logos.py), o logo;
/// sem (LI.FI e De¹ nao tem token), a inicial num disco.
struct ProviderLogo: View {
    let name: String
    var size: CGFloat = 18

    private var assetName: String? {
        let key = name.lowercased()
        for (needle, asset) in [("velora", "provedor-velora"), ("kyber", "provedor-kyberswap"), ("cow", "provedor-cow"), ("jupiter", "provedor-jupiter")]
            where key.contains(needle) { return asset }
        if key.contains("stellar") { return "rede-stellar" }
        if key.contains("xrp") { return "rede-xrpl" }
        return nil
    }

    var body: some View {
        Group {
            if let assetName, let image = UIImage(named: assetName) {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Palette.control))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A rede da troca, num menu: capsula com o selo da rede, o nome e a seta.
struct NetworkMenu: View {
    let chains: [Chain]
    let selected: Chain
    let onSelect: (Chain) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                NetworkBadge(chain: selected, size: 20, ring: .clear)
                Text(selected.name).typeStyle(.label).foregroundStyle(Palette.ink).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.inkSoft)
            }
            .padding(.leading, 6).padding(.trailing, 12)
            .frame(minHeight: 36)
            .background(Capsule(style: .continuous).fill(Palette.body)
                .overlay(Capsule(style: .continuous).strokeBorder(Palette.edge, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rede: \(selected.name)")
        // Lista propria no lugar do Menu do sistema: o Menu nao mostra o logo redondo de
        // cada rede, e escolher rede e justamente reconhecer o logo.
        .popover(isPresented: $open, arrowEdge: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(chains) { chain in
                        Button {
                            open = false
                            onSelect(chain)
                        } label: {
                            HStack(spacing: Space.sm) {
                                NetworkBadge(chain: chain, size: 28, ring: .clear)
                                Text(chain.name).typeStyle(.row).foregroundStyle(Palette.ink)
                                Spacer(minLength: Space.sm)
                                if chain == selected {
                                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                                }
                            }
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowStyle())
                        .accessibilityLabel(chain.name)
                        .accessibilityAddTraits(chain == selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, Space.xs)
            }
            .frame(width: 250)
            .frame(maxHeight: 440)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Palette.body)
        }
    }
}

/// Uma barra que brilha enquanto a cotacao chega: o lugar do numero, sem numero falso.
struct ShimmerBar: View {
    var width: CGFloat = 150
    var height: CGFloat = 26
    @State private var phase: CGFloat = -1

    var body: some View {
        Capsule(style: .continuous)
            .fill(Palette.rail)
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, Palette.edgeStrong.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.6)
                        .offset(x: phase * geometry.size.width)
                }
                .clipShape(Capsule(style: .continuous))
            }
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
            .accessibilityLabel("Buscando cotação")
    }
}

/// Tolerancia de preco num controle deslizante, de 0,1% a 3%.
///
/// O preenchimento e um roxo que ganha forca da esquerda para a direita e cresce com
/// mola ao mudar. Embaixo, o que cada faixa troca: tolerancia maior passa com mercado
/// agitado ou pouca liquidez, e em troca aceita receber menos e atrai robos.
struct SlippageSlider: View {
    @Binding var basisPoints: Int
    /// Com ele, a ponta esquerda do controle e "Auto": a tolerancia sai de
    /// `AutoSlippage` a cada cotacao, e `autoValue` e a de agora.
    var automatic: Binding<Bool>? = nil
    var autoValue: Int = AutoSlippage.floor
    @State private var shown: CGFloat = 0
    @State private var dragging = false

    nonisolated static let range: ClosedRange<Int> = 10...300
    nonisolated static let step = 10
    /// Marcas de referencia, em pontos-base: 0,1%, 0,5%, 1%, 2% e 3%.
    nonisolated static let marks = [10, 50, 100, 200, 300]

    /// As marcas ficam a distancias iguais e a escala e linear entre duas vizinhas: o
    /// trecho baixo, onde a tolerancia importa mais, ganha mais espaco para o dedo.
    nonisolated static func position(_ bps: Int) -> CGFloat {
        let value = Double(min(max(bps, range.lowerBound), range.upperBound))
        let segments = Double(marks.count - 1)
        for index in 0..<(marks.count - 1) where value <= Double(marks[index + 1]) {
            let low = Double(marks[index]), high = Double(marks[index + 1])
            return CGFloat((Double(index) + (value - low) / (high - low)) / segments)
        }
        return 1
    }

    /// O inverso de `position`, ja no passo de 0,1%.
    nonisolated static func value(at ratio: Double) -> Int {
        let x = min(max(ratio, 0), 1) * Double(marks.count - 1)
        let index = min(Int(x), marks.count - 2)
        let raw = Double(marks[index]) + (x - Double(index)) * Double(marks[index + 1] - marks[index])
        let snapped = Int((raw / Double(step)).rounded()) * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    static func label(_ bps: Int) -> String {
        "\(Fmt.grouped(Double(bps) / 100, fractionDigits: 2, trimZeros: true))%"
    }

    private var isAuto: Bool { automatic?.wrappedValue == true }
    /// A tolerancia que vale agora: a automatica ou a escolhida.
    private var effective: Int { isAuto ? autoValue : basisPoints }

    private var fraction: CGFloat { isAuto ? 0 : Self.position(basisPoints) }

    private func markLabel(_ mark: Int) -> String {
        automatic != nil && mark == Self.marks.first ? "Auto" : Self.label(mark)
    }

    private var percentText: String {
        isAuto ? "Auto · \(Self.label(autoValue))" : Self.label(basisPoints)
    }

    /// Muda para o valor do controle; a ponta esquerda, com o automatico disponivel, e
    /// "Auto".
    private func choose(_ value: Int) {
        if let automatic, value <= Self.range.lowerBound {
            automatic.wrappedValue = true
        } else {
            automatic?.wrappedValue = false
            basisPoints = value
        }
    }

    private var explanation: String {
        if isAuto {
            return "Automática: a menor tolerância que costuma passar para este par, agora \(Self.label(autoValue)). Recalculada a cada cotação: entre stablecoins fica perto de 0,1%; moeda de pouca liquidez ou dia agitado ganha mais folga."
        }
        switch basisPoints {
        case ..<30:
            return "Protege mais o preço, mas a troca pode falhar se o mercado se mexer, e a taxa da rede é cobrada mesmo assim."
        case ..<101:
            return "Equilíbrio: passa na maioria das trocas sem deixar espaço grande para robôs."
        default:
            return "Passa mesmo com o mercado agitado ou com pouca liquidez. Em troca, você aceita receber até \(percentText) a menos, e robôs podem explorar essa diferença."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("Tolerância de preço").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                Spacer()
                Text(percentText).typeStyle(.row).foregroundStyle(Palette.ink)
                    .contentTransition(.numericText(value: Double(basisPoints)))
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                let knob: CGFloat = dragging ? 30 : 24
                let fill = effective > 100 ? Palette.caution : Palette.ink
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Palette.rail).frame(height: 6)
                    Capsule(style: .continuous)
                        .fill(fill)
                        .frame(width: max(6, shown * width), height: 6)
                    // As marcas de referencia, sobre o trilho.
                    ForEach(Self.marks, id: \.self) { mark in
                        Circle()
                            .fill(mark <= basisPoints ? Palette.void.opacity(0.35) : Palette.edgeStrong)
                            .frame(width: 4, height: 4)
                            .offset(x: Self.position(mark) * width - 2)
                    }
                    Circle()
                        .fill(Palette.ink)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                        .offset(x: max(0, min(width - knob, shown * width - knob / 2)))
                }
                .frame(height: 34)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Arrastando, o botao fica embaixo do dedo, sem animacao: a mola
                            // que segue o valor deixava o botao atrasado (relatado no iPhone).
                            let ratio = min(max(value.location.x / width, 0), 1)
                            var instant = Transaction()
                            instant.disablesAnimations = true
                            withTransaction(instant) {
                                dragging = true
                                shown = ratio
                            }
                            choose(Self.value(at: Double(ratio)))
                        }
                        .onEnded { _ in
                            // Ao soltar, assenta no passo de 0,1% escolhido.
                            withAnimation(.easeOut(duration: 0.12)) {
                                dragging = false
                                shown = fraction
                            }
                        }
                )
            }
            .frame(height: 34)
            // Os rotulos das marcas: tocar leva direto ao valor.
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(Self.marks, id: \.self) { mark in
                        Button { choose(mark) } label: {
                            Text(markLabel(mark))
                                .typeStyle(.note)
                                .foregroundStyle((isAuto ? mark == Self.marks.first : mark == basisPoints) ? Palette.ink : Palette.inkMuted)
                                .fixedSize()
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.leading) { d in
                            let x = Self.position(mark) * width
                            // A primeira e a ultima ficam dentro da borda.
                            if mark == Self.marks.first { return 0 }
                            if mark == Self.marks.last { return d.width - width }
                            return d.width / 2 - x
                        }
                        .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 24)
            Text(explanation).typeStyle(.note).foregroundStyle(effective > 100 ? Palette.caution : Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .animation(Motion.fade, value: explanation)
        }
        .onAppear {
            // O preenchimento entra correndo da esquerda ate o valor.
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.1)) { shown = fraction }
        }
        .onChange(of: basisPoints) { _, _ in
            // So o toque numa marca anima; o arrasto ja posicionou o botao.
            guard !dragging else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { shown = fraction }
        }
        .onChange(of: isAuto) { _, _ in
            guard !dragging else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { shown = fraction }
        }
        .sensoryFeedback(.selection, trigger: basisPoints)
        .sensoryFeedback(.selection, trigger: isAuto)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tolerância de preço")
        .accessibilityValue(percentText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: choose(isAuto ? Self.range.lowerBound + Self.step : min(basisPoints + Self.step, Self.range.upperBound))
            case .decrement: choose(isAuto ? Self.range.lowerBound : max(basisPoints - Self.step, Self.range.lowerBound))
            @unknown default: break
            }
        }
    }
}

/// Enquanto a troca (ou o cancelamento) e montada ou enviada: as duas moedas nas pontas
/// de um arco, e um cometa rosa com rastro correndo de uma para a outra. Quando ele chega,
/// uma onda sai da moeda de destino. No cancelamento o cometa volta para a moeda vendida
/// (o valor fica na carteira) e a outra fica apagada.
///
/// Tudo sai de um relogio de quadros (`TimelineView` com `Canvas`), sem animacao
/// implicita: a que repete para sempre, ligada no `onAppear`, pegava carona na transicao
/// da tela e fazia o desenho inteiro deslizar. Cores chapadas, sem brilho.
struct SwapProcessingIndicator: View {
    let sell: Asset?
    let buy: Asset?
    var cancelling = false
    /// No envio nao ha moeda do outro lado: o destino e este simbolo num circulo.
    var destinationSymbol: String? = nil

    static let period = 1.6
    static let logoSize: CGFloat = 56
    static let width: CGFloat = 280
    /// Quanto o topo do arco fica acima do centro das moedas.
    static let rise: CGFloat = 68
    /// Folga acima do arco para a cabeca do cometa.
    static let headroom: CGFloat = 8
    /// A caixa vai do topo do arco ao pe das moedas: centralizar a figura centraliza o
    /// que se ve, sem vazio em cima.
    static let height = headroom + rise + logoSize / 2
    /// A onda de chegada passa da caixa; o desenho tem esta sobra em volta, fora do layout.
    static let bleed: CGFloat = 24

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let cycle = time.truncatingRemainder(dividingBy: Self.period) / Self.period
            let inset = Self.logoSize / 2
            let base = Self.bleed + Self.headroom + Self.rise
            let start = CGPoint(x: Self.bleed + inset, y: base)
            let end = CGPoint(x: Self.bleed + Self.width - inset, y: base)
            // O topo de uma curva quadratica simetrica fica na metade do caminho ate o controle.
            let control = CGPoint(x: Self.bleed + Self.width / 2, y: base - 2 * Self.rise)
            ZStack {
                Canvas { context, _ in
                    var arc = Path()
                    arc.move(to: start)
                    arc.addQuadCurve(to: end, control: control)
                    context.stroke(arc, with: .color(Palette.edgeStrong), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 6]))
                    Self.drawComet(context, cycle: cycle, start: start, control: control, end: end, cancelling: cancelling)
                }
                logo(sell)
                    .scaleEffect(1 + 0.03 * CGFloat(sin(time * 2 * .pi / 2.2)))
                    .position(start)
                Group {
                    if let destinationSymbol, buy == nil { destination(destinationSymbol) } else { logo(buy) }
                }
                    .scaleEffect(1 + 0.03 * CGFloat(sin(time * 2 * .pi / 2.2 + .pi)))
                    .opacity(cancelling ? 0.35 : 1)
                    .position(end)
            }
            .frame(width: Self.width + 2 * Self.bleed, height: Self.height + 2 * Self.bleed)
            .padding(-Self.bleed)
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityHidden(true)
    }

    /// Ponto do arco em `t` (0 na moeda vendida, 1 na comprada).
    static func point(_ t: Double, _ start: CGPoint, _ control: CGPoint, _ end: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }

    /// Sai devagar, corre no meio, chega devagar.
    static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    static func drawComet(_ context: GraphicsContext, cycle: Double, start: CGPoint, control: CGPoint, end: CGPoint, cancelling: Bool) {
        // O cometa corre nos primeiros 80% do ciclo; a onda ocupa o resto.
        let travel = min(1, cycle / 0.8)
        // Na troca, da moeda vendida para a comprada; no cancelamento, do meio do
        // caminho de volta para a vendida.
        let head = cancelling ? 0.7 * (1 - ease(travel)) : ease(travel)
        let direction = cancelling ? 1.0 : -1.0
        if cycle < 0.8 {
            for k in 0..<14 {
                let t = head + direction * Double(k) * 0.022
                guard (0...1).contains(t) else { continue }
                let center = point(t, start, control, end)
                let radius = max(1, 5.5 - CGFloat(k) * 0.35)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Palette.accent.opacity(1 - Double(k) / 14)))
            }
        } else {
            let wave = (cycle - 0.8) / 0.2
            let target = cancelling ? start : end
            let radius = logoSize / 2 + 2 + CGFloat(wave) * 16
            let rect = CGRect(x: target.x - radius, y: target.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(Palette.accent.opacity(1 - wave)), lineWidth: 2)
        }
    }

    private func destination(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.ink)
            .frame(width: Self.logoSize, height: Self.logoSize)
            .background(Circle().fill(Palette.rail))
            .overlay(Circle().stroke(Palette.edgeStrong, lineWidth: 1))
    }

    private func logo(_ asset: Asset?) -> some View {
        let unverified = asset?.origin != nil
        return CoinLogo(coingeckoID: asset?.coingeckoID, symbol: asset?.symbol ?? "", size: Self.logoSize, network: asset?.chain,
                        ringColor: Palette.void, unverified: unverified, logoAsset: unverified ? asset : nil)
    }
}

/// A troca na revisao: a moeda que sai, uma seta, a que entra, com os valores do plano.
struct TradeDirectionHeader: View {
    let sell: Asset?
    let buy: Asset?
    let sellAmount: BigUInt?
    let buyMinimum: BigUInt?

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            side(sell, amount: sellAmount, prefix: "")
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                .frame(width: 36, height: 52)
            side(buy, amount: buyMinimum, prefix: "no mínimo ")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func side(_ asset: Asset?, amount: BigUInt?, prefix: String) -> some View {
        let unverified = asset?.origin != nil
        return VStack(spacing: Space.xs) {
            CoinLogo(coingeckoID: asset?.coingeckoID, symbol: asset?.symbol ?? "", size: 52, network: asset?.chain,
                     unverified: unverified, logoAsset: unverified ? asset : nil)
            if let asset, let amount {
                Text(prefix + Fmt.crypto(amount, decimals: asset.decimals, symbol: asset.symbol))
                    .typeStyle(.note).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// O que pode ir para a troca. A lista conferida, em toda rede com troca; e, nas redes
/// EVM e na Solana, o token fora da lista que a carteira tem (sem suspeita) e a moeda
/// que o dono adicionou: se os provedores tem rota, a troca existe. O motor confere as
/// casas na rede e simula em duas fontes antes de qualquer assinatura.
enum TradeAccess {
    static func supportsUnlisted(_ chain: Chain) -> Bool {
        (chain.family == .evm || chain.family == .solana) && TradeEngines.engine(for: chain) != nil
    }

    static func allows(_ asset: Asset) -> Bool {
        guard let chain = asset.chain, TradeEngines.engine(for: chain) != nil else { return false }
        return asset.origin == nil || supportsUnlisted(chain)
    }
}

/// O selo de "ordem criada": um circulo que gira no eixo vertical como uma moeda jogada,
/// com a logo da moeda da ordem de um lado e o checkmark em verde do outro (pedido do
/// dono, 14/10/2026). Gira rapido tres
/// vezes ao aparecer e depois vira devagar de tempos em tempos. Com "reduzir movimento",
/// fica parado no checkmark.
struct CoinFlipBadge: View {
    let asset: Asset?
    var size: CGFloat = 112
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    /// O lado de cima e o da logo quando o angulo esta perto de 0, 360, 720...
    private var showsCoin: Bool {
        let turn = angle.truncatingRemainder(dividingBy: 360)
        return turn < 90 || turn > 270
    }

    var body: some View {
        ZStack {
            Circle().fill(Palette.body)
                .overlay(Circle().stroke(Palette.edgeStrong, lineWidth: 1))
            if showsCoin {
                if let asset {
                    CoinLogo(coingeckoID: asset.coingeckoID, symbol: asset.symbol, size: size * 0.72, network: asset.chain,
                             ringColor: Palette.body, unverified: asset.origin != nil, logoAsset: asset.origin != nil ? asset : nil)
                }
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Palette.onLime)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Palette.up))
                    // O verso de um giro em Y aparece espelhado: desfaz o espelho.
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .frame(width: size, height: size)
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .shadow(color: Palette.up.opacity(showsCoin ? 0 : 0.3), radius: 24)
        .accessibilityElement()
        .accessibilityLabel("Concluído")
        .task {
            guard !reduceMotion else {
                angle = 180
                return
            }
            // Jogada: tres voltas e meia, terminando no checkmark.
            withAnimation(.timingCurve(0.2, 0.8, 0.25, 1, duration: 1.6)) { angle = 1080 + 180 }
            try? await Task.sleep(for: .seconds(2.6))
            // Depois, vira devagar: mostra a moeda, volta ao checkmark.
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.7)) { angle += 180 }
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.7)) { angle += 180 }
                try? await Task.sleep(for: .seconds(3.2))
            }
        }
    }
}
