import Charts
import EscaliburNetwork
import SwiftUI

/// Mercado: as maiores moedas por capitalizacao, com minigrafico de 7 dias.
///
/// Sem "tokens em alta", sem navegador de dApps, sem promocao: so dado publico de
/// mercado, que e igual para todo mundo e nao revela nada da carteira do dono.
struct MarketView: View {
    @Environment(AppSession.self) private var session
    @Environment(Router.self) private var router
    @State private var coins: [MarketCoin] = []
    @State private var query = ""
    @State private var loading = false
    @State private var failed = false

    private var filtered: [MarketCoin] {
        guard !query.isEmpty else { return coins }
        return coins.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: Bindable(router).marketPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TabTitle("Mercado")
                    SearchField(prompt: "Buscar moeda", text: $query)
                        .padding(.horizontal, Space.gutter).padding(.top, Space.sm)

                    if coins.isEmpty && loading {
                        ForEach(0..<8, id: \.self) { _ in
                            HStack(spacing: Space.sm) {
                                Circle().fill(Palette.body).frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 8) { SkeletonBar(width: 48); SkeletonBar(width: 88) }
                                Spacer()
                                SkeletonBar(width: 72, height: 16)
                                SkeletonBar(width: 72, height: 28)
                            }
                            .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
                        }
                        .padding(.top, Space.sm)
                    } else if coins.isEmpty && failed {
                        Banner(kind: .neutral, title: "Não foi possível carregar o mercado agora.", actionTitle: "Tentar de novo") {
                            Task { await load() }
                        }
                        .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                    }

                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { coin in
                            NavigationLink(value: coin) { MarketRow(coin: coin, currency: session.currency) }
                                .buttonStyle(RowStyle())
                        }
                    }
                    .padding(.top, Space.sm)
                }
                .padding(.bottom, Space.xl)
            }
            .refreshable { await load() }
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MarketCoin.self) { coin in
                MarketCoinDetail(coin: coin)
            }
        }
        .task {
            // Lista viva: atualiza a cada 30 s enquanto a aba esta na tela.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            coins = try await MarketService.shared.markets(currency: session.metadata.settings.currency)
            failed = false
        } catch {
            failed = true
        }
    }
}

struct MarketRow: View {
    let coin: MarketCoin
    let currency: Fmt.Currency
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                // Texto grande: nome em cima, preco e variacao embaixo, cada um inteiro.
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.sm) {
                        CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 40, remoteURL: coin.imageURL)
                        Text(coin.symbol).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                    }
                    price
                    ChangePill(change: coin.change24h)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Space.sm)
            } else {
                HStack(spacing: Space.sm) {
                    CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 40, remoteURL: coin.imageURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coin.symbol).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(verbatim: coin.name).typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                    }
                    Spacer(minLength: Space.xs)
                    price.frame(width: 120, alignment: .trailing)
                    ChangePill(change: coin.change24h)
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .frame(minHeight: Height.row)
        .contentShape(Rectangle())
    }

    private var price: some View {
        Text(Fmt.price(coin.price, currency)).typeStyle(.row).foregroundStyle(Palette.ink)
            .lineLimit(1).minimumScaleFactor(0.6)
            .contentTransition(.numericText(value: coin.price))
    }
}

/// A pilula de variacao do dia: seta cheia e numero sem sinal (a seta ja diz a
/// direcao), na cor da direcao sobre o fundo tingido da mesma cor. Nunca texto branco
/// sobre verde (contraste 2,29:1). Variacao abaixo de 0,01% e neutra, sem seta.
struct ChangePill: View {
    let change: Double?

    var body: some View {
        let value = change ?? 0
        let up = value > 0.004
        let down = value < -0.004
        let tint = up ? Palette.up : (down ? Palette.down : Palette.inkSoft)
        HStack(spacing: 4) {
            if up || down {
                Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(Fmt.percent(abs(value)).replacingOccurrences(of: "+", with: ""))
                .typeStyle(.label).monospacedDigit()
                .contentTransition(.numericText(value: value))
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, Space.sm)
        .frame(minWidth: 80, minHeight: 28)
        .background(
            Capsule(style: .continuous)
                .fill(up ? Palette.upTint : (down ? Palette.downTint : Palette.rail))
                .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1))
        )
        .animation(Motion.fade, value: value)
        .accessibilityLabel(up ? "Subiu \(Fmt.percent(abs(value)))" : (down ? "Caiu \(Fmt.percent(abs(value)))" : "Estável"))
    }
}

struct Sparkline: View {
    let values: [Double]
    let up: Bool

    var body: some View {
        GeometryReader { geometry in
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let span = max(high - low, .ulpOfOne)
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                    let y = geometry.size.height * (1 - CGFloat((value - low) / span))
                    index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(up ? Palette.up : Palette.down, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct MarketCoinDetail: View {
    @Environment(AppSession.self) private var session
    let coin: MarketCoin

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MarketChartSection(coingeckoID: coin.id, symbol: coin.symbol, name: coin.name,
                                   livePrice: coin.price, liveChange: coin.change24h,
                                   isStable: ["tether", "usd-coin", "dai"].contains(coin.id))
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Sobre o mercado").typeStyle(.heading).foregroundStyle(Palette.ink)
                    stat("Capitalização", coin.marketCap.map { Fmt.compact($0, session.currency) })
                    stat("Volume em 24h", coin.volume24h.map { Fmt.compact($0, session.currency) })
                    stat("Posição por capitalização", coin.rank.map { "\($0)º" })
                }
                .padding(Space.md)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xl)
            }
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 20, remoteURL: coin.imageURL)
                    Text(verbatim: coin.name).typeStyle(.action).foregroundStyle(Palette.ink)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            Spacer()
            Text(value ?? "sem dado").typeStyle(.note).foregroundStyle(Palette.ink)
        }
    }
}
