import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import SwiftUI

/// P1: quanto eu tenho e em que.
struct WalletHomeView: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @Environment(Router.self) private var router
    @State private var switching = false
    @State private var addingWallet = false
    @State private var receiving = false
    @State private var backingUp = false

    private var wallet: WalletMeta? { session.selectedWallet }
    private var hide: Bool { session.metadata.settings.hideBalances }

    var body: some View {
        NavigationStack(path: Bindable(router).walletPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    actions.padding(.top, Space.lg)
                    if let wallet, !wallet.hasBackup, !wallet.isWatchOnly {
                        Banner(kind: .caution, title: "Esta carteira ainda não tem cópia",
                               message: "Grave as \(wordCount(wallet)) palavras antes de receber. Leva 2 minutos.",
                               actionTitle: "Gravar agora") { backingUp = true }
                            .padding(.horizontal, Space.gutter)
                            .padding(.top, Space.lg)
                    }
                    statusBanners
                    assets.padding(.top, Space.xl)
                }
                .padding(.bottom, Space.xl)
            }
            .refreshable { await portfolio.refresh(wallet, session: session) }
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PortfolioRow.self) { row in
                AssetDetailView(row: row)
            }
        }
        .task(id: wallet?.id) {
            portfolio.show(wallet, session: session)
            await portfolio.refresh(wallet, session: session)
            #if DEBUG
            if DebugDemo.screen == "detalhe", let first = portfolio.rows.first { router.walletPath.append(first) }
            if DebugDemo.screen == "receber" { receiving = true }
            #endif
        }
        .sheet(isPresented: $switching) {
            WalletSwitcherSheet(onAdd: { switching = false; addingWallet = true })
        }
        .sheet(isPresented: $receiving) { ReceiveSheet(preselected: nil) }
        .fullScreenCover(isPresented: $addingWallet) { AddWalletView(isFirst: false) { addingWallet = false } }
        .fullScreenCover(isPresented: $backingUp) {
            if let wallet { RevealFlow(wallet: wallet, purpose: .backup) { backingUp = false } }
        }
    }

    private func wordCount(_ wallet: WalletMeta) -> Int {
        if case .phrase(let count) = wallet.kind { return count }
        return 12
    }

    // MARK: Cabecalho

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { switching = true } label: {
                    HStack(spacing: Space.xs) {
                        if let wallet { WalletGlyph(id: wallet.id, size: 24, selected: true) }
                        Text(wallet?.name ?? "Carteira").typeStyle(.action).foregroundStyle(Palette.ink).lineLimit(1)
                        if wallet?.isWatchOnly == true {
                            Text("Só observar").typeStyle(.label).foregroundStyle(Palette.inkSoft)
                                .padding(.horizontal, 6).frame(height: Height.badge)
                                .background(RoundedRectangle(cornerRadius: Radius.badge).fill(Palette.rail))
                        }
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                    }
                    .frame(minHeight: Height.touch)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    session.metadata.settings.hideBalances.toggle()
                    try? session.persist()
                } label: {
                    Image(systemName: hide ? "eye.slash" : "eye")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Palette.inkSoft)
                        .frame(width: Height.touch, height: Height.touch)
                }
                .accessibilityLabel(hide ? "Mostrar valores" : "Ocultar valores")
            }
            .padding(.horizontal, Space.gutter - 4)

            Text("Saldo total").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                .padding(.horizontal, Space.gutter).padding(.top, Space.md)

            BalanceFigure(value: portfolio.total, currency: session.currency, hidden: hide)
                .padding(.horizontal, Space.gutter).padding(.top, Space.xxs)

            changeLine
                .padding(.horizontal, Space.gutter).padding(.top, Space.xxs)
        }
    }

    @ViewBuilder
    private var changeLine: some View {
        if hide || portfolio.total == 0 {
            Text(" ").typeStyle(.row)
        } else {
            let color = portfolio.change24hFiat > 0 ? Palette.up : (portfolio.change24hFiat < 0 ? Palette.down : Palette.inkSoft)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Fmt.fiat(portfolio.change24hFiat, session.currency, signed: true)) (\(Fmt.percent(portfolio.change24hPercent)))")
                    .typeStyle(.row).foregroundStyle(color)
                Text(portfolio.failedChains.isEmpty ? "24h" : "24h, sem \(portfolio.failedChains.map(\.name).joined(separator: ", "))")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
            .contentTransition(.numericText())
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if wallet?.isWatchOnly != true {
                QuickAction(title: "Enviar", systemImage: "arrow.up") { router.present(.send(nil)) }
            }
            QuickAction(title: "Receber", systemImage: "arrow.down") { receiving = true }
            if wallet?.isWatchOnly != true {
                QuickAction(title: "Trocar", systemImage: "arrow.left.arrow.right") { router.tab = .trade }
                QuickAction(title: "Limite", systemImage: "scope") { router.tab = .trade; router.tradeMode = .limit }
            }
        }
        .padding(.horizontal, Space.xs)
    }

    @ViewBuilder
    private var statusBanners: some View {
        if portfolio.offline, let updated = portfolio.lastUpdated {
            Banner(kind: .neutral, title: "Sem internet. Valores de \(Fmt.relative(updated).lowercased()).")
                .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
        } else if let failed = portfolio.failedChains.first, !portfolio.offline {
            Banner(kind: .neutral, title: "Não foi possível ler o saldo \(failed.id == "xrpl" ? "no" : "na") \(failed.name). Os outros estão em dia.",
                   actionTitle: "Tentar de novo") {
                Task { await portfolio.refresh(wallet, session: session) }
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
        }
    }

    // MARK: Ativos

    private var assets: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack {
            Text("Ativos").typeStyle(.heading).foregroundStyle(Palette.ink)
            Spacer()
            if portfolio.loading { ProgressView().tint(Palette.inkMuted).scaleEffect(0.8) }
        }
        .padding(.horizontal, Space.gutter)

        if portfolio.rows.isEmpty {
            if portfolio.loading && portfolio.lastUpdated == nil {
                skeleton.padding(.top, Space.xs)
            } else {
                emptyState.padding(.top, Space.md)
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(portfolio.rows) { row in
                    NavigationLink(value: row) {
                        AssetRowView(row: row, currency: session.currency, hidden: hide)
                    }
                    .buttonStyle(RowStyle())
                }
            }
            .padding(.top, Space.xs)
            if portfolio.unknownTokens > 0 {
                Text("\(portfolio.unknownTokens) \(portfolio.unknownTokens == 1 ? "token desconhecido escondido" : "tokens desconhecidos escondidos")")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, Space.gutter).padding(.top, Space.md)
            }
        }
        }
    }

    private var skeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: Space.sm) {
                    Circle().fill(Palette.body).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 8) { SkeletonBar(width: 56); SkeletonBar(width: 88) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) { SkeletonBar(width: 72); SkeletonBar(width: 48) }
                }
                .padding(.horizontal, Space.gutter)
                .frame(height: Height.row)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Um endereço em cada rede").typeStyle(.row).foregroundStyle(Palette.ink)
            Text("Esta carteira já tem endereço em Bitcoin, Ethereum, Base, Solana, XRP Ledger, Stellar e outras. Receba em qualquer um para começar.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: -6) {
                ForEach([Chain.bitcoin, .ethereum, .solana, .xrpl, .stellar, .tron, .base], id: \.id) { chain in
                    NetworkBadge(chain: chain, size: 28, ring: Palette.body)
                }
            }
            .padding(.top, Space.md)
            Text("No XRP Ledger e na Stellar, a conta passa a existir no primeiro recebimento de 1 XRP ou 1 XLM, que ficam reservados pela rede.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.md)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "Receber") { receiving = true }.padding(.top, Space.md)
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
        .padding(.horizontal, Space.gutter)
    }
}

