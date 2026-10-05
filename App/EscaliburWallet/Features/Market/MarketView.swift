import Charts
import EscaliburChains
import EscaliburNetwork
import SwiftUI

/// Mercado: as maiores moedas por capitalizacao, com minigrafico de 7 dias.
///
/// Sem "tokens em alta", sem navegador de dApps, sem promocao: so dado publico de
/// mercado, que e igual para todo mundo e nao revela nada da carteira do dono.
struct MarketView: View {
    @Environment(AppSession.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var coins: [MarketCoin] = []
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var loading = false
    @State private var failed = false
    @State private var order: Order = .relevance
    /// De onde e de quando e a lista na tela; `isStale` quando as fontes falharam agora
    /// e a lista e a ultima boa.
    @State private var snapshot: MarketSnapshot?

    /// A ordem da lista. Relevancia e a do CoinGecko (valor de mercado).
    enum Order: String, CaseIterable, Hashable {
        case relevance = "Relevância"
        case gainers = "Maior alta"
        case losers = "Maior queda"
        case priceHigh = "Maior preço"

        func sorted(_ coins: [MarketCoin]) -> [MarketCoin] {
            switch self {
            case .relevance: return coins
            // Sem variacao conhecida, a moeda vai para o fim nos dois sentidos.
            case .gainers: return coins.sorted { ($0.change24h ?? -.infinity) > ($1.change24h ?? -.infinity) }
            case .losers: return coins.sorted { ($0.change24h ?? .infinity) < ($1.change24h ?? .infinity) }
            case .priceHigh: return coins.sorted { $0.price > $1.price }
            }
        }
    }

    private var favoriteIDs: [String] { session.metadata.settings.favoriteCoins ?? [] }

    /// As marcadas com coracao, na ordem em que foram marcadas.
    private var favorites: [MarketCoin] {
        let marked = favoriteIDs.compactMap { id in filtered.first { $0.id == id } }
        return order == .relevance ? marked : order.sorted(marked)
    }

    private var others: [MarketCoin] { order.sorted(filtered.filter { !favoriteIDs.contains($0.id) }) }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, Space.gutter).padding(.top, Space.md).padding(.bottom, Space.xxs)
    }

    private var filtered: [MarketCoin] {
        guard !query.isEmpty else { return coins }
        return coins.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: Bindable(router).marketPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TabTitle("Mercado")
                    SearchField(prompt: "Buscar moeda", text: $query, focus: $searching)
                        .padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.xs) {
                            ForEach(Order.allCases, id: \.self) { option in
                                Chip(title: option.rawValue, selected: order == option) {
                                    withAnimation(Motion.fade) { order = option }
                                }
                                .accessibilityIdentifier("ordem-\(option.rawValue)")
                            }
                        }
                        .padding(.horizontal, Space.gutter)
                    }
                    .padding(.top, Space.sm)

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
                    } else if let snapshot, snapshot.isStale {
                        Banner(
                            kind: .neutral, title: "Sem conexão com os dados de mercado agora.",
                            message: "Mostrando os preços de \(Fmt.stamp(snapshot.fetchedAt)).", actionTitle: "Tentar de novo"
                        ) {
                            Task { await load() }
                        }
                        .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                    }

                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !favorites.isEmpty {
                            sectionTitle("Favoritas")
                            ForEach(favorites) { coin in
                                NavigationLink(value: coin) { MarketRow(coin: coin, currency: session.currency) }
                                    .buttonStyle(RowStyle())
                            }
                            sectionTitle("Todas")
                        }
                        ForEach(others) { coin in
                            NavigationLink(value: coin) { MarketRow(coin: coin, currency: session.currency) }
                                .buttonStyle(RowStyle())
                        }
                    }
                    .padding(.top, Space.sm)
                    .animation(Motion.fade, value: favoriteIDs)
                    .animation(Motion.fade, value: order)
                    if let snapshot {
                        Text("Dados de mercado: \(snapshot.source.rawValue), às \(Fmt.stamp(snapshot.fetchedAt))")
                            .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                            .frame(maxWidth: .infinity).padding(.top, Space.lg)
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .dismissesKeyboard($searching)
            // Lista viva: atualiza a cada 30 s so enquanto ela esta na tela e o app na
            // frente. Abrir uma moeda, trocar de aba ou sair do app para a atualizacao.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .refreshable { await load() }
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .statusBarBackdrop()
            .navigationDestination(for: MarketCoin.self) { coin in
                MarketCoinDetail(coin: coin)
            }
            .onAppear { openPendingCoin() }
            .onChange(of: router.pendingCoinID) { openPendingCoin() }
            .onChange(of: coins.isEmpty) { openPendingCoin() }
        }
    }

    /// A moeda de um alerta de preco tocado, assim que a lista tiver chegado.
    private func openPendingCoin() {
        guard let id = router.pendingCoinID, let coin = coins.first(where: { $0.id == id }) else { return }
        router.pendingCoinID = nil
        var path = NavigationPath()
        path.append(coin)
        router.marketPath = path
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let fresh = try await MarketService.shared.marketSnapshot(currency: session.metadata.settings.currency)
            snapshot = fresh
            coins = fresh.coins
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
                    ChangePill(change: coin.change24h, animated: false)
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
                    ChangePill(change: coin.change24h, animated: false)
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .frame(minHeight: Height.row)
        .contentShape(Rectangle())
    }

    /// Na lista, preco e variacao trocam sem animar. A lista atualiza a cada 30 s com a
    /// aba aberta, muitas vezes no meio de uma rolagem, e cem numeros rolando e cem
    /// pilulas mudando de cor juntos piscavam a tela (relatado no iPhone). A pagina da
    /// moeda continua animando o seu numero.
    private var price: some View {
        Text(Fmt.price(coin.price, currency)).typeStyle(.row).foregroundStyle(Palette.ink)
            .lineLimit(1).minimumScaleFactor(0.6)
    }
}

