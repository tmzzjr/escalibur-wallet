import EscaliburChains
import EscaliburCore
import EscaliburEngines
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
                    if DeviceIntegrity.suspicious {
                        Banner(kind: .caution, title: "Este iPhone parece ter jailbreak",
                               message: "Apps de fora da App Store podem ler o que este app guarda. Para valor alto, prefira uma carteira de hardware.")
                            .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                    }
                    assets.padding(.top, Space.xl)
                    // A distribuicao vem depois da lista: primeiro o que a carteira tem,
                    // depois como isso se divide.
                    if portfolio.rows.count >= 2 {
                        VStack(alignment: .leading, spacing: Space.md) {
                            Text("Distribuição").typeStyle(.heading).foregroundStyle(Palette.ink)
                            AllocationDonut(rows: portfolio.rows, hidden: hide)
                        }
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.xl)
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .refreshable { await portfolio.refresh(wallet, session: session) }
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .statusBarBackdrop()
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
            if DebugDemo.screen == "revelar" { backingUp = true }
            if DebugDemo.screen == "adicionar" { addingWallet = true }
            #endif
        }
        .sheet(isPresented: $switching) {
            WalletSwitcherSheet(onAdd: { switching = false; addingWallet = true })
        }
        .sheet(isPresented: $receiving) { ReceiveSheet(preselected: nil) }
        #if DEBUG
        .modifier(DemoEnvelopes())
        #endif
        .fullScreenCover(isPresented: $addingWallet) { AddWalletView(isFirst: false) { addingWallet = false } }
        .fullScreenCover(isPresented: $backingUp) {
            if let wallet { RevealFlow(wallet: wallet, purpose: .backup) { backingUp = false } }
        }
    }

    // MARK: Unidade do total

    /// A escolhida, se ha cotacao para ela agora; senao a moeda do app.
    private var unit: Fmt.DisplayUnit {
        let saved = session.metadata.settings.totalUnit.flatMap(Fmt.DisplayUnit.init(rawValue:)) ?? Fmt.DisplayUnit(session.currency)
        return availableUnits.contains(saved) ? saved : Fmt.DisplayUnit(session.currency)
    }

    private var availableUnits: [Fmt.DisplayUnit] {
        Fmt.DisplayUnit.allCases.filter { portfolio.convert(1, to: $0, base: session.currency) != nil }
    }

    private var unitBinding: Binding<Fmt.DisplayUnit> {
        Binding(get: { unit }, set: { newValue in
            session.metadata.settings.totalUnit = newValue.rawValue
            try? session.persist()
        })
    }

    private var shownTotal: Double { portfolio.convert(portfolio.total, to: unit, base: session.currency) ?? portfolio.total }
    private var shownChange: Double { portfolio.convert(portfolio.change24hFiat, to: unit, base: session.currency) ?? portfolio.change24hFiat }

    static func signed(_ value: Double, _ unit: Fmt.DisplayUnit) -> String {
        let sign = value < 0 ? Fmt.minus : (value > 0 ? "+" : "")
        return "\(sign)\(unit.symbol)\u{00A0}\(Fmt.grouped(abs(value), fractionDigits: unit.fractionDigits))"
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
                        .frame(width: Height.touch, height: Height.touch, alignment: .trailing)
                }
                .accessibilityLabel(hide ? "Mostrar valores" : "Ocultar valores")
            }
            .padding(.horizontal, Space.gutter)

            HStack(alignment: .center) {
                Text("Saldo total").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                Spacer()
                UnitPicker(selection: unitBinding, available: availableUnits)
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.md)

            BalanceFigure(value: shownTotal, symbol: unit.symbol, fractionDigits: unit.fractionDigits, hidden: hide)
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
                Text("\(Self.signed(shownChange, unit)) (\(Fmt.percent(portfolio.change24hPercent)))")
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
            if wallet?.isWatchOnly != true, !TradeEngines.chains.isEmpty {
                QuickAction(title: "Trocar", systemImage: "arrow.left.arrow.right") { router.tab = .trade }
            }
        }
        .padding(.horizontal, Space.xs)
    }

    @ViewBuilder
    private var statusBanners: some View {
        if portfolio.offline, let updated = portfolio.lastUpdated {
            Banner(kind: .neutral, title: "Sem internet. Valores de \(Fmt.relative(updated).lowercased()).")
                .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
        } else if portfolio.offline {
            // Sem cache nenhum (primeira abertura, carteira recem importada): sem este
            // aviso a tela mostraria saldo zero, e zero parece frase errada.
            Banner(kind: .neutral, title: "Sem internet. Os saldos aparecem quando a conexão voltar.",
                   actionTitle: "Tentar de novo") {
                Task { await portfolio.refresh(wallet, session: session) }
            }
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
            if portfolio.loading { ProgressView().tint(Palette.inkMuted).scaleEffect(0.7) }
            Spacer()
            if !portfolio.allRows.isEmpty {
                NavigationLink { ManageAssetsView() } label: {
                    Text("Gerenciar").typeStyle(.body).foregroundStyle(Palette.inkSoft).frame(minHeight: Height.touch)
                }
            }
        }
        .padding(.horizontal, Space.gutter)

        if portfolio.rows.isEmpty {
            if portfolio.loading && portfolio.lastUpdated == nil {
                skeleton.padding(.top, Space.xs)
            } else if portfolio.lastUpdated == nil, portfolio.offline || !portfolio.failedChains.isEmpty {
                unreadState.padding(.top, Space.md)
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
                NavigationLink { ManageAssetsView() } label: {
                    HStack(spacing: 4) {
                        Text("\(portfolio.unknownTokens) \(portfolio.unknownTokens == 1 ? "token desconhecido escondido" : "tokens desconhecidos escondidos")")
                            .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                    }
                    .frame(minHeight: Height.touch)
                }
                .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
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
                .frame(minHeight: Height.row)
            }
        }
    }

    /// Nenhum saldo lido ainda: nao e carteira vazia, e leitura que nao aconteceu.
    private var unreadState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Os saldos ainda não foram lidos").typeStyle(.row).foregroundStyle(Palette.ink)
            Text("As redes não responderam agora. Isso não quer dizer que a carteira está vazia: os valores aparecem quando a leitura der certo.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "Tentar de novo") { Task { await portfolio.refresh(wallet, session: session) } }
                .padding(.top, Space.md)
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
        .padding(.horizontal, Space.gutter)
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
    let symbol: String
    var fractionDigits: Int = 2
    var hidden: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.inkSoft)
                .contentTransition(.opacity)
            if hidden {
                Text("••••••").typeStyle(.display).foregroundStyle(Palette.ink)
            } else {
                // O inteiro sozinho no tamanho grande; as casas menores e mais claras,
                // como o simbolo, na mesma linha de base.
                let text = Fmt.grouped(value, fractionDigits: fractionDigits)
                let parts = text.split(separator: ",", maxSplits: 1).map(String.init)
                (Text(parts[0]).style(.display).foregroundColor(Palette.ink)
                 + Text("," + (parts.count > 1 ? parts[1] : String(repeating: "0", count: fractionDigits)))
                    .font(.system(size: fractionDigits > 2 ? 22 : 28, weight: .bold).monospacedDigit()).foregroundColor(Palette.inkSoft))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText(value: value))
                    .animation(Motion.number, value: value)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// R$, US$, €, ₿: em que unidade o total aparece. Capsulas pequenas, a escolhida
