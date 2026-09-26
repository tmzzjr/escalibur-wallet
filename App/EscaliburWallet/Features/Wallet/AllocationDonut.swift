import Charts
import SwiftUI

/// Onde esta o saldo: uma rosca com a fatia de cada ativo na cor do proprio logo, e a
/// legenda ao lado com a porcentagem. Os cinco maiores aparecem por nome; o resto vira
/// "Outros". Tocar numa fatia destaca o ativo no centro.
struct AllocationDonut: View {
    let rows: [PortfolioRow]
    var hidden: Bool = false
    @State private var selectedAngle: Double?

    struct Slice: Identifiable {
        let id: String
        let symbol: String
        let value: Double
        let color: Color
        let coingeckoID: String?
    }

    private var slices: [Slice] {
        let valued = rows.compactMap { row -> Slice? in
            guard let value = row.fiatValue, value > 0 else { return nil }
            return Slice(id: row.id, symbol: row.symbol, value: value, color: LogoColor.dominant(for: row.coingeckoID), coingeckoID: row.coingeckoID)
        }
        .sorted { $0.value > $1.value }
        guard valued.count > 6 else { return valued }
        let rest = valued.dropFirst(5).reduce(0) { $0 + $1.value }
        return Array(valued.prefix(5)) + [Slice(id: "outros", symbol: "Outros", value: rest, color: Palette.inkDead, coingeckoID: nil)]
    }

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    private var selected: Slice? {
        guard let selectedAngle else { return nil }
        var running = 0.0
        for slice in slices {
            running += slice.value
            if selectedAngle <= running { return slice }
        }
        return nil
    }

    var body: some View {
        let slices = self.slices
        if slices.count >= 2, total > 0 {
            HStack(alignment: .center, spacing: Space.lg) {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Valor", slice.value),
                        innerRadius: .ratio(0.64),
                        outerRadius: .ratio(selected?.id == slice.id ? 1.0 : 0.94),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(slice.color)
                    .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.35)
                }
                .chartLegend(.hidden)
                .chartAngleSelection(value: $selectedAngle)
                .frame(width: 132, height: 132)
                .overlay {
                    VStack(spacing: 0) {
                        if let selected {
                            Text(selected.symbol).typeStyle(.label).foregroundStyle(Palette.inkSoft)
                            Text(hidden ? "••" : Self.percent(selected.value / total)).typeStyle(.row).foregroundStyle(Palette.ink)
                        } else {
                            Text("\(rows.count)").typeStyle(.row).foregroundStyle(Palette.ink)
                            Text(rows.count == 1 ? "ativo" : "ativos").typeStyle(.label).foregroundStyle(Palette.inkSoft)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .animation(Motion.select, value: selected?.id)

                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(slices) { slice in
                        HStack(spacing: Space.xs) {
                            Circle().fill(slice.color).frame(width: 8, height: 8)
                            Text(slice.symbol).typeStyle(.note).foregroundStyle(Palette.ink).lineLimit(1)
                            Spacer(minLength: Space.xs)
                            Text(hidden ? "••" : Self.percent(slice.value / total))
                                .typeStyle(.note).foregroundStyle(Palette.inkSoft).monospacedDigit()
                        }
                        .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.4)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(slices.map { "\($0.symbol) \(Self.percent($0.value / total))" }.joined(separator: ", "))
        }
    }

    static func percent(_ share: Double) -> String {
        let value = share * 100
        return value < 0.1 ? "< 0,1%" : "\(Fmt.grouped(value, fractionDigits: value < 10 ? 1 : 0, trimZeros: true))%"
    }
}
