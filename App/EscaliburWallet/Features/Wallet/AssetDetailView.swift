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
    private var canTrade: Bool { !row.positions.isEmpty && row.positions.allSatisfy { TradeAccess.allows($0.asset) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                position.padding(.horizontal, Space.gutter)
                if row.isCustom, let asset = row.positions.first?.asset {
                    // Moeda custom: o dono conferiu e adicionou o contrato; o grafico vem dele
                    // (CoinGecko ou, sem listagem, a pool de DEX).
                    MarketChartSection(
                        coingeckoID: nil, symbol: row.symbol, name: row.name, livePrice: row.price, liveChange: row.change24h,
                        isStable: false, priceAsFigure: false, contractAsset: asset
                    )
                    .padding(.top, Space.lg)
                    customDetails(asset).padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                } else if let identity = row.recognized {
                    // Reconhecida pelo CoinGecko: o grafico de la, o aviso de que nao e da
                    // lista conferida e o contrato inteiro de cada rede.
                    MarketChartSection(
                        coingeckoID: identity.coingeckoID, symbol: row.symbol, name: row.name,
                        livePrice: row.price, liveChange: row.change24h, isStable: false, priceAsFigure: false
                    )
                    .padding(.top, Space.lg)
                    recognizedDetails.padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                } else {
                    // Fora da lista e sem reconhecimento (um token com aviso do CoinGecko,
                    // por exemplo): o grafico vem pelo contrato, so se ele ja tem preco.
                    // Token suspeito nunca tem preco, entao nunca ganha grafico.
                    let byContract = row.coingeckoID == nil && row.price != nil ? row.positions.first?.asset : nil
                    MarketChartSection(
                        coingeckoID: row.coingeckoID, symbol: row.symbol, name: row.name,
                        livePrice: row.price, liveChange: row.change24h, isStable: row.isStablecoin, priceAsFigure: false,
                        contractAsset: byContract
                    )
                    .padding(.top, Space.lg)
                    if let byContract { ContractNoticeBanner(asset: byContract).padding(.horizontal, Space.gutter).padding(.top, Space.lg) }
                    if row.positions.count > 1 { networks.padding(.top, Space.xl) }
                    contract.padding(.top, Space.lg)
                }
                AssetActivitySection(row: row).padding(.top, Space.xl)
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
                             logoAsset: row.contractLogoAsset)
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
                        SecondaryButton(title: String(localized: "Enviar"), height: Height.primary) { router.present(.send(row.positions.first?.asset)) }
                        SecondaryButton(title: String(localized: "Receber"), height: Height.primary) { receiving = true }
                        if canTrade, let asset = row.positions.first?.asset {
                            PrimaryButton(title: String(localized: "Trocar")) {
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
            Banner(kind: .caution, title: String(localized: "Moeda custom, não verificada"), message: TokenReasonText.anyoneCanCreate)
            ContractPanel(asset: asset)
            if let chain = asset.chain, let reason = CustomToken.sendUnavailableReason(chain) {
                Banner(kind: .neutral, title: String(localized: "Envio indisponível nesta rede"), message: reason)
            }
            TertiaryButton(title: String(localized: "Remover moeda custom")) { removing = true }
                .accessibilityIdentifier("remover-moeda-custom")
        }
    }

    /// Moeda reconhecida: listada no CoinGecko com o contrato exato, fora da lista
    /// conferida. Mostra de onde vem o nome e o contrato inteiro de cada rede.
    private var recognizedDetails: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Banner(kind: .neutral, title: String(localized: "Listada no CoinGecko, não conferida pela Escalibur"),
                   message: String(localized: "O nome, o símbolo e a logo vêm do CoinGecko, que lista este contrato. A troca fica só para as moedas da lista conferida. Ao enviar, confira o contrato inteiro."))
            ForEach(row.positions, id: \.asset.id) { holding in
                ContractPanel(asset: holding.asset)
            }
        }
    }

    private func customPriceLine(_ asset: Asset) -> String {
        guard let price = row.price else { return String(localized: "Sem preço confiável por contrato. Fica fora do saldo total.") }
        return String(localized: "Preço por contrato: \(Fmt.price(price, session.currency)) cada.")
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
            Text(hidden ? Redaction.fiat : (row.fiatValue.map { Fmt.fiat($0, session.currency) } ?? String(localized: "sem preço")))
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
                    Text(chain.id == "xrpl" ? "Contrato no \(chain.name)" : "Contrato na \(chain.name)").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    Text(verbatim: Fmt.address(address)).typeStyle(.monoSmall).foregroundStyle(Palette.inkSoft)
                }
                Spacer()
                Button {
                    Pasteboard.copyAddress(address)
                    toasts.show(String(localized: "Contrato copiado."))
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
    /// Sem id: o grafico pelo contrato deste token (`MarketService.contractChartSnapshot`).
    var contractAsset: Asset? = nil
    /// Tocar no preco mostra a outra moeda (real e dolar), com o grafico junto.
    @State private var alternate = false

    @State private var range: ChartRange = .day
    @State private var points: [PricePoint] = []
    @State private var loading = false
    @State private var selection: PricePoint?
    @State private var failed = false
    /// Pelo contrato: de onde veio o grafico (CoinGecko, ou a pool de DEX), ou que nenhuma
    /// das duas fontes tem o token.
    @State private var tokenSource: TokenChartSource?

    enum TokenChartSource: Equatable {
        case coingecko
        case dex(DexPool)
        case none
    }
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

    /// A unidade mostrada: a escolhida em Ativos (real, dolar, euro ou bitcoin), ou, ao
    /// tocar no preco, a outra (o dolar, ou o real para quem nao usa real).
    private var displayUnit: Fmt.DisplayUnit {
        alternate ? alternateUnit : session.metadata.settings.displayUnit
    }

    private var alternateUnit: Fmt.DisplayUnit { session.metadata.settings.displayUnit == .brl ? .usd : .brl }

    /// Quanto vale 1 da moeda dos precos na unidade mostrada, pela cotacao do bitcoin. Sem
    /// cotacao, nao ha troca.
    private var factor: Double? {
        let unit = displayUnit
        if unit == Fmt.DisplayUnit(session.currency) { return 1 }
        return portfolio.convert(1, to: unit, base: session.currency)
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
                    Text(shown.map { Fmt.price($0, unit: displayUnit) } ?? " ")
                        .typeStyle(.figure)
                } else {
                    Text(shown.map { Fmt.price($0, unit: displayUnit) } ?? " ")
                        .typeStyle(.row)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let next = !alternate
                guard !next || portfolio.convert(1, to: alternateUnit, base: session.currency) != nil else { return }
                withAnimation(Motion.number) { alternate = next }
            }
            .sensoryFeedback(.selection, trigger: alternate)
            .accessibilityHint(alternateUnit == .brl ? "Toque para ver em reais" : "Toque para ver em dólar")
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

            PriceChart(points: displayPoints, loading: loading && points.isEmpty, isStable: isStable, selection: $selection, unit: displayUnit)
                .padding(.top, Space.sm)
            if tokenSource == TokenChartSource.none {
                Text("Sem gráfico: o CoinGecko não lista este contrato e o GeckoTerminal não tem pool com liquidez para ele.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.gutter)
            } else if failed && points.isEmpty {
                Text("Não foi possível carregar o gráfico agora.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, Space.gutter)
            } else if let staleSince {
                Text("Gráfico de \(Fmt.stamp(staleSince)). Sem conexão com as fontes agora.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, Space.gutter)
            }
            PeriodPicker(range: $range)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.sm)
            if let note = sourceNote {
                Text(note).typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.sm)
            }
        }
        .task(id: range) { await load() }
        .task { await live() }
    }

    private var periodLabel: String {
        switch range {
        case .day: return String(localized: "em 24h")
        case .week: return String(localized: "em 7 dias")
        case .month: return String(localized: "em 30 dias")
        case .year: return String(localized: "em 1 ano")
        case .all: return String(localized: "desde o início")
        }
    }

    /// De onde vem o grafico de um token fora da lista, dito embaixo dele.
    private var sourceNote: String? {
        switch tokenSource {
        case .coingecko?:
            return String(localized: "Gráfico do CoinGecko, pelo contrato. O token não está na lista conferida da Escalibur.")
        case .dex(let pool)?:
            let liquidity = "US$\(Fmt.nbsp)\(Fmt.compact(pool.reserveUSD))"
            return String(localized: "Preço da pool \(pool.name) na \(pool.dex), com \(liquidity) de liquidez, pelo GeckoTerminal. É preço de DEX: qualquer um cria uma pool, e por isso ele não entra no saldo total.")
        default:
            return nil
        }
    }

    private func load() async {
        guard coingeckoID != nil || contractAsset != nil else { return }
        if points.isEmpty { points = Self.seeded(seed, range: range) }
        loading = true
        defer { loading = false }
        let currency = session.metadata.settings.currency
        if let coingeckoID {
            do {
                let snapshot = try await MarketService.shared.chartSnapshot(id: coingeckoID, currency: currency, range: range)
                points = snapshot.points
                staleSince = snapshot.isStale ? snapshot.fetchedAt : nil
                failed = false
            } catch {
                failed = true
            }
            return
        }
        // Pelo contrato: CoinGecko e GeckoTerminal limitam por IP (o CoinGecko fica de fora
        // pelo menos 1 minuto depois de um 429). Tenta de novo enquanto a tela esta aberta;
        // "nao listado em nenhum" e resposta, e para.
        for delay in Self.contractRetryDelays {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let asset = contractAsset else { return }
            do {
                let chart = try await MarketService.shared.tokenChart(asset, currency: currency, range: range)
                points = chart.snapshot.points
                staleSince = chart.snapshot.isStale ? chart.snapshot.fetchedAt : nil
                tokenSource = chart.pool.map { .dex($0) } ?? .coingecko
                failed = false
                return
            } catch HTTPClient.Failure.status(404) {
                tokenSource = TokenChartSource.none
                points = []
                return
            } catch {
                failed = true
            }
        }
    }

    static let contractRetryDelays: [Double] = [0, 6, 15, 30, 60]

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

/// O aviso que o CoinGecko poe no token (dono do contrato pode bloquear venda, mudar taxa,
/// cunhar), para o token sem reconhecimento que mostra grafico pelo contrato. O texto vem
/// em ingles, como o CoinGecko publica; o app nao traduz o que nao escreveu.
struct ContractNoticeBanner: View {
    let asset: Asset
    @State private var notice: String?

    var body: some View {
        Group {
            if let notice {
                Banner(kind: .caution, title: String(localized: "O CoinGecko marca este token com um aviso"),
                       message: String(localized: "O aviso, como o CoinGecko publica: \u{201C}\(notice)\u{201D}"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: asset.id) {
            for delay in MarketChartSection.contractRetryDelays {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                // Sem erro, a resposta vale, com ou sem aviso; com erro (limite), de novo.
                if let read = try? await MarketService.shared.contractNotice(asset) {
                    notice = read
                    return
                }
            }
        }
    }
}
