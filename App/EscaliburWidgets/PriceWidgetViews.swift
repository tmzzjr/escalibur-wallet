import SwiftUI
import UIKit
import WidgetKit

/// O que o widget desenha, separado da configuracao: o app compila este arquivo tambem,
/// para a tela de teste `-tela widgets` (DEBUG) mostrar os cinco tamanhos.
struct PriceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let logo: UIImage?
}

/// As cores do app, so as que o widget usa.
enum WidgetColor {
    static let void = Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255)
    static let ink = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF6 / 255)
    static let inkSoft = Color(red: 0xA8 / 255, green: 0xA8 / 255, blue: 0xAE / 255)
    static let inkMuted = Color(red: 0x8A / 255, green: 0x8A / 255, blue: 0x92 / 255)
    static let up = Color(red: 0xC4 / 255, green: 0xF1 / 255, blue: 0x35 / 255)
    static let down = Color(red: 0xFF / 255, green: 0x4D / 255, blue: 0x3D / 255)
    static let brand = Color(red: 0xFF / 255, green: 0x00 / 255, blue: 0x7B / 255)
}

struct PriceWidgetView: View {
    let entry: PriceEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryInline: inline(snapshot)
                case .accessoryCircular: circular(snapshot)
                case .accessoryRectangular: rectangular(snapshot)
                case .systemMedium: medium(snapshot)
                default: small(snapshot)
                }
            } else {
                empty
            }
        }
    }

    private func trend(_ snapshot: WidgetSnapshot) -> Color {
        guard let change = snapshot.change, change != 0 else { return WidgetColor.inkSoft }
        return change > 0 ? WidgetColor.up : WidgetColor.down
    }

    private func arrow(_ snapshot: WidgetSnapshot) -> String {
        guard let change = snapshot.change, change != 0 else { return "minus" }
        return change > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    // MARK: Tela bloqueada

    private func inline(_ snapshot: WidgetSnapshot) -> some View {
        Label {
            Text(verbatim: "\(snapshot.symbol) \(snapshot.shortPriceText) \(snapshot.changeText)")
        } icon: {
            Image(systemName: arrow(snapshot))
        }
    }

    private func circular(_ snapshot: WidgetSnapshot) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Text(verbatim: snapshot.symbol).font(.system(size: 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                WidgetSparkline(points: snapshot.points, lineWidth: 1.5, filled: false)
                    .frame(height: 13)
                    .padding(.horizontal, 9)
                    .widgetAccentable()
                Text(verbatim: snapshot.changeText).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.vertical, 6)
        }
    }

    private func rectangular(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(verbatim: snapshot.symbol).font(.system(size: 14, weight: .bold))
                    Image(systemName: arrow(snapshot)).font(.system(size: 10, weight: .bold))
                    Text(verbatim: snapshot.changeText).font(.system(size: 12, weight: .semibold))
                }
                .lineLimit(1)
                .widgetAccentable()
                Text(verbatim: snapshot.shortPriceText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
            }
            Spacer(minLength: 0)
            WidgetSparkline(points: snapshot.points, lineWidth: 1.8, filled: false)
                .frame(width: 46, height: 30)
        }
    }

    // MARK: Tela de inicio

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            if let logo = entry.logo {
                Image(uiImage: logo).resizable().scaledToFit().frame(width: 22, height: 22).clipShape(Circle())
            } else {
                Text(verbatim: String(snapshot.symbol.prefix(1)))
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(WidgetColor.ink)
                    .frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.12)))
            }
            Text(verbatim: snapshot.symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(WidgetColor.ink)
            Spacer(minLength: 0)
            Image(systemName: snapshot.reason == .received ? "arrow.down.circle.fill" : "eye.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(WidgetColor.inkMuted)
        }
    }

    private func changeLine(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 3) {
            Image(systemName: arrow(snapshot)).font(.system(size: 10, weight: .bold))
            Text(verbatim: snapshot.changeText).font(.system(size: 13, weight: .semibold))
            Text("24h").font(.system(size: 11, weight: .medium)).foregroundStyle(WidgetColor.inkMuted)
        }
        .foregroundStyle(trend(snapshot))
    }

    private func updated(_ snapshot: WidgetSnapshot) -> some View {
        Text("Às \(snapshot.updated.formatted(date: .omitted, time: .shortened))")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(WidgetColor.inkMuted)
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(snapshot)
            Spacer(minLength: 0)
            Text(verbatim: snapshot.priceText)
                .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(WidgetColor.ink)
                .lineLimit(1).minimumScaleFactor(0.5)
            changeLine(snapshot)
            WidgetSparkline(points: snapshot.points, lineWidth: 2, filled: true, color: trend(snapshot))
                .frame(height: 34)
                .padding(.top, 2)
        }
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                header(snapshot)
                Text(verbatim: snapshot.name).font(.system(size: 12, weight: .medium)).foregroundStyle(WidgetColor.inkSoft).lineLimit(1)
                Spacer(minLength: 0)
                Text(verbatim: snapshot.priceText)
                    .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(WidgetColor.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                changeLine(snapshot)
                updated(snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WidgetSparkline(points: snapshot.points, lineWidth: 2.2, filled: true, color: trend(snapshot))
                .frame(maxWidth: .infinity)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            if family == .systemSmall || family == .systemMedium {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 18, weight: .semibold)).foregroundStyle(WidgetColor.brand)
                Spacer(minLength: 0)
            }
            Text("Abra uma moeda na Escalibur para ver o preço aqui.")
                .font(.system(size: family == .accessoryInline ? 13 : 12, weight: .medium))
                .foregroundStyle(family == .systemSmall || family == .systemMedium ? WidgetColor.inkSoft : .primary)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A linha do preco, normalizada no espaco do quadro, com a area embaixo nos widgets da
/// tela de inicio.
private struct WidgetSparkline: View {
    let points: [Double]
    var lineWidth: CGFloat = 2
    var filled = false
    var color: Color = .primary

    var body: some View {
        GeometryReader { geo in
            let path = Self.line(points, in: geo.size)
            ZStack {
                if filled {
                    Self.area(path, in: geo.size)
                        .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                path.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }

    static func area(_ line: Path, in size: CGSize) -> Path {
        var area = line
        guard !line.isEmpty else { return area }
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        return area
    }

    static func line(_ points: [Double], in size: CGSize) -> Path {
        var path = Path()
        guard points.count > 1, let low = points.min(), let high = points.max() else { return path }
        let span = max(high - low, high * 0.0005)
        for (index, value) in points.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = size.height * (1 - CGFloat((value - low) / span))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
