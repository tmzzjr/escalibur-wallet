import Charts
import EscaliburNetwork
import SwiftUI

/// O grafico de preco no estilo de corretora: linha fina, area que some, sem grade e
/// sem eixo, so maxima e minima, e a referencia do preco de abertura do periodo.
/// Toque longo ou arrasto horizontal mostra o preco de um ponto.
struct PriceChart: View {
    let points: [PricePoint]
    var loading: Bool = false
    /// Stablecoin: a escala tem piso de 2% do preco medio, senao 0,3% de oscilacao
    /// vira sismografo.
    var isStable: Bool = false
    @Binding var selection: PricePoint?
    let currency: Fmt.Currency

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// No maximo 120 pontos, pela media de cada balde: o dado cru de 24h tem 288,
    /// mais do que 248pt de largura mostram, e o excesso so desenha ruido.
    private var shown: [PricePoint] {
        guard points.count > 120 else { return points }
        let size = Double(points.count) / 120
        return (0..<120).compactMap { bucket in
            let start = Int(Double(bucket) * size)
            let end = min(points.count, Int(Double(bucket + 1) * size))
            guard start < end else { return nil }
            let slice = points[start..<end]
            let average = slice.reduce(0) { $0 + $1.price } / Double(slice.count)
            return PricePoint(time: slice.last!.time, price: bucket == 119 ? points.last!.price : average)
        }
    }

    private var trend: Color {
        guard let first = points.first?.price, let last = points.last?.price else { return Palette.inkSoft }
        if last > first { return Palette.up }
        if last < first { return Palette.down }
        return Palette.inkSoft
    }

    var body: some View {
        ZStack {
            if loading && points.isEmpty {
                RoundedRectangle(cornerRadius: Radius.badge).fill(Palette.body).padding(.vertical, 18)
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
        let pad = (high - low) * 0.08
        return (low - pad)...(high + pad)
    }

    private var chart: some View {
        let data = shown
        let color = trend
        let range = domain
        return Chart {
            ForEach(data, id: \.time) { point in
                AreaMark(x: .value("t", point.time), yStart: .value("base", range.lowerBound), yEnd: .value("p", point.price))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.18), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)
                LineMark(x: .value("t", point.time), y: .value("p", point.price))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            if let first = data.first {
                RuleMark(y: .value("abertura", first.price))
                    .foregroundStyle(Palette.edgeStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if let selection {
                RuleMark(x: .value("t", selection.time))
                    .foregroundStyle(Palette.inkMuted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("t", selection.time), y: .value("p", selection.price))
                    .symbol { Circle().fill(color).frame(width: 10, height: 10).overlay(Circle().stroke(Palette.void, lineWidth: 2)) }
            } else if let last = data.last {
                PointMark(x: .value("t", last.time), y: .value("p", last.price))
                    .symbol { PulseDot(color: color, animated: !reduceMotion) }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: range)
        .chartXScale(range: .plotDimension(endPadding: 8))
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.15)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { value in
                                guard case .second(true, let drag?) = value, let frame = proxy.plotFrame else { return }
                                let x = drag.location.x - geometry[frame].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                selection = data.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
                            }
                            .onEnded { _ in withAnimation(Motion.fade) { selection = nil } }
                    )
            }
        }
        .overlay(alignment: .topLeading) { extreme(data.map(\.price).max() ?? 0, top: true, data: data) }
        .overlay(alignment: .bottomLeading) { extreme(data.map(\.price).min() ?? 0, top: false, data: data) }
        .padding(.vertical, 18)
        .sensoryFeedback(.selection, trigger: selection?.time)
        .animation(Motion.crossfade, value: data.count)
    }

    private func extreme(_ value: Double, top: Bool, data: [PricePoint]) -> some View {
        let prices = data.map(\.price)
        let amplitude = ((prices.max() ?? 0) - (prices.min() ?? 0)) / max(prices.max() ?? 1, .ulpOfOne)
        return GeometryReader { geometry in
            let index = data.firstIndex { $0.price == value } ?? 0
            let x = data.count > 1 ? geometry.size.width * CGFloat(index) / CGFloat(data.count - 1) : 0
            Text(amplitude < 0.01 ? "\(currency.symbol)\(Fmt.nbsp)\(Fmt.grouped(value, fractionDigits: 4))" : Fmt.price(value, currency))
                .typeStyle(.axis)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize()
                .position(x: min(max(x, 44), geometry.size.width - 44), y: top ? -10 : geometry.size.height + 10)
        }
    }
}

/// O ultimo ponto, com um anel que respira devagar. Desliga com reduzir movimento.
private struct PulseDot: View {
    let color: Color
    let animated: Bool
    @State private var expanded = false

    var body: some View {
        ZStack {
            if animated {
                Circle().stroke(color, lineWidth: 1.5)
                    .frame(width: expanded ? 16 : 6, height: expanded ? 16 : 6)
                    .opacity(expanded ? 0 : 0.35)
            }
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expanded = true }
        }
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
                        .foregroundStyle(range == option ? Palette.ink : Palette.inkMuted)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 34)
                        .background {
                            if range == option {
                                Capsule(style: .continuous)
                                    .fill(Palette.control)
                                    .overlay(Capsule(style: .continuous).strokeBorder(Palette.edgeStrong, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "period", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(range == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Palette.body))
        .sensoryFeedback(.selection, trigger: range)
    }
}