/// preenchida; a troca anima o numero.
struct UnitPicker: View {
    @Binding var selection: Fmt.DisplayUnit
    let available: [Fmt.DisplayUnit]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(available, id: \.self) { unit in
                Button {
                    withAnimation(Motion.select) { selection = unit }
                } label: {
                    Text(unit.symbol)
                        .typeStyle(.label)
                        .foregroundStyle(selection == unit ? Palette.ink : Palette.inkMuted)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .background {
                            if selection == unit {
                                Capsule(style: .continuous).fill(Palette.control)
                                    .matchedGeometryEffect(id: "unidade", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(unit.name)
                .accessibilityAddTraits(selection == unit ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Palette.body))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Uma linha de ativo, 64pt, sem filete. Nos tamanhos de texto de acessibilidade, os
/// valores descem para linhas proprias: numero nunca quebra no meio.
struct AssetRowView: View {
    let row: PortfolioRow
    let currency: Fmt.Currency
    var hidden: Bool = false
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        Group {
            if dynamicType.isAccessibilitySize { stacked } else { inline }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, dynamicType.isAccessibilitySize ? Space.sm : 0)
        .frame(minHeight: Height.row)
        .contentShape(Rectangle())
    }

    private var inline: some View {
        HStack(spacing: Space.sm) {
            logo
            VStack(alignment: .leading, spacing: 2) {
                Text(row.symbol).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                HStack(spacing: 6) { priceAndChange }
            }
            Spacer(minLength: Space.sm)
            VStack(alignment: .trailing, spacing: 2) {
                fiatValue
                amount
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.sm) {
                logo
                Text(row.symbol).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
            }
            fiatValue
            amount
            HStack(spacing: 6) { priceAndChange }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var logo: some View {
        CoinLogo(
            coingeckoID: row.coingeckoID, symbol: row.symbol, size: 40,
            network: row.positions.count == 1 ? row.positions.first?.asset.chain : nil,
            networkCount: row.positions.count
        )
    }

    @ViewBuilder
    private var priceAndChange: some View {
        if let price = row.price {
            Text(Fmt.price(price, currency)).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        if let change = row.change24h {
            Text(Fmt.percent(change)).typeStyle(.note)
                .foregroundStyle(change > 0.004 ? Palette.up : (change < -0.004 ? Palette.down : Palette.inkSoft))
                .lineLimit(1).fixedSize()
        }
    }

    private var fiatValue: some View {
        Text(hidden ? Redaction.fiat : (row.fiatValue.map { Fmt.fiat($0, currency) } ?? "sem preço"))
            .typeStyle(.row).foregroundStyle(Palette.ink)
            .lineLimit(1).minimumScaleFactor(0.6)
    }

    private var amount: some View {
        Text(hidden ? Redaction.short : Fmt.crypto(row.totalAmount, decimals: row.decimals, symbol: row.symbol, style: row.isStablecoin ? .stable : .list))
            .typeStyle(.note).foregroundStyle(Palette.inkSoft)
            .lineLimit(1).minimumScaleFactor(0.6)
    }
}

/// P2: trocar de carteira.
struct WalletSwitcherSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onAdd: () -> Void
    @State private var renaming: WalletMeta?
    @State private var newName = ""

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
                                        .foregroundStyle(!wallet.hasBackup && !wallet.isWatchOnly ? Palette.caution : Palette.inkSoft)
                                }
                                Spacer()
                                if wallet.id == session.selectedWallet?.id {
                                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                                }
                                Button {
                                    newName = wallet.name
                                    renaming = wallet
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Palette.inkSoft)
                                        .frame(width: Height.touch, height: Height.touch)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Editar o nome de \(wallet.name)")
                            }
                            .padding(.horizontal, Space.gutter)
                            .frame(minHeight: Height.row)
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
        .alert("Nome da carteira", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Cancelar", role: .cancel) { renaming = nil }
            Button("Salvar") { saveName() }
        } message: {
            Text("Só aparece neste iPhone.")
        }
    }

    /// O nome passa pelo mesmo saneamento dos nomes vindos de envelope: sem controle,
    /// sem caractere invisivel, ate 40 caracteres.
    private func saveName() {
        guard var wallet = renaming else { return }
        let clean = Envelope.sanitize(newName, limit: 40)
        renaming = nil
        guard !clean.isEmpty else { return }
        wallet.name = clean
        session.update(wallet)
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
