import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import EscaliburNetwork
import SwiftUI

/// O estado de um envio em andamento.
@MainActor
@Observable
final class SendModel {
    /// `unsure`: assinado e transmitido sem resposta certa da rede (auditoria 2, M3).
    enum Stage: Hashable { case destination, tag, amount, review, sending, done, unsure }

    let wallet: WalletMeta
    var holding: Holding?
    var stage: Stage = .destination
    var destinationText = ""
    var destination: Address.Destination?
    var destinationProblem: String?
    /// Link de pagamento recusado e o texto que ele deixou no campo.
    var linkProblem: (text: String, message: String)?
    var destinationInfo: DestinationInfo?
    var lookalike: String?
    /// Com endereco parecido, os 6 caracteres do meio onde os dois diferem, digitados
    /// pelo dono (auditoria 2, M2: as pontas o atacante copia).
    var lookalikeCheck = ""
    var lookalikeSegment: AddressPoisoning.Segment?
    /// Endereco M da Stellar da mesma conta de um ja usado, com outro ID: o conhecido, e o
    /// que o dono digita (o numero do ID, ou os 6 ultimos lidos na fonte). Um programa que
    /// troca o endereco copiado pode trocar so o ID pelo de uma conta do atacante na mesma
    /// corretora (revisao dos enderecos parecidos, B-6).
    var otherID: AddressPoisoning.SameAccount?
    var otherIDCheck = ""
    /// Para quem esta carteira ja pagou, lido do historico da rede: o endereco
    /// envenenado chega como recebido, entao so os enviados contam.
    var historyRecipients: [String] = []
    /// O historico da rede nao pode ser lido (indexador fora ou recusando o app): sem ele,
    /// o envenenamento de endereco nao tem com o que comparar (auditoria 3, B1).
    var historyUnavailable = false
    /// A leitura do historico terminou, lida ou falha. Antes disso o parecido ainda nao tem
    /// com o que comparar, e o Continuar fica desligado: apertado cedo, ele pulava a
    /// conferencia contra o historico (revisao dos enderecos parecidos).
    var historyLoaded = false
    /// Primeiro envio sem historico para comparar: os 6 do meio que o dono digita.
    var blindSegment: AddressPoisoning.Segment?
    /// O endereco como foi colado: o desafio do meio e conferido nele, com o trecho
    /// escondido na tela, para o dono ler na fonte (revisao da auditoria 4, M-1).
    var blindSource = ""
    var blindCheck = ""
    var isFirstSend = false
    var tagText = ""
    /// A tag ou o memo que o QR ou o link trazia: ja no campo, e dito na tela para o dono
    /// conferir (auditoria 4, B5).
    var linkTag: String?
    var skippedTag = false
    /// O dono abriu o campo opcional de tag, memo ou comentario (auditoria 2, M5).
    var showOptionalTag = false
    /// Endereco de outra rede onde a carteira tem a mesma moeda: um toque troca a rede.
    var networkSuggestion: Holding?
    /// Primeiro envio EVM para este endereco: o dono confirmou que quem recebe aceita a
    /// rede escolhida. O endereco EVM e o mesmo em todas as redes EVM e nao diz qual.
    var networkConfirmed = false

    var needsNetworkConfirmation: Bool {
        guard let chain, let destination, isFirstSend else { return false }
        switch chain.family {
        // Sui e Aptos: "0x" e 64 hex nas duas, e o texto nao diz de qual e.
        case .evm, .sui, .aptos: return true
        // NEAR: a conta implicita e 64 hex, o formato de Sui e Aptos sem o "0x". Colado
        // por engano, vira uma conta NEAR nova que ninguem controla.
        case .near: return Self.isBareHex64(destination.address)
        default: return false
        }
    }

    static func isBareHex64(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }
    var amountText = ""
    var sendAll = false
    var spendable: Spendable?
    var feeLevel: FeeLevel = .normal
    var plan: SigningPlan?
    var working = false
    var error: String?
    var resultID: String?
    var status: TransferStatus = .pending
    /// A transacao assinada cuja transmissao nao teve resposta certa. So ela pode ser
    /// transmitida de novo (os mesmos bytes, o mesmo id): remontar pagaria duas vezes.
    var unsureSigned: [SignedTransaction]?
    var unsureDetail: String?
    /// O dono marcou que sabe que o envio nao se desfaz (pedido do dono, 14/10/2026).
    /// Volta a desmarcar a cada plano novo.
    var irreversibleAcknowledged = false
    /// As ordens limite abertas desta conta que vendem o ativo: o que elas ainda vao
    /// vender nao sai num envio sem cancelar antes (pedido do dono, 14/10/2026).
    var sellingOrders: [OpenOrder] = []
    var showingLockedOrders = false

    /// O que as ordens abertas ainda vao vender deste ativo.
    var locked: BigUInt { sellingOrders.reduce(BigUInt()) { $0 + $1.remainingSell } }

    init(wallet: WalletMeta, holding: Holding?) {
        self.wallet = wallet
        self.holding = holding
    }

    var chain: Chain? { holding?.asset.chain }
    var account: DerivedAccount? { chain.flatMap { wallet.account($0) } }

    /// O disponivel que a tela mostra antes de o motor responder quanto da para gastar.
    var availableFallback: BigUInt?

    var amount: BigUInt? {
        guard let holding else { return nil }
        // Enviar tudo antes da conta do motor (ou se ela falhou): o disponivel da tela, e o
        // motor desconta a taxa ao montar. Antes, a tela mostrava 0 (pedido do dono,
        // 16/10/2026).
        if sendAll { return spendable?.amount ?? availableFallback }
        return Fmt.parseAmount(amountText, decimals: holding.asset.decimals)
    }

    /// Sem endereco parecido, nada a conferir. Com ele, so segue quem digitou o trecho
    /// do meio onde o destino difere do conhecido, lendo-o em vez de reconhecer as
    /// pontas. Com a mesma conta e outro ID, quem digitou o ID que quem recebe mostra.
    var lookalikeCleared: Bool {
        if let segment = blindSegment {
            let typed = blindCheck.trimmingCharacters(in: .whitespaces).lowercased()
            guard typed.count == segment.length, typed == segment.text(in: blindSource).lowercased() else { return false }
        }
        if otherID != nil {
            guard let address = destination?.address, AddressPoisoning.muxedIDConfirmed(otherIDCheck, address: address) else { return false }
        }
        guard lookalike != nil, let address = destination?.address else { return true }
        guard let segment = lookalikeSegment else { return false }
        let typed = lookalikeCheck.trimmingCharacters(in: .whitespaces).lowercased()
        return typed.count == segment.length && typed == segment.text(in: address).lowercased()
    }

    /// Um desafio do destino esta na tela (parecido, ID trocado, ou o trecho escondido sem
    /// historico): o campo do endereco colado some e fica so leitura, porque a resposta se
    /// leria nele, o M inteiro em ate tres linhas (segunda revisao dos enderecos parecidos).
    /// "Editar" desfaz o desafio e devolve o campo.
    var challengeOnScreen: Bool {
        destination != nil && (lookalike != nil || otherID != nil || blindSegment != nil)
    }

    /// O dono quer mudar o endereco com um desafio na tela: o campo volta vazio, e o desafio
    /// sai junto com o endereco. A tag de antes tambem sai: ela era do destino de antes
    /// (revisao da auditoria 4, B-1).
    func editDestination() {
        destinationText = ""
        destination = nil
        linkProblem = nil
        lookalike = nil
        lookalikeSegment = nil
        lookalikeCheck = ""
        otherID = nil
        otherIDCheck = ""
        blindSegment = nil
        blindCheck = ""
        tagText = ""
        linkTag = nil
    }

    /// Endereco M da Stellar: o id do cliente ja vai nele, e um memo junto seria um
    /// segundo id disputando o credito (o planejador recusa memo ID com M).
    var isMuxedStellar: Bool {
        guard chain?.family == .stellar, let address = destination?.address else { return false }
        return StellarMuxedAccount(address: address)?.isMuxed == true
    }

    var needsTagStep: Bool {
        guard let chain, chain.destinationTag != .none, !isMuxedStellar else { return false }
        return destinationInfo?.requiresTag == true || KnownExchanges.name(for: destination?.address ?? "") != nil
    }
}

/// E1 a E8: enviar, em tela cheia, sem fechar por gesto no meio de uma assinatura.
struct SendFlow: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @Environment(\.dismiss) private var dismiss
    let initialAsset: Asset?
    @State private var model: SendModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    if model.holding == nil {
                        SendAssetPicker { holding in model.holding = holding }
                    } else {
                        SendStages(model: model, close: { dismiss() })
                    }
                }
            }
            .background(Palette.void.ignoresSafeArea())
            .toolbar {
                // Transmitindo, nao fecha: a tela so some com a resposta da rede.
                if model?.stage != .sending {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                        }
                        .accessibilityLabel("Fechar")
                    }
                }
            }
        }
        .interactiveDismissDisabled(model?.stage == .sending)
        .onAppear {
            guard model == nil, let wallet = session.selectedWallet else { return }
            var holding = initialAsset.flatMap { asset in
                asset.chain.flatMap { portfolio.balance($0) }?.holdings.first { $0.asset.id == asset.id }
            }
            #if DEBUG
            // A carteira de teste nao tem saldo em rede EVM, onde um endereco parecido
            // sem checksum se escreve a mao: o teste de envenenamento entra com zero.
            if holding == nil, ["enviar-eth", "envio-incerto"].contains(DebugDemo.screen) { holding = Holding(asset: .native(.ethereum), amount: 0) }
            #endif
            model = SendModel(wallet: wallet, holding: holding)
            #if DEBUG
            // `-tela envio-valor`, `envio-revisao`, `envio-enviando`, `enviado` e `envio-preso`:
            // um envio da carteira de teste ja com destino, para conferir cada etapa. A revisao
            // usa o USDT da Tron: a conta XRP dela teve a chave mestra desligada por quem
            // conhece a frase.
            let stages = ["envio-valor", "envio-revisao", "envio-enviando", "enviado", "envio-preso"]
            if stages.contains(DebugDemo.screen ?? "") {
                let usdt = TokenRegistry.tokens.first { $0.chainID == "tron" && $0.symbol == "USDT" }
                let review = DebugDemo.screen == "envio-revisao"
                let held = review && usdt != nil ? Holding(asset: usdt!, amount: BigUInt(8_250_350_000)) : Holding(asset: .native(.xrpl), amount: BigUInt(2_267_600_000))
                let chain: Chain = review ? .tron : .xrpl
                let demo = SendModel(wallet: wallet, holding: held)
                demo.destinationText = review ? "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7" : "rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe"
                if case .success(let destination) = Address.validate(demo.destinationText, for: chain) { demo.destination = destination }
                demo.amountText = DebugDemo.screen == "envio-valor" ? "123456789012,123456" : (DebugDemo.screen == "envio-preso" ? "500" : "150")
                demo.stage = DebugDemo.screen == "envio-enviando" ? .sending : (DebugDemo.screen == "enviado" ? .done : .amount)
                if DebugDemo.screen == "envio-preso", let rlusd = TokenRegistry.tokens.first(where: { $0.chainID == "xrpl" && $0.symbol == "RLUSD" }) {
                    demo.sellingOrders = [OpenOrder(id: "demo", chain: .xrpl, sellAssetID: Asset.native(.xrpl).id, buyAssetID: rlusd.id,
                                                    remainingSell: BigUInt(2_000_000_000), minimumBuy: BigUInt(3_000_000_000),
                                                    expiresAt: Date().addingTimeInterval(6 * 86_400), sources: 1, cancellations: [.onchain])]
                    demo.showingLockedOrders = true
                }
                model = demo
            }
            // A tela de transmissao sem resposta certa, para conferir o desenho.
            if DebugDemo.screen == "envio-incerto" {
                model?.resultID = "0x" + String(repeating: "ab", count: 32)
                model?.unsureDetail = "Não foi possível falar com a rede Ethereum agora."
                model?.stage = .unsure
            }
            #endif
        }
    }
}

