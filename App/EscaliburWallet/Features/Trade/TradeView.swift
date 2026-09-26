import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import EscaliburNetwork
import SwiftUI

/// O estado da aba Trocar.
@MainActor
@Observable
final class TradeModel {
    var chain: Chain = .base
    var sell: Asset?
    var buy: Asset?
    var amountText = ""
    var slippageBps = 50
    var automaticSlippage = true
    var quote: TradeQuote?
    var quoting = false
    var error: String?
    var nextRefresh = 15
    /// O impacto que o dono aceitou, em %. Vale enquanto a cotacao nao piorar; trocar
    /// par, valor ou rede zera (auditoria 2, B1).
    var acceptedImpactPercent: Double?
    /// O preco limite que o dono confirmou mesmo abaixo do mercado, como digitado.
    var acceptedLimitPrice: String?

    var acceptedHighImpact: Bool {
        guard let accepted = acceptedImpactPercent, let current = quote?.priceImpactPercent else { return false }
        return current <= accepted
    }
    var invertedRate = false
    var showDetails = false

    // Ordem limite
    var targetPriceText = ""
    var validFor: TimeInterval = 7 * 86_400

    var amountIn: BigUInt? {
        guard let sell else { return nil }
        return Fmt.parseAmount(amountText, decimals: sell.decimals)
    }

    func reset(to chain: Chain) {
        self.chain = chain
        sell = .native(chain)
        buy = TokenRegistry.tokens.first { $0.chainID == chain.id && $0.isStablecoin }
        quote = nil
        error = nil
        amountText = ""
    }
}

