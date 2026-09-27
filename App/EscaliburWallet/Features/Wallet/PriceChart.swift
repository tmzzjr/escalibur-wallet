import EscaliburNetwork
import SwiftUI

/// O grafico de preco: linha grossa com brilho, a area embaixo em pontinhos, sem grade
/// e sem eixo, so a maxima em cima do pico e a minima embaixo do vale. Lima quando o
/// periodo sobe, vermelho quando desce. Toque longo ou arrasto horizontal mostra o
/// preco de um ponto.
struct PriceChart: View {
    let points: [PricePoint]
    var loading: Bool = false
    /// Stablecoin: a escala tem piso de 2% do preco medio, senao 0,3% de oscilacao
    /// vira sismografo.
    var isStable: Bool = false
    @Binding var selection: PricePoint?
    let currency: Fmt.Currency

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Espaco acima e abaixo da linha para os rotulos de maxima e minima.
    private static let labelRoom: CGFloat = 26

    /// No maximo 160 pontos, pela media de cada balde: o dado cru de 24h tem 288, mais
    /// do que a largura mostra, e o excesso so desenha ruido.
    private var shown: [PricePoint] {
        guard points.count > 160 else { return points }
        let size = Double(points.count) / 160
        return (0..<160).compactMap { bucket in
            let start = Int(Double(bucket) * size)
            let end = min(points.count, Int(Double(bucket + 1) * size))
            guard start < end else { return nil }
            let slice = points[start..<end]
            let average = slice.reduce(0) { $0 + $1.price } / Double(slice.count)
            return PricePoint(time: slice.last!.time, price: bucket == 159 ? points.last!.price : average)
        }
    }

    private var trend: Color {
        guard let first = points.first?.price, let last = points.last?.price else { return Palette.inkSoft }
        if last > first { return Palette.lime }
        if last < first { return Palette.down }
        return Palette.inkSoft
    }

    var body: some View {
        ZStack {
            if loading && points.isEmpty {
                RoundedRectangle(cornerRadius: Radius.badge).fill(Palette.body).padding(.vertical, Self.labelRoom)
                    .opacity(reduceMotion ? 0.7 : 1)
            } else if points.count < 2 {
                Text("Sem histórico de preço neste período").typeStyle(.note).foregroundStyle(Palette.inkMuted)
            } else {
                chart
            }
        }
        .frame(height: 248)
    }

    private var domain: ClosedRange<Double> {
        let prices = shown.map(\.price)
        var low = prices.min() ?? 0
        var high = prices.max() ?? 1
        if isStable {
            let mean = prices.reduce(0, +) / Double(max(prices.count, 1))
            low = min(low, mean * 0.99)
            high = max(high, mean * 1.01)
        }
        if high <= low { high = low + max(abs(low) * 0.01, .ulpOfOne) }
        return low...high
    }

