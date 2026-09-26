import Charts
import EscaliburNetwork
import SwiftUI

/// O grafico de preco no estilo de corretora: linha fina, area que some, sem grade e
/// sem eixo, so maxima e minima, e a referencia do preco de abertura do periodo.
/// Toque longo ou arrasto horizontal mostra o preco de um ponto.
struct PriceChart: View {
    let points: [PricePoint]
    var loading: Bool = false
    @Binding var selection: PricePoint?
    let currency: Fmt.Currency

    private var trend: Color {
        guard let first = points.first?.price, let last = points.last?.price else { return Palette.inkSoft }
        if last > first { return Palette.up }
        if last < first { return Palette.down }
        return Palette.inkSoft
    }

    var body: some View {
        ZStack {
            if loading && points.isEmpty {
                Rectangle().fill(Palette.rail).frame(height: 1.5)
            } else if points.count < 2 {
                Text("Sem histórico de preço neste período").typeStyle(.note).foregroundStyle(Palette.inkMuted)
            } else {
                chart
            }
        }
        .frame(height: 248)
    }

    private var chart: some View {
        let prices = points.map(\.price)
        let low = prices.min() ?? 0
        let high = prices.max() ?? 1
        let pad = (high - low) * 0.08
        let color = trend
        return Chart {
            ForEach(points, id: \.time) { point in
                AreaMark(x: .value("t", point.time), yStart: .value("base", low - pad), yEnd: .value("p", point.price))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.18), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)
                LineMark(x: .value("t", point.time), y: .value("p", point.price))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            if let first = points.first {
                RuleMark(y: .value("abertura", first.price))
                    .foregroundStyle(Palette.edgeStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if let selection {
                RuleMark(x: .value("t", selection.time))
                    .foregroundStyle(Palette.inkMuted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("t", selection.time), y: .value("p", selection.price))
                    .symbolSize(100)
                    .foregroundStyle(color)
            } else if let last = points.last {
                PointMark(x: .value("t", last.time), y: .value("p", last.price))
                    .symbolSize(36)
                    .foregroundStyle(color)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.15)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { value in
                                guard case .second(true, let drag?) = value else { return }
                                let plot = geometry[proxy.plotFrame!]
                                let x = drag.location.x - plot.origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                selection = points.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
                            }
                            .onEnded { _ in withAnimation(Motion.fade) { selection = nil } }
                    )
            }
        }
        .overlay(alignment: .topLeading) { extreme(high, top: true) }
        .overlay(alignment: .bottomLeading) { extreme(low, top: false) }
        .padding(.vertical, 18)
        .sensoryFeedback(.selection, trigger: selection == nil)
        .animation(Motion.crossfade, value: points.count)
    }

    private func extreme(_ value: Double, top: Bool) -> some View {
        GeometryReader { geometry in
            let index = points.firstIndex { $0.price == value } ?? 0
            let x = points.count > 1 ? geometry.size.width * CGFloat(index) / CGFloat(points.count - 1) : 0
            Text(Fmt.price(value, currency))
                .typeStyle(.axis)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize()
                .position(x: min(max(x, 44), geometry.size.width - 44), y: top ? -10 : geometry.size.height + 10)
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
        HStack(spacing: 0) {
            ForEach(ChartRange.allCases) { option in
                Button {
                    withAnimation(Motion.select) { range = option }
                } label: {
                    Text(title(option))
                        .typeStyle(.label)
                        .foregroundStyle(range == option ? Palette.ink : Palette.inkMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: Height.chip)
                        .background {
                            if range == option {
                                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .fill(Palette.rail)
                                    .matchedGeometryEffect(id: "period", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: range)
    }
}
