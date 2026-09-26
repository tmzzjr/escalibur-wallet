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
    enum Stage: Hashable { case destination, tag, amount, review, sending, done }

    let wallet: WalletMeta
    var holding: Holding?
    var stage: Stage = .destination
    var destinationText = ""
    var destination: Address.Destination?
    var destinationProblem: String?
    var destinationInfo: DestinationInfo?
    var lookalike: String?
    /// Com endereco parecido, os 6 ultimos caracteres digitados pelo dono.
    var lookalikeCheck = ""
    var isFirstSend = false
    var tagText = ""
    var skippedTag = false
    var amountText = ""
    var sendAll = false
    var spendable: Spendable?
    var feeLevel: FeeLevel = .normal
    var plan: SigningPlan?
    var working = false
    var error: String?
    var resultID: String?
    var status: TransferStatus = .pending

    init(wallet: WalletMeta, holding: Holding?) {
        self.wallet = wallet
        self.holding = holding
    }

    var chain: Chain? { holding?.asset.chain }
    var account: DerivedAccount? { chain.flatMap { wallet.account($0) } }

    var amount: BigUInt? {
        guard let holding else { return nil }
        if sendAll { return spendable?.amount }
        return Fmt.parseAmount(amountText, decimals: holding.asset.decimals)
    }

    /// Sem endereco parecido, nada a conferir. Com ele, so segue quem digitou o fim
    /// do endereco de verdade, lendo-o em vez de reconhecer as pontas.
    var lookalikeCleared: Bool {
        guard lookalike != nil, let address = destination?.address else { return true }
        let typed = lookalikeCheck.trimmingCharacters(in: .whitespaces).lowercased()
        return typed.count == 6 && typed == address.suffix(6).lowercased()
    }

    var needsTagStep: Bool {
        guard let chain, chain.destinationTag != .none else { return false }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                    }
                    .accessibilityLabel("Fechar")
                }
            }
        }
        .interactiveDismissDisabled(model?.stage == .sending)
        .onAppear {
            guard model == nil, let wallet = session.selectedWallet else { return }
            let holding = initialAsset.flatMap { asset in
                asset.chain.flatMap { portfolio.balance($0) }?.holdings.first { $0.asset.id == asset.id }
            }
            model = SendModel(wallet: wallet, holding: holding)
        }
    }
}