/// A pilula de variacao do dia: seta cheia e numero sem sinal (a seta ja diz a
/// direcao), sobre a cor cheia da direcao. Alta: lima com texto escuro (nunca branco
/// sobre verde, 2,29:1). Queda: vermelho saturado (#E8112D), com o texto branco
/// a 4,6:1. Variacao abaixo de 0,01% e neutra, sem seta.
struct ChangePill: View {
    let change: Double?
    /// Fora de lista longa: o numero rola e a cor troca devagar. Na lista do Mercado, nao.
    var animated = true

    var body: some View {
        let value = change ?? 0
        let up = value > 0.004
        let down = value < -0.004
        let tint = up ? Palette.onLime : (down ? Color.white : Palette.inkSoft)
        HStack(spacing: 4) {
            if up || down {
                Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(Fmt.percent(abs(value)).replacingOccurrences(of: "+", with: ""))
                .typeStyle(.label).monospacedDigit()
                .contentTransition(animated ? .numericText(value: value) : .identity)
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Space.sm)
        .frame(minWidth: 80, minHeight: 28)
        .background(
            Capsule(style: .continuous)
                .fill(up ? Palette.up : (down ? Palette.downSolid : Palette.rail))
        )
        .layoutPriority(1)
        .animation(animated ? Motion.fade : nil, value: value)
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
    @Environment(Router.self) private var router
    @Environment(Portfolio.self) private var portfolio
    let coin: MarketCoin

    private var tradable: Asset? { CoinTrade.asset(for: coin.id) }

    /// O que a carteira tem desta moeda, na rede onde ha mais: e o que Vender oferece.
    private var held: Asset? {
        Chain.all.compactMap { portfolio.balance($0) }.flatMap(\.holdings)
            .filter { $0.asset.coingeckoID == coin.id && !$0.amount.isZero }
            .max { Fmt.double($0.amount, decimals: $0.asset.decimals) < Fmt.double($1.amount, decimals: $1.asset.decimals) }?
            .asset
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MarketChartSection(coingeckoID: coin.id, symbol: coin.symbol, name: coin.name,
                                   livePrice: coin.price, liveChange: coin.change24h,
                                   isStable: ["tether", "usd-coin", "dai"].contains(coin.id), seed: coin.sparkline)
                MarketFacts(coin: coin)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xl)
            }
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        // Vender depende do saldo, e tocar no preco, da cotacao em outras moedas: quem
        // abre direto no Mercado ainda nao carregou a carteira.
        .task(id: session.selectedWallet?.id) { await portfolio.ensureLoaded(session.selectedWallet, session: session) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 20, remoteURL: coin.imageURL)
                    Text(verbatim: coin.name).typeStyle(.action).foregroundStyle(Palette.ink)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 0) {
                    PriceAlertBell(coin: coin)
                    FavoriteButton(coingeckoID: coin.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if session.selectedWallet?.isWatchOnly != true, tradable != nil || held != nil {
                ActionFooter {
                    HStack(spacing: Space.sm) {
                        if let held {
                            SecondaryButton(title: "Vender", height: Height.primary) {
                                router.tradePreset = (held, true)
                                router.tab = .trade
                            }
                        }
                        if let tradable {
                            PrimaryButton(title: "Comprar \(coin.symbol.uppercased())") {
                                router.tradePreset = (tradable, false)
                                router.tab = .trade
                            }
                        }
                    }
                }
            }
        }
    }
}