/// E1: uma linha por ativo **por rede**, porque todo envio acontece numa rede.
struct SendAssetPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    let onPick: (Holding) -> Void
    @State private var query = ""
    @State private var receiving = false
    /// Moeda custom numa rede que ainda nao envia custom: o motivo, num alerta.
    @State private var blocked: (symbol: String, reason: String)?

    var body: some View {
        let holdings = Chain.all.compactMap { portfolio.balance($0) }.flatMap(\.holdings).filter { !$0.amount.isZero }
        let filtered = query.isEmpty ? holdings : holdings.filter { $0.asset.symbol.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 0) {
            if holdings.isEmpty && portfolio.loading {
                Text("Escolha o que enviar").typeStyle(.title).foregroundStyle(Palette.ink).padding(.horizontal, Space.gutter)
                HStack(spacing: Space.sm) {
                    ProgressView().tint(Palette.inkSoft)
                    Text("Lendo os saldos desta carteira.").typeStyle(.body).foregroundStyle(Palette.inkSoft)
                }
                .padding(Space.gutter)
                Spacer()
            } else if holdings.isEmpty {
                empty
            } else {
                Text("Escolha o que enviar").typeStyle(.title).foregroundStyle(Palette.ink).padding(.horizontal, Space.gutter)
                TextField("", text: $query, prompt: Text("Buscar").foregroundColor(Palette.inkDead))
                    .typeStyle(.body).foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.md).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                    .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered, id: \.asset.id) { holding in
                            let unavailable = holding.asset.isCustom ? holding.asset.chain.flatMap(CustomToken.sendUnavailableReason) : nil
                            Button {
                                if let unavailable { blocked = (holding.asset.symbol, unavailable) } else { onPick(holding) }
                            } label: {
                                HStack(spacing: Space.sm) {
                                    CoinLogo(coingeckoID: holding.asset.coingeckoID, symbol: holding.asset.symbol, size: 40, network: holding.asset.chain,
                                             unverified: !holding.asset.isVerified, logoAsset: holding.asset.isVerified ? nil : holding.asset)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(verbatim: holding.asset.symbol).typeStyle(.row).foregroundStyle(Palette.ink)
                                            if holding.asset.isCustom { TokenBadge(.custom) }
                                        }
                                        Text(unavailable == nil
                                             ? "na \(holding.asset.chain?.name ?? "") · \(Fmt.crypto(portfolio.available(holding), decimals: holding.asset.decimals))"
                                             : "na \(holding.asset.chain?.name ?? "") · envio indisponível")
                                            .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                    }
                                    Spacer()
                                    if let price = portfolio.price(of: holding.asset) {
                                        Text(Fmt.fiat(Fmt.double(holding.amount, decimals: holding.asset.decimals) * price, session.currency))
                                            .typeStyle(.row).foregroundStyle(Palette.ink)
                                    }
                                }
                                .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
                            }
                            .buttonStyle(RowStyle())
                        }
                    }
                    .padding(.top, Space.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, Space.md)
        .task(id: session.selectedWallet?.id) { await portfolio.ensureLoaded(session.selectedWallet, session: session) }
        .alert("Envio de \(blocked?.symbol ?? "") indisponível", isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
            Button("Entendi", role: .cancel) { blocked = nil }
        } message: {
            Text(blocked?.reason ?? "")
        }
    }

    /// Carteira sem saldo: a ilustracao de nada para enviar e o caminho para receber.
    private var empty: some View {
        VStack(spacing: 0) {
            EmptySendArt(height: 280).padding(.top, Space.sm)
            VStack(spacing: Space.sm) {
                Text("Ainda não há ativos para enviar").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Quando chegar saldo nesta carteira, ele aparece aqui para você escolher o que enviar.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.top, Space.md)
            Spacer(minLength: Space.md)
            PrimaryButton(title: String(localized: "Receber")) { receiving = true }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.xs)
        .sheet(isPresented: $receiving) { ReceiveSheet(preselected: nil) }
    }
}