/// E1: uma linha por ativo **por rede**, porque todo envio acontece numa rede.
struct SendAssetPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    let onPick: (Holding) -> Void
    @State private var query = ""

    var body: some View {
        let holdings = Chain.all.compactMap { portfolio.balance($0) }.flatMap(\.holdings).filter { !$0.amount.isZero }
        let filtered = query.isEmpty ? holdings : holdings.filter { $0.asset.symbol.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Escolha o que enviar").typeStyle(.title).foregroundStyle(Palette.ink).padding(.horizontal, Space.gutter)
            if holdings.isEmpty {
                Text("Nada para enviar ainda. Quando chegar saldo nesta carteira, ele aparece aqui.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(Space.gutter)
                Spacer()
            } else {
                TextField("", text: $query, prompt: Text("Buscar").foregroundColor(Palette.inkDead))
                    .typeStyle(.body).foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.md).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                    .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered, id: \.asset.id) { holding in
                            Button { onPick(holding) } label: {
                                HStack(spacing: Space.sm) {
                                    CoinLogo(coingeckoID: holding.asset.coingeckoID, symbol: holding.asset.symbol, size: 40, network: holding.asset.chain)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(holding.asset.symbol).typeStyle(.row).foregroundStyle(Palette.ink)
                                        Text("na \(holding.asset.chain?.name ?? "") · \(Fmt.crypto(holding.amount, decimals: holding.asset.decimals))")
                                            .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                    }
                                    Spacer()
                                    if let price = holding.asset.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }) {
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
        .padding(.top, Space.md)
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

    private var engine: (any SendEngine)? { model.chain.flatMap { SendEngines.engine(for: $0) } }

    var body: some View {
        Group {
            switch model.stage {
            case .destination: destinationStage
            case .tag: tagStage
            case .amount: amountStage
            case .review: reviewStage
            case .sending, .done: statusStage
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
                model.destinationText = PaymentURI.address(from: text)
                validate()
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            if let holding = model.holding {
                CoinLogo(coingeckoID: holding.asset.coingeckoID, symbol: holding.asset.symbol, size: 32, network: holding.asset.chain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Enviar \(model.holding?.asset.symbol ?? "")").typeStyle(.title).foregroundStyle(Palette.ink)
                if let chain = model.chain { Text("pela rede \(chain.name)").typeStyle(.note).foregroundStyle(Palette.inkSoft) }
            }
        }
    }

    // MARK: E2 Para

    private var destinationStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text("Para").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
            TextField("", text: $model.destinationText, prompt: Text("Endereço").foregroundColor(Palette.inkDead), axis: .vertical)
                .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .lineLimit(1...3)
                .onChange(of: model.destinationText) { _, _ in validate() }
                .padding(Space.md)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                .padding(.top, Space.xs)
            HStack(spacing: Space.xs) {
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        model.destinationText = PaymentURI.address(from: strings.first ?? "")
                        validate()
                    }
                }
                .labelStyle(.titleOnly).tint(Palette.rail).buttonBorderShape(.capsule)
                Button { scanning = true } label: {
                    Label("Ler QR", systemImage: "qrcode.viewfinder").typeStyle(.label)
                        .padding(.horizontal, Space.sm).frame(height: 34)
                        .background(Capsule(style: .continuous).fill(Palette.rail))
                }
                .foregroundStyle(Palette.ink)
            }
            .padding(.top, Space.xs)

            validationLine.padding(.top, Space.sm)

            if let lookalike = model.lookalike {
                Banner(kind: .caution, title: "Endereço parecido com um que você já usou",
                       message: "Começa e termina igual a \(Fmt.address(lookalike)), mas o meio é diferente. Golpistas mandam centavos de um endereço assim para ele aparecer no seu histórico.")
                    .padding(.top, Space.md)
                Text("Para seguir, digite os 6 últimos caracteres do endereço de destino, lendo no endereço inteiro acima.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: $model.lookalikeCheck, prompt: Text("6 últimos").foregroundColor(Palette.inkDead))
                    .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(Space.sm)
                    .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(Palette.body))
                    .frame(maxWidth: 180, alignment: .leading)
                    .padding(.top, Space.xs)
                    .accessibilityIdentifier("conferir-fim-endereco")
            }

            contacts.padding(.top, Space.lg)
            Spacer()
            PrimaryButton(title: "Continuar", enabled: model.destination != nil && model.lookalikeCleared, loading: model.working) {
                Task { await continueFromDestination() }
            }
        }
    }

    @ViewBuilder
    private var validationLine: some View {
        if let problem = model.destinationProblem {
            Text(problem).typeStyle(.note).foregroundStyle(Palette.down).fixedSize(horizontal: false, vertical: true)
        } else if let destination = model.destination, let chain = model.chain {
            VStack(alignment: .leading, spacing: 2) {
                Text(KnownExchanges.name(for: destination.address).map { "\($0), endereço de depósito" } ?? "Endereço \(Self.of(chain)) \(chain.name)")
                    .typeStyle(.note).foregroundStyle(Palette.up)
                if let tag = destination.tag {
                    Text("A tag de destino \(tag) veio junto no endereço.").typeStyle(.note).foregroundStyle(Palette.inkSoft)
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
            Text("Contatos").typeStyle(.note).foregroundStyle(Palette.inkSoft)
            ForEach(saved) { contact in
                Button {
                    model.destinationText = contact.address
                    model.tagText = contact.tag ?? ""
                    validate()
                } label: {
                    HStack {
                        Text(verbatim: contact.name).typeStyle(.row).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(verbatim: Fmt.address(contact.address)).typeStyle(.monoSmall).foregroundStyle(Palette.inkSoft)
                    }
                    .frame(minHeight: Height.rowCompact)
                }
            }
        }
    }

    static func of(_ chain: Chain) -> String { chain.id == "xrpl" ? "do" : "da" }

    private func validate() {
        guard let chain = model.chain else { return }
        model.destination = nil
        model.destinationProblem = nil
        model.lookalike = nil
        model.lookalikeCheck = ""
        let text = model.destinationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch Address.validate(text, for: chain) {
        case .success(let destination):
            if model.wallet.accounts.contains(where: { $0.address == destination.address }) {
                model.destinationProblem = "Este endereço é desta mesma carteira."
                return
            }
            model.destination = destination
            if let tag = destination.tag { model.tagText = String(tag) }
            let sent = session.metadata.sentTo[chain.id] ?? []
            model.isFirstSend = !sent.contains(destination.address)
            // Tudo que o dono pode reconhecer de vista: para onde ja enviou, os
            // contatos e os enderecos de todas as carteiras deste iPhone.
            let contacts = session.metadata.contacts.filter { $0.chainID == chain.id }.map(\.address)
            let wallets = session.metadata.wallets.compactMap { $0.account(chain)?.address }
            model.lookalike = AddressPoisoning.lookalike(destination.address, among: sent + contacts + wallets, chain: chain)
        case .failure(let problem):
            model.destinationProblem = Self.message(problem, chain: chain)
        }
    }

    static func message(_ problem: Address.Problem, chain: Chain) -> String {
        switch problem {
        case .empty: return ""
        case .otherNetwork(let other):
            let name = other.family == .evm ? "EVM (Ethereum, Base e outras)" : other.name
            return "Este é um endereço \(name). Para enviar pela rede \(chain.name), use um endereço \(of(chain)) \(chain.name)."
        case .badChecksum: return "Uma letra deste endereço não confere. Ele pode ter sido copiado pela metade ou alterado. Copie de novo, inteiro."
        case .unsupportedType: return "Este tipo de endereço ainda não recebe envios desta carteira."
        case .malformed: return "Este endereço não é \(of(chain)) \(chain.name). Confira se copiou inteiro."
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
            model.destinationProblem = (error as? LocalizedError)?.errorDescription ?? "Não foi possível consultar o destino agora."
        }
    }

    // MARK: E3 Tag

    private var tagNoun: String {
        switch model.chain?.destinationTag {
        case .stellarMemo: return "memo"
        case .tonComment: return "comentário"
        default: return "tag de destino"
        }
    }

    private var tagStage: some View {
        let exchange = KnownExchanges.name(for: model.destination?.address ?? "")
        let required = model.destinationInfo?.requiresTag == true
        return VStack(alignment: .leading, spacing: 0) {
            Text(required ? "Esta conta exige \(tagNoun)" : "Este endereço é da \(exchange ?? "exchange")")
                .typeStyle(.title).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            Text(required
                 ? "A exchange usa a \(tagNoun) para saber que este envio é seu. Copie da tela de depósito da exchange, a mesma onde está o endereço."
                 : "Exchanges quase sempre pedem \(tagNoun). Sem ela, o valor chega na exchange mas não na sua conta, e recuperar leva semanas de suporte.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            TextField("", text: $model.tagText, prompt: Text(tagNoun.capitalized).foregroundColor(Palette.inkDead))
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
            PrimaryButton(title: "Continuar", enabled: !model.tagText.isEmpty && tagProblem == nil) { model.stage = .amount }
            if !required {
                SecondaryButton(title: "A exchange não pediu \(tagNoun)") {
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
            return UInt32(model.tagText) == nil ? "A tag é um número de 0 a 4.294.967.295. Confira na exchange." : nil
        case .stellarMemo:
            return model.tagText.utf8.count > 28 && UInt64(model.tagText) == nil ? "O memo cabe até 28 caracteres." : nil
        default:
            return nil
        }
    }

    // MARK: E4 Valor

    private var amountStage: some View {
        let holding = model.holding!
        let price = holding.asset.coingeckoID.flatMap { portfolio.quotes[$0]?.price }
        let fiat = model.amount.map { Fmt.double($0, decimals: holding.asset.decimals) * (price ?? 0) }
        let limit = model.spendable?.amount ?? holding.amount
        let over = model.amount.map { $0 > limit } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                TextField("0", text: Binding(
                    get: { model.sendAll ? Fmt.plainDecimal(model.spendable?.amount ?? 0, decimals: holding.asset.decimals) : model.amountText },
                    set: { model.sendAll = false; model.amountText = $0 }
                ))
                .font(.system(size: 40, weight: .bold).monospacedDigit())
                .foregroundStyle(over ? Palette.down : Palette.ink)
                .keyboardType(.decimalPad)
                .fixedSize()
                Text(holding.asset.symbol).typeStyle(.heading).foregroundStyle(Palette.inkSoft)
            }
            .padding(.top, Space.xl)
            if let fiat, price != nil {
                Text("≈ \(Fmt.fiat(fiat, session.currency))").typeStyle(.body).foregroundStyle(Palette.inkSoft)
            }
            HStack {
                Text("Disponível \(Fmt.crypto(limit, decimals: holding.asset.decimals, symbol: holding.asset.symbol, style: .full))")
                    .typeStyle(.note).foregroundStyle(over ? Palette.down : Palette.inkSoft)
                Spacer()
                Button { model.sendAll = true } label: {
                    Text("Máx").typeStyle(.label).foregroundStyle(Palette.ink)
                        .padding(.horizontal, Space.sm).frame(height: 28)
                        .background(Capsule(style: .continuous).fill(Palette.rail))
                }
            }
            .padding(.top, Space.lg)
            if let note = model.spendable?.reserveNote {
                Text(note).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xs).fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.spendable?.feeNote {
                Text(note).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xxs)
            }
            if let minimum = model.destinationInfo?.activationMinimum, let chain = model.chain {
                Text("Esta conta ainda não existe \(chain.id == "xrpl" ? "no" : "na") \(chain.name). Para ativá-la, o primeiro envio precisa ser de \(Fmt.crypto(minimum, decimals: holding.asset.decimals, symbol: holding.asset.symbol)) ou mais.")
                    .typeStyle(.note).foregroundStyle(Palette.caution).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                Banner(kind: .failure, title: error).padding(.top, Space.md)
            }
            Spacer()
            PrimaryButton(title: over ? "Saldo insuficiente" : "Revisar", enabled: (model.amount.map { !$0.isZero } ?? false) && !over, loading: model.working) {
                Task { await review() }
            }
        }
        .task { await loadSpendable() }
    }

    private func request(amount: BigUInt, sendAll: Bool) -> SendRequest? {
        guard let holding = model.holding, let chain = model.chain, let account = model.account, let destination = model.destination else { return nil }
        return SendRequest(
            walletID: model.wallet.id, chain: chain, asset: holding.asset, account: account,
            destination: destination.address, tag: model.tagText.isEmpty ? nil : model.tagText,
            amount: amount, sendAll: sendAll, feeLevel: model.feeLevel, utxoUsage: model.wallet.utxoUsage[chain.id],
            knownAddresses: session.metadata.sentTo[chain.id] ?? []
        )
    }

    private func loadSpendable() async {
        guard let engine, let holding = model.holding, let probe = request(amount: holding.amount, sendAll: true) else { return }
        model.spendable = try? await engine.spendable(probe)
    }

    private func review() async {
        guard let engine, let amount = model.amount, let request = request(amount: amount, sendAll: model.sendAll) else { return }
        model.working = true
        model.error = nil
        defer { model.working = false }
        do {
            let plan = try await engine.plan(request)
            guard planMatches(plan) else {
                model.plan = nil
                model.error = "O envio montado não confere com o destino digitado. Nada foi assinado."
                return
            }
            model.plan = plan
            model.stage = .review
        } catch {
            model.error = (error as? LocalizedError)?.errorDescription ?? "Não foi possível preparar o envio."
        }
    }

    // MARK: E6 Revisao

    /// O plano confere com o que o dono digitou: mesma carteira, mesma rede, mesmo
    /// destino e mesma tag. A revisao mostra o plano, nunca a intencao, e esta
    /// conferencia e o que garante que os dois sao o mesmo envio.
    private func planMatches(_ plan: SigningPlan) -> Bool {
        guard let chain = model.chain, let destination = model.destination else { return false }
        guard plan.review.kind == .send, plan.chain.id == chain.id, plan.walletID == model.wallet.id else { return false }
        guard Address.sameRecipient(plan.review.recipient, destination.address, chain: chain) else { return false }
        return Self.sameTag(plan.review.recipientTag, model.tagText)
    }

    static func sameTag(_ planned: String?, _ typed: String?) -> Bool {
        let a = planned.flatMap { $0.isEmpty ? nil : $0 }
        let b = typed.flatMap { $0.isEmpty ? nil : $0 }
        if let a, let b, let x = UInt64(a), let y = UInt64(b) { return x == y }
        return a == b
    }

    private var reviewStage: some View {
        let holding = model.holding!
        let price = holding.asset.coingeckoID.flatMap { portfolio.quotes[$0]?.price }
        let amount = model.amount ?? 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let plan = model.plan {
                    Text(plan.review.title).typeStyle(.title).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let price {
                        Text("cerca de \(Fmt.fiat(Fmt.double(amount, decimals: holding.asset.decimals) * price, session.currency))")
                            .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, 2)
                    }
                    PlanVerbatimPlate(review: plan.review).padding(.top, Space.lg)
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
                PrimaryButton(title: model.plan?.review.title ?? "Enviar", loading: model.working) {
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

    private func warnings(_ plan: SigningPlan) -> [String] {
        var out: [String] = []
        if let lookalike = model.lookalike { out.append("Endereço parecido com \(Fmt.address(lookalike)). Confira o endereço inteiro.") }
        if model.skippedTag { out.append("Envio sem \(tagNoun), por sua escolha.") }
        for warning in plan.review.warnings {
            // O aviso de primeiro envio ja aparece embaixo do botao.
            if warning == .firstSendToAddress, model.isFirstSend { continue }
            out.append(PlanWarningText.text(warning, tagNoun: tagNoun))
        }
        return out
    }

    private func send() async {
        guard let plan = model.plan, let engine, let chain = model.chain, let holding = model.holding else { return }
        guard planMatches(plan) else {
            model.error = "O envio montado não confere com o destino digitado. Nada foi assinado."
            return
        }
        guard !plan.isExpired() else {
            model.stage = .amount
            model.error = "Os dados da rede venceram. Revise de novo."
            return
        }
        // Sem cotacao, o valor em reais e desconhecido e a voz e pedida (falha fechada).
        let price = holding.asset.coingeckoID.flatMap { portfolio.quotes[$0]?.price }
        let fiat = price.map { Fmt.double(model.amount ?? 0, decimals: holding.asset.decimals) * $0 }
        guard await VoiceGate.shared.confirm(.send(fiat: fiat), session: session) else { return }
        model.working = true
        defer { model.working = false }
        do {
            guard let signed = try await auth.perform(session, reason: plan.review.title, { rk in
                try Signer.sign(plan, rootKey: rk, vault: KeyServices.wallets)
            }) else { return }
            model.stage = .sending
            let id = try await engine.broadcast(signed, chain: chain)
            model.resultID = id
            // Troco num endereco novo: o indice avanca para o proximo envio nao repetir.
            if let usage = engine.usage(after: plan, current: model.wallet.utxoUsage[chain.id]),
               var wallet = session.metadata.wallets.first(where: { $0.id == model.wallet.id }) {
                wallet.utxoUsage[chain.id] = usage
                session.update(wallet)
            }
            if let address = model.destination?.address {
                var sent = session.metadata.sentTo[chain.id] ?? []
                if !sent.contains(address) { sent.append(address) }
                session.metadata.sentTo[chain.id] = sent
                try? session.persist()
            }
            model.stage = .done
            await track(engine: engine, id: id, chain: chain)
        } catch {
            model.error = (error as? LocalizedError)?.errorDescription ?? "O envio não saiu. Nada foi debitado."
            model.stage = .review
        }
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

    private var statusStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            switch model.status {
            case .pending:
                ProgressView().tint(Palette.ink)
                Text(model.stage == .sending ? "Enviando" : "Enviado").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
                if let chain = model.chain {
                    Text(chain.family == .utxo
                         ? "A primeira confirmação leva cerca de \(chain.typicalConfirmationSeconds / 60) minutos. Pode fechar o app."
                         : "\(chain.id == "xrpl" ? "No" : "Na") \(chain.name) leva cerca de \(chain.typicalConfirmationSeconds) segundos.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                }
            case .confirmed(let detail):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Palette.up)
                Text("Enviado").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
                Text(detail ?? "Confirmado na rede.").typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
            case .failed(let reason):
                Image(systemName: "xmark.octagon.fill").font(.system(size: 44)).foregroundStyle(Palette.down)
                Text("A rede recusou o envio").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
                Text(reason).typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
            }
            Spacer()
            if let id = model.resultID, let url = model.chain?.explorerURL(tx: id) {
                Link(destination: url) {
                    Text("Ver no \(model.chain?.explorerName ?? "explorador")").typeStyle(.action)
                        .frame(maxWidth: .infinity).frame(height: Height.secondary)
                }
                .buttonStyle(SecondaryStyle())
            }
            PrimaryButton(title: "Concluir", action: close).padding(.top, Space.sm)
        }
        .sensoryFeedback(.success, trigger: model.stage == .done)
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

/// Le o endereco de um QR ou de um link de pagamento (BIP-21, EIP-681, "xrpl:"),
/// sem aceitar mais nada dele. O valor do link nao e usado: o dono digita.
enum PaymentURI {
    static func address(from text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count <= 512 else { return "" }
        if let colon = body.firstIndex(of: ":"), body[..<colon].allSatisfy({ $0.isLetter }) {
            body = String(body[body.index(after: colon)...])
        }
        if body.hasPrefix("pay-") { body.removeFirst(4) }
        return String(body.prefix { $0 != "?" && $0 != "@" && $0 != "/" })
    }
}
