import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import SwiftUI

/// T3 a T5: revisar o plano da troca ou da ordem limite, assinar e acompanhar.
///
/// Mesma regra do envio: a tela mostra o plano que o motor montou e validou, nunca a
/// intencao, e o plano precisa ser desta carteira e desta rede antes de qualquer
/// assinatura.
struct TradeReviewFlow: View {
    enum Kind: Sendable {
        case swap(TradeRequest, TradeQuote)
        case limit(LimitOrderRequest)
        /// Cancelar uma ordem aberta, pelo jeito escolhido.
        case cancel(OpenOrder, OpenOrder.Cancellation)
    }

    struct Item: Identifiable {
        let id = UUID()
        let kind: Kind
        let chain: Chain
        /// Valor vendido em moeda do dono, para a camada de voz; nil sem cotacao.
        let fiat: Double?
        /// Ordem limite: refazer quando vencer (`LimitRenewalCenter`).
        var renewLimit = false
        /// Refazendo uma ordem vencida: o id dela, que sai da lista quando a nova sai.
        var replacesRenewal: String? = nil
    }

    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(Portfolio.self) private var portfolio
    let item: Item
    let onClose: (_ completed: Bool) -> Void
    #if DEBUG
    /// `-tela carregando` e `-tela enviando`: a tela parada numa etapa, sem rede.
    var debugStage: Stage?
    #endif

    /// `unsure`: assinado e enviado sem resposta certa (auditoria 2, M3).
    enum Stage { case planning, review, sending, done, unsure }
    @State private var stage: Stage = .planning
    @State private var plan: SigningPlan?
    @State private var error: String?
    @State private var ids: [String] = []
    /// O que foi assinado e enviado sem resposta certa: so isto pode ir de novo.
    @State private var unsureSigned: [SignedTransaction]?
    @State private var unsureDetail: String?

    private var engine: (any TradeEngine)? { TradeEngines.engine(for: item.chain) }
    private var isLimit: Bool { if case .limit = item.kind { return true }; return false }
    private var isCancel: Bool { if case .cancel = item.kind { return true }; return false }

    /// Os textos de cada etapa, por tipo: troca, ordem limite ou cancelamento.
    private func text(swap: String, limit: String, cancel: String) -> String {
        switch item.kind {
        case .swap: return swap
        case .limit: return limit
        case .cancel: return cancel
        }
    }

