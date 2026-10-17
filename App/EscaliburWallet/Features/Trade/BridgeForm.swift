import EscaliburChains
import EscaliburCore
import EscaliburEngines
import SwiftUI

/// O estado da ponte na tela de Trocar: redes, moeda, valor e as opcoes cotadas.
@MainActor
@Observable
final class BridgeFormModel {
    var from: Chain = .base
    var to: Chain = .arbitrum
    var asset: BridgeAsset = .usdc
    var amountText = ""
    var route: BridgeRoute = .cctpFast
    var options: [ValidatedBridgeQuote] = []
    var quoting = false
    var error: String?

    var assets: [BridgeAsset] { BridgeEngine.assets(from: from, to: to) }
    var fromBridge: BridgeChain? { BridgeAllowlist.chain(from) }
    var toBridge: BridgeChain? { BridgeAllowlist.chain(to) }
    var sellAsset: Asset? { fromBridge.flatMap { asset.asset(on: $0) } }
    var receiveAsset: Asset? { toBridge.flatMap { asset.asset(on: $0) } }
    /// As casas do que sai e do que chega: o USDC e o USDT da BNB tem 18, os outros 6.
    var sellDecimals: Int { fromBridge.map { asset.decimals(on: $0) } ?? 18 }
    var receiveDecimals: Int { toBridge.map { asset.decimals(on: $0) } ?? 18 }

    var amount: BigUInt? {
        guard let parsed = TradeDecimal(amountText), parsed.scale <= sellDecimals else { return nil }
        return parsed.mantissa * BigUInt.power(of: 10, sellDecimals - parsed.scale)
    }

    /// A opcao escolhida, ou a primeira cotada.
    var selected: ValidatedBridgeQuote? { options.first { $0.route == route } ?? options.first }

    func setFrom(_ chain: Chain) {
        if chain.id == to.id { to = from }
        from = chain
        // A Tron so recebe USDT, e so da Ethereum e da Arbitrum: de outra origem, o destino
        // volta a uma rede EVM.
        if to == .tron, !BridgeEngine.assets(from: chain, to: .tron).contains(.usdt) { to = chain == .arbitrum ? .base : .arbitrum }
        changed()
    }

    func setTo(_ chain: Chain) {
        if chain.id == from.id { from = to }
        to = chain
        // Para a Tron (pedido do dono, 17/10/2026): USDT, saindo da Ethereum ou da Arbitrum.
        if chain == .tron {
            if !BridgeEngine.assets(from: from, to: .tron).contains(.usdt) { from = .ethereum }
            asset = .usdt
        }
        changed()
    }

    /// A Tron nunca e origem: com ela num dos lados, inverter nao faz sentido.
    var canSwap: Bool { from != .tron && to != .tron }

    func swapNetworks() {
        guard canSwap else { return }
        (from, to) = (to, from)
        changed()
    }

    func changed() {
        if !assets.contains(asset) { asset = assets.first ?? .usdc }
        options = []
        error = nil
    }
}

