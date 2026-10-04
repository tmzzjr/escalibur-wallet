import EscaliburNetwork
import SwiftUI

/// O que a pagina da moeda mostra abaixo do grafico, como as boas corretoras: mercado,
/// faixa de 24 horas, maxima historica, oferta e um "Sobre" curto.
///
/// Os tres numeros da lista aparecem na hora; o resto chega quando a pagina abre
/// (`MarketService.coinDetails`, guardado por 5 minutos) e so o que a fonte entregou
/// aparece. Nenhum link e tocavel por enquanto.
struct MarketFacts: View {
    @Environment(AppSession.self) private var session
    let coin: MarketCoin

    @State private var details: MarketCoinDetails?
    @State private var loading = true

    private var currency: Fmt.Currency { session.currency }
    private var price: Double { details?.price ?? coin.price }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            market
            if let details {
                if let low = details.low24h, let high = details.high24h, high > low {
                    DayRange(low: low, high: high, price: price, currency: currency)
                }
                if let ath = details.allTimeHigh { allTimeHigh(ath, details: details) }
                supply(details)
                if let about = details.about { aboutSection(about, portuguese: details.aboutInPortuguese) }
            } else if loading {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SkeletonBar(width: 140, height: 16)
                    SkeletonBar(width: 220)
                    SkeletonBar(width: 180)
                }
            }
            footer
        }
        .task(id: session.metadata.settings.currency) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        details = try? await MarketService.shared.coinDetails(id: coin.id, currency: session.metadata.settings.currency)
    }

    // MARK: Mercado

    private var market: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Sobre o mercado").typeStyle(.heading).foregroundStyle(Palette.ink)
            FactGrid(items: marketItems)
        }
    }

    private var marketItems: [Fact] {
        var items = [
            Fact("Capitalização", (details?.marketCap ?? coin.marketCap).map { Fmt.compact($0, currency) }),
            Fact("Volume em 24h", (details?.volume24h ?? coin.volume24h).map { Fmt.compact($0, currency) }),
            Fact("Posição no mercado", (details?.rank ?? coin.rank).map { "\($0)º" }),
        ]
        if let diluted = details?.fullyDilutedValuation {
            items.append(Fact("Valor totalmente diluído", Fmt.compact(diluted, currency)))
        }
        return items
    }

    // MARK: Maxima historica

    private func allTimeHigh(_ ath: Double, details: MarketCoinDetails) -> some View {
        let when = details.allTimeHighDate.map { "Em \(Fmt.longDay($0))" }
        return VStack(alignment: .leading, spacing: Space.xs) {
            Text("Máxima histórica").typeStyle(.action).foregroundStyle(Palette.ink)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.price(ath, currency)).typeStyle(.row).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if let when { Text(when).typeStyle(.note).foregroundStyle(Palette.inkMuted) }
                }
                Spacer(minLength: Space.sm)
                if let distance = details.fromAllTimeHigh {
                    Text(Self.distance(distance)).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "87% abaixo da máxima"; perto dela, "Na máxima".
    static func distance(_ percent: Double) -> String {
        guard percent < -0.5 else { return "Na máxima" }
        let value = abs(percent)
        return "\(Fmt.grouped(value, fractionDigits: value < 10 ? 1 : 0, trimZeros: true))% abaixo da máxima"
    }

    // MARK: Oferta

    private func supplyItems(_ details: MarketCoinDetails) -> [Fact] {
        let symbol = coin.symbol.uppercased()
        let amount: (Double) -> String = { "\(Fmt.compact($0)) \(symbol)" }
        var items: [Fact] = []
        if let circulating = details.circulatingSupply { items.append(Fact("Em circulação", amount(circulating))) }
        if let total = details.totalSupply { items.append(Fact("Oferta total", amount(total))) }
        if let maximum = details.maxSupply {
            items.append(Fact("Oferta máxima", amount(maximum)))
        } else if details.unlimitedSupply {
            items.append(Fact("Oferta máxima", "Sem teto"))
        }
        return items
    }

    @ViewBuilder
    private func supply(_ details: MarketCoinDetails) -> some View {
        let items = supplyItems(details)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Oferta").typeStyle(.action).foregroundStyle(Palette.ink)
                FactGrid(items: items)
            }
        }
    }

    // MARK: Sobre

    private func aboutSection(_ text: String, portuguese: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Sobre o projeto").typeStyle(.action).foregroundStyle(Palette.ink)
            Text(verbatim: text).typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !portuguese {
                Text("Texto em inglês, como a fonte publica.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
        }
    }

    // MARK: Fonte

    @ViewBuilder
    private var footer: some View {
        if let details {
            let stamp = Fmt.stamp(details.fetchedAt)
            Text(details.isStale
                 ? "Sem conexão com as fontes agora. Dados de \(stamp), do \(details.source.rawValue)."
                 : "Dados do \(details.source.rawValue), às \(stamp).")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted)
        } else if !loading {
            Text("Não foi possível carregar mais dados desta moeda agora.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
        }
    }
}

/// Um numero e o que ele e. Sem valor, "sem dado".
struct Fact: Hashable {
    let label: String
    let value: String

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value ?? "sem dado"
    }
}

/// Numeros em duas colunas: valor em cima, rotulo embaixo.
struct FactGrid: View {
    let items: [Fact]

    private let columns = [
        GridItem(.flexible(), spacing: Space.md, alignment: .topLeading),
        GridItem(.flexible(), spacing: Space.md, alignment: .topLeading),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.md) {
            ForEach(items, id: \.self) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.value).typeStyle(.row).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(item.label).typeStyle(.note).foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Faixa de 24 horas: minima e maxima, com o preco de agora marcado entre elas.
struct DayRange: View {
    let low: Double
    let high: Double
    let price: Double
    let currency: Fmt.Currency

    /// Onde o preco cai na faixa. A maxima e a minima da fonte podem estar um pouco
    /// atras do preco vivo: o marcador fica na ponta.
    private var position: Double { min(max((price - low) / (high - low), 0), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Faixa de 24 horas").typeStyle(.action).foregroundStyle(Palette.ink)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.rail).frame(height: 4)
                    Capsule().fill(Palette.edgeStrong).frame(width: max(4, width * position), height: 4)
                    Circle().fill(Palette.ink).frame(width: 12, height: 12)
                        .offset(x: min(max(0, width * position - 6), width - 12))
                }
                .frame(height: 12)
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.price(low, currency)).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
                    Text("Mínima").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: Space.sm)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.price(high, currency)).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
                    Text("Máxima").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
