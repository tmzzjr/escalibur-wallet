import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import SwiftUI

/// P3: detalhe de um ativo da carteira, numa rolagem so. A posicao e o numero
/// grande; o preco, com o grafico, vem logo abaixo.
struct AssetDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    let row: PortfolioRow

    @State private var receiving = false

    private var primaryChain: Chain? { row.positions.first?.asset.chain }
    private var canTrade: Bool { primaryChain.flatMap { TradeEngines.engine(for: $0) } != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                position.padding(.horizontal, Space.gutter)
                MarketChartSection(
                    coingeckoID: row.coingeckoID, symbol: row.symbol, name: row.name,
                    livePrice: row.price, liveChange: row.change24h, isStable: row.isStablecoin, priceAsFigure: false
                )
                .padding(.top, Space.lg)
                if row.positions.count > 1 { networks.padding(.top, Space.xl) }
                contract.padding(.top, Space.lg)
            }
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    CoinLogo(coingeckoID: row.coingeckoID, symbol: row.symbol, size: 20)
                    Text(verbatim: row.name).typeStyle(.action).foregroundStyle(Palette.ink)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if session.selectedWallet?.isWatchOnly != true {
                ActionFooter {
                    HStack(spacing: Space.sm) {
                        SecondaryButton(title: "Enviar", height: Height.primary) { router.present(.send(row.positions.first?.asset)) }
                        SecondaryButton(title: "Receber", height: Height.primary) { receiving = true }
                        if canTrade {
                            PrimaryButton(title: "Trocar") { router.tab = .trade }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $receiving) { ReceiveSheet(preselected: row.positions.first?.asset) }
    }

    private var position: some View {
        let hidden = session.metadata.settings.hideBalances
        return VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Sua posição").typeStyle(.note).foregroundStyle(Palette.inkSoft)
            Text(hidden ? Redaction.fiat : (row.fiatValue.map { Fmt.fiat($0, session.currency) } ?? "sem preço"))
                .typeStyle(.figure).foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            Text(hidden ? Redaction.short : Fmt.crypto(row.totalAmount, decimals: row.decimals, symbol: row.symbol, style: .full))
                .typeStyle(.note).foregroundStyle(Palette.inkSoft)
        }
    }

    private var networks: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Por rede").typeStyle(.heading).foregroundStyle(Palette.ink)
            ForEach(row.positions, id: \.asset.id) { holding in
                HStack(spacing: Space.xs) {
                    if let chain = holding.asset.chain { NetworkBadge(chain: chain, size: 20, ring: Palette.void) }
                    Text(holding.asset.chain?.name ?? "").typeStyle(.body).foregroundStyle(Palette.ink)
                    Spacer()
                    Text(Fmt.crypto(holding.amount, decimals: holding.asset.decimals, symbol: holding.asset.symbol, style: .full))
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                .frame(height: 36)
            }
        }
        .padding(.horizontal, Space.gutter)
    }

    @ViewBuilder
    private var contract: some View {
        if let asset = row.positions.first?.asset, case .token(let address) = asset.kind, let chain = asset.chain {
            HStack(spacing: Space.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Contrato \(chain.id == "xrpl" ? "no" : "na") \(chain.name)").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    Text(verbatim: Fmt.address(address)).typeStyle(.monoSmall).foregroundStyle(Palette.inkSoft)
                }
                Spacer()
                Button {
                    Pasteboard.copyAddress(address)
                    toasts.show("Contrato copiado.")
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 15)).foregroundStyle(Palette.inkSoft)
                        .frame(width: Height.touch, height: Height.touch)
                }
                .accessibilityLabel("Copiar contrato")
                if let url = chain.explorerURL(address: address) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right").font(.system(size: 15)).foregroundStyle(Palette.inkSoft)
                            .frame(width: Height.touch, height: Height.touch)
                    }
                    .accessibilityLabel("Ver no \(chain.explorerName)")
                }
            }
            .padding(.horizontal, Space.gutter)
        }
    }
}

