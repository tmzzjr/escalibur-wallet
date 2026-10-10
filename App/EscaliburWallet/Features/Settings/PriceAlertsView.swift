import EscaliburNetwork
import SwiftUI

/// Ajustes, Alertas de preco: liga, escolhe quando avisar, o que aparece na tela
/// bloqueada e quais moedas. A lista comeca vazia; as moedas da carteira e as
/// favoritas aparecem como sugestao, e o dono marca uma a uma.
struct PriceAlertsView: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @State private var file = PriceAlertFile()
    @State private var denied = false
    @State private var adding = false
    @State private var market: [MarketCoin] = []

    private var coinCount: String { file.coins.count == 1 ? "1 moeda" : "\(file.coins.count) moedas" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                SettingsGroup {
                    Toggle(isOn: Binding(get: { file.enabled }, set: { setEnabled($0) })) {
                        rowLabel("bell", "Avisar sobre preços")
                    }
                    .tint(Palette.lime)
                    .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                    .accessibilityIdentifier("alertas-ligar")
                }
                .padding(.top, Space.lg)

                if denied {
                    Banner(kind: .caution, title: "As notificações da Escalibur estão desligadas no iPhone.",
                           message: "Ligue em Ajustes do iPhone, Notificações, Escalibur Wallet.",
                           actionTitle: "Abrir Ajustes do iPhone") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                }

                if file.enabled {
                    rules
                    lockScreen
                    coins
                }

                VStack(alignment: .leading, spacing: Space.sm) {
                    note("Sem servidor, quem decide a hora de conferir é o iOS: algumas vezes por hora com o iPhone em uso, menos quando ele está parado ou com pouca bateria. O aviso pode chegar alguns minutos depois do preço passar.")
                    note("Um alerta só sai quando o CoinGecko e o CoinPaprika concordam no preço.")
                    note("A lista de moedas fica neste iPhone fora do cofre, para o alerta funcionar com a tela bloqueada. Nela não entra saldo nem endereço.")
                }
                .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
            }
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // As sugestoes vem do saldo: quem chega direto em Ajustes ainda nao leu a carteira.
        .task(id: session.selectedWallet?.id) { await portfolio.ensureLoaded(session.selectedWallet, session: session) }
        .task {
            file = await PriceAlertCenter.shared.file()
            denied = file.enabled ? await PriceAlertCenter.permissionDenied() : false
            if let snapshot = try? await MarketService.shared.marketSnapshot(currency: session.metadata.settings.currency) {
                market = snapshot.coins
            }
        }
        .sheet(isPresented: $adding) {
            AddAlertCoinSheet(market: market, watched: Set(file.coins.map(\.id)), full: file.coins.count >= PriceAlertFile.maxCoins) { coin in
                toggle(coin)
            }
        }
    }

    private var header: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: "bell.badge")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Palette.control))
            Text("Alertas de preço").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.xs)
            Text("O próprio iPhone confere os preços e avisa quando uma moeda passa de um número redondo ou se mexe forte em 24 h. Sem servidor da Escalibur no caminho.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.md)
    }

    private var rules: some View {
        SettingsSection(title: "Quando avisar") {
            Toggle(isOn: Binding(get: { file.roundNumbers }, set: { on in apply { $0.roundNumbers = on } })) {
                rowLabel("number", "Números redondos", "Ex.: Bitcoin passou de \(exampleLevel)")
            }
            .tint(Palette.lime)
            .padding(.horizontal, Space.md).frame(minHeight: Height.row)
            Toggle(isOn: Binding(get: { file.moveThreshold != nil }, set: { on in apply { $0.moveThreshold = on ? 10 : nil } })) {
                rowLabel("arrow.up.arrow.down", "Alta ou queda forte", "Variação em 24 h acima do limite")
            }
            .tint(Palette.lime)
            .padding(.horizontal, Space.md).frame(minHeight: Height.row)
            if let threshold = file.moveThreshold {
                Segmented(
                    options: PriceAlertFile.thresholds.map { ($0, "\(Int($0))%") },
                    selection: Binding(get: { threshold }, set: { value in apply { $0.moveThreshold = value } })
                )
                .padding(.horizontal, Space.md).padding(.bottom, Space.md)
            }
        }
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Na tela bloqueada").typeStyle(.note).foregroundStyle(Palette.inkSoft)
            Segmented(
                options: [(true, "Moeda e preço"), (false, "Só o aviso")],
                selection: Binding(get: { file.showDetails }, set: { value in apply { $0.showDetails = value } })
            )
            Text(file.showDetails
                 ? "Quem pegar o iPhone bloqueado vê a moeda e o preço. Nunca o seu saldo."
                 : "A tela bloqueada mostra só \"Alerta de preço\". Moeda e preço aparecem no app, depois do PIN.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.lg)
    }

    private var coins: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: file.coins.isEmpty ? "Moedas" : "Moedas, \(coinCount)") {
                ForEach(file.coins) { coin in
                    HStack(spacing: Space.sm) {
                        CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 32, remoteURL: image(coin), ringColor: Palette.body)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: coin.name).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                            Text(verbatim: coin.symbol.uppercased()).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        }
                        Spacer()
                        Button { toggle(coin) } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(Palette.inkMuted)
                                .frame(width: Height.touch, height: Height.touch)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Tirar \(coin.name) dos alertas")
                    }
                    .padding(.leading, Space.md).padding(.trailing, Space.xs)
                    .frame(minHeight: Height.row)
                }
                Button { adding = true } label: {
                    SettingsRow(icon: "plus", title: "Adicionar moeda")
                }
                .disabled(file.coins.count >= PriceAlertFile.maxCoins)
                .accessibilityIdentifier("alertas-adicionar")
            }

            if !suggestions.isEmpty {
                Text("Da sua carteira e das favoritas").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) {
                        ForEach(suggestions) { coin in
                            Button { toggle(coin) } label: {
                                HStack(spacing: 6) {
                                    CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 20, remoteURL: image(coin), ringColor: Palette.body)
                                    Text(verbatim: coin.symbol.uppercased()).typeStyle(.label).foregroundStyle(Palette.ink)
                                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.inkSoft)
                                }
                                .padding(.leading, 6).padding(.trailing, Space.sm)
                                .frame(height: Height.chip)
                                .background(Capsule(style: .continuous).fill(Palette.body))
                                .overlay(Capsule(style: .continuous).stroke(Palette.edge, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Adicionar \(coin.name) aos alertas")
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                }
                .padding(.top, Space.xs)
            }
        }
    }

    /// As moedas da carteira e as favoritas que ainda nao estao na lista. Montadas na
    /// tela, destravada; nunca gravadas sozinhas.
    private var suggestions: [WatchedCoin] {
        var out: [WatchedCoin] = []
        let watched = Set(file.coins.map(\.id))
        for row in portfolio.rows {
            guard let id = row.coingeckoID, !watched.contains(id), !out.contains(where: { $0.id == id }) else { continue }
            out.append(WatchedCoin(id: id, symbol: row.symbol, name: row.name))
        }
        for id in session.metadata.settings.favoriteCoins ?? [] where !watched.contains(id) && !out.contains(where: { $0.id == id }) {
            if let coin = market.first(where: { $0.id == id }) { out.append(WatchedCoin(id: coin.id, symbol: coin.symbol, name: coin.name, image: coin.imageURL)) }
        }
        return Array(out.prefix(10))
    }

    /// A logo de uma moeda da lista: a gravada com ela ou, nas antigas, a da lista do
    /// Mercado.
    private func image(_ coin: WatchedCoin) -> URL? {
        coin.image ?? market.first { $0.id == coin.id }?.imageURL
    }

    private var exampleLevel: String {
        let currency = session.currency
        let price = market.first { $0.id == "bitcoin" }?.price ?? (currency == .brl ? 600_000 : 110_000)
        return PriceAlertText.level(PriceAlertRules.level(atOrBelow: price), currency)
    }

    private func rowLabel(_ icon: String, _ title: String, _ subtitle: String? = nil) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.inkSoft).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typeStyle(.body).foregroundStyle(Palette.ink)
                if let subtitle { Text(subtitle).typeStyle(.note).foregroundStyle(Palette.inkSoft) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Mudancas

    /// Muda na tela na hora e grava pelo centro dos alertas, que e quem guarda o arquivo.
    private func apply(_ change: @escaping @Sendable (inout PriceAlertFile) -> Void) {
        change(&file)
        Task { file = await PriceAlertCenter.shared.update(change) }
    }

    private func setEnabled(_ on: Bool) {
        guard on else {
            apply { $0.enabled = false }
            return
        }
        let currency = session.metadata.settings.currency
        Task {
            guard await PriceAlertCenter.requestPermission() else {
                denied = true
                return
            }
            denied = false
            apply { file in
                file.enabled = true
                if file.currency != currency {
                    file.currency = currency
                    file.memory = [:]
                }
            }
        }
    }

    private func toggle(_ coin: WatchedCoin) {
        apply { file in
            if let index = file.coins.firstIndex(where: { $0.id == coin.id }) {
                file.coins.remove(at: index)
            } else if file.coins.count < PriceAlertFile.maxCoins {
                file.coins.append(coin)
            }
        }
        // A moeda nova ganha a base de preco agora: o primeiro aviso dela ja compara.
        Task { await PriceAlertCenter.shared.check(force: true) }
    }
}