/// T1 e L1: trocar agora ou por ordem limite, dentro de uma rede.
struct TradeView: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @Environment(Router.self) private var router
    @State private var model = TradeModel()
    @State private var picking: Side?
    @State private var routeSheet = false
    @State private var reviewing: TradeReviewFlow.Item?
    @State private var receivingAsset: Asset?

    enum Side: Identifiable { case sell, buy; var id: Self { self } }

    private var engine: (any TradeEngine)? { TradeEngines.engine(for: model.chain) }
    private var tradeChains: [Chain] { TradeEngines.chains }
    @State private var flipTurns = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TabTitle(title: "Trocar") {
                        if !tradeChains.isEmpty {
                            NetworkMenu(chains: tradeChains, selected: model.chain) { chain in
                                withAnimation(Motion.fade) { model.reset(to: chain) }
                            }
                        }
                    }
                    if tradeChains.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Trocas chegam numa atualização").typeStyle(.row).foregroundStyle(Palette.ink)
                            Text("Enviar e receber já funcionam em todas as redes. A troca entra rede por rede, cada uma depois de passar pela validação de segurança.")
                                .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Segmented(options: [(Router.TradeMode.now, "Imediata"), (.limit, "Limite")], selection: Bindable(router).tradeMode)
                                .padding(.top, Space.sm)
                            if session.selectedWallet?.isWatchOnly == true {
                                Banner(kind: .neutral, title: "Esta carteira só observa. Escolha outra carteira para trocar.").padding(.top, Space.md)
                            }
                            if router.tradeMode == .now { nowForm.padding(.top, Space.md) } else { limitForm.padding(.top, Space.md) }
                        }
                        .padding(.horizontal, Space.gutter)
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { footer }
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            if model.sell == nil, let first = tradeChains.first { model.reset(to: first) }
            applyPreset()
        }
        .onChange(of: router.tradePreset?.asset.id) { _, _ in applyPreset() }
        .sheet(item: $picking) { side in
            TokenPickerSheet(chain: model.chain, exclude: side == .sell ? model.buy : model.sell) { asset in
                if side == .sell { model.sell = asset } else { model.buy = asset }
                model.quote = nil
                picking = nil
            }
        }
        .sheet(item: $receivingAsset) { asset in ReceiveSheet(preselected: asset) }
        .sheet(isPresented: $routeSheet) { if let quote = model.quote { RouteSheet(quote: quote) } }
        .fullScreenCover(item: $reviewing) { item in
            TradeReviewFlow(item: item) { completed in
                reviewing = nil
                if completed {
                    model.amountText = ""
                    model.targetPriceText = ""
                    model.quote = nil
                }
            }
        }
        .task(id: quoteKey) { await refreshQuote() }
    }

    /// Chegando do detalhe de uma moeda: a rede dela e ela como venda ou compra.
    private func applyPreset() {
        guard let preset = router.tradePreset, let chain = preset.asset.chain, tradeChains.contains(chain) else { return }
        router.tradePreset = nil
        router.tradeMode = .now
        model.reset(to: chain)
        if preset.sell {
            model.sell = preset.asset
            if model.buy == preset.asset { model.buy = TokenRegistry.tokens.first { $0.chainID == chain.id && $0.isStablecoin && $0 != preset.asset } ?? .native(chain) }
        } else {
            model.buy = preset.asset
            if model.sell == preset.asset { model.sell = TokenRegistry.tokens.first { $0.chainID == chain.id && $0.isStablecoin && $0 != preset.asset } }
        }
    }

    private var quoteKey: String {
        "\(model.chain.id)|\(model.sell?.id ?? "")|\(model.buy?.id ?? "")|\(model.amountText)|\(model.slippageBps)|\(router.tradeMode == .now)"
    }

    // MARK: Cabecalho

    // MARK: Agora

    private var fractionAction: ((Double) -> Void)? {
        guard hasBalance(model.sell) else { return nil }
        return { fraction in setFraction(fraction) }
    }

    private var nowForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                AmountBox(title: "Você paga", asset: model.sell, amount: $model.amountText, balance: balance(model.sell),
                          fiat: fiat(model.amountIn, model.sell), editable: true, over: over,
                          onPick: { picking = .sell }, onFraction: fractionAction)
                AmountBox(title: "Você recebe", asset: model.buy, amount: .constant(receiveText), balance: balance(model.buy),
                          fiat: fiat(model.quote?.expectedOut, model.buy), editable: false, over: false,
                          loading: model.quoting && model.quote == nil && model.amountIn != nil,
                          onPick: { picking = .buy }, onFraction: nil)
                    .overlay(alignment: .top) {
                        Button(action: flip) {
                            Image(systemName: "arrow.up.arrow.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                                .rotationEffect(.degrees(Double(flipTurns) * 180))
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Palette.rail))
                                .overlay(Circle().stroke(Palette.void, lineWidth: 4))
                        }
                        .offset(y: -20)
                        .sensoryFeedback(.impact(weight: .light), trigger: flipTurns)
                        .accessibilityLabel("Inverter")
                    }
            }

            SlippageSlider(basisPoints: $model.slippageBps)
                .padding(.top, Space.lg)
            quoteLines.padding(.top, Space.lg)
        }
    }

    private var receiveText: String {
        guard let quote = model.quote, let buy = model.buy else { return "" }
        return Fmt.plainDecimal(quote.expectedOut, decimals: buy.decimals)
    }

    @ViewBuilder
    private var quoteLines: some View {
        if let quote = model.quote, let sell = model.sell, let buy = model.buy {
            VStack(alignment: .leading, spacing: Space.xs) {
                Button { model.invertedRate.toggle() } label: {
                    Text(rateText(quote, sell: sell, buy: buy)).typeStyle(.note).foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
                Button { routeSheet = true } label: {
                    HStack(spacing: 6) {
                        HStack(spacing: -6) {
                            ForEach(Array(quote.legs.prefix(3).enumerated()), id: \.offset) { _, leg in
                                ProviderLogo(name: leg.provider, size: 20)
                                    .overlay(Circle().stroke(Palette.void, lineWidth: 2))
                            }
                        }
                        Text(quote.legs.count > 1
                             ? "Dividida entre \(quote.legs.count) provedores para você receber mais"
                             : "\(quote.legs.first?.provider ?? ""), o melhor entre \(quote.providersCompared)")
                            .typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("Ver rota").typeStyle(.note).fontWeight(.semibold).foregroundStyle(Palette.ink)
                    }
                }
                .buttonStyle(.plain)
                Text(feeText(quote)).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                impactLine(quote)
                Button { withAnimation(Motion.flip) { model.showDetails.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text("Detalhes").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                            .rotationEffect(.degrees(model.showDetails ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)
                if model.showDetails {
                    detail("Você recebe no mínimo", Fmt.crypto(quote.minimumOut, decimals: buy.decimals, symbol: buy.symbol, style: .full))
                    if let impact = quote.priceImpactPercent { detail("Impacto no preço", "\(Fmt.grouped(impact, fractionDigits: 2))%") }
                    if model.chain == .ethereum, session.metadata.settings.mevProtection { detail("Proteção contra robôs", "ligada") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        } else if let error = model.error {
            Banner(kind: .neutral, title: error)
        }
    }

    @ViewBuilder
    private func impactLine(_ quote: TradeQuote) -> some View {
        switch PriceImpact.level(quote.priceImpactPercent) {
        case .normal: EmptyView()
        case .visible:
            Text("Impacto no preço \(Fmt.grouped(quote.priceImpactPercent ?? 0, fractionDigits: 2))%").typeStyle(.note).foregroundStyle(Palette.down)
        case .confirm:
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Esta ordem move o preço em \(Fmt.grouped(quote.priceImpactPercent ?? 0, fractionDigits: 1))%. Dividir em ordens menores ajuda.")
                    .typeStyle(.note).foregroundStyle(Palette.down).fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: Binding(get: { model.acceptedHighImpact },
                                     set: { model.acceptedImpactPercent = $0 ? model.quote?.priceImpactPercent : nil })) {
                    Text("Entendo e quero trocar assim").typeStyle(.note).foregroundStyle(Palette.ink)
                }
                .tint(Palette.down)
            }
        case .blocked:
            Text("Esta troca perderia \(Fmt.grouped(quote.priceImpactPercent ?? 0, fractionDigits: 0))% para o impacto no preço. Divida em ordens menores ou use uma ordem limite.")
                .typeStyle(.note).foregroundStyle(Palette.down).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            Spacer()
            Text(value).typeStyle(.note).foregroundStyle(Palette.ink)
        }
    }

    private func rateText(_ quote: TradeQuote, sell: Asset, buy: Asset) -> String {
        let inAmount = Fmt.double(quote.amountIn, decimals: sell.decimals)
        let outAmount = Fmt.double(quote.expectedOut, decimals: buy.decimals)
        guard inAmount > 0, outAmount > 0 else { return "" }
        if model.invertedRate {
            return "1 \(buy.symbol) = \(Fmt.grouped(inAmount / outAmount, fractionDigits: 6, trimZeros: true)) \(sell.symbol)"
        }
        return "1 \(sell.symbol) = \(Fmt.grouped(outAmount / inAmount, fractionDigits: 6, trimZeros: true)) \(buy.symbol)"
    }

    private func feeText(_ quote: TradeQuote) -> String {
        guard let fee = quote.networkFeeFiat else { return "Sem taxa da Escalibur. A taxa da rede aparece na revisão." }
        return "Taxas: rede \(Fmt.fiat(fee, session.currency)) · sem taxa da Escalibur"
    }

    // MARK: Ordem limite

    private var limitForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            AmountBox(title: "Você vende", asset: model.sell, amount: $model.amountText, balance: balance(model.sell),
                      fiat: fiat(model.amountIn, model.sell), editable: true, over: over,
                      onPick: { picking = .sell }, onFraction: setFraction)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Quando 1 \(model.sell?.symbol ?? "") valer").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                HStack(alignment: .firstTextBaseline) {
                    TextField("0", text: $model.targetPriceText)
                        .font(.system(size: 28, weight: .bold).monospacedDigit()).foregroundStyle(Palette.ink)
                        .keyboardType(.decimalPad)
                    Text(model.buy?.symbol ?? "").typeStyle(.action).foregroundStyle(Palette.inkSoft)
                }
                HStack(spacing: Space.xs) {
                    ForEach([0, 5, 10, 20], id: \.self) { percent in
                        Chip(title: percent == 0 ? "Atual" : "+\(percent)%") { setTarget(percent) }
                    }
                }
            }
            .padding(Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
            limitSanityLine
            AmountBox(title: "Você recebe", asset: model.buy, amount: .constant(limitReceiveText), balance: balance(model.buy),
                      fiat: nil, editable: false, over: false, onPick: { picking = .buy }, onFraction: nil)
            HStack {
                Text("Vale por").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                Spacer()
                ForEach([(3600.0, "1 hora"), (86_400.0, "1 dia"), (604_800.0, "7 dias"), (2_592_000.0, "30 dias")], id: \.0) { seconds, title in
                    Chip(title: title, selected: model.validFor == seconds) { model.validFor = seconds }
                }
            }
            .padding(.top, Space.sm)
            if let engine {
                Text(engine.limitCustodyNote).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Onde o preco limite fica em relacao ao mercado (auditoria 2, M6). No XRP Ledger
    /// e na Stellar a ordem abaixo do mercado cruza o livro na hora e vai vendendo ate
    /// o preco digitado; um zero a menos vira prejuizo imediato.
    enum LimitSanity: Equatable {
        case fine
        /// Abaixo do mercado, em % (positivo): pede confirmacao.
        case below(Double)
        /// Abaixo demais: quase certamente erro de digitacao, bloqueia.
        case farBelow(Double)
        /// Muitas vezes acima: nao perde nada, mas provavelmente nunca executa.
        case farAbove(Double)
        /// Sem preco de mercado para comparar: pede confirmacao.
        case unknown
    }

    private var marketRate: Double? {
        guard let sell = model.sell, let buy = model.buy,
              let sellPrice = sell.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }),
              let buyPrice = buy.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }), sellPrice > 0, buyPrice > 0 else { return nil }
        return sellPrice / buyPrice
    }

    private var limitSanity: LimitSanity {
        // O preco que a ordem leva de fato: o minimo que vai para o motor sobre o valor
        // vendido, e nao uma segunda leitura do texto.
        guard let minimum = limitMinimumOut, let amount = model.amountIn, !amount.isZero,
              let sell = model.sell, let buy = model.buy else { return .fine }
        let target = Fmt.double(minimum, decimals: buy.decimals) / Fmt.double(amount, decimals: sell.decimals)
        guard target > 0 else { return .fine }
        guard let market = marketRate else { return .unknown }
        let ratio = target / market
        if ratio < 0.5 { return .farBelow((1 - ratio) * 100) }
        if ratio < 0.98 { return .below((1 - ratio) * 100) }
        if ratio > 4 { return .farAbove(ratio) }
        return .fine
    }

    private var limitPriceConfirmed: Bool {
        switch limitSanity {
        case .fine, .farAbove: return true
        case .farBelow: return false
        case .below, .unknown: return model.acceptedLimitPrice == model.targetPriceText
        }
    }

    @ViewBuilder
    private var limitSanityLine: some View {
        let confirm = Binding(get: { model.acceptedLimitPrice == model.targetPriceText },
                              set: { model.acceptedLimitPrice = $0 ? model.targetPriceText : nil })
        switch limitSanity {
        case .fine:
            EmptyView()
        case .below(let percent):
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("\(Fmt.grouped(percent, fractionDigits: percent < 10 ? 1 : 0))% abaixo do preço de mercado. A ordem pode sair na hora, vendendo abaixo do mercado até este preço.")
                    .typeStyle(.note).foregroundStyle(Palette.down).fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: confirm) {
                    Text("Conferi o preço e quero assim").typeStyle(.note).foregroundStyle(Palette.ink)
                }
                .tint(Palette.down)
            }
            .padding(.vertical, Space.xs)
        case .farBelow(let percent):
            Text("\(Fmt.grouped(percent, fractionDigits: 0))% abaixo do preço de mercado. Confira o número: a ordem sairia na hora, com prejuízo.")
                .typeStyle(.note).foregroundStyle(Palette.down).fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Space.xs)
        case .farAbove(let ratio):
            Text("\(Fmt.grouped(ratio, fractionDigits: 0)) vezes o preço de mercado: a ordem provavelmente nunca executa.")
                .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Space.xs)
        case .unknown:
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Sem preço de mercado agora para comparar. Confira o número antes de seguir.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: confirm) {
                    Text("Conferi o preço").typeStyle(.note).foregroundStyle(Palette.ink)
                }
                .tint(Palette.purple)
            }
            .padding(.vertical, Space.xs)
        }
    }

    private var limitReceiveText: String {
        guard let amount = model.amountIn, let sell = model.sell, let buy = model.buy,
              let target = Double(model.targetPriceText.replacingOccurrences(of: ",", with: ".")), target > 0 else { return "" }
        let value = Fmt.double(amount, decimals: sell.decimals) * target
        return Fmt.grouped(value, fractionDigits: min(buy.decimals, 6), trimZeros: true)
    }

    /// O minimo da ordem limite em unidades da rede, calculado do preco digitado sem
    /// passar pelo texto formatado: valor vendido vezes preco, arredondado para baixo.
    private var limitMinimumOut: BigUInt? {
        guard let amount = model.amountIn, !amount.isZero, let sell = model.sell, let buy = model.buy,
              let price = Fmt.parseAmount(model.targetPriceText, decimals: 18), !price.isZero else { return nil }
        let out = amount * price * Self.powerOfTen(buy.decimals) / (Self.powerOfTen(sell.decimals) * Self.powerOfTen(18))
        return out.isZero ? nil : out
    }

    static func powerOfTen(_ exponent: Int) -> BigUInt {
        (0..<exponent).reduce(BigUInt(1)) { result, _ in result * BigUInt(10) }
    }

    /// Congela o pedido e abre a revisao. O motor recota e monta o plano de novo la.
    private func startReview() {
        guard engine != nil, let wallet = session.selectedWallet, !wallet.isWatchOnly,
              let account = wallet.account(model.chain), let sell = model.sell, let buy = model.buy,
              let amount = model.amountIn, !amount.isZero else { return }
        let price = sell.coingeckoID.flatMap { portfolio.quotes[$0]?.price }
        let fiat = price.map { Fmt.double(amount, decimals: sell.decimals) * $0 }
        switch router.tradeMode {
        case .now:
            guard let quote = model.quote else { return }
            let request = TradeRequest(walletID: wallet.id, chain: model.chain, account: account, sell: sell, buy: buy,
                                       amountIn: amount, slippageBasisPoints: model.slippageBps)
            reviewing = TradeReviewFlow.Item(kind: .swap(request, quote), chain: model.chain, fiat: fiat)
        case .limit:
            guard let minimum = limitMinimumOut else { return }
            let request = LimitOrderRequest(walletID: wallet.id, chain: model.chain, account: account, sell: sell, buy: buy,
                                            amountIn: amount, minimumOut: minimum, validFor: model.validFor)
            reviewing = TradeReviewFlow.Item(kind: .limit(request), chain: model.chain, fiat: fiat)
        }
    }

    private func setTarget(_ percent: Int) {
        guard let sell = model.sell, let buy = model.buy,
              let sellPrice = sell.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }),
              let buyPrice = buy.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }), buyPrice > 0 else { return }
        let current = sellPrice / buyPrice * (1 + Double(percent) / 100)
        model.targetPriceText = Fmt.grouped(current, fractionDigits: 6, trimZeros: true).replacingOccurrences(of: ".", with: "")
    }

    // MARK: Rodape

    private var over: Bool {
        guard let amount = model.amountIn, let sell = model.sell else { return false }
        return amount > (holding(sell)?.amount ?? 0)
    }

    private var footer: some View {
        ActionFooter {
            if !tradeChains.isEmpty {
            if router.tradeMode == .now, model.quote != nil {
                Text("Nova cotação em \(model.nextRefresh) s").typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
            if !hasBalance(model.sell), let sell = model.sell {
                AccentButton(title: "Receber \(sell.symbol)", systemImage: "arrow.down") { receivingAsset = sell }
            } else {
                PrimaryButton(title: primaryTitle, enabled: primaryEnabled, loading: model.quoting && model.quote == nil && model.amountIn != nil) {
                    startReview()
                }
            }
            }
        }
        .padding(.bottom, Space.xs)
    }

    private var primaryTitle: String {
        guard engine != nil else { return "Trocar \(model.chain.id == "xrpl" ? "no" : "na") \(model.chain.name) chega em breve" }
        guard let amount = model.amountIn, !amount.isZero else { return "Digite um valor" }
        if over { return "Saldo de \(model.sell?.symbol ?? "") insuficiente" }
        if router.tradeMode == .limit {
            if case .farBelow = limitSanity { return "Preço muito abaixo do mercado" }
            return "Revisar ordem"
        }
        if model.quoting && model.quote == nil { return "Buscando o melhor preço" }
        if PriceImpact.level(model.quote?.priceImpactPercent) == .blocked { return "Impacto no preço alto demais" }
        return model.quote?.needsApproval == true ? "Autorizar \(model.sell?.symbol ?? "") e trocar" : "Revisar troca"
    }

    private var primaryEnabled: Bool {
        guard engine != nil, let amount = model.amountIn, !amount.isZero, !over else { return false }
        if router.tradeMode == .limit { return engine?.supportsLimitOrders == true && limitMinimumOut != nil && limitPriceConfirmed }
        switch PriceImpact.level(model.quote?.priceImpactPercent) {
        case .blocked: return false
        case .confirm: return model.acceptedHighImpact
        default: return model.quote != nil
        }
    }

    // MARK: Acoes

    private func holding(_ asset: Asset?) -> Holding? {
        guard let asset, let chain = asset.chain else { return nil }
        return portfolio.balance(chain)?.holdings.first { $0.asset.id == asset.id }
    }

    private func balance(_ asset: Asset?) -> String? {
        guard let asset else { return nil }
        let amount = holding(asset)?.amount ?? 0
        return "Saldo \(Fmt.crypto(amount, decimals: asset.decimals, symbol: asset.symbol, style: .list))"
    }

    private func hasBalance(_ asset: Asset?) -> Bool {
        !(holding(asset)?.amount.isZero ?? true)
    }

    private func fiat(_ amount: BigUInt?, _ asset: Asset?) -> String? {
        guard let asset, let price = asset.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }) else { return nil }
        return "≈ \(Fmt.fiat(Fmt.double(amount ?? 0, decimals: asset.decimals) * price, session.currency))"
    }

    private func setFraction(_ fraction: Double) {
        guard let sell = model.sell, let total = holding(sell)?.amount else { return }
        let part = fraction >= 1 ? total : total * BigUInt(UInt64(fraction * 100)) / BigUInt(100)
        model.amountText = Fmt.plainDecimal(part, decimals: sell.decimals)
    }

    private func flip() {
        withAnimation(Motion.flip) { flipTurns += 1 }
        withAnimation(Motion.flip) {
            let sell = model.sell
            model.sell = model.buy
            model.buy = sell
            model.amountText = ""
            model.quote = nil
        }
    }

    private func refreshQuote() async {
        guard router.tradeMode == .now, let engine, let wallet = session.selectedWallet, !wallet.isWatchOnly,
              let sell = model.sell, let buy = model.buy, let amount = model.amountIn, !amount.isZero,
              let account = wallet.account(model.chain) else {
            model.quote = nil
            return
        }
        // Pedido novo (par, valor, rede ou tolerancia): o aceite do impacto era do outro.
        model.acceptedImpactPercent = nil
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        while !Task.isCancelled {
            model.quoting = true
            model.error = nil
            do {
                let request = TradeRequest(walletID: wallet.id, chain: model.chain, account: account, sell: sell, buy: buy,
                                           amountIn: amount, slippageBasisPoints: model.slippageBps)
                model.quote = try await engine.quote(request)
            } catch {
                model.quote = nil
                model.error = (error as? LocalizedError)?.errorDescription
                    ?? "Nenhum provedor troca \(sell.symbol) por \(buy.symbol) \(model.chain.id == "xrpl" ? "no" : "na") \(model.chain.name) agora. Tente um valor menor ou outro par."
            }
            model.quoting = false
            for second in stride(from: 15, through: 1, by: -1) {
                model.nextRefresh = second
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
    }
}

/// Caixa de valor do swap: "Voce paga" e "Voce recebe".
struct AmountBox: View {
    let title: String
    let asset: Asset?
    @Binding var amount: String
    let balance: String?
    let fiat: String?
    let editable: Bool
    let over: Bool
    var loading: Bool = false
    let onPick: () -> Void
    let onFraction: ((Double) -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(title).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                Spacer()
                if let balance { Text(balance).typeStyle(.note).foregroundStyle(over ? Palette.down : Palette.inkSoft) }
            }
            HStack(alignment: .center, spacing: Space.sm) {
                if editable {
                    TextField("0", text: $amount)
                        .font(.system(size: 32, weight: .bold).monospacedDigit())
                        .foregroundStyle(over ? Palette.down : Palette.ink)
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .minimumScaleFactor(0.5)
                        .toolbar {
                            // O teclado numerico nao tem tecla de fechar; sem isto, a
                            // cotacao e os detalhes ficam escondidos embaixo dele.
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Pronto") { focused = false }.fontWeight(.semibold)
                            }
                        }
                } else if loading {
                    ShimmerBar(width: 150, height: 30)
                    Spacer(minLength: 0)
                } else {
                    Text(amount.isEmpty ? "0" : amount)
                        .font(.system(size: 32, weight: .bold).monospacedDigit())
                        .foregroundStyle(amount.isEmpty ? Palette.inkDead : Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                        .animation(Motion.number, value: amount)
                    Spacer(minLength: 0)
                }
                Button(action: onPick) {
                    HStack(spacing: 6) {
                        if let asset {
                            CoinLogo(coingeckoID: asset.coingeckoID, symbol: asset.symbol, size: 24, network: asset.chain, ringColor: Palette.rail)
                            Text(asset.symbol).typeStyle(.action).foregroundStyle(Palette.ink)
                        } else {
                            Text("Escolher").typeStyle(.action).foregroundStyle(Palette.ink)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                    }
                    .padding(.horizontal, Space.sm)
                    .frame(height: Height.tokenChip)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text(fiat ?? " ").typeStyle(.note).foregroundStyle(amount.isEmpty ? Palette.inkMuted : Palette.inkSoft)
                Spacer()
                if let onFraction {
                    ForEach([(0.25, "25%"), (0.5, "50%"), (1.0, "Máx")], id: \.0) { fraction, label in
                        Button { onFraction(fraction) } label: {
                            Text(label).typeStyle(.label).foregroundStyle(Palette.inkSoft)
                                .padding(.horizontal, Space.xs).frame(height: 28)
                                .background(Capsule(style: .continuous).fill(Palette.rail))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(focused ? Palette.edgeStrong : Palette.edge, lineWidth: 1))
        )
    }
}

/// T2: escolher token dentro da rede.
struct TokenPickerSheet: View {
    @Environment(Portfolio.self) private var portfolio
    @Environment(\.dismiss) private var dismiss
    let chain: Chain
    let exclude: Asset?
    let onPick: (Asset) -> Void
    @State private var query = ""

    var body: some View {
        let all = TokenRegistry.assets(on: chain).filter { $0.id != exclude?.id }
        let shown = query.isEmpty ? all : all.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Escolher token") { dismiss() }
            TextField("", text: $query, prompt: Text("Buscar por nome").foregroundColor(Palette.inkDead))
                .typeStyle(.body).foregroundStyle(Palette.ink)
                .padding(.horizontal, Space.md).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
                .padding(.horizontal, Space.gutter).padding(.top, Space.md)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { asset in
                        Button { onPick(asset) } label: {
                            HStack(spacing: Space.sm) {
                                CoinLogo(coingeckoID: asset.coingeckoID, symbol: asset.symbol, size: 36, network: asset.chain, ringColor: Palette.body)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asset.symbol).typeStyle(.row).foregroundStyle(Palette.ink)
                                    Text(asset.name).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                }
                                Spacer()
                                if let amount = portfolio.balance(chain)?.holdings.first(where: { $0.asset.id == asset.id })?.amount, !amount.isZero {
                                    Text(Fmt.crypto(amount, decimals: asset.decimals)).typeStyle(.note).foregroundStyle(Palette.ink)
                                }
                            }
                            .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
                        }
                        .buttonStyle(RowStyle(surface: .body))
                    }
                }
                .padding(.top, Space.xs)
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
    }
}

/// T4: tolerancia de preco.
/// T3: a rota, com a divisao entre provedores como ganho medido.
struct RouteSheet: View {
    let quote: TradeQuote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: quote.legs.count > 1 ? "Como a sua ordem foi dividida" : "Rota da troca") { dismiss() }
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(quote.legs.enumerated()), id: \.offset) { _, leg in
                    HStack {
                        Text(leg.provider).typeStyle(.row).foregroundStyle(Palette.ink)
                        Spacer()
                        Text("\(Int((leg.fraction * 100).rounded()))%").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        Text(Fmt.crypto(leg.expectedOut, decimals: quote.buy.decimals, symbol: quote.buy.symbol)).typeStyle(.note).foregroundStyle(Palette.ink)
                    }
                }
                Text(quote.legs.count > 1
                     ? "São \(quote.legs.count) transações, uma por provedor, confirmadas com um único Face ID. Cada parte é independente: se uma não passar, você fica com o que foi trocado, e o saldo daquela parte continua na sua carteira."
                     : "Tudo acontece numa transação só. Ou executa inteira, ou nada sai da sua carteira.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true).padding(.top, Space.xs)
                if !quote.alternatives.isEmpty {
                    Text("Outras cotações").typeStyle(.heading).foregroundStyle(Palette.ink).padding(.top, Space.md)
                    ForEach(Array(quote.alternatives.enumerated()), id: \.offset) { _, alternative in
                        HStack {
                            Text(alternative.provider).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                            Spacer()
                            Text(Fmt.crypto(alternative.out, decimals: quote.buy.decimals, symbol: quote.buy.symbol)).typeStyle(.note).foregroundStyle(Palette.ink)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.md)
            Spacer()
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
    }
}
