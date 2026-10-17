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
    /// O dono escolheu a troca em partes (so existe quando a cotacao oferece).
    var inParts = false
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
    /// Por quanto tempo a ordem limite vale; nil e "ate cancelar".
    var validFor: TimeInterval? = 7 * 86_400
    /// O preco-alvo que o app preencheu (o de agora). Enquanto o dono nao muda o campo,
    /// trocar o par preenche de novo.
    var autoTarget: String?
    /// Refazer a ordem quando vencer: o app avisa e pergunta (`LimitRenewalCenter`).
    var renewOnExpiry = false
    /// Editando uma ordem aberta: a revisao cancela esta antes de criar a nova.
    var editing: LimitEdit?

    // Quanto receber (pedido do dono, 14/10/2026)
    /// O dono digitou em "Voce recebe". Na troca imediata o app acha quanto pagar
    /// (`ExactOutSolver`); na ordem limite, o preco ou o valor vendido sai da conta.
    var exactOut = false
    var receiveText = ""
    /// O campo "Voce recebe" esta com o teclado.
    var editingReceive = false
    /// A busca de quanto pagar para o recebido digitado.
    var solving = false
    /// Nem a ultima tentativa chegou ao recebido digitado: o garantido fica abaixo.
    var shortOfTarget = false
    /// Na ordem limite, o que acompanha o recebido digitado.
    var limitDerives: LimitDerived = .price

    enum LimitDerived { case price, amount }

    var wantOut: BigUInt? {
        guard let buy else { return nil }
        return Fmt.parseAmount(receiveText, decimals: buy.decimals)
    }

    /// O dono digitou em "Voce paga" (ou "Voce vende"): volta a valer o valor de entrada.
    func typePay(_ text: String) {
        amountText = text
        clearExactOut()
    }

    func clearExactOut() {
        exactOut = false
        receiveText = ""
        shortOfTarget = false
    }

    var amountIn: BigUInt? {
        guard let sell else { return nil }
        return Fmt.parseAmount(amountText, decimals: sell.decimals)
    }

    func reset(to chain: Chain) {
        self.chain = chain
        // Prazo que a rede nova nao tem (o "ate cancelar" fora do XRP Ledger) volta aos 7 dias.
        if validFor == nil, chain.family != .xrpl { validFor = 7 * 86_400 }
        sell = .native(chain)
        buy = TokenRegistry.tokens.first { $0.chainID == chain.id && $0.isStablecoin }
        quote = nil
        inParts = false
        error = nil
        amountText = ""
        clearExactOut()
    }

    /// O que a tela mostra em "Voce recebe": o minimo garantido da execucao escolhida,
    /// gravado na transacao ou na ordem assinada. Chega ele ou mais.
    var shownMinimum: BigUInt? {
        quote.map { $0.minimumOut(inParts: inParts && $0.parts != nil) }
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
    /// Sobe quando uma ordem foi criada: as ordens abertas releem.
    @State private var ordersRefresh = 0

    /// Os prazos da ordem limite que a rede aceita. Na CoW, de 1 a 30 dias: o "ate
    /// cancelar" de lá era um prazo de 364 dias disfarcado e saiu (pedido do dono,
    /// 11/10/2026). No XRP Ledger a oferta pode ir sem prazo de verdade. Na Stellar nao ha
    /// prazo nenhum: a oferta fica ate executar ou o dono cancelar.
    static func validities(_ chain: Chain) -> [(seconds: TimeInterval?, title: String)] {
        let days: [(seconds: TimeInterval?, title: String)] = [(86_400, String(localized: "1 dia")), (604_800, String(localized: "7 dias")), (2_592_000, String(localized: "30 dias"))]
        switch chain.family {
        case .xrpl: return days + [(nil, String(localized: "Até cancelar"))]
        case .stellar: return []
        default: return days
        }
    }

    enum Side: Identifiable { case sell, buy; var id: Self { self } }

    private var engine: (any TradeEngine)? { TradeEngines.engine(for: model.chain) }
    private var tradeChains: [Chain] { TradeEngines.chains }
    @State private var flipTurns = 0
    @State private var bridgeModel = BridgeFormModel()
    @State private var bridgeReviewing: BridgeReviewFlow.Item?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TabTitle(title: String(localized: "Trocar")) {
                        if !tradeChains.isEmpty, router.tradeMode != .bridge {
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
                            Segmented(options: [(Router.TradeMode.now, String(localized: "Imediata")), (.limit, String(localized: "Limite")), (.bridge, String(localized: "Ponte"))],
                                      selection: Bindable(router).tradeMode)
                                .padding(.top, Space.sm)
                            if session.selectedWallet?.isWatchOnly == true {
                                Banner(kind: .neutral, title: String(localized: "Esta carteira só observa. Escolha outra carteira para trocar.")).padding(.top, Space.md)
                            }
                            switch router.tradeMode {
                            case .now: nowForm.padding(.top, Space.md)
                            case .limit: limitForm.padding(.top, Space.md)
                            case .bridge: BridgeForm(model: bridgeModel).padding(.top, Space.md)
                            }
                        }
                        .padding(.horizontal, Space.gutter)
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            // A base do rodape desce ate o fim da tela, por baixo da barra de abas: o toque
            // que cai no vao entre os botoes da barra para nela, e nao numa ordem aberta
            // que esteja rolada por tras (relato do dono, 14/10/2026).
            .safeAreaInset(edge: .bottom) { footer.background(Palette.void.ignoresSafeArea(.container, edges: .bottom)) }
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .statusBarBackdrop()
        }
        .onAppear {
            if model.sell == nil, let first = tradeChains.first { model.reset(to: first) }
            applyPreset()
            applyEdit()
            #if DEBUG
            // `-tela trocar-grande`: uma venda grande de ETH por USDC na Ethereum, com
            // cotacao ao vivo, para conferir a troca pela CoW e a opcao em partes.
            if DebugDemo.screen == "trocar-grande", model.amountText.isEmpty {
                model.reset(to: .ethereum)
                model.buy = TokenRegistry.tokens.first { $0.chainID == "ethereum" && $0.symbol == "USDC" }
                model.amountText = "8000"
            }
            // `-tela trocar-xrp` e `-tela limite-xrp`: as capturas da loja, com o XRP que a
            // carteira publica de teste tem. Na Solana nao da: a conta dela foi entregue a
            // um programa por quem conhece a frase, e o app recusa montar.
            if DebugDemo.screen == "trocar-xrp", model.amountText.isEmpty {
                model.reset(to: .xrpl)
                model.buy = TokenRegistry.tokens.first { $0.chainID == "xrpl" && $0.symbol == "RLUSD" }
                model.amountText = "500"
            }
            if DebugDemo.screen == "limite-xrp", model.amountText.isEmpty {
                model.reset(to: .xrpl)
                model.buy = TokenRegistry.tokens.first { $0.chainID == "xrpl" && $0.symbol == "RLUSD" }
                model.amountText = "1000"
            }
            // `-tela trocar-recebe` e `-tela limite-recebe`: "Voce recebe" ja digitado (500
            // RLUSD), para conferir a busca do valor a pagar e o preco que sai da conta.
            if ["trocar-recebe", "limite-recebe"].contains(DebugDemo.screen), model.receiveText.isEmpty {
                model.reset(to: .xrpl)
                model.buy = TokenRegistry.tokens.first { $0.chainID == "xrpl" && $0.symbol == "RLUSD" }
                if DebugDemo.screen == "limite-recebe" { model.amountText = "1000" }
                if DebugDemo.screen == "limite-recebe" { typeLimitReceive("1500") } else { model.receiveText = "500"; model.exactOut = true }
            }
            #endif
        }
        .onChange(of: router.tradePreset?.asset.id) { _, _ in applyPreset() }
        .onChange(of: router.limitEdit?.order.id) { _, _ in applyEdit() }
        // Outro modo: o recebido digitado era do anterior (o valor a pagar fica).
        .onChange(of: router.tradeMode) { _, _ in model.clearExactOut() }
        .sheet(item: $picking) { side in
            TokenPickerSheet(chain: model.chain, exclude: side == .sell ? model.buy : model.sell, selling: side == .sell) { asset in
                if side == .sell { model.sell = asset } else { model.buy = asset }
                model.quote = nil
                // Outra moeda a receber: o recebido digitado era em outra unidade.
                if side == .buy, model.exactOut {
                    model.clearExactOut()
                    if router.tradeMode == .now { model.amountText = "" }
                }
                picking = nil
            }
        }
        .sheet(item: $receivingAsset) { asset in ReceiveSheet(preselected: asset) }
        .sheet(isPresented: $routeSheet) { if let quote = model.quote { RouteSheet(quote: quote) } }
        .fullScreenCover(item: $reviewing) { item in
            TradeReviewFlow(item: item) { completed in
                reviewing = nil
                if completed { ordersRefresh += 1 }
                if completed {
                    model.amountText = ""
                    model.targetPriceText = ""
                    model.quote = nil
                    model.editing = nil
                }
            }
        }
        .fullScreenCover(item: $bridgeReviewing) { item in
            BridgeReviewFlow(item: item) { completed in
                bridgeReviewing = nil
                if completed {
                    bridgeModel.amountText = ""
                    bridgeModel.changed()
                }
            }
        }
        .task(id: quoteKey) { await refreshQuote() }
        // Ordem limite: o preco de agora ja no campo, e de novo ao trocar o par (enquanto o
        // dono nao mudou o campo); quando o preco chega depois, tambem.
        .task(id: "\(model.chain.id)|\(model.sell?.id ?? "")|\(model.buy?.id ?? "")|\(router.tradeMode == .limit)|\(marketRate != nil)") {
            prefillTarget()
        }
        .task(id: session.selectedWallet?.id) { await portfolio.ensureLoaded(session.selectedWallet, session: session) }
    }

    /// Chegando do detalhe de uma moeda: a rede dela e ela como venda ou compra.
    /// A ordem em edicao: o par, o que falta vender, o preco dela, o prazo mais perto do
    /// que restava e o "refazer quando vencer" (pedido do dono, 17/10/2026).
    private func applyEdit() {
        guard let edit = router.limitEdit, let chain = edit.sell.chain, tradeChains.contains(chain) else { return }
        router.limitEdit = nil
        router.tradeMode = .limit
        model.reset(to: chain)
        model.sell = edit.sell
        model.buy = edit.buy
        let order = edit.order
        model.typePay(Fmt.plainDecimal(order.remainingSell, decimals: edit.sell.decimals))
        let sold = Fmt.double(order.remainingSell, decimals: edit.sell.decimals)
        if sold > 0 {
            model.targetPriceText = Self.priceText(Fmt.double(order.minimumBuy, decimals: edit.buy.decimals) / sold)
            model.autoTarget = nil
        }
        let options = Self.validities(chain)
        if let expires = order.expiresAt {
            let left = expires.timeIntervalSinceNow
            model.validFor = options.compactMap(\.seconds).first { $0 >= left } ?? options.compactMap(\.seconds).last ?? model.validFor
        } else if options.contains(where: { $0.seconds == nil }) {
            model.validFor = nil
        }
        model.renewOnExpiry = LimitRenewalCenter.shared.isRenewing(order.id, session: session)
        model.editing = edit
    }

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

    /// Com o recebido digitado, o valor a pagar e do app: a busca so recomeca quando o
    /// recebido, o par, a tolerancia ou a execucao (em partes) mudam.
    private var quoteKey: String {
        let amount = model.exactOut ? "recebe:\(model.receiveText)|\(model.inParts)" : "paga:\(model.amountText)"
        return "\(model.chain.id)|\(model.sell?.id ?? "")|\(model.buy?.id ?? "")|\(amount)|\(slippage())|\(router.tradeMode == .now)"
    }

    /// A tolerancia do pedido: a automatica (o par, o dia e a rede) ou a escolhida no
    /// controle. O impacto que a API do agregador informa nunca entra: uma API
    /// comprometida inflaria o impacto para alargar o proprio teto de perda (auditoria 3,
    /// M1). Ele so aparece como aviso na cotacao.
    private func slippage() -> Int {
        guard model.automaticSlippage, let sell = model.sell, let buy = model.buy else { return model.slippageBps }
        let changes = [sell, buy].compactMap { $0.coingeckoID.flatMap { portfolio.quotes[$0]?.change24h } }.map(abs)
        return AutoSlippage.basisPoints(sell: sell, buy: buy, chainID: model.chain.id, volatilityPercent: changes.max())
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
                AmountBox(title: String(localized: "Você paga"), asset: model.sell, amount: Binding(get: { model.amountText }, set: { model.typePay($0) }),
                          balance: balance(model.sell), fiat: fiat(model.amountIn, model.sell), editable: true, over: over,
                          loading: model.exactOut && model.solving, computed: model.exactOut,
                          onPick: { picking = .sell }, onFraction: fractionAction)
                AmountBox(title: String(localized: "Você recebe"), asset: model.buy, amount: receiveBinding(computed: receiveText),
                          balance: balance(model.buy), fiat: fiat(model.exactOut ? model.wantOut : model.shownMinimum, model.buy),
                          editable: true, over: false,
                          loading: !model.exactOut && model.quoting && model.quote == nil && model.amountIn != nil,
                          computed: !model.exactOut, placeholder: receivePlaceholder(receiveText), keyboardDone: false,
                          onFocusChange: receiveFocus, onPick: { picking = .buy }, onFraction: nil)
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

            if let quote = model.quote, let parts = quote.parts, let buy = model.buy {
                ExecutionChoice(quote: quote, parts: parts, buy: buy, inParts: $model.inParts)
                    .padding(.top, Space.md)
                    .transition(.opacity)
            }
            SlippageSlider(basisPoints: $model.slippageBps, automatic: $model.automaticSlippage, autoValue: slippage())
                .padding(.top, Space.lg)
            quoteLines.padding(.top, Space.lg)
            OpenOrdersSection(refresh: ordersRefresh, hidesWhenEmpty: true).padding(.top, Space.lg)
        }
    }

    private var receiveText: String {
        guard let minimum = model.shownMinimum, let buy = model.buy else { return "" }
        return Fmt.plainDecimal(minimum, decimals: buy.decimals)
    }

    /// "Voce recebe" editavel: mostra o calculado ate o dono digitar. Com o teclado nele,
    /// o campo abre vazio, com o calculado de dica, e o que se digita vira o pedido.
    private func receiveBinding(computed: String) -> Binding<String> {
        Binding(
            get: { model.exactOut ? model.receiveText : (model.editingReceive ? "" : computed) },
            set: { text in
                if router.tradeMode == .limit { typeLimitReceive(text) } else {
                    model.receiveText = text
                    model.exactOut = true
                }
            }
        )
    }

    private func receivePlaceholder(_ computed: String) -> String {
        !model.exactOut && model.editingReceive && !computed.isEmpty ? computed : "0"
    }

    /// Saiu do campo sem digitar nada: volta a valer o valor de entrada. Na troca
    /// imediata, o valor a pagar era do app e sai junto.
    private func receiveFocus(_ focused: Bool) {
        model.editingReceive = focused
        guard !focused, model.exactOut, model.receiveText.isEmpty else { return }
        model.exactOut = false
        if router.tradeMode == .now { model.amountText = "" }
    }

    private var routeText: String {
        guard let quote = model.quote else { return "" }
        if model.inParts, quote.parts != nil { return String(localized: "Em partes pela CoW, conforme chega liquidez") }
        if quote.execution == .order { return String(localized: "Leilão da CoW, o melhor entre \(quote.providersCompared)") }
        return quote.legs.count > 1
            ? String(localized: "Dividida entre \(quote.legs.count) provedores para você receber mais")
            : String(localized: "\(quote.legs.first?.provider ?? ""), o melhor entre \(quote.providersCompared)")
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
                        Text(routeText)
                            .typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("Ver rota").typeStyle(.note).fontWeight(.semibold).foregroundStyle(Palette.ink)
                    }
                }
                .buttonStyle(.plain)
                Text(feeText(quote)).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                if model.exactOut, model.shortOfTarget {
                    Text("A liquidez de agora não chega a \(model.receiveText) \(buy.symbol). O garantido fica em \(Fmt.crypto(model.shownMinimum ?? quote.minimumOut, decimals: buy.decimals, symbol: buy.symbol, style: .full)).")
                        .typeStyle(.note).foregroundStyle(Palette.caution).fixedSize(horizontal: false, vertical: true)
                }
                if let unverified = [sell, buy].first(where: { $0.origin != nil }) {
                    Text("\(unverified.symbol) não está na lista verificada da Escalibur. Qualquer pessoa cria um token com qualquer nome, e alguns deixam comprar mas não deixam vender. Confira o contrato antes.")
                        .typeStyle(.note).foregroundStyle(Palette.caution).fixedSize(horizontal: false, vertical: true)
                }
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
                    let inParts = model.inParts && quote.parts != nil
                    detail(String(localized: "Garantido"), Fmt.crypto(model.shownMinimum ?? quote.minimumOut, decimals: buy.decimals, symbol: buy.symbol, style: .full))
                    detail(String(localized: "Cotação do provedor"), Fmt.crypto(inParts ? quote.parts?.expectedOut ?? quote.expectedOut : quote.expectedOut,
                                                             decimals: buy.decimals, symbol: buy.symbol, style: .full))
                    if quote.execution == .order || inParts {
                        detail(String(localized: "Prazo da ordem"), inParts ? String(localized: "1 hora") : String(localized: "30 minutos"))
                    }
                    if let impact = quote.priceImpactPercent { detail(String(localized: "Impacto no preço"), "\(Fmt.grouped(impact, fractionDigits: 2))%") }
                    if model.chain == .ethereum, session.metadata.settings.mevProtection { detail(String(localized: "Proteção contra robôs"), String(localized: "ligada")) }
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

    /// O preco pelo garantido: o mesmo numero de "Voce recebe".
    private func rateText(_ quote: TradeQuote, sell: Asset, buy: Asset) -> String {
        let inAmount = Fmt.double(quote.amountIn, decimals: sell.decimals)
        let outAmount = Fmt.double(model.shownMinimum ?? quote.minimumOut, decimals: buy.decimals)
        guard inAmount > 0, outAmount > 0 else { return "" }
        if model.invertedRate {
            return "1 \(buy.symbol) = \(Fmt.grouped(inAmount / outAmount, fractionDigits: 6, trimZeros: true)) \(sell.symbol)"
        }
        return "1 \(sell.symbol) = \(Fmt.grouped(outAmount / inAmount, fractionDigits: 6, trimZeros: true)) \(buy.symbol)"
    }

    private func feeText(_ quote: TradeQuote) -> String {
        guard let fee = quote.networkFeeFiat else { return String(localized: "Sem taxa da Escalibur. A taxa da rede aparece na revisão.") }
        return String(localized: "Taxas: rede \(Fmt.fiat(fee, session.currency)) · sem taxa da Escalibur")
    }

    // MARK: Ordem limite

    /// A faixa da edicao: qual ordem, o que acontece na revisao, e desistir.
    private func editingBanner(_ edit: LimitEdit) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "pencil").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Editando a ordem de \(Fmt.crypto(edit.order.remainingSell, decimals: edit.sell.decimals, symbol: edit.sell.symbol)) por \(edit.buy.symbol)")
                    .typeStyle(.note).fontWeight(.semibold).foregroundStyle(Palette.ink).lineLimit(2)
                Spacer(minLength: 0)
                Button { withAnimation(Motion.fade) { model.editing = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.inkSoft)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Desistir de editar")
                .accessibilityIdentifier("desistir-edicao")
            }
            Text("Mude o que quiser. Na revisão, a ordem atual é cancelada primeiro e a nova é criada em seguida.")
                .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
        .padding(.bottom, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editando-ordem")
    }

    private var limitForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let edit = model.editing, edit.order.chain.id == model.chain.id { editingBanner(edit) }
            AmountBox(title: String(localized: "Você vende"), asset: model.sell, amount: Binding(get: { model.amountText }, set: { model.typePay($0) }),
                      balance: balance(model.sell), fiat: fiat(model.amountIn, model.sell), editable: true, over: over,
                      computed: model.exactOut && model.limitDerives == .amount,
                      onPick: { picking = .sell }, onFraction: setFraction)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Quando 1 \(model.sell?.symbol ?? "") valer").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                HStack(alignment: .firstTextBaseline) {
                    TextField("0", text: Binding(get: { model.targetPriceText }, set: { model.targetPriceText = $0; limitPriceChanged() }))
                        .font(.system(size: 28, weight: .bold).monospacedDigit()).foregroundStyle(Palette.ink)
                        .keyboardType(.decimalPad)
                    Text(model.buy?.symbol ?? "").typeStyle(.action).foregroundStyle(Palette.inkSoft)
                }
                if let compact = Fmt.compactZeros(model.targetPriceText) {
                    Text("\(compact) \(model.buy?.symbol ?? "")").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        .accessibilityLabel("\(model.targetPriceText) \(model.buy?.symbol ?? "")")
                }
                HStack(spacing: Space.xs) {
                    ForEach([0, 5, 10, 20], id: \.self) { percent in
                        Chip(title: percent == 0 ? String(localized: "Atual") : "+\(percent)%") { setTarget(percent) }
                    }
                }
            }
            .padding(Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
            limitSanityLine
            AmountBox(title: String(localized: "Você recebe"), asset: model.buy, amount: receiveBinding(computed: limitReceiveText), balance: balance(model.buy),
                      fiat: nil, editable: true, over: false, computed: !model.exactOut, placeholder: receivePlaceholder(limitReceiveText),
                      keyboardDone: false, onFocusChange: receiveFocus, onPick: { picking = .buy }, onFraction: nil)
            VStack(alignment: .leading, spacing: Space.xs) {
                let options = Self.validities(model.chain)
                if options.isEmpty {
                    Text("Na \(model.chain.name) a oferta não tem prazo: fica até executar ou você cancelar.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Vale por").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.xs) {
                            ForEach(options, id: \.title) { option in
                                Chip(title: option.title, selected: model.validFor == option.seconds) { model.validFor = option.seconds }
                            }
                        }
                    }
                }
                if model.validFor != nil, LimitRenewalCenter.supports(model.chain) {
                    renewToggle.padding(.top, Space.xs)
                }
            }
            .padding(.top, Space.sm)
            if let engine {
                Text(engine.limitCustodyNote).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                OpenOrdersSection(refresh: ordersRefresh).padding(.top, Space.lg)
            }
        }
    }

    /// Refazer quando vencer. Sem servidor e com a chave so no iPhone, nada assina
    /// sozinho: o app avisa e pergunta, e refazer pede o Face ID ou o PIN.
    private var renewToggle: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Toggle(isOn: Binding(get: { model.renewOnExpiry }, set: { on in
                model.renewOnExpiry = on
                if on { Task { _ = await PriceAlertCenter.requestPermission() } }
            })) {
                Text("Refazer quando vencer").typeStyle(.row).foregroundStyle(Palette.ink)
            }
            .tint(Palette.accent)
            .accessibilityIdentifier("refazer-ordem")
            Text("Quando o prazo acabar, o iPhone avisa e o app pergunta se refaz com o mesmo preço. Refazer pede o seu Face ID ou PIN: sem você, ninguém assina uma ordem nova com a sua chave.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
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

    /// O preco de um ativo na moeda do app: o da lista pelo id do CoinGecko, o de fora da
    /// lista pelo contrato.
    private func price(_ asset: Asset) -> Double? {
        let value = asset.coingeckoID.flatMap { portfolio.quotes[$0]?.price } ?? portfolio.tokenQuotes[asset.id]?.price
        return value.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
    }

    private var marketRate: Double? {
        guard let sell = model.sell, let buy = model.buy, let sellPrice = price(sell), let buyPrice = price(buy) else { return nil }
        return sellPrice / buyPrice
    }

    /// O preco no campo: sem separador de milhar, com seis algarismos que contam, por
    /// menor que seja (o de um token de fracao de centavo nao vira zero).
    static func priceText(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "" }
        let decimals = max(2, min(30, 5 - Int(floor(log10(value)))))
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text.replacingOccurrences(of: ".", with: Fmt.decimal)
    }

    /// O preco de agora no campo, se ele esta vazio ou ainda com o que o app preencheu.
    private func prefillTarget() {
        guard router.tradeMode == .limit, model.targetPriceText.isEmpty || model.targetPriceText == model.autoTarget else { return }
        setTarget(0)
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
        // Recebido digitado: ele mesmo e o minimo, sem passar pelo preco arredondado.
        if model.exactOut {
            guard let amount = model.amountIn, !amount.isZero, let want = model.wantOut, !want.isZero else { return nil }
            return want
        }
        guard let amount = model.amountIn, !amount.isZero, let sell = model.sell, let buy = model.buy,
              let price = Fmt.parseAmount(model.targetPriceText, decimals: 36), !price.isZero else { return nil }
        let out = amount * price * Self.powerOfTen(buy.decimals) / (Self.powerOfTen(sell.decimals) * Self.powerOfTen(36))
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
                                       amountIn: amount, slippageBasisPoints: slippage(), inParts: model.inParts && quote.parts != nil)
            reviewing = TradeReviewFlow.Item(kind: .swap(request, quote), chain: model.chain, fiat: fiat)
        case .limit:
            guard let minimum = limitMinimumOut else { return }
            let request = LimitOrderRequest(walletID: wallet.id, chain: model.chain, account: account, sell: sell, buy: buy,
                                            amountIn: amount, minimumOut: minimum, validFor: model.validFor)
            var item = TradeReviewFlow.Item(kind: .limit(request), chain: model.chain, fiat: fiat,
                                            renewLimit: model.renewOnExpiry && model.validFor != nil && LimitRenewalCenter.supports(model.chain))
            // Editando: a revisao cancela a ordem atual antes de criar esta.
            if let edit = model.editing, edit.order.chain.id == model.chain.id {
                item.cancelFirst = TradeReviewFlow.Replacement(order: edit.order, via: edit.via)
                item.replacesRenewal = edit.order.id
            }
            reviewing = item
        case .bridge:
            return
        }
    }

    private func setTarget(_ percent: Int) {
        guard let rate = marketRate else { return }
        let text = Self.priceText(rate * (1 + Double(percent) / 100))
        model.targetPriceText = text
        model.autoTarget = percent == 0 ? text : nil
        limitPriceChanged()
    }

    /// "Voce recebe" digitado na ordem limite. Com valor vendido, o preco sai da conta
    /// (como na CoW); sem ele, sai o valor vendido, pelo preco do campo.
    private func typeLimitReceive(_ text: String) {
        if !model.exactOut { model.limitDerives = (model.amountIn?.isZero ?? true) ? .amount : .price }
        model.receiveText = text
        model.exactOut = true
        deriveLimit()
    }

    private func deriveLimit() {
        guard model.exactOut, let want = model.wantOut, !want.isZero, let sell = model.sell, let buy = model.buy else { return }
        let wantValue = Fmt.double(want, decimals: buy.decimals)
        switch model.limitDerives {
        case .price:
            guard let amount = model.amountIn, !amount.isZero else { return }
            model.targetPriceText = Self.priceText(wantValue / Fmt.double(amount, decimals: sell.decimals))
            model.autoTarget = nil
        case .amount:
            guard let price = Double(model.targetPriceText.replacingOccurrences(of: ",", with: ".")), price > 0, price.isFinite,
                  let amount = Self.units(wantValue / price, decimals: sell.decimals) else { return }
            model.amountText = Fmt.plainDecimal(ExactOutSolver.roundUp(amount), decimals: sell.decimals)
        }
    }

    /// O preco mudou (digitado, chip ou o de agora). Se o valor vendido acompanha o
    /// recebido digitado, ele refaz a conta; se era o preco que acompanhava, o recebido
    /// volta a sair do preco.
    private func limitPriceChanged() {
        guard model.exactOut else { return }
        if model.limitDerives == .amount { deriveLimit() } else { model.clearExactOut() }
    }

    /// Um valor decimal em unidades da rede, arredondado para cima.
    static func units(_ value: Double, decimals: Int) -> BigUInt? {
        guard value.isFinite, value > 0 else { return nil }
        let text = String(format: "%.\(min(decimals, 18))f", value)
        guard let parsed = Fmt.parseAmount(text, decimals: decimals) else { return nil }
        return parsed + BigUInt(1)
    }

    // MARK: Rodape

    private var over: Bool {
        guard let amount = model.amountIn, let sell = model.sell else { return false }
        return amount > free(sell)
    }

    /// O que da para usar do ativo: o saldo menos a reserva da rede (XRP Ledger,
    /// Stellar) e, na ordem limite, menos o que ainda falta vender nas ordens abertas
    /// dele, que a autorizacao ja cobre.
    private func free(_ asset: Asset?) -> BigUInt {
        guard let asset, let held = holding(asset) else { return 0 }
        let available = portfolio.available(held)
        guard router.tradeMode == .limit else { return available }
        var locked = OpenOrdersBook.shared.lockedSell(asset)
        // Editando: o que falta vender na ordem editada volta a ser livre, ela sai antes.
        if let edit = model.editing, edit.sell.id == asset.id { locked = locked.subtractingReportingUnderflow(edit.order.remainingSell) ?? BigUInt() }
        return available.subtractingReportingUnderflow(locked) ?? BigUInt()
    }

    private var footer: some View {
        ActionFooter {
            if router.tradeMode == .bridge {
                BridgeFooter(model: bridgeModel) { bridgeReviewing = $0 }
            } else if !tradeChains.isEmpty {
            if router.tradeMode == .now, model.quote != nil {
                Text("Nova cotação em \(model.nextRefresh) s").typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
            if !hasBalance(model.sell), let sell = model.sell {
                AccentButton(title: String(localized: "Receber \(sell.symbol)"), systemImage: "arrow.down") { receivingAsset = sell }
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
        guard engine != nil else { return String(localized: "Troca indisponível nesta rede") }
        guard let amount = model.amountIn, !amount.isZero else { return String(localized: "Digite um valor") }
        if over { return String(localized: "Saldo de \(model.sell?.symbol ?? "") insuficiente") }
        if router.tradeMode == .limit {
            if case .farBelow = limitSanity { return String(localized: "Preço muito abaixo do mercado") }
            return String(localized: "Revisar ordem")
        }
        if model.quoting && model.quote == nil { return String(localized: "Buscando o melhor preço") }
        if model.inParts, model.quote?.parts != nil { return String(localized: "Revisar troca em partes") }
        if PriceImpact.level(model.quote?.priceImpactPercent) == .blocked { return String(localized: "Impacto no preço alto demais") }
        return model.quote?.needsApproval == true ? String(localized: "Autorizar \(model.sell?.symbol ?? "") e trocar") : String(localized: "Revisar troca")
    }

    private var primaryEnabled: Bool {
        guard engine != nil, let amount = model.amountIn, !amount.isZero, !over else { return false }
        if router.tradeMode == .limit { return engine?.supportsLimitOrders == true && limitMinimumOut != nil && limitPriceConfirmed }
        // Em partes, cada parte sai por um preco melhor que o da ordem inteira.
        if model.inParts, model.quote?.parts != nil { return true }
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
        let amount = free(asset)
        if router.tradeMode == .limit, asset.id == model.sell?.id, !OpenOrdersBook.shared.lockedSell(asset).isZero {
            return String(localized: "Livre \(Fmt.crypto(amount, decimals: asset.decimals, symbol: asset.symbol, style: .list)), o resto em ordens")
        }
        if let held = holding(asset), held.amount > portfolio.available(held) {
            return String(localized: "Disponível \(Fmt.crypto(amount, decimals: asset.decimals, symbol: asset.symbol, style: .list))")
        }
        return String(localized: "Saldo \(Fmt.crypto(amount, decimals: asset.decimals, symbol: asset.symbol, style: .list))")
    }

    private func hasBalance(_ asset: Asset?) -> Bool {
        !(holding(asset)?.amount.isZero ?? true)
    }

    private func fiat(_ amount: BigUInt?, _ asset: Asset?) -> String? {
        guard let asset, let price = asset.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }) else { return nil }
        return String(localized: "≈ \(Fmt.fiat(Fmt.double(amount ?? 0, decimals: asset.decimals) * price, session.currency))")
    }

    private func setFraction(_ fraction: Double) {
        guard let sell = model.sell else { return }
        let total = free(sell)
        let part = fraction >= 1 ? total : total * BigUInt(UInt64(fraction * 100)) / BigUInt(100)
        model.typePay(Fmt.plainDecimal(part, decimals: sell.decimals))
    }

    private func flip() {
        withAnimation(Motion.flip) { flipTurns += 1 }
        withAnimation(Motion.flip) {
            let sell = model.sell
            model.sell = model.buy
            model.buy = sell
            model.amountText = ""
            model.quote = nil
            model.clearExactOut()
        }
    }

    private func refreshQuote() async {
        guard router.tradeMode == .now, let engine, let wallet = session.selectedWallet, !wallet.isWatchOnly,
              let sell = model.sell, let buy = model.buy, let account = wallet.account(model.chain) else {
            model.quote = nil
            model.quoting = false
            return
        }
        if model.exactOut {
            let chain = model.chain
            let tolerance = slippage()
            await solveLoop(sell: sell, buy: buy) { amount in
                try await engine.quote(TradeRequest(walletID: wallet.id, chain: chain, account: account, sell: sell, buy: buy,
                                                    amountIn: amount, slippageBasisPoints: tolerance))
            }
            return
        }
        guard let amount = model.amountIn, !amount.isZero else {
            model.quote = nil
            model.quoting = false
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
                                           amountIn: amount, slippageBasisPoints: slippage())
                let fresh = try await engine.quote(request)
                if fresh.parts == nil { model.inParts = false }
                model.quote = fresh
            } catch {
                model.quote = nil
                model.error = (error as? LocalizedError)?.errorDescription
                    ?? (model.chain.id == "xrpl"
                        ? String(localized: "Nenhum provedor troca \(sell.symbol) por \(buy.symbol) no \(model.chain.name) agora. Tente um valor menor ou outro par.")
                        : String(localized: "Nenhum provedor troca \(sell.symbol) por \(buy.symbol) na \(model.chain.name) agora. Tente um valor menor ou outro par."))
            }
            model.quoting = false
            for second in stride(from: 15, through: 1, by: -1) {
                model.nextRefresh = second
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
    }

    /// "Voce recebe" digitado: acha quanto pagar e, a cada 15 s, recota mantendo o
    /// recebido. Na revisao o motor recota esse valor e monta o plano como sempre.
    private func solveLoop(sell: Asset, buy: Asset, quote: (BigUInt) async throws -> TradeQuote) async {
        guard let want = model.wantOut, !want.isZero else {
            model.quote = nil
            model.quoting = false
            model.solving = false
            model.shortOfTarget = false
            model.amountText = ""
            return
        }
        model.acceptedImpactPercent = nil
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        // O valor a pagar some ate a primeira resposta; nas recotacoes, fica o anterior.
        model.solving = true
        while !Task.isCancelled {
            model.quoting = true
            model.error = nil
            do {
                let solution = try await ExactOutSolver.solve(
                    want: want, start: sellEstimate(want: want, sell: sell, buy: buy),
                    unit: Self.powerOfTen(sell.decimals), inParts: model.inParts, quote: quote
                )
                guard !Task.isCancelled else { return }
                model.amountText = Fmt.plainDecimal(solution.amountIn, decimals: sell.decimals)
                if solution.quote.parts == nil { model.inParts = false }
                model.quote = solution.quote
                model.shortOfTarget = !solution.reached
            } catch {
                guard !Task.isCancelled else { return }
                model.quote = nil
                model.amountText = ""
                model.error = (error as? LocalizedError)?.errorDescription
                    ?? (model.chain.id == "xrpl"
                        ? String(localized: "Nenhum provedor troca \(sell.symbol) por \(buy.symbol) no \(model.chain.name) agora. Tente um valor menor ou outro par.")
                        : String(localized: "Nenhum provedor troca \(sell.symbol) por \(buy.symbol) na \(model.chain.name) agora. Tente um valor menor ou outro par."))
            }
            model.quoting = false
            model.solving = false
            for second in stride(from: 15, through: 1, by: -1) {
                model.nextRefresh = second
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
    }

    /// A partida da busca: a cotacao de agora do mesmo par, ou o preco de mercado com a
    /// tolerancia. Sem nenhum dos dois, o `ExactOutSolver` sonda com uma unidade.
    private func sellEstimate(want: BigUInt, sell: Asset, buy: Asset) -> BigUInt? {
        if let quote = model.quote, quote.sell.id == sell.id, quote.buy.id == buy.id {
            let got = quote.minimumOut(inParts: model.inParts && quote.parts != nil)
            if !got.isZero { return ExactOutSolver.ceilDiv(quote.amountIn * want, got) }
        }
        guard let rate = marketRate else { return nil }
        let margin = 1 + Double(slippage()) / 10_000
        return Self.units(Fmt.double(want, decimals: buy.decimals) / rate * margin, decimals: sell.decimals)
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
    /// O valor veio do app (cotacao ou conta), nao do dono: aparece com a animacao dos
    /// numeros ate o dono tocar para digitar.
    var computed: Bool = false
    var placeholder: String = "0"
    /// So uma caixa por tela poe o "Pronto" no teclado: o botao fecha qualquer campo, e
    /// dois apareceriam lado a lado.
    var keyboardDone: Bool = true
    var onFocusChange: ((Bool) -> Void)? = nil
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
                    // O campo fica sempre ali (o toque cai nele); por cima, enquanto o dono
                    // nao digita, o valor calculado com animacao ou o brilho de carregando.
                    let shimmer = loading && !focused
                    let shown = computed && !focused && !shimmer
                    ZStack(alignment: .leading) {
                        TextField(placeholder, text: $amount)
                            .font(.system(size: 32, weight: .bold).monospacedDigit())
                            .foregroundStyle(over ? Palette.down : Palette.ink)
                            .keyboardType(.decimalPad)
                            .focused($focused)
                            .minimumScaleFactor(0.5)
                            .opacity(shimmer || shown ? 0 : 1)
                            .modifier(KeyboardDone(enabled: keyboardDone) { focused = false })
                        if shimmer {
                            ShimmerBar(width: 150, height: 30).allowsHitTesting(false)
                        } else if shown {
                            Text(amount.isEmpty ? "0" : amount)
                                .font(.system(size: 32, weight: .bold).monospacedDigit())
                                .foregroundStyle(amount.isEmpty ? Palette.inkDead : (over ? Palette.down : Palette.ink))
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .contentTransition(.numericText())
                                .animation(Motion.number, value: amount)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: focused) { _, value in onFocusChange?(value) }
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
                            CoinLogo(coingeckoID: asset.coingeckoID, symbol: asset.symbol, size: 24, network: asset.chain, ringColor: Palette.rail,
                                     unverified: asset.origin != nil, logoAsset: asset.origin != nil ? asset : nil)
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
                .accessibilityIdentifier("escolher-token-" + title)
            }
            HStack {
                Text(fiat ?? " ").typeStyle(.note).foregroundStyle(amount.isEmpty ? Palette.inkMuted : Palette.inkSoft)
                Spacer()
                if let onFraction {
                    ForEach([(0.25, "25%"), (0.5, "50%"), (1.0, String(localized: "Máx"))], id: \.0) { fraction, label in
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

/// O "Pronto" no teclado numerico, que nao tem tecla de fechar: sem ele, a cotacao e os
/// detalhes ficam escondidos embaixo do teclado. Fecha qualquer campo da tela (o do
/// preco-alvo da ordem limite tambem), nao so o da caixa.
private struct KeyboardDone: ViewModifier {
    let enabled: Bool
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Pronto") {
                        dismiss()
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold)
                }
            }
        } else {
            content
        }
    }
}

/// T2: escolher token dentro da rede. A lista conferida e, nas redes EVM e na Solana, os
/// tokens fora dela que a carteira tem (sem suspeita) e as moedas que o dono adicionou,
/// mais o caminho para adicionar uma pelo contrato.
struct TokenPickerSheet: View {
    @Environment(Portfolio.self) private var portfolio
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let chain: Chain
    let exclude: Asset?
    /// "Voce vende": so o que a carteira tem nesta rede (pedido do dono, 17/10/2026).
    var selling = false
    let onPick: (Asset) -> Void
    @State private var query = ""
    @State private var adding = false

    /// Fora da lista: as moedas adicionadas e os tokens que a carteira tem, sem suspeita.
    private var unlisted: [Asset] {
        guard TradeAccess.supportsUnlisted(chain) else { return [] }
        let custom = session.metadata.customTokens.filter { $0.chainID == chain.id }
        let held = (portfolio.balance(chain)?.unlisted ?? []).filter { !$0.isSuspicious }.map(\.asset)
        var seen = Set<String>()
        return (custom + held).filter { seen.insert($0.id).inserted }
    }

    private func amount(_ asset: Asset) -> BigUInt? {
        if let held = portfolio.balance(chain)?.holdings.first(where: { $0.asset.id == asset.id })?.amount { return held }
        return portfolio.balance(chain)?.unlisted?.first { $0.asset.id == asset.id }?.amount
    }

    private func matches(_ asset: Asset) -> Bool {
        query.isEmpty || asset.symbol.localizedCaseInsensitiveContains(query) || asset.name.localizedCaseInsensitiveContains(query)
    }

    /// Do maior saldo para o menor, nas duas secoes (pedido do dono, 17/10/2026): pelo valor
    /// na moeda local quando ha preco, senao pela quantidade; sem saldo, depois, na ordem da
    /// lista. Vendendo, so o que tem saldo.
    private func ordered(_ assets: [Asset]) -> [Asset] {
        let keyed = assets.enumerated().map { index, asset -> (asset: Asset, index: Int, value: Double, amount: Double) in
            let held = amount(asset).map { Fmt.double($0, decimals: asset.decimals) } ?? 0
            let price = asset.origin == nil ? (portfolio.price(of: asset) ?? 0) : 0
            return (asset, index, held * price, held)
        }
        let shown = selling ? keyed.filter { $0.amount > 0 } : keyed
        return shown.sorted { a, b in
            if (a.amount > 0) != (b.amount > 0) { return a.amount > 0 }
            if a.value != b.value { return a.value > b.value }
            if a.amount > 0, a.amount != b.amount { return a.amount > b.amount }
            return a.index < b.index
        }.map(\.asset)
    }

    var body: some View {
        let verified = ordered(TokenRegistry.assets(on: chain).filter { $0.id != exclude?.id && matches($0) })
        let others = ordered(unlisted.filter { $0.id != exclude?.id && matches($0) })
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Escolher token")) { dismiss() }
            TextField("", text: $query, prompt: Text("Buscar por nome").foregroundColor(Palette.inkDead))
                .typeStyle(.body).foregroundStyle(Palette.ink)
                .padding(.horizontal, Space.md).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
                .padding(.horizontal, Space.gutter).padding(.top, Space.md)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !others.isEmpty {
                        section(String(localized: "Fora da lista verificada"))
                        ForEach(others) { row($0) }
                        if !verified.isEmpty { section(String(localized: "Verificadas")) }
                    }
                    ForEach(verified) { row($0) }
                    if selling, verified.isEmpty, others.isEmpty {
                        Text(query.isEmpty ? String(localized: "Nada para vender na \(chain.name) ainda. Receba ou troque em outra rede primeiro.")
                                           : String(localized: "Nada com este nome entre o que você tem na \(chain.name)."))
                            .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                    }
                    if TradeAccess.supportsUnlisted(chain) {
                        Button { adding = true } label: {
                            HStack(spacing: Space.sm) {
                                Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                                    .frame(width: 36, height: 36).background(Circle().fill(Palette.control))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Adicionar moeda pelo contrato").typeStyle(.row).foregroundStyle(Palette.ink)
                                    Text("Qualquer token que os provedores trocam na \(chain.name)").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
                        }
                        .buttonStyle(RowStyle(surface: .body))
                        .accessibilityIdentifier("troca-adicionar-moeda")
                    }
                }
                .padding(.top, Space.xs)
                .padding(.bottom, Space.lg)
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
        .sheet(isPresented: $adding) {
            NavigationStack {
                AddCustomTokenView(preset: AddCustomTokenView.Preset(chain: chain, kind: .native)) { adding = false }
            }
            .presentationBackground(Palette.void)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, Space.gutter).padding(.top, Space.md).padding(.bottom, Space.xxs)
    }

    private func row(_ asset: Asset) -> some View {
        let unverified = asset.origin != nil
        return Button { onPick(asset) } label: {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: asset.coingeckoID, symbol: asset.symbol, size: 36, network: asset.chain, ringColor: Palette.body,
                         unverified: unverified, logoAsset: unverified ? asset : nil)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: asset.symbol).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                        if unverified { TokenBadge(asset.isCustom ? .custom : .unverified) }
                    }
                    Text(verbatim: asset.name).typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                Spacer()
                if let amount = amount(asset), !amount.isZero {
                    Text(Fmt.crypto(amount, decimals: asset.decimals)).typeStyle(.note).foregroundStyle(Palette.ink)
                }
            }
            .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
        }
        .buttonStyle(RowStyle(surface: .body))
    }
}