/// Escolher moedas para os alertas, na lista do Mercado.
private struct AddAlertCoinSheet: View {
    @Environment(\.dismiss) private var dismiss
    let market: [MarketCoin]
    @State var watched: Set<String>
    let full: Bool
    let onToggle: (WatchedCoin) -> Void
    @State private var query = ""

    init(market: [MarketCoin], watched: Set<String>, full: Bool, onToggle: @escaping (WatchedCoin) -> Void) {
        self.market = market
        _watched = State(initialValue: watched)
        self.full = full
        self.onToggle = onToggle
    }

    private var filtered: [MarketCoin] {
        guard !query.isEmpty else { return market }
        return market.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SearchField(prompt: "Buscar moeda", text: $query)
                        .padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                    if market.isEmpty {
                        Banner(kind: .neutral, title: "Não foi possível carregar a lista de moedas agora.")
                            .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { coin in
                            let on = watched.contains(coin.id)
                            Button {
                                guard on || watched.count < PriceAlertFile.maxCoins else { return }
                                if on { watched.remove(coin.id) } else { watched.insert(coin.id) }
                                onToggle(WatchedCoin(id: coin.id, symbol: coin.symbol, name: coin.name, image: coin.imageURL))
                            } label: {
                                HStack(spacing: Space.sm) {
                                    CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 36, remoteURL: coin.imageURL)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: coin.name).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                                        Text(verbatim: coin.symbol.uppercased()).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                    }
                                    Spacer()
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22, weight: .regular))
                                        .foregroundStyle(on ? Palette.lime : Palette.edgeStrong)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowStyle())
                            .sensoryFeedback(.selection, trigger: on)
                        }
                    }
                    .padding(.top, Space.sm)
                }
                .padding(.bottom, Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.void.ignoresSafeArea())
            .navigationTitle("Adicionar moeda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") { dismiss() }.fontWeight(.semibold).foregroundStyle(Palette.ink)
                }
            }
        }
        .presentationBackground(Palette.void)
    }
}

