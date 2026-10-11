import EscaliburChains
import EscaliburCore
import EscaliburEngines
import SwiftUI

/// As ordens limite abertas desta carteira numa rede, lidas da rede, ali mesmo na tela
/// da ordem limite, e o cancelamento (auditoria 2, A3). O cancelamento passa pela mesma
/// revisao, PIN e assinatura de qualquer plano.
///
/// A lista rele a cada 5 segundos enquanto esta na tela: o anel de cada ordem mostra
/// quanto ja foi preenchido. A ordem que some da lista (executou, venceu ou foi
/// cancelada) fica com o resultado final ate a tela fechar.
struct OpenOrdersSection: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    let chain: Chain
    /// Muda quando uma ordem foi criada ou cancelada fora daqui: a lista rele.
    var refresh: Int = 0
    /// Na troca imediata: a secao so aparece quando ha ordem (a troca pela CoW e uma
    /// ordem que pode levar alguns leiloes).
    var hidesWhenEmpty = false

    enum Load { case loading, loaded([OpenOrder]), failed(String) }
    @State private var load: Load = .loading
    /// As que sairam da lista nesta visita, com o andamento final.
    @State private var finished: [FinishedOrder] = []

    struct FinishedOrder: Identifiable {
        let order: OpenOrder
        let progress: OrderProgress
        var id: String { order.id }
    }

    static let pollInterval: Duration = .seconds(5)
    @State private var choosing: OpenOrder?
    @State private var reviewing: TradeReviewFlow.Item?

    private var engine: (any TradeEngine)? { TradeEngines.engine(for: chain) }
    private var canSign: Bool { session.selectedWallet?.isWatchOnly == false }

    private var hasRows: Bool {
        if case .loaded(let orders) = load, !orders.isEmpty { return true }
        return !finished.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if !hidesWhenEmpty || hasRows {
                Text("Ordens abertas").typeStyle(.heading).foregroundStyle(Palette.ink)
                content
            }
        }
        .task(id: "\(chain.id)-\(refresh)") {
            await reload(initial: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                await reload(initial: false)
            }
        }
        .confirmationDialog("Cancelar esta ordem?", isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                            titleVisibility: .visible, presenting: choosing) { order in
            if let via = Self.safest(order.cancellations) {
                Button("Cancelar a ordem", role: .destructive) {
                    reviewing = TradeReviewFlow.Item(kind: .cancel(order, via), chain: chain, fiat: nil)
                }
            }
            Button("Manter a ordem", role: .cancel) {}
        } message: { order in
            Text(Self.explanation(Self.safest(order.cancellations)))
        }
        .fullScreenCover(item: $reviewing) { item in
            TradeReviewFlow(item: item) { completed in
                reviewing = nil
                if completed { Task { await reload() } }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            HStack(spacing: Space.sm) {
                ProgressView().tint(Palette.inkSoft)
                Text("Lendo as ordens na rede.").typeStyle(.note).foregroundStyle(Palette.inkSoft)
            }
            .frame(minHeight: 44)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(message).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                TertiaryButton(title: "Tentar de novo") { Task { await reload() } }
            }
        case .loaded(let orders) where orders.isEmpty && finished.isEmpty:
            Text("Nenhuma ordem aberta \(chain.id == "xrpl" ? "no" : "na") \(chain.name). A que você criar aparece aqui até executar, vencer ou você cancelar.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
        case .loaded(let orders):
            VStack(spacing: 0) {
                ForEach(orders) { order in row(order) }
                ForEach(finished) { item in finishedRow(item) }
            }
            if orders.isEmpty {
                EmptyView()
            } else if !canSign {
                Text("Esta carteira só acompanha: para cancelar, abra a carteira que assina.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Toque numa ordem para cancelar.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
        }
    }

    private func assets(_ order: OpenOrder) -> (sell: Asset?, buy: Asset?) {
        (TradedAssets.resolve(order.sellAssetID, listed: order.sell, chain: chain, session: session, portfolio: portfolio),
         TradedAssets.resolve(order.buyAssetID, listed: order.buy, chain: chain, session: session, portfolio: portfolio))
    }

    private func logo(_ asset: Asset?) -> some View {
        let unverified = asset?.origin != nil
        return CoinLogo(coingeckoID: asset?.coingeckoID, symbol: asset?.symbol ?? "?", size: 36, network: chain,
                        unverified: unverified, logoAsset: unverified ? asset : nil)
    }

    /// O preco limite: quanto do comprado por uma unidade do vendido, pelo minimo
    /// gravado na ordem.
    static func limitPrice(_ order: OpenOrder, sell: Asset?, buy: Asset?) -> String? {
        guard let sell, let buy, !order.remainingSell.isZero else { return nil }
        let sold = Fmt.double(order.remainingSell, decimals: sell.decimals)
        let bought = Fmt.double(order.minimumBuy, decimals: buy.decimals)
        guard sold > 0, bought > 0 else { return nil }
        let text = TradeView.priceText(bought / sold)
        return "Preço: 1 \(sell.symbol) = \(Fmt.compactZeros(text) ?? text) \(buy.symbol)"
    }

    private func row(_ order: OpenOrder) -> some View {
        let (sell, buy) = assets(order)
        return Button { choosing = order } label: {
            HStack(spacing: Space.sm) {
                logo(sell)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vende \(Self.amount(order.totalSell ?? order.remainingSell, sell))").typeStyle(.row).foregroundStyle(Palette.ink)
                    if let received = order.receivedBuy, !received.isZero {
                        Text("Recebido \(Self.amount(received, buy)), falta vender \(Self.amount(order.remainingSell, sell))")
                            .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("por no mínimo \(Self.amount(order.minimumBuy, buy))").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    }
                    if let price = Self.limitPrice(order, sell: sell, buy: buy) {
                        Text(price).typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    if order.filledFraction != nil {
                        Text(Self.expiry(order.expiresAt)).typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    }
                }
                Spacer(minLength: Space.sm)
                if let fraction = order.filledFraction {
                    FillRing(fraction: fraction, size: 44)
                } else {
                    Text(Self.expiry(order.expiresAt)).typeStyle(.note).foregroundStyle(Palette.inkSoft).multilineTextAlignment(.trailing)
                }
            }
            .frame(minHeight: Height.row)
            .padding(.vertical, Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSign || order.cancellations.isEmpty)
        .accessibilityHint(canSign ? "Cancelar a ordem" : "")
    }

    private func finishedRow(_ item: FinishedOrder) -> some View {
        let progress = item.progress
        let order = item.order
        let (sell, buy) = assets(order)
        let outcome: String
        switch progress.state {
        case .filled: outcome = "Executada. Recebido \(Self.amount(progress.receivedBuy, buy))"
        case .expired: outcome = progress.fraction > 0 ? "Venceu com \(FillRing.percentText(progress.fraction)) preenchido" : "Venceu sem preencher"
        case .cancelled: outcome = progress.fraction > 0 ? "Cancelada com \(FillRing.percentText(progress.fraction)) preenchido" : "Cancelada"
        case .open: outcome = ""
        }
        return HStack(spacing: Space.sm) {
            logo(sell)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vende \(Self.amount(progress.totalSell, sell))").typeStyle(.row).foregroundStyle(Palette.ink)
                Text(outcome).typeStyle(.note).foregroundStyle(progress.state == .filled ? Palette.up : Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            FillRing(fraction: progress.fraction, size: 44)
        }
        .frame(minHeight: Height.row)
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .combine)
    }

    /// `initial`: a primeira leitura mostra o carregando e o erro. As seguintes so
    /// trocam a lista quando a leitura volta; falha no meio mantem a lista que havia.
    private func reload(initial: Bool = true) async {
        guard let engine, let account = session.selectedWallet?.account(chain) else {
            load = .failed("Esta carteira não tem conta nesta rede.")
            return
        }
        if initial {
            load = .loading
            finished = []
        }
        let before: [OpenOrder]
        if case .loaded(let orders) = load { before = orders } else { before = [] }
        do {
            let orders = try await engine.openOrders(account: account)
            // A que saiu da lista terminou: le o andamento final para mostrar o resultado.
            let current = Set(orders.map(\.id))
            for order in before where !current.contains(order.id) && !finished.contains(where: { $0.id == order.id }) {
                if let progress = try? await engine.orderProgress(id: order.id, account: account), progress.isFinal {
                    finished.append(FinishedOrder(order: order, progress: progress))
                }
            }
            load = .loaded(orders)
        } catch {
            if initial {
                load = .failed((error as? LocalizedError)?.errorDescription ?? "Não foi possível ler as ordens agora. Tente de novo.")
            }
        }
    }

    // MARK: Textos

    /// Ativo fora da lista (ordem criada fora da carteira) nao ganha nome nem casas da
    /// rede: aparece como tal, sem numero que poderia estar errado.
    static func amount(_ value: BigUInt, _ asset: Asset?) -> String {
        guard let asset else { return "um token fora da lista" }
        return Fmt.crypto(value, decimals: asset.decimals, symbol: asset.symbol)
    }

    static func expiry(_ date: Date?) -> String {
        guard let date else { return "Até cancelar" }
        let relative = date.formatted(Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .wide).locale(Fmt.locale))
        return "Vence \(relative)"
    }

    /// Um jeito so de cancelar, o garantido: a transacao na rede, que invalida a ordem
    /// de vez. O pedido gratis a CoW nao garante (um solver que ja estava executando ainda
    /// conclui), e duas opcoes confundiam (pedido do dono, 11/10/2026).
    static func safest(_ options: [OpenOrder.Cancellation]) -> OpenOrder.Cancellation? {
        options.contains(.onchain) ? .onchain : options.first
    }

    static func explanation(_ via: OpenOrder.Cancellation?) -> String {
        switch via {
        case .onchain?: return "A carteira envia uma transação que invalida a ordem de vez, com a taxa da rede. Depois que ela confirmar, a ordem não executa mais, e o que não foi vendido continua na sua carteira."
        case .offchain?: return "A carteira pede à CoW para parar de oferecer a ordem. O que não foi vendido continua na sua carteira."
        case nil: return "Esta ordem não pode ser cancelada pela carteira."
        }
    }
}

/// Os tokens fora da lista que a carteira conhece, para as ordens abertas mostrarem o
/// nome, as casas e a logo deles: a moeda adicionada, o que esta no saldo e o que ja foi
/// usado numa ordem ou troca.
@MainActor
enum TradedAssets {
    static let limit = 50

    static func remember(_ assets: [Asset], session: AppSession) {
        let unlisted = assets.filter { $0.origin != nil }
        guard !unlisted.isEmpty else { return }
        var list = session.metadata.tradedAssets ?? []
        for asset in unlisted where !list.contains(where: { $0.id == asset.id }) { list.insert(asset, at: 0) }
        session.metadata.tradedAssets = Array(list.prefix(limit))
        try? session.persist()
    }

    static func resolve(_ id: String, listed: Asset?, chain: Chain, session: AppSession, portfolio: Portfolio) -> Asset? {
        if let listed { return listed }
        if let custom = session.metadata.customTokens.first(where: { $0.id == id }) { return custom }
        if let held = portfolio.balance(chain)?.unlisted?.first(where: { $0.asset.id == id && !$0.isSuspicious }) { return held.asset }
        return session.metadata.tradedAssets?.first { $0.id == id }
    }
}