/// A ponte: levar a mesma moeda da sua conta numa rede para a sua conta em outra.
struct BridgeForm: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @Bindable var model: BridgeFormModel
    @State private var pickingAsset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            networks
            VStack(spacing: 4) {
                AmountBox(title: String(localized: "Você envia"), asset: model.sellAsset, amount: $model.amountText, balance: balanceText,
                          fiat: fiatText(model.amount, decimals: model.sellDecimals), editable: true, over: over,
                          onPick: { pickingAsset = true }, onFraction: fractionAction)
                AmountBox(title: String(localized: "Chega na \(model.to.name)"), asset: model.receiveAsset, amount: .constant(receiveText), balance: nil,
                          fiat: fiatText(model.selected?.minimumReceived, decimals: model.receiveDecimals), editable: false, over: false,
                          loading: model.quoting && model.options.isEmpty && model.amount != nil,
                          onPick: { pickingAsset = true }, onFraction: nil)
            }
            .padding(.top, Space.md)
            if model.asset == .usdc, model.options.count > 1 {
                Segmented(options: model.options.map { ($0.route, $0.route == .cctpFast ? String(localized: "Rápida") : String(localized: "Padrão")) }, selection: $model.route)
                    .padding(.top, Space.md)
            }
            details.padding(.top, Space.lg)
            BridgeList().padding(.top, Space.lg)
        }
        .sheet(isPresented: $pickingAsset) {
            BridgeAssetSheet(model: model) { asset in
                model.asset = asset
                model.amountText = ""
                model.changed()
                pickingAsset = false
            }
        }
        .task(id: quoteKey) { await refresh() }
        .task { await BridgeCenter.shared.refresh(session: session) }
        #if DEBUG
        .onAppear {
            if DebugDemo.screen == "ponte", model.amountText.isEmpty { model.amountText = "250" }
            if DebugDemo.screen == "ponte-tron", model.amountText.isEmpty {
                model.setFrom(.ethereum)
                model.setTo(.tron)
                model.amountText = "1000"
            }
        }
        #endif
    }

    /// As redes na mesma ordem da troca (pedido do dono, 15/10/2026).
    private var bridgeChains: [Chain] { Chain.all.filter { BridgeEngine.chains.contains($0) } }
    /// No destino, tambem a Tron (so USDT, pela Tether).
    private var destinationChains: [Chain] { Chain.all.filter { BridgeEngine.destinations.contains($0) } }

    /// De e Para em colunas de largura igual: o botao de inverter fica parado no meio,
    /// qualquer que seja o nome da rede (pedido do dono, 15/10/2026). Alinhado por baixo: o
    /// botao, da altura do seletor, fica no meio dos seletores, e nao no meio de rotulo e
    /// seletor (pedido do dono, 16/10/2026).
    private var networks: some View {
        HStack(alignment: .bottom, spacing: Space.xs) {
            VStack(alignment: .leading, spacing: 4) {
                Text("De").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                NetworkMenu(chains: bridgeChains, selected: model.from) { model.setFrom($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { withAnimation(Motion.flip) { model.swapNetworks() } } label: {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.canSwap ? Palette.ink : Palette.inkDead)
                    .frame(width: 36, height: 36).background(Circle().fill(Palette.rail))
            }
            .disabled(!model.canSwap)
            .accessibilityLabel("Inverter redes")
            VStack(alignment: .trailing, spacing: 4) {
                Text("Para").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                NetworkMenu(chains: destinationChains, selected: model.to) { model.setTo($0) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var details: some View {
        if let quote = model.selected {
            VStack(alignment: .leading, spacing: Space.xs) {
                let bridgeFee = Fmt.crypto(quote.bridgeFee, decimals: model.sellDecimals, symbol: model.asset.symbol, style: .full)
                if quote.route == .usdt0 {
                    line(String(localized: "Pela USDT0 da própria Tether: o contrato dela entrega o mesmo valor em USDT na Tron (TRC-20)"))
                    line(String(localized: "Taxa da Tether: \(bridgeFee)"))
                    let delivery = Fmt.crypto(quote.messageFee, decimals: model.from.nativeDecimals, symbol: model.from.nativeSymbol, style: .full)
                    line(String(localized: "Taxa de entrega na Tron: \(delivery), paga aqui. Você não precisa de TRX"))
                } else {
                    line(quote.route.isCCTP ? String(localized: "Pelo CCTP da Circle: queima aqui e a própria Circle cunha o mesmo USDC na \(model.to.name)")
                                            : String(localized: "Pelo Across: um relayer entrega na \(model.to.name) em segundos"))
                    line(quote.route.isCCTP ? String(localized: "Taxa da ponte, no máximo: \(bridgeFee)") : String(localized: "Taxa da ponte: \(bridgeFee)"))
                }
                line(String(localized: "Tempo: \(timeText(quote))"))
                line(model.to == .tron ? String(localized: "Vai para a sua própria conta na Tron, desta mesma carteira")
                                       : String(localized: "Vai para a sua própria conta na \(model.to.name), o mesmo endereço"))
                if model.from == .bnb || model.to == .bnb {
                    line(String(localized: "Na BNB, o \(model.asset.symbol) é o da Binance (Binance-Peg): vale enquanto a Binance mantiver o lastro"))
                }
                line(String(localized: "Sem taxa da Escalibur"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = model.error {
            Banner(kind: .neutral, title: error)
        } else {
            Text(model.from == .bnb || model.to == .bnb
                 ? "Leva a moeda para a sua conta em outra rede, pelo Across. Na BNB, o USDC, o USDT e o ETH são os da Binance (Binance-Peg): valem enquanto a Binance mantiver o lastro, e não são os da Circle nem os da Tether. Sem taxa da Escalibur."
                 : "Leva a mesma moeda para a sua conta em outra rede. USDC pelo CCTP da própria Circle; ETH e USDT pelo Across; USDT para a Tron pela USDT0 da própria Tether. Sem taxa da Escalibur.")
                .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
    }

    private func timeText(_ quote: ValidatedBridgeQuote) -> String {
        switch quote.route {
        case .cctpFast: return String(localized: "menos de 1 minuto")
        case .cctpStandard: return String(localized: "uns 20 minutos (sem taxa do protocolo)")
        case .across: return quote.estimatedSeconds < 120 ? String(localized: "segundos") : String(localized: "uns \(quote.estimatedSeconds / 60) minutos")
        case .usdt0: return String(localized: "uns minutos")
        }
    }

    private var receiveText: String {
        guard let quote = model.selected else { return "" }
        return Fmt.plainDecimal(quote.minimumReceived, decimals: model.receiveDecimals)
    }

    // MARK: Saldo

    private var holding: BigUInt {
        guard let asset = model.sellAsset else { return 0 }
        return portfolio.balance(model.from)?.holdings.first { $0.asset.id == asset.id }?.amount ?? 0
    }

    private var over: Bool { (model.amount ?? 0) > holding }

    private var balanceText: String? {
        guard let asset = model.sellAsset else { return nil }
        return String(localized: "Saldo \(Fmt.crypto(holding, decimals: asset.decimals, symbol: asset.symbol, style: .list))")
    }

    private var fractionAction: ((Double) -> Void)? {
        guard !holding.isZero else { return nil }
        return { fraction in
            var part = fraction >= 1 ? holding : holding * BigUInt(UInt64(fraction * 100)) / BigUInt(100)
            // ETH nativo: deixa o gas do deposito na conta (na BNB o ETH e token, e o gas e BNB).
            if let from = model.fromBridge, model.asset.isNativeInput(on: from), fraction >= 1 {
                let reserve = BigUInt(decimal: model.from == .ethereum ? "5000000000000000" : "300000000000000")!
                part = part > reserve ? part - reserve : 0
            }
            model.amountText = Fmt.plainDecimal(part, decimals: model.sellDecimals)
        }
    }

    /// O valor na moeda do app, com as casas do lado do valor: o que chega na BNB tem 18,
    /// o que sai da Base 6 (revisao da ponte BNB, B3).
    private func fiatText(_ amount: BigUInt?, decimals: Int) -> String? {
        guard let amount, let asset = model.sellAsset, let price = asset.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }) else { return nil }
        return String(localized: "≈ \(Fmt.fiat(Fmt.double(amount, decimals: decimals) * price, session.currency))")
    }

    // MARK: Cotacao

    private var quoteKey: String { "\(model.from.id)|\(model.to.id)|\(model.asset.rawValue)|\(model.amountText)" }

    private func refresh() async {
        model.options = []
        model.error = nil
        guard let wallet = session.selectedWallet, !wallet.isWatchOnly, let amount = model.amount, !amount.isZero,
              let account = wallet.account(model.from), let owner = try? EVMAddress(account.address) else { return }
        // Na Tron, quem recebe e a conta Tron desta carteira.
        var tronRecipient: TronAddress?
        if model.to == .tron {
            guard let tron = wallet.account(.tron).flatMap({ TronAddress(base58: $0.address) }) else {
                model.error = String(localized: "Esta carteira não tem conta na Tron para receber.")
                return
            }
            tronRecipient = tron
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        model.quoting = true
        defer { model.quoting = false }
        do {
            let intent = try BridgeIntent(owner: owner, asset: model.asset, from: model.from, to: model.to, amount: amount, tronRecipient: tronRecipient)
            let options = try await BridgeEngine.shared.quotes(intent)
            guard !Task.isCancelled else { return }
            model.options = options
            if !options.contains(where: { $0.route == model.route }), let first = options.first { model.route = first.route }
        } catch let refusal as BridgeRefusal {
            model.error = BridgeRefusalText.text(refusal)
        } catch {
            guard !Task.isCancelled else { return }
            model.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Não foi possível cotar a ponte agora.")
        }
    }
}

/// O texto das recusas que acontecem antes da cotacao (no pedido).
enum BridgeRefusalText {
    static func text(_ refusal: BridgeRefusal) -> String {
        switch refusal {
        case .aboveBurnLimit: return String(localized: "O CCTP da Circle leva até 10 milhões de USDC por vez. Faça em partes.")
        case .unsupportedRoute: return String(localized: "A ponte ainda não leva esta moeda entre estas redes.")
        case .sameChain: return String(localized: "Escolha redes diferentes.")
        default: return String(localized: "A ponte recusou este pedido.")
        }
    }
}

/// O rodape da ponte: o botao de revisar.
struct BridgeFooter: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    let model: BridgeFormModel
    let onReview: (BridgeReviewFlow.Item) -> Void

    var body: some View {
        PrimaryButton(title: title, enabled: enabled, loading: model.quoting && model.options.isEmpty && model.amount != nil) {
            guard let quote = model.selected else { return }
            let price = model.sellAsset?.coingeckoID.flatMap { portfolio.quotes[$0]?.price }
            onReview(.init(intent: quote.intent, route: quote.route,
                           fiat: price.map { Fmt.double(quote.intent.amount, decimals: model.sellDecimals) * $0 }))
        }
    }

    private var over: Bool {
        guard let asset = model.sellAsset, let amount = model.amount else { return false }
        return amount > (portfolio.balance(model.from)?.holdings.first { $0.asset.id == asset.id }?.amount ?? 0)
    }

    private var title: String {
        guard let amount = model.amount, !amount.isZero else { return String(localized: "Digite um valor") }
        if over { return String(localized: "Saldo de \(model.asset.symbol) insuficiente na \(model.from.name)") }
        if model.quoting && model.options.isEmpty { return String(localized: "Cotando a ponte") }
        return String(localized: "Revisar ponte")
    }

    private var enabled: Bool {
        guard session.selectedWallet?.isWatchOnly == false, let amount = model.amount, !amount.isZero, !over else { return false }
        return model.selected != nil
    }
}

/// As pontes da carteira: em curso primeiro, depois as ultimas terminadas.
struct BridgeList: View {
    @Environment(AppSession.self) private var session
    @State private var opened: UUID?

    var body: some View {
        let records = BridgeCenter.shared.visible(session)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Suas pontes").typeStyle(.row).foregroundStyle(Palette.ink)
                ForEach(records) { record in
                    Button { opened = record.id } label: { row(record) }.buttonStyle(.plain)
                }
            }
            .sheet(item: Binding(get: { opened.map(Opened.init) }, set: { opened = $0?.id })) { item in
                VStack(alignment: .leading) {
                    BridgeProgressPanel(recordID: item.id)
                    Spacer()
                }
                .padding(Space.gutter)
                .presentationDetents([.medium])
                .presentationBackground(Palette.body)
            }
        }
    }

    private struct Opened: Identifiable { let id: UUID }

    private func row(_ record: BridgeRecord) -> some View {
        let text = BridgeText.status(record, BridgeCenter.shared.progress[record.id])
        let decimals = record.from.map { record.asset.decimals(on: $0) } ?? 18
        let amount = BigUInt(decimal: record.amount).map { Fmt.crypto($0, decimals: decimals, symbol: record.asset.symbol, style: .list) } ?? ""
        return HStack(spacing: Space.sm) {
            if let from = record.from?.chain, let to = record.to?.chain {
                HStack(spacing: -6) {
                    NetworkBadge(chain: from, size: 24, ring: Palette.void)
                    NetworkBadge(chain: to, size: 24, ring: Palette.void)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(amount).typeStyle(.row).foregroundStyle(Palette.ink)
                Text(text.title).typeStyle(.note).foregroundStyle(record.state == .arrived ? Palette.up : Palette.inkSoft)
            }
            Spacer()
            if record.state == .pending { ProgressView().tint(Palette.accent) }
        }
        .padding(Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
    }
}

/// Escolher a moeda da ponte, como o seletor da troca: logo, nome, saldo na rede de
/// origem. A que nao faz esta rota aparece apagada, com o motivo.
struct BridgeAssetSheet: View {
    @Environment(Portfolio.self) private var portfolio
    @Environment(\.dismiss) private var dismiss
    let model: BridgeFormModel
    let onPick: (BridgeAsset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Moeda")) { dismiss() }
            Text("Da \(model.from.name) para a \(model.to.name)").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
            ScrollView {
                VStack(spacing: Space.xs) {
                    ForEach(BridgeAsset.allCases, id: \.self) { asset in row(asset) }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.void)
    }

    private func reason(_ asset: BridgeAsset) -> String? {
        guard let from = model.fromBridge, let to = model.toBridge else { return String(localized: "Rede fora da ponte.") }
        guard !asset.available(from: from, to: to) else { return nil }
        switch asset {
        case .usdc: return String(localized: "Fora da ponte nestas redes.")
        case .eth:
            if from.across == nil || to.across == nil { return String(localized: "O Across não atende \(from.across == nil ? from.chain.name : to.chain.name).") }
            return String(localized: "ETH só entre redes em que ele é a moeda nativa, e na BNB, onde é o da Binance.")
        case .usdt:
            if from.across == nil || to.across == nil { return String(localized: "O Across não atende \(from.across == nil ? from.chain.name : to.chain.name).") }
            return String(localized: "USDT só onde o Across entrega o USDT da Tether (Ethereum, Arbitrum, Unichain e Plasma) ou o da Binance, na BNB.")
        case .wbtc:
            if from.across == nil || to.across == nil { return String(localized: "O Across não atende \(from.across == nil ? from.chain.name : to.chain.name).") }
            return String(localized: "WBTC só entre Ethereum, Arbitrum, Optimism e Polygon.")
        }
    }

    private func row(_ asset: BridgeAsset) -> some View {
        let listed = model.fromBridge.flatMap { asset.asset(on: $0) }
        let held = listed.flatMap { item in portfolio.balance(model.from)?.holdings.first { $0.asset.id == item.id } }
        let why = reason(asset)
        return Button { if why == nil { onPick(asset) } } label: {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: listed?.coingeckoID, symbol: asset.symbol, size: 40, network: model.from, ringColor: Palette.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.symbol).typeStyle(.row).foregroundStyle(Palette.ink)
                    Text(why ?? (model.fromBridge.flatMap { from in model.toBridge.map { BridgeAsset.usesCCTP(asset, from: from, to: $0) } } == true
                                 ? String(localized: "Pelo CCTP da Circle") : String(localized: "Pelo Across"))).typeStyle(.note)
                        .foregroundStyle(why == nil ? Palette.inkSoft : Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let held, why == nil {
                    Text(Fmt.crypto(portfolio.available(held), decimals: held.asset.decimals, symbol: asset.symbol, style: .list))
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                if asset == model.asset {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent)
                }
            }
            .padding(Space.sm)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
            .opacity(why == nil ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(why != nil)
        .accessibilityIdentifier("ponte-moeda-\(asset.symbol)")
    }
}