/// O sino no topo da pagina da moeda: liga ou desliga os alertas desta moeda.
struct PriceAlertBell: View {
    @Environment(AppSession.self) private var session
    @Environment(ToastCenter.self) private var toasts
    let coin: MarketCoin
    @State private var watching = false
    @State private var denied = false

    var body: some View {
        Button { Task { await toggle() } } label: {
            Image(systemName: watching ? "bell.fill" : "bell")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(watching ? Palette.ink : Palette.inkSoft)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Height.touch, height: Height.touch)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: watching)
        .accessibilityLabel(watching ? "Desligar alertas desta moeda" : "Avisar sobre o preço desta moeda")
        .task {
            let file = await PriceAlertCenter.shared.file()
            watching = file.enabled && file.watches(coin.id)
        }
        .alert("Notificações desligadas", isPresented: $denied) {
            Button("Abrir Ajustes do iPhone") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Agora não", role: .cancel) {}
        } message: {
            Text("Para receber alertas de preço, ligue as notificações da Escalibur Wallet nos Ajustes do iPhone.")
        }
    }

    private func toggle() async {
        let watched = WatchedCoin(id: coin.id, symbol: coin.symbol, name: coin.name, image: coin.imageURL)
        if watching {
            await PriceAlertCenter.shared.update { $0.coins.removeAll { $0.id == watched.id } }
            watching = false
            toasts.show("Alertas de \(coin.symbol.uppercased()) desligados", kind: .info)
            return
        }
        guard await PriceAlertCenter.requestPermission() else {
            denied = true
            return
        }
        let currency = session.metadata.settings.currency
        let file = await PriceAlertCenter.shared.update { file in
            file.enabled = true
            if file.currency != currency {
                file.currency = currency
                file.memory = [:]
            }
            if !file.watches(watched.id), file.coins.count < PriceAlertFile.maxCoins { file.coins.append(watched) }
        }
        guard file.watches(watched.id) else {
            toasts.show("A lista de alertas já tem \(PriceAlertFile.maxCoins) moedas", kind: .failure)
            return
        }
        watching = true
        toasts.show("Alertas de \(coin.symbol.uppercased()) ligados")
        await PriceAlertCenter.shared.check(force: true)
    }
}