/// T4: tolerancia de preco.
/// T3: a rota, com a divisao entre provedores como ganho medido.
struct RouteSheet: View {
    let quote: TradeQuote
    @Environment(\.dismiss) private var dismiss

    private var explanation: String {
        if quote.execution == .order {
            return String(localized: "Uma ordem assinada no leilão da CoW: os solvers disputam com a liquidez das corretoras descentralizadas e dos formadores de mercado. Se não couber de uma vez, ela é preenchida em partes, cada uma pelo mínimo garantido ou mais. O que não sair em 30 minutos continua na sua carteira, sem custo.")
        }
        return quote.legs.count > 1
            ? String(localized: "São \(quote.legs.count) transações, uma por provedor, confirmadas com um único \(KeyServices.biometryName). Cada parte é independente: se uma não passar, você fica com o que foi trocado, e o saldo daquela parte continua na sua carteira.")
            : String(localized: "Tudo acontece numa transação só. Ou executa inteira, ou nada sai da sua carteira.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: quote.legs.count > 1 ? String(localized: "Como a sua ordem foi dividida") : String(localized: "Rota da troca")) { dismiss() }
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(quote.legs.enumerated()), id: \.offset) { _, leg in
                    HStack {
                        Text(leg.provider).typeStyle(.row).foregroundStyle(Palette.ink)
                        Spacer()
                        Text("\(Int((leg.fraction * 100).rounded()))%").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        Text(Fmt.crypto(leg.expectedOut, decimals: quote.buy.decimals, symbol: quote.buy.symbol)).typeStyle(.note).foregroundStyle(Palette.ink)
                    }
                }
                Text(explanation)
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
