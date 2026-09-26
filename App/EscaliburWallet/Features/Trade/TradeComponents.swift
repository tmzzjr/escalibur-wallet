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

    var body: some View {
        Menu {
            ForEach(chains) { chain in
                Button {
                    onSelect(chain)
                } label: {
                    if chain == selected { Label(chain.name, systemImage: "checkmark") } else { Text(chain.name) }
                }
            }
        } label: {
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
        .accessibilityLabel("Rede: \(selected.name)")
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

    static let range: ClosedRange<Int> = 10...300
    static let step = 10

    private var fraction: CGFloat {
        CGFloat(basisPoints - Self.range.lowerBound) / CGFloat(Self.range.upperBound - Self.range.lowerBound)
    }

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
                let knob: CGFloat = dragging ? 26 : 22
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Palette.rail).frame(height: 8)
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Palette.purpleDeep, Palette.purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, shown * width), height: 8)
                    Circle()
                        .fill(Palette.ink)
                        .frame(width: knob, height: knob)
                        .overlay(Circle().strokeBorder(Palette.purple, lineWidth: 3))
                        .offset(x: max(0, min(width - knob, shown * width - knob / 2)))
                }
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            let ratio = min(max(value.location.x / width, 0), 1)
                            let raw = Double(Self.range.lowerBound) + ratio * Double(Self.range.upperBound - Self.range.lowerBound)
                            let snapped = Int((raw / Double(Self.step)).rounded()) * Self.step
                            basisPoints = min(max(snapped, Self.range.lowerBound), Self.range.upperBound)
                        }
                        .onEnded { _ in withAnimation(Motion.select) { dragging = false } }
                )
            }
            .frame(height: 30)
            Text(explanation).typeStyle(.note).foregroundStyle(basisPoints > 100 ? Palette.caution : Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .animation(Motion.fade, value: explanation)
        }
        .onAppear {
            // O preenchimento entra correndo da esquerda ate o valor.
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.1)) { shown = fraction }
        }
        .onChange(of: basisPoints) { _, _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { shown = fraction }
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