/// O saldo grande: "R$" menor e mais claro, o numero em peso, digitos tabulares.
struct BalanceFigure: View {
    let value: Double
    let currency: Fmt.Currency
    var hidden: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(currency.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.inkSoft)
            Text(hidden ? "••••••" : Fmt.grouped(value, fractionDigits: 2))
                .typeStyle(.display)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: value))
                .animation(Motion.number, value: value)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Uma linha de ativo, 64pt, sem filete.
struct AssetRowView: View {
    let row: PortfolioRow
    let currency: Fmt.Currency
    var hidden: Bool = false

    var body: some View {
        HStack(spacing: Space.sm) {
            CoinLogo(
                coingeckoID: row.coingeckoID, symbol: row.symbol, size: 40,
                network: row.positions.count == 1 ? row.positions.first?.asset.chain : nil,
                networkCount: row.positions.count
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(row.symbol).typeStyle(.row).foregroundStyle(Palette.ink)
                HStack(spacing: 6) {
                    if let price = row.price {
                        Text(Fmt.price(price, currency)).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    }
                    if let change = row.change24h {
                        Text(Fmt.percent(change)).typeStyle(.note)
                            .foregroundStyle(change > 0.004 ? Palette.up : (change < -0.004 ? Palette.down : Palette.inkSoft))
                    }
                }
            }
            Spacer(minLength: Space.sm)
            VStack(alignment: .trailing, spacing: 2) {
                Text(hidden ? Redaction.fiat : (row.fiatValue.map { Fmt.fiat($0, currency) } ?? "sem preço"))
                    .typeStyle(.row).foregroundStyle(Palette.ink)
                Text(hidden ? Redaction.short : Fmt.crypto(row.totalAmount, decimals: row.decimals, symbol: row.symbol, style: row.isStablecoin ? .stable : .list))
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(.horizontal, Space.gutter)
        .frame(height: Height.row)
        .contentShape(Rectangle())
    }
}

/// P2: trocar de carteira.
struct WalletSwitcherSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Carteiras") { dismiss() }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(session.metadata.wallets) { wallet in
                        Button {
                            session.select(wallet)
                            dismiss()
                        } label: {
                            HStack(spacing: Space.sm) {
                                WalletGlyph(id: wallet.id, size: 36, selected: wallet.id == session.selectedWallet?.id)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: wallet.name).typeStyle(.row).foregroundStyle(Palette.ink)
                                    Text(subtitle(wallet)).typeStyle(.note)
                                        .foregroundStyle(!wallet.hasBackup && !wallet.isWatchOnly ? Palette.down : Palette.inkSoft)
                                }
                                Spacer()
                                if wallet.id == session.selectedWallet?.id {
                                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                                }
                            }
                            .padding(.horizontal, Space.gutter)
                            .frame(height: Height.row)
                            .background(wallet.id == session.selectedWallet?.id ? Palette.rail : Color.clear)
                        }
                        .buttonStyle(RowStyle(surface: .body))
                    }
                }
                .padding(.top, Space.md)
            }
            PrimaryButton(title: "Adicionar carteira", action: onAdd)
                .padding(.horizontal, Space.gutter).padding(.bottom, Space.xs)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
        .sensoryFeedback(.selection, trigger: session.selectedWallet?.id)
    }

    private func subtitle(_ wallet: WalletMeta) -> String {
        switch wallet.kind {
        case .watch(let chainID): return "Só observar · \(Chain.find(chainID)?.name ?? chainID)"
        case .phrase(let count):
            if !wallet.hasBackup { return "Sem cópia" }
            return "\(count) palavras · \(wallet.accounts.count) redes"
        }
    }
}