/// As etapas depois de escolhido o ativo.
struct SendStages: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(Portfolio.self) private var portfolio
    @Bindable var model: SendModel
    let close: () -> Void
    @State private var scanning = false
    @State private var pickingWallet = false
    /// O slider da tela de valor, de 0 a 1 do disponivel.
    @State private var sliderFraction: Double = 0
    /// O teclado do valor: tocar fora fecha, e o OK em cima dele tambem.
    @FocusState private var amountFocused: Bool

    private var engine: (any SendEngine)? { model.chain.flatMap { SendEngines.engine(for: $0) } }

    var body: some View {
        Group {
            switch model.stage {
            case .destination: destinationStage.task(id: model.chain?.id) { await loadHistoryRecipients() }
            case .tag: tagStage
            case .amount: amountStage
            case .review: reviewStage
            case .sending, .done: statusStage
            case .unsure: unsureStage
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.md)
        .padding(.bottom, Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Motion.crossfade, value: model.stage)
        .sheet(isPresented: $scanning) {
            QRScannerSheet { text in
                scanning = false
                apply(PaymentURI.read(text))
            }
        }
        .sheet(isPresented: $pickingWallet) { ownWalletsSheet }
    }

    /// As outras carteiras deste app com conta nesta rede: o endereco vem da propria
    /// carteira, nada de colar. A que so observa fica de fora: ela nao e sua chave, e
    /// "observe meu endereco e deposite nele" e golpe (pentest de 14/10/2026). A que ainda
    /// nao tem copia conferida tambem: ela nao recebe por caminho nenhum (auditoria 4, C7-01).
    private var ownWallets: [(wallet: WalletMeta, address: String)] {
        guard let chain = model.chain else { return [] }
        let current = session.selectedWallet?.id
        return session.metadata.wallets.compactMap { wallet in
            guard wallet.id != current, !wallet.isWatchOnly, wallet.hasBackup, let address = wallet.account(chain)?.address, !address.isEmpty,
                  !(chain.family == .tron && wallet.tronForeignControl == true) else { return nil }
            return (wallet, address)
        }
    }

    private var ownWalletsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Minhas carteiras")) { pickingWallet = false }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if ownWallets.isEmpty {
                        Text(model.chain.map { $0.id == "xrpl" ? String(localized: "Nenhuma outra carteira deste app tem conta no \($0.name).") : String(localized: "Nenhuma outra carteira deste app tem conta na \($0.name).") }
                             ?? String(localized: "Nenhuma outra carteira deste app tem conta nesta rede."))
                            .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(ownWallets, id: \.wallet.id) { item in
                        Button {
                            model.destinationText = item.address
                            model.tagText = ""
                            pickingWallet = false
                            validate()
                        } label: {
                            HStack(spacing: Space.sm) {
                                Image(systemName: "wallet.bifold")
                                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                                    .frame(width: 36, height: 36).background(Circle().fill(Palette.rail))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.wallet.name).typeStyle(.row).foregroundStyle(Palette.ink)
                                    Text(verbatim: Fmt.address(item.address, chain: model.chain)).typeStyle(.monoSmall).foregroundStyle(Palette.inkSoft)
                                }
                                Spacer()
                                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                            }
                            .padding(Space.sm)
                            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("minha-carteira-\(item.wallet.name)")
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.void)
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            if let holding = model.holding {
                CoinLogo(coingeckoID: holding.asset.coingeckoID, symbol: holding.asset.symbol, size: 32, network: holding.asset.chain,
                         unverified: !holding.asset.isVerified, logoAsset: holding.asset.isVerified ? nil : holding.asset)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Enviar \(model.holding?.asset.symbol ?? "")").typeStyle(.title).foregroundStyle(Palette.ink)
                    if model.holding?.asset.isCustom == true { TokenBadge(.custom) }
                }
                if let chain = model.chain { Text("pela rede \(chain.name)").typeStyle(.note).foregroundStyle(Palette.inkSoft) }
            }
        }
    }

    // MARK: E2 Para

    private var destinationStage: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Text("Para").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
                if model.challengeOnScreen {
                    HiddenAddressField { model.editDestination() }
                        .padding(.top, Space.xs)
                } else {
                    TextField("", text: $model.destinationText, prompt: Text("Endereço").foregroundColor(Palette.inkDead), axis: .vertical)
                        .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .lineLimit(1...3)
                        .padding(Space.md)
                        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                        .padding(.top, Space.xs)
                    HStack(spacing: Space.xs) {
                        PasteButton(payloadType: String.self) { strings in
                            Task { @MainActor in apply(PaymentURI.read(strings.first ?? "")) }
                        }
                        .labelStyle(.titleOnly).tint(Palette.rail).buttonBorderShape(.capsule)
                        Button { scanning = true } label: {
                            Label("Ler QR", systemImage: "qrcode.viewfinder").typeStyle(.label)
                                .padding(.horizontal, Space.sm).frame(height: 34)
                                .background(Capsule(style: .continuous).fill(Palette.rail))
                        }
                        .foregroundStyle(Palette.ink)
                        if session.metadata.wallets.count > 1 {
                            Button { pickingWallet = true } label: {
                                Label("Minhas carteiras", systemImage: "wallet.bifold").typeStyle(.label)
                                    .padding(.horizontal, Space.sm).frame(height: 34)
                                    .background(Capsule(style: .continuous).fill(Palette.rail))
                            }
                            .foregroundStyle(Palette.ink)
                            .accessibilityIdentifier("minhas-carteiras")
                        }
                    }
                    .padding(.top, Space.xs)
                }

                validationLine.padding(.top, Space.sm)
                optionalTag.id("tag-opcional")

                if let lookalike = model.lookalike, let destination = model.destination, let chain = model.chain {
                    Banner(kind: .caution, title: String(localized: "Endereço parecido com um que você já usou"),
                           message: String(localized: "As pontas são iguais, o meio é diferente. Golpistas mandam centavos de um endereço assim para ele aparecer no seu histórico."))
                        .padding(.top, Space.md)
                    VStack(alignment: .leading, spacing: Space.sm) {
                        comparedAddress(String(localized: "Você colou"), destination.address, model.lookalikeSegment)
                        comparedAddress(KnownAddress.label(lookalike, chain: chain, session: session, history: model.historyRecipients), lookalike,
                                        AddressPoisoning.differingSegment(lookalike, from: destination.address, chain: chain))
                    }
                    .padding(.top, Space.sm)
                    Text("Para seguir, digite os 6 caracteres marcados do endereço que você colou.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("", text: $model.lookalikeCheck, prompt: Text("6 marcados").foregroundColor(Palette.inkDead))
                        .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(Space.sm)
                        .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(Palette.body))
                        .frame(maxWidth: 180, alignment: .leading)
                        .padding(.top, Space.xs)
                        .accessibilityIdentifier("conferir-trecho-endereco")
                }

                if let known = model.otherID, let destination = model.destination, let chain = model.chain {
                    OtherIDCheck(pasted: destination.address, known: known,
                                 knownLabel: KnownAddress.label(known.known, chain: chain, session: session, history: model.historyRecipients),
                                 check: $model.otherIDCheck)
                        .padding(.top, Space.md)
                }

                if model.lookalike == nil, let segment = model.blindSegment, let destination = model.destination {
                    Banner(kind: .neutral, title: String(localized: "Primeiro envio para este endereço"),
                           message: String(localized: "O histórico desta rede não pôde ser lido agora, então o app não consegue comparar com os endereços que você já usou. Confira o endereço com quem vai receber."))
                        .padding(.top, Space.md)
                    MarkedAddress(label: String(localized: "Você colou"), address: model.blindSource, segment: segment, masked: true).padding(.top, Space.sm)
                    Text("Para seguir, digite os 6 caracteres escondidos, lendo no lugar de onde você copiou o endereço.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("", text: $model.blindCheck, prompt: Text("6 escondidos").foregroundColor(Palette.inkDead))
                        .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(Space.sm)
                        .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(Palette.body))
                        .frame(maxWidth: 180, alignment: .leading)
                        .padding(.top, Space.xs)
                        .accessibilityIdentifier("conferir-meio-endereco")
                }

                networkConfirmation
                contacts.padding(.top, Space.lg)
            }
            .padding(.bottom, Space.lg)
            // Na pilha, e nao no campo: o campo some com um desafio na tela, e o "Editar"
            // que o devolve vazio tem de validar de novo.
            .onChange(of: model.destinationText) { _, _ in validate() }
        }
        .scrollDismissesKeyboard(.interactively)
        // Com o teclado aberto, o Continuar cobria a tag opcional logo abaixo do endereco
        // (visto no teste de interface): com o endereco valido, a tela sobe ate ela. Com
        // aviso de endereco parecido, fica onde esta, para o aviso nao sair de vista.
        .onChange(of: model.destination?.address) { _, address in
            guard address != nil, model.chain.map({ $0.destinationTag != .none }) == true, !model.needsTagStep,
                  model.lookalike == nil, model.otherID == nil, model.blindSegment == nil else { return }
            withAnimation(Motion.fade) { proxy.scrollTo("tag-opcional", anchor: .bottom) }
        }
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: String(localized: "Continuar"), enabled: model.destination != nil && model.historyLoaded && model.lookalikeCleared && tagProblem == nil
                          && (!model.needsNetworkConfirmation || model.networkConfirmed),
                          loading: model.working || (model.destination != nil && !model.historyLoaded)) {
                Task { await continueFromDestination() }
            }
            .padding(.top, Space.xs)
            .background(Palette.void)
        }
    }

    @ViewBuilder
    private var validationLine: some View {
        if let problem = model.destinationProblem {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(problem).typeStyle(.note).foregroundStyle(Palette.down).fixedSize(horizontal: false, vertical: true)
                if let suggestion = model.networkSuggestion, let other = suggestion.asset.chain {
                    SecondaryButton(title: String(localized: "Enviar \(suggestion.asset.symbol) pela \(other.name)")) { switchNetwork(to: suggestion) }
                }
            }
        } else if let destination = model.destination, let chain = model.chain {
            VStack(alignment: .leading, spacing: 2) {
                // O endereco como ele vai para a transacao, com o comeco e o fim marcados
                // para conferir contra a origem. Com um desafio na tela, ele some com o campo:
                // o fim do ID e o trecho escondido se leriam aqui.
                if !model.challengeOnScreen {
                    AddressBlocks(address: destination.address).padding(.bottom, Space.xxs)
                }
                Text(KnownExchanges.name(for: destination.address).map { String(localized: "\($0), endereço de depósito") }
                     ?? (chain.id == "xrpl" ? String(localized: "Endereço do \(chain.name)") : String(localized: "Endereço da \(chain.name)")))
                    .typeStyle(.note).foregroundStyle(Palette.up)
                if let tag = destination.tag {
                    Text("A tag de destino \(String(tag)) veio junto no endereço.").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                if model.isFirstSend {
                    Text("Primeira vez que você envia para este endereço.").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
            }
        }
    }

    @ViewBuilder
    private var contacts: some View {
        let saved = session.metadata.contacts.filter { $0.chainID == model.chain?.id }
        if !saved.isEmpty {
            Text("Endereços salvos").typeStyle(.note).foregroundStyle(Palette.inkSoft)
            ForEach(saved) { contact in
                Button {
                    model.destinationText = contact.address
                    model.tagText = contact.tag ?? ""
                    validate()
                } label: {
                    HStack {
                        Text(verbatim: contact.name).typeStyle(.row).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(verbatim: Fmt.address(contact.address, chain: model.chain)).typeStyle(.monoSmall).foregroundStyle(Palette.inkSoft)
                    }
                    .frame(minHeight: Height.rowCompact)
                }
            }
        }
    }

    /// A mesma moeda na rede do endereco colado, se a carteira tem saldo dela la. Na EVM
    /// o endereco nao diz a rede: com o token em varias, a Ethereum primeiro, e a etapa
    /// seguinte pede a confirmacao da rede.
    private func networkSuggestion(for other: Chain) -> Holding? {
        // Moeda custom nunca troca de rede pelo simbolo: outro contrato com o mesmo nome
        // e outro token.
        guard let current = model.holding?.asset, current.isVerified else { return nil }
        let holdings = Chain.all.compactMap { portfolio.balance($0) }.flatMap(\.holdings).filter { !$0.amount.isZero && $0.asset.isVerified }
        let candidates = holdings.filter { holding in
            guard let chain = holding.asset.chain else { return false }
            let sameNetwork = other.family == .evm ? chain.family == .evm : chain.id == other.id
            let sameCoin = current.coingeckoID.map { $0 == holding.asset.coingeckoID } ?? (holding.asset.symbol == current.symbol)
            return sameNetwork && sameCoin
        }
        return candidates.first { $0.asset.chainID == other.id } ?? candidates.first
    }

    private func switchNetwork(to holding: Holding) {
        model.holding = holding
        model.networkSuggestion = nil
        model.amountText = ""
        model.sendAll = false
        validate()
    }

    /// Primeiro envio EVM para este endereco: a rede em destaque, e a confirmacao de que
    /// quem recebe aceita esta rede. Exchange costuma aceitar um token so em algumas.
    @ViewBuilder
    private var networkConfirmation: some View {
        if model.needsNetworkConfirmation, let chain = model.chain, let holding = model.holding {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    NetworkBadge(chain: chain, size: 28, ring: .clear)
                    Text("Envio pela rede \(chain.name)").typeStyle(.row).foregroundStyle(Palette.ink)
                }
                Text(Self.networkConfirmationNote(chain, symbol: holding.asset.symbol))
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $model.networkConfirmed) {
                    Text(chain.family == .near ? String(localized: "Este endereço é de uma conta NEAR") : String(localized: "Quem vai receber aceita \(holding.asset.symbol) pela \(chain.name)"))
                        .typeStyle(.note).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(Palette.accent)
                .accessibilityIdentifier("confirmar-rede")
            }
            .padding(Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
            .padding(.top, Space.md)
        }
    }

    static func networkConfirmationNote(_ chain: Chain, symbol: String) -> String {
        switch chain.family {
        case .sui:
            return String(localized: "Endereços Sui têm o mesmo formato dos endereços Aptos, então o endereço não diz a rede. Se quem vai receber espera o valor pela Aptos ou por outra rede, ele não chega.")
        case .aptos:
            return String(localized: "Endereços Aptos têm o mesmo formato dos endereços Sui, então o endereço não diz a rede. Se quem vai receber espera o valor pela Sui ou por outra rede, ele não chega.")
        case .near:
            return String(localized: "Contas NEAR sem nome têm 64 letras e números, o mesmo formato de um endereço Sui ou Aptos sem o 0x. Se este endereço é de outra rede, o valor vai para uma conta NEAR que ninguém controla e se perde.")
        default:
            return String(localized: "Endereços EVM são iguais em todas as redes EVM, então o endereço não diz a rede. Se quem vai receber só aceita \(symbol) por outra rede (uma exchange que recebe só pela Ethereum, por exemplo), o valor não chega.")
        }
    }

    /// Um endereco inteiro com o trecho que difere marcado.
    private func comparedAddress(_ label: String, _ address: String, _ segment: AddressPoisoning.Segment?) -> some View {
        MarkedAddress(label: label, address: address, segment: segment)
    }

    /// Os contatos desta rede salvos com tag ou memo: um G com o ID no memo e o mesmo par
    /// (conta, ID) de um M da Stellar (revisao do B-6).
    static func taggedContacts(_ chain: Chain, session: AppSession) -> [(address: String, tag: String)] {
        session.metadata.contacts.filter { $0.chainID == chain.id }.compactMap { contact in contact.tag.map { (address: contact.address, tag: $0) } }
    }

    /// Tudo que o dono pode reconhecer de vista nesta rede: para onde ja enviou, os
    /// contatos, os enderecos das carteiras deste iPhone e o historico lido. A que so
    /// observa fica de fora: o endereco dela nao e do dono (auditoria 4, C7-07).
    private func knownAddresses(_ chain: Chain) -> [String] {
        (session.metadata.sentTo[chain.id] ?? []) + session.metadata.contacts.filter { $0.chainID == chain.id }.map(\.address)
            + session.metadata.wallets.filter { !$0.isWatchOnly }.compactMap { $0.account(chain)?.address } + model.historyRecipients
    }

    /// Para quem esta carteira ja pagou nesta rede, do historico da propria rede.
    /// Melhor esforco: sem historico, a lista fica com o que o app guardou.
    private func loadHistoryRecipients() async {
        model.historyLoaded = false
        guard let chain = model.chain, let account = model.wallet.account(chain) else {
            model.historyLoaded = true
            return
        }
        var read: [ActivityEntry]?
        if let source = ActivitySources.source(for: chain) {
            read = try? await source.history(chain: chain, account: account, usage: model.wallet.utxoUsage[chain.id])
        }
        // Leitura cancelada (a rede mudou, ou a tela saiu): a leitura seguinte cuida do
        // estado, e esta nao libera o Continuar.
        guard !Task.isCancelled, model.chain?.id == chain.id else { return }
        defer { model.historyLoaded = true }
        guard let entries = read else {
            model.historyUnavailable = true
            if model.destination != nil { validate() }
            return
        }
        model.historyUnavailable = false
        let paid = entries.compactMap { entry -> String? in
            guard entry.direction == .sent, entry.status == .confirmed, !entry.suspicious else { return nil }
            return entry.counterparty
        }
        model.historyRecipients = Array(Set(paid))
        if model.destination != nil { validate() }
    }

    /// O que veio do QR ou do colar. O problema do link fica preso ao texto que ele
    /// deixou no campo: a validacao que roda a cada mudanca do campo nao o apaga, e
    /// qualquer edicao do dono o solta.
    private func apply(_ reading: PaymentURI.Reading) {
        var problem = reading.problem
        if problem == nil, let chain = model.chain {
            problem = PaymentURI.networkProblem(reading, chain: chain)
        }
        // Link de outra rede: o endereco nem entra no campo, para uma edicao nao soltar o
        // aviso e a tela aceitar o endereco de outra rede (revisao dos baixos, B1).
        let address = problem == nil ? reading.address : ""
        model.linkProblem = problem.map { (text: address, message: $0) }
        model.destinationText = address
        // A tag de antes nunca fica para o destino novo, escondida ou nao (revisao da
        // auditoria 4, B-1): o campo fica com a do codigo, ou vazio.
        model.tagText = ""
        model.linkTag = nil
        validate()
        // A tag ou o memo do link vai para o campo, nunca some (auditoria 4, B5).
        if problem == nil, let tag = reading.tag, !tag.isEmpty, let chain = model.chain, chain.destinationTag != .none,
           model.destination != nil, !model.isMuxedStellar {
            model.tagText = tag
            model.linkTag = tag
            model.showOptionalTag = true
        }
    }

    private func validate() {
        guard let chain = model.chain else { return }
        model.destination = nil
        model.destinationProblem = nil
        model.lookalike = nil
        model.lookalikeSegment = nil
        model.lookalikeCheck = ""
        model.otherID = nil
        model.otherIDCheck = ""
        model.blindSegment = nil
        model.networkSuggestion = nil
        model.networkConfirmed = false
        if let link = model.linkProblem {
            if link.text == model.destinationText {
                model.destinationProblem = link.message
                return
            }
            model.linkProblem = nil
        }
        let text = model.destinationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // A frase digitada ou colada no campo do destino sai dele na hora.
        if PhraseGuard.looksLikePhrase(text) {
            model.destinationText = ""
            model.linkProblem = (text: "", message: PhraseGuard.message)
            model.destinationProblem = PhraseGuard.message
            return
        }
        switch Address.validate(text, for: chain) {
        case .success(let destination):
            if model.wallet.accounts.contains(where: { $0.address == destination.address }) {
                model.destinationProblem = String(localized: "Este endereço é desta mesma carteira.")
                return
            }
            model.destination = destination
            if let tag = destination.tag { model.tagText = String(tag) }
            // Rede sem tag, ou endereco M da Stellar: nenhuma tag vai junto, mesmo uma que
            // tenha vindo de um contato ou de um codigo lido antes.
            if chain.destinationTag == .none || model.isMuxedStellar { model.tagText = ""; model.linkTag = nil }
            let sent = session.metadata.sentTo[chain.id] ?? []
            model.isFirstSend = !sent.contains(destination.address)
            let contacts = session.metadata.contacts.filter { $0.chainID == chain.id }.map(\.address)
            let wallets = session.metadata.wallets.filter { !$0.isWatchOnly }.compactMap { $0.account(chain)?.address }
            let known = knownAddresses(chain)
            model.lookalike = AddressPoisoning.lookalike(destination.address, among: known, chain: chain)
            model.lookalikeSegment = model.lookalike.flatMap { AddressPoisoning.differingSegment(destination.address, from: $0, chain: chain) }
            // Endereco M da mesma conta de um ja usado (ou de um contato G salvo com o ID no
            // memo), com outro ID: o parecido deixa de fora, porque e a mesma conta, e o ID
            // e o que diz de quem e o deposito (B-6).
            model.otherID = AddressPoisoning.sameAccountOtherID(destination.address, among: known,
                                                                tagged: Self.taggedContacts(chain, session: session), chain: chain)
            // Sem historico da rede, o primeiro envio para endereco que nao e contato nem
            // carteira deste iPhone pede um trecho do endereco digitado, escondido: o meio,
            // ou, num M, o fim do ID (o meio de um M e a chave, igual em todo M da conta).
            // Com o ID trocado, o desafio do ID basta.
            if model.lookalike == nil, model.otherID == nil, model.isFirstSend, model.historyUnavailable,
               !contacts.contains(destination.address), !wallets.contains(destination.address) {
                model.blindSource = text
                model.blindSegment = AddressPoisoning.blindSegment(text, chain: chain)
            }
        case .failure(let problem):
            model.destinationProblem = Self.message(problem, chain: chain)
            if case .otherNetwork(let other) = problem { model.networkSuggestion = networkSuggestion(for: other) }
        }
    }

    static func message(_ problem: Address.Problem, chain: Chain) -> String {
        switch problem {
        case .empty: return ""
        case .otherNetwork(let other):
            let name = other.family == .evm ? String(localized: "EVM (Ethereum, Base e outras)") : other.name
            return chain.id == "xrpl"
                ? String(localized: "Este é um endereço \(name). Para enviar pela rede \(chain.name), use um endereço do \(chain.name).")
                : String(localized: "Este é um endereço \(name). Para enviar pela rede \(chain.name), use um endereço da \(chain.name).")
        case .badChecksum: return String(localized: "Uma letra deste endereço não confere. Ele pode ter sido copiado pela metade ou alterado. Copie de novo, inteiro.")
        case .unsupportedType: return String(localized: "Este tipo de endereço ainda não recebe envios desta carteira.")
        case .malformed:
            return chain.id == "xrpl"
                ? String(localized: "Este endereço não é do \(chain.name). Confira se copiou inteiro.")
                : String(localized: "Este endereço não é da \(chain.name). Confira se copiou inteiro.")
        }
    }

    private func continueFromDestination() async {
        guard let chain = model.chain, let destination = model.destination else { return }
        guard let engine else {
            model.destinationProblem = SendEngineError.unsupported(chain).errorDescription
            return
        }
        model.working = true
        defer { model.working = false }
        do {
            model.destinationInfo = try await engine.destination(destination.address, chain: chain)
            model.stage = model.needsTagStep && destination.tag == nil ? .tag : .amount
        } catch {
            model.destinationProblem = (error as? LocalizedError)?.errorDescription ?? String(localized: "Não foi possível consultar o destino agora.")
        }
    }

    // MARK: E3 Tag

    /// Tag, memo ou comentario quando a rede tem e o destino nao exige: o campo ja vem
    /// aberto, com o nome que a rede e as exchanges usam (pedido do dono, 14/10/2026).
    /// Quando o destino exige, a etapa propria cuida.
    @ViewBuilder
    private var optionalTag: some View {
        if model.isMuxedStellar {
            Text("Endereço M: o ID de quem recebe já vai dentro dele, sem memo.")
                .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.md)
                .fixedSize(horizontal: false, vertical: true)
        } else if let chain = model.chain, chain.destinationTag != .none, !model.needsTagStep {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: 6) {
                    Text(tagTitle).typeStyle(.row).foregroundStyle(Palette.ink)
                    Text("opcional").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
                Text(tagExplanation).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                TextField("", text: $model.tagText, prompt: Text(tagPlaceholder).foregroundColor(Palette.inkDead))
                    .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                    .keyboardType(chain.destinationTag == .xrplTag ? .numberPad : .asciiCapable)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, Space.md).frame(height: Height.field)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                    .accessibilityIdentifier("tag-opcional")
                if let problem = tagProblem {
                    Text(problem).typeStyle(.note).foregroundStyle(Palette.down).fixedSize(horizontal: false, vertical: true)
                }
                if let linkTag = model.linkTag, linkTag == model.tagText {
                    Text("Veio do código que você leu. Confira com quem pediu.")
                        .typeStyle(.note).foregroundStyle(Palette.caution).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Space.lg)
        }
    }

    /// O nome como a exchange mostra, para o dono achar o mesmo campo dos dois lados.
    private var tagTitle: String {
        switch model.chain?.destinationTag {
        case .stellarMemo: return String(localized: "Memo (MEMO)")
        case .tonComment: return String(localized: "Comentário (Memo)")
        default: return String(localized: "Tag de destino (Destination Tag)")
        }
    }

    private var tagExplanation: String {
        let exchange = String(localized: "Exchanges pedem para saber de quem é o depósito. Se quem pediu o envio deu")
        switch model.chain?.destinationTag {
        case .stellarMemo: return String(localized: "\(exchange) um memo, cole aqui exatamente igual. Para uma carteira pessoal, deixe vazio.")
        case .tonComment: return String(localized: "\(exchange) um comentário ou memo, cole aqui exatamente igual. Para uma carteira pessoal, deixe vazio.")
        default: return String(localized: "\(exchange) uma tag (um número), cole aqui. Sem ela, a exchange pode não achar o depósito. Para uma carteira pessoal, deixe vazio.")
        }
    }

    private var tagPlaceholder: String {
        model.chain?.destinationTag == .xrplTag ? "Ex.: 123456789" : String(localized: "Cole aqui, se tiver")
    }

    private var tagKind: PlanWarningText.TagKind {
        switch model.chain?.destinationTag {
        case .stellarMemo: return .memo
        case .tonComment: return .comment
        default: return .tag
        }
    }

    /// As frases da etapa da tag, inteiras para cada tipo: o nome muda o genero e a ordem
    /// da frase em cada idioma.
    private func tagText(required: Bool, exchange: String?) -> (title: String, body: String, placeholder: String, skip: String) {
        let title: String
        if required {
            switch tagKind {
            case .tag: title = String(localized: "Esta conta exige tag de destino")
            case .memo: title = String(localized: "Esta conta exige memo")
            case .comment: title = String(localized: "Esta conta exige comentário")
            }
        } else {
            title = exchange.map { String(localized: "Este endereço é da \($0)") } ?? String(localized: "Este endereço é de uma exchange")
        }
        switch tagKind {
        case .tag:
            return (title,
                    required ? String(localized: "A exchange usa a tag de destino para saber que este envio é seu. Copie da tela de depósito da exchange, a mesma onde está o endereço.")
                        : String(localized: "Exchanges quase sempre pedem tag de destino. Sem ela, o valor chega na exchange mas não na sua conta, e recuperar leva semanas de suporte."),
                    String(localized: "Tag de destino"), String(localized: "A exchange não pediu tag de destino"))
        case .memo:
            return (title,
                    required ? String(localized: "A exchange usa o memo para saber que este envio é seu. Copie da tela de depósito da exchange, a mesma onde está o endereço.")
                        : String(localized: "Exchanges quase sempre pedem memo. Sem ele, o valor chega na exchange mas não na sua conta, e recuperar leva semanas de suporte."),
                    String(localized: "Memo"), String(localized: "A exchange não pediu memo"))
        case .comment:
            return (title,
                    required ? String(localized: "A exchange usa o comentário para saber que este envio é seu. Copie da tela de depósito da exchange, a mesma onde está o endereço.")
                        : String(localized: "Exchanges quase sempre pedem comentário. Sem ele, o valor chega na exchange mas não na sua conta, e recuperar leva semanas de suporte."),
                    String(localized: "Comentário"), String(localized: "A exchange não pediu comentário"))
        }
    }

    private var tagStage: some View {
        let exchange = KnownExchanges.name(for: model.destination?.address ?? "")
        let required = model.destinationInfo?.requiresTag == true
        let words = tagText(required: required, exchange: exchange)
        return VStack(alignment: .leading, spacing: 0) {
            Text(words.title)
                .typeStyle(.title).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            Text(words.body)
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            TextField("", text: $model.tagText, prompt: Text(words.placeholder).foregroundColor(Palette.inkDead))
                .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                .keyboardType(model.chain?.destinationTag == .xrplTag ? .numberPad : .asciiCapable)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, Space.md).frame(height: 56)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edgeStrong, lineWidth: 1)))
                .padding(.top, Space.lg)
            if let problem = tagProblem {
                Text(problem).typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.xs)
            }
            Spacer()
            PrimaryButton(title: String(localized: "Continuar"), enabled: !model.tagText.isEmpty && tagProblem == nil) { model.stage = .amount }
            if !required {
                SecondaryButton(title: words.skip) {
                    model.skippedTag = true
                    model.tagText = ""
                    model.stage = .amount
                }
                .padding(.top, Space.sm)
            }
        }
    }

    private var tagProblem: String? {
        guard !model.tagText.isEmpty, let chain = model.chain else { return nil }
        switch chain.destinationTag {
        case .xrplTag:
            return UInt32(model.tagText) == nil ? String(localized: "A tag é um número de 0 a 4.294.967.295. Confira na exchange.") : nil
        case .stellarMemo:
            return model.tagText.utf8.count > 28 && UInt64(model.tagText) == nil ? String(localized: "O memo cabe até 28 caracteres.") : nil
        default:
            return nil
        }
    }

    // MARK: E4 Valor

    private var amountStage: some View {
        let holding = model.holding!
        let price = portfolio.price(of: holding.asset)
        let fiat = model.amount.map { Fmt.double($0, decimals: holding.asset.decimals) * (price ?? 0) }
        // Antes da consulta do motor, o saldo menos a reserva da rede: a reserva nao sai.
        let limit = model.spendable?.amount ?? portfolio.available(holding)
        let over = model.amount.map { $0 > limit } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            header
            let shown = model.sendAll ? Fmt.plainDecimal(model.spendable?.amount ?? limit, decimals: holding.asset.decimals) : model.amountText
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                TextField("0", text: Binding(get: { shown }, set: { model.sendAll = false; model.amountText = $0 }))
                    .font(.system(size: Self.amountFontSize(shown), weight: .bold).monospacedDigit())
                    .foregroundStyle(over ? Palette.down : Palette.ink)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
                    .fixedSize()
                Text(holding.asset.symbol).typeStyle(.heading).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
            .padding(.top, Space.xl)
            if let fiat, price != nil {
                Text("≈ \(Fmt.fiat(fiat, session.currency))").typeStyle(.body).foregroundStyle(Palette.inkSoft)
            }
            HStack {
                Text("Disponível \(Fmt.crypto(limit, decimals: holding.asset.decimals, symbol: holding.asset.symbol, style: .full))")
                    .typeStyle(.note).foregroundStyle(over ? Palette.down : Palette.inkSoft)
                Spacer()
                Button {
                    model.sendAll = true
                    amountFocused = false
                    // Sem a conta do motor ainda (ou ela falhou): pede de novo.
                    if model.spendable == nil { Task { await loadSpendable() } }
                } label: {
                    Text("Máx").typeStyle(.label).foregroundStyle(Palette.ink)
                        .padding(.horizontal, Space.sm).frame(height: 28)
                        .background(Capsule(style: .continuous).fill(Palette.rail))
                }
            }
            .padding(.top, Space.lg)
            amountSlider(limit: limit, decimals: holding.asset.decimals)
            if !model.locked.isZero {
                Button { model.showingLockedOrders = true } label: {
                    HStack(spacing: Space.xxs) {
                        Text("\(Fmt.crypto(min(model.locked, limit), decimals: holding.asset.decimals, symbol: holding.asset.symbol)) em ordens de venda abertas")
                            .typeStyle(.note).foregroundStyle(lockedOver ? Palette.caution : Palette.inkSoft)
                        Image(systemName: "chevron.forward").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, Space.sm)
                .accessibilityIdentifier("envio-ordens-abertas")
            }
            if let note = model.spendable?.reserveNote {
                Text(note).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xs).fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.spendable?.feeNote {
                Text(note).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xxs)
            }
            if let minimum = model.destinationInfo?.activationMinimum, let chain = model.chain {
                let minimumText = Fmt.crypto(minimum, decimals: holding.asset.decimals, symbol: holding.asset.symbol)
                Text(chain.id == "xrpl"
                     ? String(localized: "Esta conta ainda não existe no \(chain.name). Para ativá-la, o primeiro envio precisa ser de \(minimumText) ou mais.")
                     : String(localized: "Esta conta ainda não existe na \(chain.name). Para ativá-la, o primeiro envio precisa ser de \(minimumText) ou mais."))
                    .typeStyle(.note).foregroundStyle(Palette.caution).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                Banner(kind: .failure, title: error).padding(.top, Space.md)
            }
            Spacer()
            PrimaryButton(title: over ? String(localized: "Saldo insuficiente") : String(localized: "Revisar"), enabled: (model.amount.map { !$0.isZero } ?? false) && !over, loading: model.working) {
                // Parte do valor esta numa ordem de venda: antes, a tela de liberar.
                if lockedOver { model.showingLockedOrders = true } else { Task { await review() } }
            }
        }
        // Tocar fora do campo fecha o teclado numerico, que nao tem tecla de fechar; e o OK
        // em cima dele faz o mesmo (pedido do dono, 16/10/2026).
        .contentShape(Rectangle())
        .onTapGesture { amountFocused = false }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "OK")) { amountFocused = false }
                    .foregroundStyle(Palette.ink)
            }
        }
        .onAppear { model.availableFallback = limit }
        .onChange(of: limit) { _, value in model.availableFallback = value }
        .task {
            await loadSpendable()
            #if DEBUG
            if DebugDemo.screen == "envio-revisao" { await review() }
            #endif
        }
        .task(id: model.chain?.id) { await loadSellingOrders() }
        .sheet(isPresented: $model.showingLockedOrders) {
            LockedOrdersSheet(model: model, limit: limit) { await loadSellingOrders() }
        }
    }

    /// O valor pedido passa do que esta livre das ordens de venda abertas.
    private var lockedOver: Bool {
        guard !model.locked.isZero, let amount = model.amount, let holding = model.holding else { return false }
        let limit = model.spendable?.amount ?? portfolio.available(holding)
        return amount > (limit.subtractingReportingUnderflow(model.locked) ?? BigUInt())
    }

    /// As ordens limite abertas que vendem este ativo, lidas da rede para esta conta (a
    /// lista da aba Trocar pode ser de outra carteira ou ainda nao ter sido lida).
    private func loadSellingOrders() async {
        #if DEBUG
        if DebugDemo.screen == "envio-preso" { return }
        #endif
        guard let chain = model.chain, let account = model.account, let holding = model.holding,
              let engine = TradeEngines.engine(for: chain), engine.supportsLimitOrders,
              let orders = try? await engine.openOrders(account: account) else { return }
        let id = holding.asset.id.lowercased()
        model.sellingOrders = orders.filter { $0.sellAssetID.lowercased() == id && $0.chain.id == chain.id }
    }

    /// O numero grande encolhe com a quantidade de algarismos: um saldo de bilhoes com
    /// 9 casas cabe na tela, e o slider embaixo nao muda de largura enquanto arrasta.
    static func amountFontSize(_ text: String) -> CGFloat {
        let count = max(text.count, 1)
        return count <= 11 ? 40 : max(18, 40 * 11 / CGFloat(count))
    }

    /// Para baixo, com 6 algarismos que contam: o slider nao enche o campo de casas.
    static func roundDown(_ value: BigUInt, significant: Int = 6) -> BigUInt {
        let digits = value.decimalString.count
        guard digits > significant else { return value }
        let factor = BigUInt.power(of: 10, digits - significant)
        return value / factor * factor
    }

    private func request(amount: BigUInt, sendAll: Bool) -> SendRequest? {
        guard let holding = model.holding, let chain = model.chain, let account = model.account, let destination = model.destination else { return nil }
        return SendRequest(
            walletID: model.wallet.id, chain: chain, asset: holding.asset, account: account,
            destination: destination.address, tag: model.tagText.isEmpty ? nil : model.tagText,
            amount: amount, sendAll: sendAll, feeLevel: model.feeLevel, utxoUsage: model.wallet.utxoUsage[chain.id],
            knownAddresses: session.metadata.sentTo[chain.id] ?? [],
            nonceQueue: NonceQueue.queue(session, wallet: model.wallet.id, chain: chain, address: account.address)
        )
    }

    private func loadSpendable() async {
        guard let engine, let holding = model.holding, let probe = request(amount: holding.amount, sendAll: true) else { return }
        model.spendable = try? await engine.spendable(probe)
    }

    private func review() async {
        guard let engine, let amount = model.amount, let chain = model.chain, let account = model.account else { return }
        model.working = true
        model.error = nil
        defer { model.working = false }
        // A fila de nonces sem o que a rede ja confirmou, antes de entrar no pedido.
        await NonceQueue.prune(session, wallet: model.wallet.id, chain: chain, address: account.address)
        guard let request = request(amount: amount, sendAll: model.sendAll) else { return }
        do {
            let plan = try await engine.plan(request)
            guard planMatches(plan) else {
                model.plan = nil
                model.error = String(localized: "O envio montado não confere com o destino digitado. Nada foi assinado.")
                return
            }
            model.plan = plan
            model.irreversibleAcknowledged = false
            model.stage = .review
        } catch {
            // A fila estava a frente da rede (transacao descartada): esquecida, o proximo
            // plano parte do que a rede conhece.
            if (error as? SendEngineError)?.isLocalNonceQueueAhead == true {
                NonceQueue.clear(session, wallet: model.wallet.id, chain: chain, address: account.address)
            }
            model.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Não foi possível preparar o envio.")
        }
    }

    /// O valor pelo slider, de 0 ao disponivel. No fim, vira "enviar tudo" (o motor
    /// desconta a taxa). Digitar move o slider junto.
    private func amountSlider(limit: BigUInt, decimals: Int) -> some View {
        let total = Fmt.double(limit, decimals: decimals)
        let typed = model.sendAll ? 1 : (model.amount.map { total > 0 ? min(Fmt.double($0, decimals: decimals) / total, 1) : 0 } ?? 0)
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { typed }, set: { fraction in
                if fraction >= 0.995 {
                    model.sendAll = true
                } else {
                    model.sendAll = false
                    let part = Self.roundDown(limit * BigUInt(UInt64((fraction * 1000).rounded())) / BigUInt(1000))
                    model.amountText = part.isZero ? "" : Fmt.plainDecimal(part, decimals: decimals)
                }
            }), in: 0...1)
            .tint(Palette.accent)
            .disabled(limit.isZero)
            .accessibilityLabel("Quanto do disponível enviar")
            .accessibilityValue("\(Int((typed * 100).rounded())) por cento")
            HStack {
                ForEach(["0%", "25%", "50%", "75%", String(localized: "Máx")], id: \.self) { label in
                    Text(label).typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    if label != String(localized: "Máx") { Spacer() }
                }
            }
        }
        .padding(.top, Space.md)
        .sensoryFeedback(.selection, trigger: Int((typed * 4).rounded()))
    }

    // MARK: E6 Revisao

    /// O plano confere com o que o dono digitou: mesma carteira, mesma rede, mesmo
    /// destino e mesma tag. A revisao mostra o plano, nunca a intencao, e esta
    /// conferencia e o que garante que os dois sao o mesmo envio.
    private func planMatches(_ plan: SigningPlan) -> Bool {
        guard let chain = model.chain, let destination = model.destination else { return false }
        guard plan.review.kind == .send, plan.chain.id == chain.id, plan.walletID == model.wallet.id else { return false }
        guard Address.sameRecipient(plan.review.recipient, destination.address, chain: chain) else { return false }
        guard PlanIntentCheck.sameTag(plan.review.recipientTag, model.tagText, chain: chain) else { return false }
        // O ativo e o valor que saem, lidos da transacao pelo planejador: o pedido
        // exato, ou no enviar tudo no maximo o saldo que a tela mostrou (a taxa pode
        // ter caido entre a estimativa e o plano) (auditoria 2, M1).
        guard let holding = model.holding, let requested = model.amount else { return false }
        return (try? PlanIntentCheck.send(plan.review, asset: holding.asset, amount: model.sendAll ? nil : requested,
                                          ceiling: holding.amount, chain: chain)) != nil
    }

    private var reviewStage: some View {
        let holding = model.holding!
        let price = portfolio.price(of: holding.asset)
        // O valor em reais sai do plano, o que a transacao move, e nao do campo.
        let amount = model.plan?.review.outgoing?.amount ?? model.amount ?? 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let plan = model.plan {
                    Text(plan.review.title).typeStyle(.title).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let price {
                        Text("cerca de \(Fmt.fiat(Fmt.double(amount, decimals: holding.asset.decimals) * price, session.currency))")
                            .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, 2)
                    }
                    // So o destino (e a tag ou o memo dele): o contrato do token ficou de fora
                    // (pedido do dono, 14/10/2026). O ativo do plano e conferido em `planMatches`.
                    PlanVerbatimPlate(review: plan.review, onlyDestination: true).padding(.top, Space.lg)
                    PlanDetailLines(review: plan.review, extra: [("De", model.wallet.name)])
                        .padding(.top, Space.lg)
                    ForEach(Array(warnings(plan).enumerated()), id: \.offset) { _, warning in
                        Banner(kind: .caution, title: warning).padding(.top, Space.sm)
                    }
                }
                if let error = model.error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            }
            .padding(.bottom, Space.lg)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.sm) {
                irreversibleCheck
                PrimaryButton(title: model.plan?.review.title ?? String(localized: "Enviar"), enabled: model.irreversibleAcknowledged, loading: model.working) {
                    Task { await send() }
                }
                if model.isFirstSend {
                    Text("Primeiro envio para este endereço? Mandar um valor pequeno antes é a forma mais barata de conferir.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted).multilineTextAlignment(.center)
                }
            }
            .padding(.top, Space.sm)
            .background(Palette.void)
        }
    }

    /// A caixa de "sei que nao se desfaz", no desenho do aceite da carteira nova.
    private var irreversibleCheck: some View {
        let checked = model.irreversibleAcknowledged
        return Button { model.irreversibleAcknowledged.toggle() } label: {
            HStack(alignment: .top, spacing: Space.sm) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(checked ? Palette.control : Palette.void)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(checked ? Palette.inkSoft : Palette.edgeStrong, lineWidth: 1.5))
                    .overlay {
                        if checked { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink) }
                    }
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)
                Text("Sei que este envio não pode ser desfeito. Depois de confirmado na rede, ninguém consegue devolver, nem a Escalibur.")
                    .typeStyle(.note).foregroundStyle(checked ? Palette.ink : Palette.inkSoft)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(checked ? "Marcado" : "Desmarcado")
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityIdentifier("envio-irreversivel")
        .sensoryFeedback(.selection, trigger: checked)
    }

    /// Destino G da Stellar com um memo que e numero, contra um M conhecido (ou um contato G
    /// com outro memo) da mesma conta: o mesmo par (conta, ID) do B-6, com o ID no memo. O
    /// memo chega depois da tela do destino, entao o aviso fica na revisao.
    private var memoOtherID: AddressPoisoning.SameAccount? {
        guard let chain = model.chain, chain.family == .stellar, let destination = model.destination, !model.isMuxedStellar,
              !model.tagText.isEmpty else { return nil }
        return AddressPoisoning.sameAccountOtherID(destination.address, tag: model.tagText, among: knownAddresses(chain),
                                                   tagged: Self.taggedContacts(chain, session: session), chain: chain)
    }

    private func warnings(_ plan: SigningPlan) -> [String] {
        var out: [String] = []
        if let lookalike = model.lookalike { out.append(String(localized: "Endereço parecido com \(Fmt.address(lookalike, chain: model.chain)). Confira o endereço inteiro.")) }
        if model.otherID != nil || memoOtherID != nil {
            out.append(String(localized: "Mesma conta de um endereço que você já usou, com outro ID. Confira o ID com quem vai receber."))
        }
        if model.skippedTag {
            switch tagKind {
            case .tag: out.append(String(localized: "Envio sem tag de destino, por sua escolha."))
            case .memo: out.append(String(localized: "Envio sem memo, por sua escolha."))
            case .comment: out.append(String(localized: "Envio sem comentário, por sua escolha."))
            }
        } else if let chain = model.chain, chain.destinationTag != .none, model.tagText.isEmpty, model.isFirstSend, !model.isMuxedStellar {
            // Primeiro envio para este destino, sem tag, numa rede que tem: se for uma
            // exchange que nao liga a flag da rede, o valor se perde la dentro.
            out.append(PlanWarningText.text(.noDestinationTag, tag: tagKind))
        }
        for warning in plan.review.warnings {
            // O aviso de primeiro envio ja aparece embaixo do botao.
            if warning == .firstSendToAddress, model.isFirstSend { continue }
            // O aviso de token fora da lista saiu do envio (pedido do dono, 14/10/2026): a
            // moeda e do saldo do dono, e o ativo do plano e conferido em `planMatches`.
            if case .unverifiedToken = warning { continue }
            out.append(PlanWarningText.text(warning, tag: tagKind, chain: model.chain))
        }
        return out
    }

    private func send() async {
        guard let plan = model.plan, let engine, let chain = model.chain, let holding = model.holding else { return }
        // A conferencia do destino vale ate a assinatura: se a validacao rodou de novo
        // depois do Continuar (historico lido tarde, rede trocada), o desafio volta para a
        // tela do destino e nada e assinado.
        guard model.historyLoaded, model.lookalikeCleared else {
            model.stage = .destination
            return
        }
        guard planMatches(plan) else {
            model.error = String(localized: "O envio montado não confere com o destino digitado. Nada foi assinado.")
            return
        }
        guard !plan.isExpired() else {
            model.stage = .amount
            model.error = String(localized: "Os dados da rede venceram. Revise de novo.")
            return
        }
        // Sem cotacao, o valor em reais e desconhecido e a voz e pedida (falha fechada).
        let price = portfolio.price(of: holding.asset)
        let moved = plan.review.outgoing?.amount ?? model.amount ?? 0
        let fiat = price.map { Fmt.double(moved, decimals: holding.asset.decimals) * $0 }
        guard await VoiceGate.shared.confirm(.send(fiat: fiat), session: session) else { return }
        model.working = true
        defer { model.working = false }
        let signed: [SignedTransaction]
        do {
            guard let result = try await auth.perform(session, reason: plan.review.title, { rk in
                try Signer.sign(plan, rootKey: rk, vault: KeyServices.wallets)
            }) else { return }
            signed = result
        } catch {
            model.error = AuthCoordinator.refusalMessage(error) ?? (error as? LocalizedError)?.errorDescription ?? String(localized: "O envio não saiu. Nada foi debitado.")
            model.stage = .review
            return
        }
        model.stage = .sending
        await transmit(signed, plan: plan, engine: engine, chain: chain)
    }

    /// Transmite os bytes assinados. Erro aqui nao quer dizer que nada saiu: a rede pode
    /// ter recebido e a resposta se perdido. A tela diz isso, acompanha o id que ja se
    /// conhece e so oferece transmitir de novo os mesmos bytes, nunca montar outro envio.
    private func transmit(_ signed: [SignedTransaction], plan: SigningPlan, engine: any SendEngine, chain: Chain) async {
        // O que o plano consome (nonce EVM, indice de troco UTXO) fica anotado antes da
        // transmissao: se ela sair sem resposta, o proximo envio nao repete nenhum dos
        // dois. Anotar de novo numa retransmissao nao muda nada.
        if let address = model.account?.address {
            NonceQueue.record(session, wallet: model.wallet.id, chain: chain, address: address, plan: plan, signed: signed)
        }
        if let usage = engine.usage(after: plan, current: model.wallet.utxoUsage[chain.id]),
           var wallet = session.metadata.wallets.first(where: { $0.id == model.wallet.id }) {
            wallet.utxoUsage[chain.id] = usage
            session.update(wallet)
        }
        // Conta na sequencia de envios sem a frase ja na transmissao: mesmo sem resposta,
        // o envio pode ter saido (falha para o lado de pedir a frase antes).
        VoiceGate.shared.noteSendTransmitted(session: session)
        do {
            let id = try await engine.broadcast(signed, chain: chain)
            model.unsureSigned = nil
            model.unsureDetail = nil
            await finish(id: id, plan: plan, engine: engine, chain: chain)
        } catch {
            model.resultID = signed.last?.id
            model.unsureSigned = signed
            model.unsureDetail = (error as? LocalizedError)?.errorDescription
            model.stage = .unsure
        }
    }

    private func finish(id: String, plan: SigningPlan, engine: any SendEngine, chain: Chain) async {
        model.resultID = id
        if let address = model.destination?.address {
            var sent = session.metadata.sentTo[chain.id] ?? []
            if !sent.contains(address) { sent.append(address) }
            session.metadata.sentTo[chain.id] = sent
        }
        session.metadata.settings.completedSends = (session.metadata.settings.completedSends ?? 0) + 1
        try? session.persist()
        model.stage = .done
        await track(engine: engine, id: id, chain: chain)
    }

    /// Enquanto a resposta e incerta, pergunta a rede pelo id ja conhecido: se ela
    /// conhece a transacao, o envio saiu.
    private func watchUnsure() async {
        guard let engine, let chain = model.chain, let plan = model.plan, let id = model.resultID else { return }
        for _ in 0..<40 where model.stage == .unsure {
            try? await Task.sleep(for: .seconds(chain.typicalConfirmationSeconds > 60 ? 15 : 4))
            guard model.stage == .unsure else { return }
            if case .confirmed = await engine.status(id, chain: chain) {
                model.unsureSigned = nil
                await finish(id: id, plan: plan, engine: engine, chain: chain)
                return
            }
        }
    }

    private func retransmit() async {
        guard let signed = model.unsureSigned, let engine, let chain = model.chain, let plan = model.plan else { return }
        model.working = true
        defer { model.working = false }
        model.stage = .sending
        await transmit(signed, plan: plan, engine: engine, chain: chain)
    }

    private var unsureStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(systemName: "questionmark.circle").font(.system(size: 44)).foregroundStyle(Palette.caution)
            Text("Não deu para confirmar o envio").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
            Text("A rede não respondeu com certeza, e a transação assinada pode já estar a caminho. Não monte outro envio: transmitir de novo usa os mesmos dados e não paga duas vezes. O app continua perguntando à rede por esta transação.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = model.unsureDetail {
                Text(detail).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let id = model.resultID, let url = model.chain?.explorerURL(tx: id) {
                Link(destination: url) {
                    Text("Procurar no \(model.chain?.explorerName ?? "explorador")").typeStyle(.action)
                        .frame(maxWidth: .infinity).frame(height: Height.secondary)
                }
                .buttonStyle(SecondaryStyle())
            }
            PrimaryButton(title: String(localized: "Transmitir de novo"), loading: model.working) { Task { await retransmit() } }.padding(.top, Space.sm)
            TertiaryButton(title: String(localized: "Fechar e acompanhar na Atividade"), action: close).frame(maxWidth: .infinity)
        }
        .task(id: model.resultID) { await watchUnsure() }
    }

    private func track(engine: any SendEngine, id: String, chain: Chain) async {
        for _ in 0..<40 {
            let status = await engine.status(id, chain: chain)
            model.status = status
            if status != .pending { return }
            try? await Task.sleep(for: .seconds(chain.typicalConfirmationSeconds > 60 ? 15 : 3))
        }
    }

    // MARK: E8 Status

    /// Enviando: a moeda indo para o destino, como na troca. Enviado: a moeda girando com
    /// o selo, e a confirmacao da rede embaixo (pedido do dono, 14/10/2026).
    private var statusStage: some View {
        VStack(spacing: 0) {
            Spacer()
            if model.stage == .sending {
                SwapProcessingIndicator(sell: model.holding?.asset, buy: nil, destinationSymbol: MainTabs.walletSymbol)
                    .frame(maxWidth: .infinity)
                Text("Enviando").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.lg)
                Text(sendingLine).typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            } else {
                switch model.status {
                case .pending, .confirmed:
                    CoinFlipBadge(asset: model.holding?.asset)
                    Text("Enviado").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.lg)
                    Text(sendingLine).typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    confirmationLine.padding(.top, Space.md)
                case .failed(let reason):
                    Image(systemName: "xmark.octagon.fill").font(.system(size: 44)).foregroundStyle(Palette.down)
                    Text("A rede recusou o envio").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
                    Text(reason).typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let id = model.resultID, let url = model.chain?.explorerURL(tx: id) {
                Link(destination: url) {
                    Text("Ver no \(model.chain?.explorerName ?? "explorador")").typeStyle(.action)
                        .frame(maxWidth: .infinity).frame(height: Height.secondary)
                }
                .buttonStyle(SecondaryStyle())
            }
            if model.stage != .sending {
                PrimaryButton(title: String(localized: "Concluir"), action: close).padding(.top, Space.sm)
            }
        }
        .sensoryFeedback(.success, trigger: model.stage == .done)
    }

    /// "0,5 ETH para 0x12ab…34cd": o valor que a transacao move, do plano.
    private var sendingLine: String {
        guard let holding = model.holding else { return "" }
        let amount = model.plan?.review.outgoing?.amount ?? model.amount ?? 0
        let value = Fmt.crypto(amount, decimals: holding.asset.decimals, symbol: holding.asset.symbol, style: .full)
        guard let address = model.destination?.address else { return value }
        return String(localized: "\(value) para \(KnownExchanges.name(for: address) ?? Fmt.address(address, chain: model.chain))")
    }

    @ViewBuilder
    private var confirmationLine: some View {
        if case .confirmed(let detail) = model.status {
            HStack(spacing: Space.xs) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.up)
                Text(detail ?? String(localized: "Confirmado na rede.")).typeStyle(.note).foregroundStyle(Palette.ink)
            }
        } else if let chain = model.chain {
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.small).tint(Palette.inkSoft)
                Text(chain.family == .utxo
                     ? "A primeira confirmação leva cerca de \(chain.typicalConfirmationSeconds / 60) minutos. Pode fechar o app."
                     : chain.id == "xrpl" ? "Confirmando no \(chain.name), cerca de \(chain.typicalConfirmationSeconds) segundos."
                     : "Confirmando na \(chain.name), cerca de \(chain.typicalConfirmationSeconds) segundos.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Exchanges conhecidas por endereco de deposito, para lembrar a tag ou o memo
/// mesmo quando a conta nao liga a flag da rede. Lista compilada, preenchida so com
/// enderecos conferidos na pagina de deposito publicada pela propria exchange;
/// vazia ate essa conferencia. A flag da propria rede (RequireDest, SEP-29) cobre a
/// maioria das exchanges e ja e lida em todo envio.
enum KnownExchanges {
    static let byAddress: [String: String] = [:]

    static func name(for address: String) -> String? { byAddress[address] }
}

/// O endereco de um QR ou de um link colado; a leitura e o `PaymentLink` do Kit.
enum PaymentURI {
    struct Reading: Equatable {
        let address: String
        let chainID: String?
        /// A familia que o esquema do link indica ("ethereum:" e EVM mesmo sem rede).
        var family: ChainFamily? = nil
        var tag: String? = nil
        /// Por que o link foi recusado; nil quando foi lido.
        let problem: String?
    }

    /// O link de outra rede que a da tela: "litecoin:" na tela de Bitcoin, ou "ethereum:"
    /// sem rede na tela da Aptos (os dois aceitam endereco com a mesma forma), e recusado
    /// (auditoria 4, B-4).
    static func networkProblem(_ reading: Reading, chain: Chain) -> String? {
        if let asked = reading.chainID, asked != chain.id {
            let name = Chain.find(asked)?.name ?? String(localized: "outra rede")
            return String(localized: "Este pedido é da rede \(name), e o envio é pela \(chain.name). Confira com quem pediu antes de enviar.")
        }
        if let family = reading.family, family != chain.family {
            return String(localized: "Este pedido é de outra rede, e o envio é pela \(chain.name). Confira com quem pediu antes de enviar.")
        }
        return nil
    }

    static func read(_ text: String) -> Reading {
        do {
            let reading = try PaymentLink.read(text)
            return Reading(address: reading.address, chainID: reading.chainID, family: reading.family, tag: reading.tag, problem: nil)
        } catch PaymentLink.Problem.tooLong {
            return Reading(address: "", chainID: nil, problem: String(localized: "Este código é longo demais para ser um endereço."))
        } catch PaymentLink.Problem.containsPhrase {
            // Nada do codigo vai para o campo (auditoria 4, C7-13).
            return Reading(address: "", chainID: nil, problem: String(localized: "Este código traz as palavras de uma senha de carteira, não um endereço. Quem tem essas palavras tem o saldo: não mostre a ninguém."))
        } catch PaymentLink.Problem.unknownScheme {
            return Reading(address: "", chainID: nil, problem: String(localized: "O app não reconhece este tipo de link. Cole só o endereço."))
        } catch PaymentLink.Problem.unsupportedNetwork {
            return Reading(address: "", chainID: nil, problem: String(localized: "Este pedido de pagamento é de uma rede que a Escalibur não envia. Confira com quem pediu."))
        } catch PaymentLink.Problem.unsupportedMemo {
            return Reading(address: "", chainID: nil, problem: String(localized: "Este pedido traz um memo que o app não envia como está. Cole só o endereço e digite o memo, conferindo com quem pediu."))
        } catch {
            return Reading(address: "", chainID: nil, problem: String(localized: "Este pedido de pagamento não pôde ser lido com segurança. Peça só o endereço."))
        }
    }
}

/// Parte do valor esta numa ordem de venda aberta: para enviar, cancela a ordem antes, ou
/// envia so o que esta livre (pedido do dono, 14/10/2026). O cancelamento passa pela
/// mesma revisao, PIN e assinatura de Ordens abertas, e o valor so fica livre quando a
/// rede confirma (ate la a ordem ainda pode executar).
struct LockedOrdersSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SendModel
    /// O disponivel do envio, antes de descontar as ordens.
    let limit: BigUInt
    let reload: () async -> Void
    @State private var cancelling: TradeReviewFlow.Item?

    private var asset: Asset? { model.holding?.asset }
    private var free: BigUInt { limit.subtractingReportingUnderflow(model.locked) ?? BigUInt() }
    private var released: Bool { model.amount.map { $0 <= free } ?? false }

    private func amount(_ value: BigUInt) -> String {
        guard let asset else { return "" }
        return Fmt.crypto(value, decimals: asset.decimals, symbol: asset.symbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Moeda em ordem de venda")) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(summary).typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: Space.xs) {
                        ForEach(model.sellingOrders) { order in row(order) }
                    }
                    if released {
                        Banner(kind: .neutral, title: String(localized: "Liberado. O valor que você digitou já pode ser enviado."))
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
                .padding(.bottom, Space.lg)
            }
            VStack(spacing: Space.sm) {
                if released {
                    PrimaryButton(title: String(localized: "Continuar o envio")) { dismiss() }
                } else if !free.isZero {
                    SecondaryButton(title: String(localized: "Enviar só o livre, \(amount(free))")) {
                        model.sendAll = false
                        model.amountText = Fmt.plainDecimal(free, decimals: asset?.decimals ?? 0)
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xs)
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
        // Rele a cada 6 s: a ordem cancelada sai da lista quando a rede confirma.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: OpenOrdersSection.pollInterval)
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
        .fullScreenCover(item: $cancelling) { item in
            TradeReviewFlow(item: item) { completed in
                if completed, case .cancel(let order, _) = item.kind {
                    OpenOrdersBook.shared.markCancelling(order.id)
                    Task { await LimitOrderWatch.shared.forget(order.id) }
                }
                cancelling = nil
                if completed { Task { await reload() } }
            }
        }
    }

    private var summary: String {
        let wanted = model.amount.map(amount) ?? ""
        return String(localized: "Do disponível de \(amount(limit)), \(amount(min(model.locked, limit))) estão reservados em ordens de venda abertas. ")
            + String(localized: "Para enviar \(wanted), cancele a ordem antes. O que ela não vendeu volta a ficar livre na carteira assim que a rede confirmar.")
    }

    private func row(_ order: OpenOrder) -> some View {
        let sell = TradedAssets.resolve(order.sellAssetID, listed: order.sell, chain: order.chain, session: session, portfolio: portfolio)
        let buy = TradedAssets.resolve(order.buyAssetID, listed: order.buy, chain: order.chain, session: session, portfolio: portfolio)
        let sent = OpenOrdersBook.shared.isCancelling(order.id)
        return HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vende \(OpenOrdersSection.amount(order.remainingSell, sell))").typeStyle(.row).foregroundStyle(Palette.ink)
                Text("por no mínimo \(OpenOrdersSection.amount(order.minimumBuy, buy))").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                Text(sent ? String(localized: "Cancelamento enviado. Esperando a rede confirmar.") : OpenOrdersSection.expiry(order.expiresAt))
                    .typeStyle(.note).foregroundStyle(sent ? Palette.caution : Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            if sent {
                ProgressView().tint(Palette.inkSoft)
            } else if let via = OpenOrdersSection.safest(order.cancellations), session.selectedWallet?.isWatchOnly == false {
                Button { cancelling = TradeReviewFlow.Item(kind: .cancel(order, via), chain: order.chain, fiat: nil) } label: {
                    Text("Cancelar").typeStyle(.label).foregroundStyle(Palette.down)
                        .padding(.horizontal, Space.sm).frame(height: 34)
                        .background(Capsule(style: .continuous).fill(Palette.rail))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("envio-cancelar-ordem")
            }
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.void)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
    }
}

/// Um endereco com o trecho que o dono le e digita destacado.
struct MarkedAddress: View {
    let label: String
    let address: String
    let segment: AddressPoisoning.Segment?
    /// Esconde o trecho: o dono le na fonte, e nao copia da propria tela o que um programa
    /// no computador pode ter trocado (revisao da auditoria 4, M-1).
    var masked = false

    var body: some View {
        var shown = address
        if masked, let segment, segment.start + segment.length <= address.count {
            let start = address.index(address.startIndex, offsetBy: segment.start)
            let end = address.index(start, offsetBy: segment.length)
            shown.replaceSubrange(start..<end, with: String(repeating: "•", count: segment.length))
        }
        var text = AttributedString(shown)
        if let segment,
           let lower = text.characters.index(text.startIndex, offsetBy: segment.start, limitedBy: text.endIndex),
           let upper = text.characters.index(lower, offsetBy: segment.length, limitedBy: text.endIndex) {
            text[lower..<upper].foregroundColor = Palette.caution
            text[lower..<upper].underlineStyle = .single
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).typeStyle(.note).foregroundStyle(Palette.inkMuted)
            Text(text).font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
        }
    }
}

/// O campo do endereco (ou do memo) colado enquanto um desafio esta na tela: escondido e so
/// leitura, porque a resposta se leria nele. "Editar" desfaz o desafio e devolve o campo,
/// vazio (segunda revisao dos enderecos parecidos).
struct HiddenAddressField: View {
    var fill: Color = Palette.body
    var buttonFill: Color = Palette.rail
    var identifier = "editar-endereco"
    let edit: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "eye.slash").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
            Text(String(localized: "Escondido enquanto você confere"))
                .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.xs)
            Button(action: edit) {
                Text(String(localized: "Editar")).typeStyle(.label).foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.sm).frame(height: 34)
                    .background(Capsule(style: .continuous).fill(buttonFill))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        }
        .padding(.leading, Space.md).padding(.trailing, Space.xs).padding(.vertical, Space.xs)
        .frame(minHeight: Height.field)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
    }
}