    private var chart: some View {
        let data = shown
        let color = trend
        let range = domain
        return GeometryReader { geometry in
            // Margem dos lados: a linha e o brilho nao encostam na borda da tela.
            let plot = CGRect(x: Space.gutter, y: Self.labelRoom, width: geometry.size.width - Space.gutter * 2,
                              height: geometry.size.height - Self.labelRoom * 2)
            let place: (Int) -> CGPoint = { index in
                let x = data.count > 1 ? plot.minX + plot.width * CGFloat(index) / CGFloat(data.count - 1) : plot.midX
                let fraction = (data[index].price - range.lowerBound) / (range.upperBound - range.lowerBound)
                return CGPoint(x: x, y: plot.maxY - plot.height * CGFloat(fraction))
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var line = Path()
                    for index in data.indices {
                        index == 0 ? line.move(to: place(index)) : line.addLine(to: place(index))
                    }
                    // A area embaixo da linha, em pontinhos da mesma cor.
                    var area = line
                    area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                    area.closeSubpath()
                    context.drawLayer { dots in
                        dots.clip(to: area)
                        let step: CGFloat = 6.5
                        var grid = Path()
                        var y = plot.maxY
                        while y >= plot.minY - step {
                            var x = plot.minX + step / 2
                            while x <= plot.maxX {
                                grid.addEllipse(in: CGRect(x: x - 0.85, y: y - 0.85, width: 1.7, height: 1.7))
                                x += step
                            }
                            y -= step
                        }
                        dots.fill(grid, with: .color(color.opacity(0.7)))
                    }
                    // O brilho: a linha larga e desfocada por baixo da linha nitida.
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: 14))
                        glow.stroke(line, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                    }
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                    if let selection, let index = data.firstIndex(where: { $0.time == selection.time }) {
                        let point = place(index)
                        var rule = Path()
                        rule.move(to: CGPoint(x: point.x, y: plot.minY))
                        rule.addLine(to: CGPoint(x: point.x, y: plot.maxY))
                        context.stroke(rule, with: .color(Palette.inkMuted), lineWidth: 1)
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)), with: .color(Palette.void))
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)), with: .color(color))
                    }
                }
                extremeLabel(data: data, top: true, place: place, width: geometry.size.width)
                extremeLabel(data: data, top: false, place: place, width: geometry.size.width)
            }
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.15)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard case .second(true, let drag?) = value, data.count > 1 else { return }
                        let fraction = min(max((drag.location.x - plot.minX) / max(plot.width, 1), 0), 1)
                        selection = data[Int((fraction * CGFloat(data.count - 1)).rounded())]
                    }
                    .onEnded { _ in withAnimation(Motion.fade) { selection = nil } }
            )
        }
        .sensoryFeedback(.selection, trigger: selection?.time)
        .accessibilityElement()
        .accessibilityLabel("Gráfico de preço")
        .accessibilityValue(accessibilitySummary(data))
    }

    /// A maxima em cima do pico, a minima embaixo do vale, sem sair da tela.
    private func extremeLabel(data: [PricePoint], top: Bool, place: (Int) -> CGPoint, width: CGFloat) -> some View {
        let prices = data.map(\.price)
        let target = top ? (prices.max() ?? 0) : (prices.min() ?? 0)
        let index = data.firstIndex { $0.price == target } ?? 0
        let point = place(index)
        return Text(priceText(target, prices: prices))
            .typeStyle(.axis)
            .foregroundStyle(Palette.inkSoft)
            .fixedSize()
            .position(x: min(max(point.x, 48), width - 48), y: top ? point.y - 16 : point.y + 16)
    }

    private func priceText(_ value: Double, prices: [Double]) -> String {
        let amplitude = ((prices.max() ?? 0) - (prices.min() ?? 0)) / max(prices.max() ?? 1, .ulpOfOne)
        return amplitude < 0.01 ? "\(currency.symbol)\(Fmt.nbsp)\(Fmt.grouped(value, fractionDigits: 4))" : Fmt.price(value, currency)
    }

    private func accessibilitySummary(_ data: [PricePoint]) -> String {
        let prices = data.map(\.price)
        guard let low = prices.min(), let high = prices.max() else { return "" }
        return "Mínima \(priceText(low, prices: prices)), máxima \(priceText(high, prices: prices))"
    }
}

/// Os periodos, por extenso: "1M" e ambiguo entre minuto e mes.
struct PeriodPicker: View {
    @Binding var range: ChartRange
    @Namespace private var namespace

    private func title(_ range: ChartRange) -> String {
        switch range {
        case .day: return "24h"
        case .week: return "7 dias"
        case .month: return "30 dias"
        case .year: return "1 ano"
        case .all: return "Tudo"
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { option in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { range = option }
                } label: {
                    Text(title(option))
                        .typeStyle(.label)
                        .fontWeight(range == option ? .semibold : .regular)
                        .foregroundStyle(range == option ? Palette.ink : Palette.inkMuted)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 38)
                        .background {
                            if range == option {
                                Capsule(style: .continuous)
                                    .fill(Palette.control)
                                    .matchedGeometryEffect(id: "period", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(range == option ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: range)
    }
}
