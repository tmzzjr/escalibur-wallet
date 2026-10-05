import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburNetwork
import SwiftUI

/// P3: detalhe de um ativo da carteira, numa rolagem so. A posicao e o numero
/// grande; o preco, com o grafico, vem logo abaixo.
struct AssetDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(Portfolio.self) private var portfolio
    @Environment(\.dismiss) private var dismiss
    let row: PortfolioRow

    @State private var receiving = false
    @State private var removing = false

    private var primaryChain: Chain? { row.positions.first?.asset.chain }
    /// Moeda custom nao entra na troca: a lista de pares e a sanidade de preco sao da
    /// lista conferida.
    private var canTrade: Bool { !row.isCustom && primaryChain.flatMap { TradeEngines.engine(for: $0) } != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                position.padding(.horizontal, Space.gutter)
                if row.isCustom, let asset = row.positions.first?.asset {
                    customDetails(asset).padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                } else {
                    MarketChartSection(
                        coingeckoID: row.coingeckoID, symbol: row.symbol, name: row.name,
                        livePrice: row.price, liveChange: row.change24h, isStable: row.isStablecoin, priceAsFigure: false
                    )
                    .padding(.top, Space.lg)
                    if row.positions.count > 1 { networks.padding(.top, Space.xl) }
                    contract.padding(.top, Space.lg)
                }
            }
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    CoinLogo(coingeckoID: row.coingeckoID, symbol: row.symbol, size: 20, unverified: row.origin != nil,
                             logoAsset: row.isCustom ? row.positions.first?.asset : nil)
                    Text(verbatim: row.name).typeStyle(.action).foregroundStyle(Palette.ink)
                    if row.isCustom { TokenBadge(.custom) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { FavoriteButton(coingeckoID: row.coingeckoID) }
        }
        .safeAreaInset(edge: .bottom) {
            if session.selectedWallet?.isWatchOnly != true {
                ActionFooter {
                    HStack(spacing: Space.sm) {
                        SecondaryButton(title: "Enviar", height: Height.primary) { router.present(.send(row.positions.first?.asset)) }
                        SecondaryButton(title: "Receber", height: Height.primary) { receiving = true }
                        if canTrade, let asset = row.positions.first?.asset {
                            PrimaryButton(title: "Trocar") {
                                router.tradePreset = (asset, true)
                                router.tab = .trade
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $receiving) { ReceiveSheet(preselected: row.positions.first?.asset) }
        .alert("Remover \(row.symbol)?", isPresented: $removing) {
            Button("Cancelar", role: .cancel) {}
            Button("Remover", role: .destructive) { removeCustom() }
        } message: {
            Text("A moeda some da Carteira, de Receber e de Enviar. O saldo continua na rede, e você pode adicionar de novo.")
        }
    }

    /// Moeda custom: preco so por contrato, o contrato inteiro, o aviso e remover.
    private func customDetails(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(customPriceLine(asset)).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            Banner(kind: .caution, title: "Moeda custom, não verificada", message: TokenReasonText.anyoneCanCreate)
            ContractPanel(asset: asset)
            if let chain = asset.chain, let reason = CustomToken.sendUnavailableReason(chain) {
                Banner(kind: .neutral, title: "Envio indisponível nesta rede", message: reason)
            }
            TertiaryButton(title: "Remover moeda custom") { removing = true }
                .accessibilityIdentifier("remover-moeda-custom")
        }
    }

    private func customPriceLine(_ asset: Asset) -> String {
        guard let price = row.price else { return "Sem preço confiável por contrato. Fica fora do saldo total." }
        return "Preço por contrato: \(Fmt.price(price, session.currency)) cada."
    }

    private func removeCustom() {
        let ids = Set(row.positions.map(\.asset.id))
        session.metadata.customAssets = session.metadata.customTokens.filter { !ids.contains($0.id) }
        try? session.persist()
        portfolio.customChanged(session.selectedWallet, session: session)
        Task { await portfolio.refresh(session.selectedWallet, session: session) }
        dismiss()
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
    @Environment(Portfolio.self) private var portfolio
    let coingeckoID: String?
    let symbol: String
    let name: String
    let livePrice: Double?
    let liveChange: Double?
    var isStable = false
    var priceAsFigure = true
    /// A linha de 7 dias, hora a hora, que a lista do Mercado ja trouxe: desenha o
    /// grafico na hora, enquanto o detalhado chega.
    var seed: [Double] = []
    /// Tocar no preco mostra a outra moeda (real e dolar), com o grafico junto.
    @State private var alternate = false

    @State private var range: ChartRange = .day
    @State private var points: [PricePoint] = []
    @State private var loading = false
    @State private var selection: PricePoint?
    @State private var failed = false
    /// Hora do grafico na tela quando as fontes falharam e ele e o ultimo bom.
    @State private var staleSince: Date?
    @State private var price: Double?
    @State private var change: Double?
    @State private var tick: Color = Palette.ink

    private var shownPrice: Double? { selection?.price ?? price ?? livePrice ?? points.last?.price }

    private var shownChange: Double? {
        guard let first = displayPoints.first?.price, first > 0 else { return change ?? liveChange }
        if let selection { return (selection.price - first) / first * 100 }
        if range == .day, let current = change ?? liveChange { return current }
        guard let last = displayPoints.last?.price else { return change ?? liveChange }
        return (last - first) / first * 100
    }

    /// A moeda mostrada: a do app, ou a outra (dolar, ou real para quem usa dolar).
    private var displayCurrency: Fmt.Currency {
        alternate ? (session.currency == .usd ? .brl : .usd) : session.currency
    }

    /// Quanto vale 1 da moeda do app na mostrada, pela cotacao do bitcoin. Sem cotacao,
    /// nao ha troca.
    private var factor: Double? {
        guard alternate else { return 1 }
        return portfolio.convert(1, to: Fmt.DisplayUnit(displayCurrency), base: session.currency)
    }

    private var displayPoints: [PricePoint] {
        guard let factor, factor != 1 else { return points }
        return points.map { PricePoint(time: $0.time, price: $0.price * factor) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                // O ponto escolhido no grafico ja vem na moeda mostrada; o preco vivo, nao.
                let live = (price ?? livePrice ?? points.last?.price).flatMap { value in factor.map { value * $0 } }
                let shown = selection?.price ?? live
                if priceAsFigure {
                    Text(shown.map { Fmt.price($0, displayCurrency) } ?? " ")
                        .typeStyle(.figure)
                } else {
                    Text(shown.map { Fmt.price($0, displayCurrency) } ?? " ")
                        .typeStyle(.row)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let next = !alternate
                let target: Fmt.Currency = session.currency == .usd ? .brl : .usd
                guard !next || portfolio.convert(1, to: Fmt.DisplayUnit(target), base: session.currency) != nil else { return }
                withAnimation(Motion.number) { alternate = next }
            }
            .sensoryFeedback(.selection, trigger: alternate)
            .accessibilityHint(session.currency == .usd ? "Toque para ver em reais" : "Toque para ver em dólar")
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

            PriceChart(points: displayPoints, loading: loading && points.isEmpty, isStable: isStable, selection: $selection, currency: displayCurrency)
                .padding(.top, Space.sm)
            if failed && points.isEmpty {
                Text("Não foi possível carregar o gráfico agora.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, Space.gutter)
            } else if let staleSince {
                Text("Gráfico de \(Fmt.stamp(staleSince)). Sem conexão com as fontes agora.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
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
        if points.isEmpty { points = Self.seeded(seed, range: range) }
        loading = true
        defer { loading = false }
        do {
            let snapshot = try await MarketService.shared.chartSnapshot(id: coingeckoID, currency: session.metadata.settings.currency, range: range)
            points = snapshot.points
            staleSince = snapshot.isStale ? snapshot.fetchedAt : nil
            failed = false
        } catch {
            failed = true
        }
    }

    /// O comeco do grafico com a linha de 7 dias da lista: as ultimas 24 horas para 24h,
    /// a linha toda para 7 dias. Os pontos sao horarios e terminam agora.
    static func seeded(_ hourly: [Double], range: ChartRange) -> [PricePoint] {
        let values: [Double]
        switch range {
        case .day: values = Array(hourly.suffix(25))
        case .week: values = hourly
        default: return []
        }
        let now = Date()
        return values.enumerated().map { index, price in
            PricePoint(time: now.addingTimeInterval(-Double(values.count - 1 - index) * 3600), price: price)
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
