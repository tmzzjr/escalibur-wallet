import EscaliburChains
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
        "\(Fmt.grouped(Double(bps) / 100, fractionDigits: 1, trimZeros: true))%"
    }

    private var fraction: CGFloat { Self.position(basisPoints) }

    private var percentText: String {
        "\(Fmt.grouped(Double(basisPoints) / 100, fractionDigits: 1, trimZeros: true))%"
    }

    private var explanation: String {
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
                let fill = basisPoints > 100 ? Palette.caution : Palette.ink
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
                            basisPoints = Self.value(at: Double(ratio))
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
                        Button { basisPoints = mark } label: {
                            Text(Self.label(mark))
                                .typeStyle(.note)
                                .foregroundStyle(mark == basisPoints ? Palette.ink : Palette.inkMuted)
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
            Text(explanation).typeStyle(.note).foregroundStyle(basisPoints > 100 ? Palette.caution : Palette.inkMuted)
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
        .sensoryFeedback(.selection, trigger: basisPoints)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tolerância de preço")
        .accessibilityValue(percentText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: basisPoints = min(basisPoints + Self.step, Self.range.upperBound)
            case .decrement: basisPoints = max(basisPoints - Self.step, Self.range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// Enquanto a troca e montada ou enviada: a moeda que sai, a que entra, e um ponto
/// correndo entre as duas pelo caminho tracejado.
struct SwapProcessingIndicator: View {
    let sell: Asset?
    let buy: Asset?
    @State private var progress: CGFloat = 0
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 0) {
            logo(sell)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                    }
                    .stroke(Palette.edgeStrong, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6]))
                    Circle()
                        .fill(Palette.purple)
                        .frame(width: 10, height: 10)
                        .offset(x: progress * (geometry.size.width - 10))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 44)
            .padding(.horizontal, Space.sm)
            logo(buy)
        }
        .frame(maxWidth: 260)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { progress = 1 }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityHidden(true)
    }

    private func logo(_ asset: Asset?) -> some View {
        CoinLogo(coingeckoID: asset?.coingeckoID, symbol: asset?.symbol ?? "", size: 44, network: asset?.chain)
            .scaleEffect(pulse ? 1.04 : 0.96)
    }
}