/// Preco com grafico e periodos. Usado no detalhe do ativo e no Mercado. O preco
/// atualiza sozinho a cada 15 segundos e pisca verde ou vermelho quando muda; o
/// dedo no grafico troca o preco pelo do ponto tocado.
struct MarketChartSection: View {
    @Environment(AppSession.self) private var session
    let coingeckoID: String?
    let symbol: String
    let name: String
    let livePrice: Double?
    let liveChange: Double?
    var isStable = false
    var priceAsFigure = true

    @State private var range: ChartRange = .day
    @State private var points: [PricePoint] = []
    @State private var loading = false
    @State private var selection: PricePoint?
    @State private var failed = false
    @State private var price: Double?
    @State private var change: Double?
    @State private var tick: Color = Palette.ink

    private var shownPrice: Double? { selection?.price ?? price ?? livePrice ?? points.last?.price }

    private var shownChange: Double? {
        guard let first = points.first?.price, first > 0 else { return change ?? liveChange }
        if let selection { return (selection.price - first) / first * 100 }
        if range == .day, let current = change ?? liveChange { return current }
        guard let last = points.last?.price else { return change ?? liveChange }
        return (last - first) / first * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if priceAsFigure {
                    Text(shownPrice.map { Fmt.price($0, session.currency) } ?? " ")
                        .typeStyle(.figure)
                } else {
                    Text(shownPrice.map { Fmt.price($0, session.currency) } ?? " ")
                        .typeStyle(.row)
                }
            }
            .foregroundStyle(selection == nil ? tick : Palette.ink)
            .contentTransition(.numericText(value: shownPrice ?? 0))
            .animation(Motion.number, value: shownPrice)
            .padding(.horizontal, Space.gutter)
            .overlay(alignment: .leading) {
                if shownPrice == nil { SkeletonBar(width: priceAsFigure ? 160 : 90, height: priceAsFigure ? 32 : 16).padding(.leading, Space.gutter) }
            }

            HStack(spacing: 6) {
                if let change = shownChange {
                    Text(Fmt.percent(change)).typeStyle(.note)
                        .foregroundStyle(change > 0.004 ? Palette.up : (change < -0.004 ? Palette.down : Palette.inkSoft))
                }
                Text(selection.map { Fmt.relative($0.time) } ?? periodLabel)
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xxs)

            PriceChart(points: points, loading: loading, isStable: isStable, selection: $selection, currency: session.currency)
                .padding(.top, Space.sm)
            if failed && points.isEmpty {
                Text("Não foi possível carregar o gráfico agora.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, Space.gutter)
            }
            PeriodPicker(range: $range)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.sm)
        }
        .task(id: range) { await load() }
        .task { await live() }
    }

    private var periodLabel: String {
        switch range {
        case .day: return "em 24h"
        case .week: return "em 7 dias"
        case .month: return "em 30 dias"
        case .year: return "em 1 ano"
        case .all: return "desde o início"
        }
    }

    private func load() async {
        guard let coingeckoID else { return }
        loading = true
        defer { loading = false }
        do {
            points = try await MarketService.shared.chart(id: coingeckoID, currency: session.metadata.settings.currency, range: range)
            failed = false
        } catch {
            failed = true
        }
    }

    /// Preco vivo: consulta a cada 15 s e pisca a cor da mudanca por 600 ms.
    private func live() async {
        guard let coingeckoID else { return }
        while !Task.isCancelled {
            if let quote = try? await MarketService.shared.quotes(ids: [coingeckoID], currency: session.metadata.settings.currency)[coingeckoID] {
                if let old = price ?? livePrice, quote.price != old {
                    tick = quote.price > old ? Palette.up : Palette.down
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        withAnimation(.easeOut(duration: 0.6)) { tick = Palette.ink }
                    }
                }
                price = quote.price
                change = quote.change24h
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }
}