    private var assets: (sell: Asset?, buy: Asset?) {
        switch item.kind {
        case .swap(let request, _): return (request.sell, request.buy)
        case .limit(let request): return (request.sell, request.buy)
        case .cancel(let order, _):
            // A ordem pode ser de token fora da lista: o que a carteira conhece dele.
            return (TradedAssets.resolve(order.sellAssetID, listed: order.sell, chain: order.chain, session: session, portfolio: portfolio),
                    TradedAssets.resolve(order.buyAssetID, listed: order.buy, chain: order.chain, session: session, portfolio: portfolio))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .planning: planning
                case .review: review
                case .sending: sending
                case .done: done
                case .unsure: unsure
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, waits ? 0 : Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A animacao de espera fica no meio da tela, nao no meio do espaco abaixo do
            // botao de fechar.
            .ignoresSafeArea(.container, edges: waits ? .vertical : [])
            .background(Palette.void.ignoresSafeArea())
            .toolbar {
                if stage != .sending {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { onClose(stage == .done) } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                        }
                        .accessibilityLabel("Fechar")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            #if DEBUG
            if let debugStage {
                stage = debugStage
                return
            }
            #endif
            await makePlan()
        }
    }

    // MARK: Etapas

    /// Montando ou enviando: so a animacao e o texto, no centro da tela.
    private var waits: Bool { (stage == .planning && error == nil) || stage == .sending }

    private var planning: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let error {
                Text(text(swap: String(localized: "A troca não foi montada"), limit: String(localized: "A ordem não foi montada"), cancel: String(localized: "O cancelamento não foi montado")))
                    .typeStyle(.title).foregroundStyle(Palette.ink)
                Banner(kind: .failure, title: error)
                Spacer()
                PrimaryButton(title: String(localized: "Tentar de novo")) { Task { await makePlan() } }
                    .padding(.bottom, Space.xs)
            } else {
                Spacer()
                SwapProcessingIndicator(sell: assets.sell, buy: assets.buy, cancelling: isCancel).frame(maxWidth: .infinity)
                Text(text(swap: String(localized: "Recotando e simulando a troca antes de mostrar."), limit: String(localized: "Montando a ordem e conferindo os dados da rede."),
                          cancel: String(localized: "Montando o cancelamento e conferindo a ordem na rede.")))
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    .padding(.top, Space.lg)
                Spacer()
            }
        }
    }

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let plan {
                    if !isCancel {
                        TradeDirectionHeader(sell: assets.sell, buy: assets.buy, sellAmount: plan.review.outgoing?.amount,
                                             buyMinimum: plan.review.incomingMinimum?.amount)
                            .padding(.bottom, Space.lg)
                    }
                    Text(plan.review.title).typeStyle(.title).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fiat {
                        Text("cerca de \(Fmt.fiat(fiat, session.currency))").typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, 2)
                    }
                    PlanVerbatimPlate(review: plan.review, collapsible: true).padding(.top, Space.lg)
                    PlanDetailLines(review: plan.review, extra: [("De", session.selectedWallet?.name ?? "")]
                        + (item.renewLimit ? [(String(localized: "Quando vencer"), String(localized: "O app avisa e pergunta se refaz, com o mesmo preço"))] : []))
                        .padding(.top, Space.lg)
                    if plan.review.transactionCount > 1 {
                        Banner(kind: .neutral, title: String(localized: "Você vai assinar \(plan.review.transactionCount) transações de uma vez"),
                               message: String(localized: "A autorização do token vai antes e a troca logo depois, em transações separadas. Se a troca não sair, a autorização continua valendo, só para este valor e só para o contrato desta troca."))
                            .padding(.top, Space.md)
                    }
                    ForEach(Array(plan.review.warnings.enumerated()), id: \.offset) { _, warning in
                        Banner(kind: .caution, title: PlanWarningText.text(warning)).padding(.top, Space.sm)
                    }
                }
                if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            }
            .padding(.bottom, Space.lg)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: text(swap: String(localized: "Confirmar troca"), limit: String(localized: "Criar ordem limite"), cancel: String(localized: "Cancelar a ordem"))) {
                Task { await confirm() }
            }
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xs)
                .background(Palette.void)
        }
    }

    private var sending: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Spacer()
            SwapProcessingIndicator(sell: assets.sell, buy: assets.buy, cancelling: isCancel).frame(maxWidth: .infinity)
            Text(text(swap: String(localized: "Enviando a troca"), limit: String(localized: "Enviando a ordem"), cancel: String(localized: "Enviando o cancelamento"))).typeStyle(.title).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity).padding(.top, Space.lg)
            Text(sendingNote).typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    /// A troca pela CoW: o id devolvido e o UID da ordem, e a tela acompanha o
    /// preenchimento. A ordem limite nao: ela espera o preco, e o andamento fica em Ordens
    /// abertas (pedido do dono, 11/10/2026).
    private var followedOrder: (id: String, kind: OrderProgressPanel.Kind, account: DerivedAccount)? {
        guard let plan, plan.transactions.last is EIP712ValidatedMessage, let id = ids.first,
              let account = session.selectedWallet?.account(item.chain) else { return nil }
        if case .swap = item.kind { return (id, .swap, account) }
        return nil
    }

    @ViewBuilder
    private var done: some View {
        if let order = followedOrder {
            VStack(spacing: 0) {
                Spacer()
                OrderProgressPanel(kind: order.kind, chain: item.chain, orderID: order.id, account: order.account,
                                   sell: assets.sell, buy: assets.buy)
                Spacer()
                PrimaryButton(title: String(localized: "Concluir")) { onClose(true) }.padding(.top, Space.sm).padding(.bottom, Space.xs)
            }
        } else {
            plainDone
        }
    }

    private var plainDone: some View {
        VStack(spacing: 0) {
            Spacer()
            // A moeda da ordem e o checkmark, girando como uma moeda jogada.
            CoinFlipBadge(asset: assets.sell)
            Text(text(swap: String(localized: "Troca enviada"), limit: String(localized: "Ordem limite criada"), cancel: String(localized: "Cancelamento enviado")))
                .typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.lg)
                .multilineTextAlignment(.center)
            Text(doneMessage)
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !isLimit, !isOffchainCancel, let last = ids.last, let url = item.chain.explorerURL(tx: last) {
                Link(destination: url) {
                    Text("Ver no \(item.chain.explorerName)").typeStyle(.action)
                        .frame(maxWidth: .infinity).frame(height: Height.secondary)
                }
                .buttonStyle(SecondaryStyle())
            }
            PrimaryButton(title: String(localized: "Concluir")) { onClose(true) }.padding(.top, Space.sm).padding(.bottom, Space.xs)
        }
        .sensoryFeedback(.success, trigger: stage == .done)
    }

    /// Ordem da CoW com autorizacao antes: a CoW so aceita a ordem depois que a
    /// autorizacao confirma na rede, e a espera e essa.
    private var sendingNote: String {
        guard let plan, plan.transactions.last is EIP712ValidatedMessage, plan.transactions.count > 1 else {
            return String(localized: "Não feche o app até terminar.")
        }
        return String(localized: "A autorização vai primeiro. A ordem segue para a CoW assim que ela confirmar na \(item.chain.name). Não feche o app até terminar.")
    }

    // MARK: Acoes

    private var isOffchainCancel: Bool {
        if case .cancel(_, .offchain) = item.kind { return true }
        return false
    }

    private var doneMessage: String {
        switch item.kind {
        case .swap: return String(localized: "O saldo novo aparece quando a rede confirmar.")
        case .limit: return String(localized: "A ordem fica aberta até executar, vencer ou você cancelar.")
        case .cancel(_, .offchain): return String(localized: "A CoW recebeu o pedido. Se um solver já estava executando a ordem, ela ainda pode sair.")
        case .cancel(_, .onchain): return String(localized: "A ordem deixa de valer quando a rede confirmar a transação.")
        }
    }

    private func makePlan() async {
        guard let engine else {
            error = String(localized: "Troca nesta rede ainda não está disponível.")
            return
        }
        error = nil
        stage = .planning
        guard let wallet = session.selectedWallet, let account = wallet.account(item.chain) else {
            error = String(localized: "Esta carteira não tem conta nesta rede.")
            return
        }
        // A fila de nonces EVM desta conta, sem o que a rede ja confirmou, entra no
        // pedido: o planejador sabe o que este aparelho ja transmitiu.
        await NonceQueue.prune(session, wallet: wallet.id, chain: item.chain, address: account.address)
        let queue = NonceQueue.queue(session, wallet: wallet.id, chain: item.chain, address: account.address)
        do {
            let built: SigningPlan
            switch item.kind {
            case .swap(let r, let quote):
                let request = TradeRequest(walletID: r.walletID, chain: r.chain, account: r.account, sell: r.sell, buy: r.buy,
                                           amountIn: r.amountIn, slippageBasisPoints: r.slippageBasisPoints, nonceQueue: queue,
                                           inParts: r.inParts)
                built = try await engine.plan(request, quote: quote)
            case .limit(let r):
                let request = LimitOrderRequest(walletID: r.walletID, chain: r.chain, account: r.account, sell: r.sell, buy: r.buy,
                                                amountIn: r.amountIn, minimumOut: r.minimumOut, validFor: r.validFor, nonceQueue: queue)
                built = try await engine.planLimitOrder(request)
            case .cancel(let order, let via):
                built = try await engine.planCancel(order, walletID: wallet.id, account: account, via: via, nonceQueue: queue)
            }
            guard planMatches(built) else {
                error = String(localized: "O plano montado não confere com a troca pedida. Nada foi assinado.")
                return
            }
            plan = built
            stage = .review
        } catch {
            if (error as? SendEngineError)?.isLocalNonceQueueAhead == true {
                NonceQueue.clear(session, wallet: wallet.id, chain: item.chain, address: account.address)
            }
            self.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Não foi possível montar agora. Tente de novo.")
        }
    }

    /// Desta carteira, desta rede e do tipo pedido; vende o ativo pedido, nunca mais
    /// que o valor; garante pelo menos o minimo mostrado do ativo comprado; e o que
    /// entra vai para a propria conta (auditoria 2, M1). O resto foi validado pelo
    /// planejador da rede (minimo decodificado da transacao, contrato na lista).
    private func planMatches(_ plan: SigningPlan) -> Bool {
        guard let wallet = session.selectedWallet, plan.walletID == wallet.id, plan.chain.id == item.chain.id else { return false }
        do {
            switch item.kind {
            case .swap(let request, let quote):
                guard plan.review.kind == .swap else { return false }
                try PlanIntentCheck.trade(plan.review, sell: request.sell, amountIn: request.amountIn, buy: request.buy,
                                          minimumOut: quote.minimumOut(inParts: request.inParts), owner: request.account.address,
                                          chain: item.chain)
            case .limit(let request):
                guard plan.review.kind == .limitOrder else { return false }
                try PlanIntentCheck.trade(plan.review, sell: request.sell, amountIn: request.amountIn, buy: request.buy,
                                          minimumOut: request.minimumOut, owner: request.account.address, chain: item.chain)
            case .cancel:
                // Cancelar nao move valor: o plano tem de ser so um cancelamento.
                guard plan.review.kind == .cancelOrder, plan.review.outgoing == nil || plan.review.outgoing?.amount == 0 else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    /// O valor vendido em moeda do dono, do que o plano move: e o que a voz e o
    /// "cerca de" usam. Sem plano, a estimativa da tela anterior.
    private var fiat: Double? {
        guard let outgoing = plan?.review.outgoing else { return item.fiat }
        guard let sell = assets.sell, let price = sell.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }) else { return nil }
        return Fmt.double(outgoing.amount, decimals: sell.decimals) * price
    }

    private func confirm() async {
        guard let plan, let engine else { return }
        guard !plan.isExpired() else {
            await makePlan()
            error = String(localized: "Os dados da rede venceram. Confira de novo.")
            return
        }
        guard planMatches(plan) else { return }
        // Cancelar nao tira valor da carteira: a voz fica para o que tira.
        if !isCancel {
            guard await VoiceGate.shared.confirm(.send(fiat: fiat), session: session) else { return }
        }
        let signed: [SignedTransaction]
        do {
            guard let result = try await auth.perform(session, reason: plan.review.title, { rk in
                try Signer.sign(plan, rootKey: rk, vault: KeyServices.wallets)
            }) else { return }
            signed = result
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? text(swap: String(localized: "A troca não saiu. Nada foi debitado."), limit: String(localized: "A ordem não saiu. Nada foi debitado."),
                        cancel: String(localized: "O cancelamento não saiu. A ordem continua aberta."))
            stage = .review
            return
        }
        await transmit(signed, plan: plan, engine: engine)
    }

    /// Envia o que foi assinado. Erro aqui nao quer dizer que nada saiu: a resposta pode
    /// ter se perdido depois de a rede (ou a CoW) receber. A tela diz isso e so oferece
    /// enviar de novo os mesmos bytes, que tem o mesmo id e nao pagam duas vezes.
    private func transmit(_ signed: [SignedTransaction], plan: SigningPlan, engine: any TradeEngine) async {
        if let wallet = session.selectedWallet, let account = wallet.account(item.chain) {
            NonceQueue.record(session, wallet: wallet.id, chain: item.chain, address: account.address, plan: plan, signed: signed)
        }
        stage = .sending
        do {
            if !isCancel { VoiceGate.shared.noteSendTransmitted(session: session) }
            ids = try await engine.submit(signed, plan: plan)
            unsureSigned = nil
            switch item.kind {
            case .swap(let request, _): TradedAssets.remember([request.sell, request.buy], session: session)
            case .limit(let request): TradedAssets.remember([request.sell, request.buy], session: session)
            case .cancel: break
            }
            if case .limit(let request) = item.kind, let orderID = ids.first {
                if let old = item.replacesRenewal { LimitRenewalCenter.shared.forget(old, session: session) }
                if item.renewLimit { LimitRenewalCenter.shared.register(orderID: orderID, request: request, session: session) }
                // Avisos de 24 horas antes de vencer e de executada: pede a permissao de
                // notificacao aqui, com a ordem na tela, se ainda nao pediu. A carteira com
                // passphrase fica de fora: o UID traz o endereco, e o arquivo dos avisos abre
                // com o iPhone bloqueado (revisao da auditoria 4, C7-03).
                if session.selectedWallet?.hasPassphrase != true, CoWProtocol.supports(request.chain),
                   let uid = Hex.decode(orderID), let validTo = CoWProtocol.validTo(ofUID: uid) {
                    let chainID = request.chain.id
                    Task {
                        _ = await PriceAlertCenter.requestPermission()
                        await LimitOrderWatch.shared.track(id: orderID, chainID: chainID, expiresAt: Date(timeIntervalSince1970: TimeInterval(validTo)))
                    }
                }
            }
            stage = .done
            portfolio.show(session.selectedWallet, session: session, force: true)
        } catch {
            ids = signed.map(\.id)
            unsureSigned = signed
            unsureDetail = (error as? LocalizedError)?.errorDescription
            stage = .unsure
        }
    }

    private var unsure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(systemName: "questionmark.circle").font(.system(size: 44)).foregroundStyle(Palette.caution)
            Text(text(swap: String(localized: "Não deu para confirmar a troca"), limit: String(localized: "Não deu para confirmar a ordem"),
                      cancel: String(localized: "Não deu para confirmar o cancelamento")))
                .typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
            Text("A resposta não veio com certeza, e o que foi assinado pode já estar a caminho. Não monte de novo: enviar de novo usa os mesmos dados e não paga duas vezes. Confira na Atividade antes de qualquer outra operação.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                .fixedSize(horizontal: false, vertical: true)
            if let unsureDetail {
                Text(unsureDetail).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !isLimit, !isOffchainCancel, let last = ids.last, let url = item.chain.explorerURL(tx: last) {
                Link(destination: url) {
                    Text("Procurar no \(item.chain.explorerName)").typeStyle(.action)
                        .frame(maxWidth: .infinity).frame(height: Height.secondary)
                }
                .buttonStyle(SecondaryStyle())
            }
            PrimaryButton(title: String(localized: "Enviar de novo")) {
                guard let signed = unsureSigned, let plan, let engine else { return }
                Task { await transmit(signed, plan: plan, engine: engine) }
            }
            .padding(.top, Space.sm)
            TertiaryButton(title: String(localized: "Fechar e acompanhar na Atividade")) { onClose(true) }.frame(maxWidth: .infinity)
                .padding(.bottom, Space.xs)
        }
    }
}
