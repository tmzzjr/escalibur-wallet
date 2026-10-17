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
    @State private var offeringReceipts = false

    private var wallet: WalletMeta? { session.selectedWallet }
    private var hide: Bool { session.metadata.settings.hideBalances }

    var body: some View {
        NavigationStack(path: Bindable(router).walletPath) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top)
                    header
                    actions.padding(.top, Space.lg)
                    if let wallet, !wallet.hasBackup, !wallet.isWatchOnly {
                        Group {
                            if wallet.wordsConfirmed {
                                Banner(kind: .caution, title: String(localized: "Falta conferir a passphrase"),
                                       message: String(localized: "Digite a passphrase de novo, de onde você anotou, antes de receber."),
                                       actionTitle: String(localized: "Conferir agora")) { backingUp = true }
                            } else {
                                Banner(kind: .caution, title: String(localized: "Falta confirmar que você anotou as palavras"),
                                       message: String(localized: "Grave as \(wordCount(wallet)) palavras antes de receber. Leva 2 minutos."),
                                       actionTitle: String(localized: "Gravar agora")) { backingUp = true }
                            }
                        }
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.lg)
                    }
                    statusBanners
                    if DeviceIntegrity.suspicious {
                        Banner(kind: .caution, title: String(localized: "Este iPhone parece ter jailbreak"),
                               message: String(localized: "Apps de fora da App Store podem ler o que este app guarda. Para valor alto, prefira uma carteira de hardware."))
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
            // A Carteira abre sempre no topo, no nome e no saldo: com muitos "Outros tokens", as
            // listas preguicosas seguravam uma linha no lugar quando as linhas chegavam e
            // trocavam de ordem com os precos, e a tela descia (visto pelo dono, 16/10/2026).
            // As listas sao pilhas comuns; trocar de carteira volta ao topo.
            .defaultScrollAnchor(.top)
            .onChange(of: wallet?.id) { proxy.scrollTo(Self.top, anchor: .top) }
            .refreshable { await portfolio.refresh(wallet, session: session) }
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .statusBarBackdrop()
            .navigationDestination(for: PortfolioRow.self) { row in
                AssetDetailView(row: row)
            }
            .navigationDestination(for: UnlistedHolding.self) { holding in
                OtherTokenDetailView(holding: holding)
            }
            .navigationDestination(for: ManageAssetsRoute.self) { _ in ManageAssetsView() }
            }
        }
        #if DEBUG
        // As telas que nao dependem do saldo abrem logo, depois de a Carteira assentar: a
        // leitura de todas as redes passava dos 20 s, e apresentada cedo demais a folha as
        // vezes nao abria (visto nos testes de interface).
        .task {
            guard DebugDemo.screen != nil else { return }
            await DebugDemo.settle()
            if ["receber", "receber-btc"].contains(DebugDemo.screen) { receiving = true }
            if DebugDemo.screen == "revelar" { backingUp = true }
            if DebugDemo.screen == "adicionar" { addingWallet = true }
            if DebugDemo.screen == "gerenciar" { router.walletPath.append(ManageAssetsRoute()) }
        }
        #endif
        .task(id: wallet?.id) {
            portfolio.show(wallet, session: session)
            await portfolio.refresh(wallet, session: session, force: false)
            // O historico comeca a ler logo depois do saldo, longe da rajada da abertura:
            // ao abrir a Atividade, ele ja esta na tela.
            let disabled = session.metadata.settings.disabledChainIDs
            let balances = portfolio.balances
            Task { await ActivityFeed.shared.load(wallet, disabled: disabled, session: session, balances: balances) }
            // A folha do aviso de recebimento vem antes, e os alertas de preco esperam a
            // resposta dela: dois pedidos de permissao juntos se atropelavam.
            if ReceiptAccounts.shouldOffer(session) {
                offeringReceipts = true
            } else {
                await PriceAlertDefaults.enableByDefault(session)
            }
            #if DEBUG
            // As telas que dependem do saldo esperam a leitura acima.
            if DebugDemo.screen == "detalhe", let first = portfolio.rows.first { router.walletPath.append(first) }
            if DebugDemo.screen == "suspeito", let token = portfolio.suspicious.first { router.walletPath.append(token.holding) }
            if DebugDemo.screen == "outro", let token = portfolio.others.first { router.walletPath.append(token.holding) }
            #endif
        }
        .sheet(isPresented: $switching) {
            WalletSwitcherSheet(onAdd: { switching = false; addingWallet = true })
        }
        .sheet(isPresented: $receiving) { ReceiveSheet(preselected: Self.demoReceiving) }
        .sheet(isPresented: $offeringReceipts, onDismiss: { Task { await PriceAlertDefaults.enableByDefault(session) } }) {
            ReceiptWatchOffer { offeringReceipts = false }
        }
        #if DEBUG
        .modifier(DemoEnvelopes())
        #endif
        .fullScreenCover(isPresented: $addingWallet) { AddWalletView(isFirst: false) { addingWallet = false } }
        .fullScreenCover(isPresented: $backingUp) {
            if let wallet { BackupNowFlow(wallet: wallet) { backingUp = false } }
        }
    }

    /// `-tela receber-btc` abre Receber ja no bitcoin (captura da loja). Fora do modo
    /// demo, Receber abre na lista.
    private static var demoReceiving: Asset? {
        #if DEBUG
        if DebugDemo.screen == "receber-btc" { return .native(.bitcoin) }
        #endif
        return nil
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
            // A escolha daqui vale para o app todo: precos, graficos, Mercado e alertas.
            let changed = session.metadata.settings.choose(newValue)
            if changed { session.metadata.quoteCache = [:] }
            try? session.persist()
            if changed { portfolio.currencyChanged(session.selectedWallet, session: session) }
        })
    }

    private var shownTotal: Double { portfolio.convert(portfolio.total, to: unit, base: session.currency) ?? portfolio.total }
    private var shownChange: Double { portfolio.convert(portfolio.change24hFiat, to: unit, base: session.currency) ?? portfolio.change24hFiat }

    static func signed(_ value: Double, _ unit: Fmt.DisplayUnit) -> String {
        let sign = value < 0 ? Fmt.minus : (value > 0 ? "+" : "")
        return String(localized: "\(sign)\(unit.symbol)\u{00A0}\(Fmt.grouped(abs(value), fractionDigits: unit.fractionDigits))")
    }

    private func wordCount(_ wallet: WalletMeta) -> Int {
        if case .phrase(let count) = wallet.kind { return count }
        return 12
    }

    // MARK: Cabecalho

    private static let top = "carteira-topo"

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { switching = true } label: {
                    HStack(spacing: Space.xs) {
                        Text(wallet?.name ?? String(localized: "Carteira")).typeStyle(.action).foregroundStyle(Palette.ink).lineLimit(1)
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
                QuickAction(title: String(localized: "Enviar"), systemImage: "arrow.up") { router.present(.send(nil)) }
            }
            QuickAction(title: String(localized: "Receber"), systemImage: "arrow.down") { receiving = true }
                .accessibilityIdentifier("acao-receber")
            if wallet?.isWatchOnly != true, !TradeEngines.chains.isEmpty {
                QuickAction(title: String(localized: "Trocar"), systemImage: "arrow.left.arrow.right") { router.tab = .trade }
            }
        }
        .padding(.horizontal, Space.xs)
    }

    @ViewBuilder
    private var statusBanners: some View {
        if portfolio.offline, let updated = portfolio.lastUpdated {
            Banner(kind: .neutral, title: String(localized: "Sem internet. Valores de \(Fmt.relative(updated, inSentence: true))."))
                .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
        } else if portfolio.offline {
            // Sem cache nenhum (primeira abertura, carteira recem importada): sem este
            // aviso a tela mostraria saldo zero, e zero parece frase errada.
            Banner(kind: .neutral, title: String(localized: "Sem internet. Os saldos aparecem quando a conexão voltar."),
                   actionTitle: String(localized: "Tentar de novo")) {
                Task { await portfolio.refresh(wallet, session: session) }
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
        } else if let failed = portfolio.failedChains.first, !portfolio.offline {
            Banner(kind: .neutral, title: failed.id == "xrpl" ? String(localized: "Não foi possível ler o saldo no \(failed.name). Os outros estão em dia.")
                : String(localized: "Não foi possível ler o saldo na \(failed.name). Os outros estão em dia."),
                   actionTitle: String(localized: "Tentar de novo")) {
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
            NavigationLink(value: ManageAssetsRoute()) {
                Text("Gerenciar").typeStyle(.body).foregroundStyle(Palette.inkSoft).frame(minHeight: Height.touch)
            }
            .accessibilityIdentifier("gerenciar-ativos")
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
            // Pilha comum, nao preguicosa: a lista e curta, e a preguicosa segurava uma linha
            // no lugar quando a ordem mudava com os precos, e a tela descia.
            VStack(spacing: 0) {
                ForEach(portfolio.rows) { row in
                    NavigationLink(value: row) {
                        AssetRowView(row: row, currency: session.currency, hidden: hide,
                                     unit: unit, rate: portfolio.convert(1, to: unit, base: session.currency),
                                     awaitingPrice: portfolio.awaitingPrice(row))
                    }
                    .buttonStyle(RowStyle())
                }
            }
            .padding(.top, Space.xs)
        }
        if !portfolio.others.isEmpty || !portfolio.suspicious.isEmpty {
            OtherTokensSection().padding(.top, portfolio.rows.isEmpty ? Space.md : Space.lg)
        }
        if portfolio.unknownTokens > 0 {
            NavigationLink(value: ManageAssetsRoute()) {
                HStack(spacing: 4) {
                    Text(portfolio.unknownTokens == 1 ? "1 token sem leitura escondido" : "\(portfolio.unknownTokens) tokens sem leitura escondidos")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    Image(systemName: "chevron.forward").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                }
                .frame(minHeight: Height.touch)
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
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
            SecondaryButton(title: String(localized: "Tentar de novo")) { Task { await portfolio.refresh(wallet, session: session) } }
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
            SecondaryButton(title: String(localized: "Receber")) { receiving = true }.padding(.top, Space.md)
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

    private var symbolText: some View {
        Text(symbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(Palette.inkSoft)
            .contentTransition(.opacity)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // O simbolo do lado em que a regiao escreve dinheiro: "R$ 10" e "10 €".
            if Fmt.symbolFirst { symbolText }
            if hidden {
                Text("••••••").typeStyle(.display).foregroundStyle(Palette.ink)
            } else {
                // O inteiro sozinho no tamanho grande; as casas menores e mais claras,
                // como o simbolo, na mesma linha de base.
                let text = Fmt.grouped(value, fractionDigits: fractionDigits)
                let parts = text.components(separatedBy: Fmt.decimal)
                (Text(verbatim: parts[0]).style(.display).foregroundColor(Palette.ink)
                 + Text(verbatim: Fmt.decimal + (parts.count > 1 ? parts[1] : String(repeating: "0", count: fractionDigits)))
                    .font(.system(size: fractionDigits > 2 ? 22 : 28, weight: .bold).monospacedDigit()).foregroundColor(Palette.inkSoft))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText(value: value))
                    .animation(Motion.number, value: value)
            }
            if !Fmt.symbolFirst { symbolText }
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
    /// A unidade escolhida no total (R$, US$, € ou ₿), e quanto vale 1 da moeda do app
    /// nela. Sem a cotacao de referencia, a linha fica na moeda do app.
    var unit: Fmt.DisplayUnit? = nil
    var rate: Double? = nil
    /// A cotacao ainda vem: a barra que brilha no lugar do valor.
    var awaitingPrice = false

    private var shownUnit: Fmt.DisplayUnit { rate != nil ? (unit ?? Fmt.DisplayUnit(currency)) : Fmt.DisplayUnit(currency) }
    private func shown(_ value: Double) -> Double { value * (rate ?? 1) }
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
                Text(verbatim: row.symbol).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                HStack(spacing: 6) {
                    if row.isCustom { TokenBadge(.custom) }
                    priceAndChange
                }
            }
            .layoutPriority(1)
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
                Text(verbatim: row.symbol).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                if row.isCustom { TokenBadge(.custom) }
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
            networkCount: row.positions.count, unverified: row.origin != nil,
            logoAsset: row.contractLogoAsset
        )
    }

    @ViewBuilder
    private var priceAndChange: some View {
        if let price = row.price {
            Text(Fmt.price(shown(price), unit: shownUnit)).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                .lineLimit(1).minimumScaleFactor(0.7)
        } else if awaitingPrice {
            ShimmerBar(width: 58, height: 10)
        }
        if let change = row.change24h {
            Text(Fmt.percent(change)).typeStyle(.note)
                .foregroundStyle(change > 0.004 ? Palette.up : (change < -0.004 ? Palette.down : Palette.inkSoft))
                .lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder
    private var fiatValue: some View {
        if !hidden, row.fiatValue == nil, awaitingPrice {
            ShimmerBar(width: 72, height: 14).padding(.vertical, 3)
        } else {
            Text(hidden ? Redaction.fiat : (row.fiatValue.map { Fmt.value(shown($0), unit: shownUnit) } ?? String(localized: "sem preço")))
                .typeStyle(.row).foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
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
    @State private var reorder = WalletReorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Carteiras")) { dismiss() }
            ScrollView {
                VStack(spacing: 0) {
                    let wallets = session.metadata.wallets
                    ForEach(Array(wallets.enumerated()), id: \.element.id) { index, wallet in
                        Button {
                            guard !reorder.justDropped else { return }
                            session.select(wallet)
                            dismiss()
                        } label: {
                            HStack(spacing: Space.sm) {
                                WalletGlyph(id: wallet.id, size: 36, selected: wallet.id == session.selectedWallet?.id, watchOnly: wallet.isWatchOnly)
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
                            .frame(height: Height.row)
                            .background(wallet.id == session.selectedWallet?.id || reorder.dragging == wallet.id ? Palette.rail : Color.clear)
                        }
                        .buttonStyle(RowStyle(surface: .body))
                        .walletReorder(reorder, id: wallet.id, index: index, count: wallets.count, rowHeight: Height.row, session: session)
                    }
                    if wallets.count > 1 {
                        Text("Segure uma carteira e arraste para mudar a ordem.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                            .padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, Space.md)
            }
            .scrollDisabled(reorder.dragging != nil)
            PrimaryButton(title: String(localized: "Adicionar carteira"), action: onAdd)
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
        case .watch(let chainID): return String(localized: "Só observar · \(Chain.find(chainID)?.name ?? chainID)")
        case .phrase(let count):
            if !wallet.wordsConfirmed { return String(localized: "Palavras não confirmadas") }
            if !wallet.passphraseConfirmed { return String(localized: "Passphrase não conferida") }
            return wallet.accounts.count == 1 ? String(localized: "\(count) palavras · 1 rede")
                : String(localized: "\(count) palavras · \(wallet.accounts.count) redes")
        }
    }
}

/// O caminho de "Gerenciar ativos" na pilha da Carteira.
struct ManageAssetsRoute: Hashable {}

/// Reordenar as carteiras: segurar uma linha e arrastar. As outras abrem espaco enquanto
/// ela anda, e soltar grava a ordem nova nos metadados cifrados.
@MainActor
@Observable
final class WalletReorder {
    var dragging: UUID?
    var offset: CGFloat = 0
    var from = 0
    /// Logo depois de arrastar, o toque que solta nao seleciona a carteira.
    var justDropped = false

    func target(count: Int, rowHeight: CGFloat) -> Int {
        max(0, min(count - 1, from + Int((offset / rowHeight).rounded())))
    }

    /// Quanto uma linha que nao esta sendo arrastada desce ou sobe para abrir espaco.
    func shift(index: Int, count: Int, rowHeight: CGFloat) -> CGFloat {
        guard dragging != nil else { return 0 }
        let to = target(count: count, rowHeight: rowHeight)
        if from < to, index > from, index <= to { return -rowHeight }
        if from > to, index >= to, index < from { return rowHeight }
        return 0
    }

    func gesture(id: UUID, index: Int, count: Int, rowHeight: CGFloat, session: AppSession) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if self.dragging == nil {
                    self.dragging = id
                    self.from = index
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                let before = self.target(count: count, rowHeight: rowHeight)
                self.offset = drag?.translation.height ?? 0
                if self.target(count: count, rowHeight: rowHeight) != before { UISelectionFeedbackGenerator().selectionChanged() }
            }
            .onEnded { _ in
                guard self.dragging != nil else { return }
                let to = self.target(count: count, rowHeight: rowHeight)
                if to != self.from {
                    var wallets = session.metadata.wallets
                    let moved = wallets.remove(at: self.from)
                    wallets.insert(moved, at: to)
                    session.metadata.wallets = wallets
                    try? session.persist()
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.dragging = nil
                    self.offset = 0
                }
                self.justDropped = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    self.justDropped = false
                }
            }
    }
}

extension View {
    /// Uma linha da lista de carteiras que da para arrastar.
    func walletReorder(_ reorder: WalletReorder, id: UUID, index: Int, count: Int, rowHeight: CGFloat, session: AppSession) -> some View {
        let dragging = reorder.dragging == id
        return self
            .offset(y: dragging ? reorder.offset : reorder.shift(index: index, count: count, rowHeight: rowHeight))
            .scaleEffect(dragging ? 1.03 : 1)
            .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: 16, y: 6)
            .zIndex(dragging ? 1 : 0)
            .animation(dragging ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: reorder.shift(index: index, count: count, rowHeight: rowHeight))
            .simultaneousGesture(reorder.gesture(id: id, index: index, count: count, rowHeight: rowHeight, session: session))
            .accessibilityHint("Segure e arraste para mudar a ordem")
    }
}