/// Endereco M da Stellar da mesma conta de um conhecido, com outro ID (revisao dos
/// enderecos parecidos, B-6), no envio e ao salvar contato. O ID do colado fica escondido,
/// no endereco e no rotulo, e o do conhecido a vista: o dono digita o numero do ID que quem
/// vai receber mostra (ou os 6 ultimos caracteres, lidos onde copiou), e a resposta nao
/// sai da tela.
struct OtherIDCheck: View {
    let pasted: String
    let known: AddressPoisoning.SameAccount
    let knownLabel: String
    @Binding var check: String
    var field: Color = Palette.body
    var identifier = "conferir-id-endereco"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Banner(kind: .caution, title: String(localized: "Mesma conta de um endereço que você já usou, com outro ID"),
                   message: String(localized: "Confira o ID com quem vai receber."))
            MarkedAddress(label: String(localized: "Você colou"), address: pasted, segment: AddressPoisoning.muxedIDSegment(pasted), masked: true)
            MarkedAddress(label: String(localized: "\(knownLabel) · ID \(String(known.knownID))"), address: known.known,
                          segment: AddressPoisoning.muxedIDSegment(known.known))
            Text(String(localized: "Para seguir, digite o número do ID que quem vai receber mostra, ou os 6 últimos caracteres do endereço, lendo onde você o copiou."))
                .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $check, prompt: Text(String(localized: "Número do ID")).foregroundColor(Palette.inkDead))
                .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(Space.sm)
                .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(field))
                .frame(maxWidth: 220, alignment: .leading)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// De onde o dono conhece um endereco, dito no aviso de endereco parecido (auditoria 4,
