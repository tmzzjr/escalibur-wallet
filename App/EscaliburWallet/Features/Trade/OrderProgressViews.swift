import EscaliburChains
import EscaliburCore
import EscaliburEngines
import SwiftUI

/// O anel de preenchimento de uma ordem: quanto ja saiu, de 0 a 100%. A cor do app
/// so marca o que ja foi preenchido.
struct FillRing: View {
    let fraction: Double
    var size: CGFloat = 36
    var lineWidth: CGFloat = 4
    var showsLabel = true

    /// Para baixo: 100% so quando terminou de fato, e uma ordem que comecou a sair nunca
    /// aparece com 0%.
    static func percentText(_ fraction: Double) -> String {
        guard fraction > 0 else { return "0%" }
        guard fraction < 1 else { return "100%" }
        let percent = Int((fraction * 100).rounded(.down))
        return percent == 0 ? "<1%" : "\(min(percent, 99))%"
    }

    var body: some View {
        ZStack {
            Circle().stroke(Palette.rail, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)
            if showsLabel {
                Text(Self.percentText(fraction))
                    .font(.system(size: max(10, size * 0.26), weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                    .animation(Motion.number, value: fraction)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(lineWidth + 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preenchida \(Self.percentText(fraction))")
    }
}

/// O andamento de uma ordem acabada de enviar (troca pela CoW ou ordem limite), lido da
/// rede a cada 3 segundos ate terminar.
struct OrderProgressPanel: View {
    enum Kind { case swap, limit }

    let kind: Kind
    let chain: Chain
    let orderID: String
    let account: DerivedAccount
    let sell: Asset?
    let buy: Asset?
    /// So na conferencia visual (`-tela andamento`): um andamento fixo, sem rede.
    var preview: OrderProgress?
    @State private var progress: OrderProgress?
    @State private var unreadable = false

    var body: some View {
        VStack(spacing: 0) {
            FillRing(fraction: progress?.fraction ?? 0, size: 148, lineWidth: 10)
            Text(title).typeStyle(.title).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                .padding(.top, Space.lg)
            Text(detail).typeStyle(.body).foregroundStyle(Palette.inkSoft).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, Space.xs)
            if let progress {
                VStack(spacing: 2) {
                    if !progress.receivedBuy.isZero {
                        Text("Recebido \(amount(progress.receivedBuy, buy))").typeStyle(.row).foregroundStyle(Palette.ink)
                            .contentTransition(.numericText()).animation(Motion.number, value: progress.receivedBuy)
                    }
                    if progress.state == .open {
                        Text("Garantido no total: \(amount(progress.minimumBuy, buy)) ou mais").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    }
                }
                .padding(.top, Space.md)
            }
            if unreadable {
                Text("Sem resposta da CoW agora. O andamento volta a aparecer sozinho, e as ordens abertas mostram o mesmo.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, Space.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.success, trigger: progress?.state == .filled)
        .task(id: orderID) { await follow() }
    }

    private var title: String {
        guard let progress else { return kind == .swap ? String(localized: "Troca enviada") : String(localized: "Ordem limite criada") }
        switch progress.state {
        case .filled: return kind == .swap ? String(localized: "Troca concluída") : String(localized: "Ordem executada")
        case .expired: return String(localized: "Prazo encerrado")
        case .cancelled: return String(localized: "Ordem cancelada")
        case .open:
            if progress.fraction > 0 { return String(localized: "Preenchendo") }
            return kind == .swap ? String(localized: "No leilão da CoW") : String(localized: "Esperando o preço")
        }
    }

    private var detail: String {
        guard let progress else { return String(localized: "Lendo o andamento na CoW.") }
        let minimum = amount(progress.minimumBuy, buy)
        let leave = String(localized: "Pode fechar esta tela: o andamento fica em Ordens abertas.")
        switch progress.state {
        case .filled:
            return String(localized: "Saiu inteira, pelo mínimo garantido de \(minimum) ou mais. O saldo novo aparece em instantes.")
        case .expired, .cancelled:
            return progress.fraction > 0
                ? String(localized: "\(FillRing.percentText(progress.fraction)) foi preenchido. O restante continua na sua carteira.")
                : String(localized: "Nada foi preenchido. O valor continua na sua carteira.")
        case .open:
            if kind == .limit, progress.fraction == 0 {
                return String(localized: "Ela executa quando o mercado chegar ao seu preço, de uma vez ou em partes. \(leave)")
            }
            return String(localized: "Cada parte sai pelo preço garantido ou melhor. \(leave)")
        }
    }

    private func amount(_ value: BigUInt, _ asset: Asset?) -> String {
        guard let asset else { return "" }
        return Fmt.crypto(value, decimals: asset.decimals, symbol: asset.symbol)
    }

    private func follow() async {
        if let preview {
            progress = preview
            return
        }
        guard let engine = TradeEngines.engine(for: chain) else { return }
        while !Task.isCancelled {
            do {
                let current = try await engine.orderProgress(id: orderID, account: account)
                progress = current
                unreadable = false
                if current.isFinal { return }
            } catch {
                unreadable = true
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

/// Ordem grande: de uma vez, pelo preco da ordem inteira, ou em partes, por um preco
/// melhor, preenchida conforme chega liquidez. Os dois valores sao o minimo garantido de
/// cada jeito, o mesmo que vai assinado.
struct ExecutionChoice: View {
    let quote: TradeQuote
    let parts: TradeQuote.Parts
    let buy: Asset
    @Binding var inParts: Bool

    private var gainText: String {
        let single = Fmt.double(quote.minimumOut, decimals: buy.decimals)
        let better = Fmt.double(parts.minimumOut, decimals: buy.decimals)
        guard single > 0, better > single else { return "" }
        return String(localized: "+\(Fmt.grouped((better / single - 1) * 100, fractionDigits: 2))%")
    }

    var body: some View {
        VStack(spacing: 4) {
            option(selected: !inParts, title: String(localized: "De uma vez"), gain: nil,
                   note: quote.execution == .order ? String(localized: "Agora, no leilão da CoW") : String(localized: "Agora, numa transação"), amount: quote.minimumOut) {
                inParts = false
            }
            option(selected: inParts, title: String(localized: "Em partes"), gain: gainText,
                   note: String(localized: "Preço melhor, preenchida pela CoW conforme chega liquidez, em até 1 hora"), amount: parts.minimumOut) {
                inParts = true
            }
        }
        .sensoryFeedback(.selection, trigger: inParts)
    }

    private func option(selected: Bool, title: String, gain: String?, note: String, amount: BigUInt,
                        action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.select) { action() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(selected ? Palette.ink : Palette.inkDead)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                        if let gain, !gain.isEmpty { Text(gain).typeStyle(.note).fontWeight(.semibold).foregroundStyle(Palette.up) }
                        Spacer(minLength: Space.xs)
                        Text(Fmt.crypto(amount, decimals: buy.decimals, symbol: buy.symbol))
                            .typeStyle(.row).foregroundStyle(selected ? Palette.ink : Palette.inkSoft)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Text(note).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(selected ? Palette.edgeStrong : Palette.edge, lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
