import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import SwiftUI

/// P3: detalhe de um ativo da carteira, numa rolagem so.
struct AssetDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(Router.self) private var router
    let row: PortfolioRow

    @State private var receiving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MarketChartSection(
                    coingeckoID: row.coingeckoID, symbol: row.symbol, name: row.name,
                    livePrice: row.price, liveChange: row.change24h
                )
                position.padding(.top, Space.xl)
                if let contract = contractLine {
                    contract.padding(.top, Space.xl)
                }
            }
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.void, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if session.selectedWallet?.isWatchOnly != true {
                ActionFooter {
                    HStack(spacing: Space.sm) {
                        SecondaryButton(title: "Receber", height: Height.primary) { receiving = true }
                        SecondaryButton(title: "Enviar", height: Height.primary) { router.present(.send(row.positions.first?.asset)) }
                        PrimaryButton(title: "Trocar") { router.tab = .trade }
                    }
                }
            }
        }
        .sheet(isPresented: $receiving) { ReceiveSheet(preselected: row.positions.first?.asset) }
    }

    private var position: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Sua posição").typeStyle(.heading).foregroundStyle(Palette.ink)
            HStack(alignment: .firstTextBaseline) {
                Text(row.fiatValue.map { Fmt.fiat($0, session.currency) } ?? "sem preço")
                    .typeStyle(.row).foregroundStyle(Palette.ink)
                Spacer()
                Text(Fmt.crypto(row.totalAmount, decimals: row.decimals, symbol: row.symbol, style: .full))
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft)
            }
            if row.positions.count > 1 {
                ForEach(row.positions, id: \.asset.id) { holding in
                    HStack(spacing: Space.xs) {
                        if let chain = holding.asset.chain { NetworkBadge(chain: chain, size: 18, ring: Palette.void) }
                        Text(holding.asset.chain?.name ?? "").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        Spacer()
                        Text(Fmt.crypto(holding.amount, decimals: holding.asset.decimals, symbol: holding.asset.symbol, style: .full))
                            .typeStyle(.note).foregroundStyle(Palette.ink)
                    }
                }
            }
        }
        .padding(.horizontal, Space.gutter)
    }

    private var contractLine: AnyView? {
        guard let asset = row.positions.first?.asset, case .token(let contract) = asset.kind, let chain = asset.chain else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Contrato").typeStyle(.heading).foregroundStyle(Palette.ink)
                Text(verbatim: contract).typeStyle(.monoSmall).foregroundStyle(Palette.inkSoft).textSelection(.enabled)
                if let url = chain.explorerURL(address: contract) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text("Ver no \(chain.explorerName)").typeStyle(.note)
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Palette.inkSoft)
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
        )
    }
}

/// Cabecalho de preco com grafico e periodos. Usado no detalhe do ativo e no
/// Mercado. O numero grande vira o preco do ponto tocado enquanto o dedo arrasta.
struct MarketChartSection: View {
    @Environment(AppSession.self) private var session
    let coingeckoID: String?
    let symbol: String
    let name: String
    let livePrice: Double?
    let liveChange: Double?
    var remoteLogo: URL? = nil

    @State private var range: ChartRange = .day
    @State private var points: [PricePoint] = []
    @State private var loading = false
    @State private var selection: PricePoint?
    @State private var failed = false

    private var shownPrice: Double? { selection?.price ?? livePrice ?? points.last?.price }

    private var shownChange: Double? {
        guard let first = points.first?.price, first > 0 else { return liveChange }
        if let selection { return (selection.price - first) / first * 100 }
        if range == .day, let liveChange { return liveChange }
        guard let last = points.last?.price else { return liveChange }
        return (last - first) / first * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: coingeckoID, symbol: symbol, size: 32, remoteURL: remoteLogo)
                Text(verbatim: name).typeStyle(.action).foregroundStyle(Palette.ink)
                Text(symbol).typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, Space.gutter)

            Text(shownPrice.map { Fmt.price($0, session.currency) } ?? "sem preço")
                .typeStyle(.figure)
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)

            HStack(spacing: 6) {
                if let change = shownChange {
                    Text(Fmt.percent(change)).typeStyle(.row)
                        .foregroundStyle(change > 0.004 ? Palette.up : (change < -0.004 ? Palette.down : Palette.inkSoft))
                }
                Text(selection.map { Fmt.relative($0.time) } ?? periodLabel)
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xxs)

            PriceChart(points: points, loading: loading, selection: $selection, currency: session.currency)
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
}