/// C7-07): "voce ja pagou" e "salvo, nunca recebeu" pesam diferente, e o contato salvo sem
/// nenhum envio nao pode parecer historico.
enum KnownAddress {
    @MainActor
    static func label(_ address: String, chain: Chain, session: AppSession, history: [String] = []) -> String {
        let sent = session.metadata.sentTo[chain.id] ?? []
        if sent.contains(address) || history.contains(address) { return String(localized: "Você já pagou") }
        if let wallet = session.metadata.wallets.first(where: { !$0.isWatchOnly && $0.account(chain)?.address == address }) {
            return String(localized: "Sua carteira \(wallet.name)")
        }
        if let contact = session.metadata.contacts.first(where: { $0.chainID == chain.id && $0.address == address }) {
            return String(localized: "Salvo como \(contact.name), nunca recebeu daqui")
        }
        return String(localized: "Você já usou")
    }
}

/// Texto que parece a senha de uma carteira (12 palavras ou mais, separadas por espaco,
/// virgula, ponto e virgula ou hifen): nunca vai para um campo de endereco, por colar,
/// digitar ou ler QR (revisao do envio da auditoria 4, B-8).
enum PhraseGuard {
    static func looksLikePhrase(_ text: String) -> Bool {
        let spaced = text.replacingOccurrences(of: "[,;\\-]", with: " ", options: .regularExpression)
        return Mnemonic.words(in: spaced).count >= 12
    }

    static var message: String {
        String(localized: "Este código traz as palavras de uma senha de carteira, não um endereço. Quem tem essas palavras tem o saldo: não mostre a ninguém.")
    }
}
