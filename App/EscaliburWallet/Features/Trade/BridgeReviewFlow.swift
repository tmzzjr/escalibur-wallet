import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import SwiftUI

/// Revisar a ponte, assinar e acompanhar ate chegar.
///
/// A mesma regra da troca: a tela mostra o plano que o motor montou e conferiu, nunca a
/// cotacao da API. A cotacao vale 60 segundos, entao a revisao cota de novo ao montar, e
/// o plano e conferido contra o pedido (`PlanIntentCheck.bridge`) antes de mostrar e de
/// novo antes de assinar.
struct BridgeReviewFlow: View {
    struct Item: Identifiable {
        let id = UUID()
        let intent: BridgeIntent
        /// A rota escolhida na tela (no USDC, rapida ou padrao).
        let route: BridgeRoute
        let fiat: Double?
    }

    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(Portfolio.self) private var portfolio
    let item: Item
    let onClose: (_ completed: Bool) -> Void

    enum Stage { case planning, review, sending, done, unsure }
    @State private var stage: Stage = .planning
    @State private var quote: ValidatedBridgeQuote?
    @State private var plan: SigningPlan?
    @State private var error: String?
    @State private var record: BridgeRecord?
    @State private var unsureSigned: [SignedTransaction]?
    @State private var unsureDetail: String?

    private var intent: BridgeIntent { item.intent }
    private var sellAsset: Asset? { intent.asset.asset(on: intent.from) }
    private var receiveAsset: Asset? { intent.asset.asset(on: intent.to) }

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
        .task { await makePlan() }
    }

    // MARK: Etapas

    /// Montando ou enviando: so a animacao e o texto, no centro da tela.
    private var waits: Bool { (stage == .planning && error == nil) || stage == .sending }

    private var planning: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let error {
                Text("A ponte não foi montada").typeStyle(.title).foregroundStyle(Palette.ink)
                Banner(kind: .failure, title: error)
                Spacer()
                PrimaryButton(title: String(localized: "Tentar de novo")) { Task { await makePlan() } }
                    .padding(.bottom, Space.xs)
            } else {
                Spacer()
                SwapProcessingIndicator(sell: sellAsset, buy: receiveAsset).frame(maxWidth: .infinity)
                Text("Cotando de novo, conferindo os contratos nas duas redes e simulando antes de mostrar.")
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
                    TradeDirectionHeader(sell: sellAsset, buy: receiveAsset, sellAmount: plan.review.outgoing?.amount,
                                         buyMinimum: plan.review.incomingMinimum?.amount)
                        .padding(.bottom, Space.lg)
                    Text(plan.review.title).typeStyle(.title).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fiat {
                        Text("cerca de \(Fmt.fiat(fiat, session.currency))").typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, 2)
                    }
                    PlanVerbatimPlate(review: plan.review, collapsible: true).padding(.top, Space.lg)
                    PlanDetailLines(review: plan.review, extra: [(String(localized: "Carteira"), session.selectedWallet?.name ?? "")])
                        .padding(.top, Space.lg)
                    if plan.review.transactionCount > 1 {
                        Banner(kind: .neutral, title: String(localized: "Você vai assinar \(plan.review.transactionCount) transações de uma vez"),
                               message: String(localized: "A autorização vai antes e o depósito logo depois. Se o depósito não sair, a autorização continua valendo, só para este valor e só para o contrato da ponte."))
                            .padding(.top, Space.md)
                    }
                    ForEach(Array(plan.review.warnings.enumerated()), id: \.offset) { _, warning in
                        Banner(kind: .caution, title: PlanWarningText.text(warning, chain: plan.chain)).padding(.top, Space.sm)
                    }
                }
                if let error { Banner(kind: .failure, title: error).padding(.top, Space.md) }
            }
            .padding(.bottom, Space.lg)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: String(localized: "Confirmar ponte")) { Task { await confirm() } }
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xs)
                .background(Palette.void)
        }
    }

    private var sending: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Spacer()
            SwapProcessingIndicator(sell: sellAsset, buy: receiveAsset).frame(maxWidth: .infinity)
            Text("Enviando para a ponte").typeStyle(.title).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity).padding(.top, Space.lg)
            Text("Não feche o app até terminar.").typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private var done: some View {
        VStack(spacing: 0) {
            Spacer()
            if let record { BridgeProgressPanel(recordID: record.id) }
            Spacer()
            PrimaryButton(title: String(localized: "Concluir")) { onClose(true) }.padding(.top, Space.sm).padding(.bottom, Space.xs)
        }
    }

    private var unsure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(systemName: "questionmark.circle").font(.system(size: 44)).foregroundStyle(Palette.caution)
            Text("Não deu para confirmar o depósito").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
            Text("A resposta não veio com certeza, e o que foi assinado pode já estar a caminho. Não monte de novo: enviar de novo usa os mesmos dados e não paga duas vezes. Confira na Atividade antes de qualquer outra operação.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                .fixedSize(horizontal: false, vertical: true)
            if let unsureDetail {
                Text(unsureDetail).typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            PrimaryButton(title: String(localized: "Enviar de novo")) {
                guard let signed = unsureSigned, let plan, let quote else { return }
                Task { await transmit(signed, plan: plan, quote: quote) }
            }
            .padding(.top, Space.sm)
            TertiaryButton(title: String(localized: "Fechar e acompanhar na Atividade")) { onClose(true) }.frame(maxWidth: .infinity)
                .padding(.bottom, Space.xs)
        }
    }

    // MARK: Acoes

    private func makePlan() async {
        error = nil
        stage = .planning
        guard let wallet = session.selectedWallet, !wallet.isWatchOnly,
              let account = wallet.account(intent.from.chain), let destination = wallet.account(intent.to.chain) else {
            error = String(localized: "Esta carteira não tem conta nas duas redes.")
            return
        }
        await NonceQueue.prune(session, wallet: wallet.id, chain: intent.from.chain, address: account.address)
        let queue = NonceQueue.queue(session, wallet: wallet.id, chain: intent.from.chain, address: account.address)
        do {
            let options = try await BridgeEngine.shared.quotes(intent)
            guard let fresh = options.first(where: { $0.route == item.route }) ?? options.first else {
                error = String(localized: "A ponte não cotou esta rota agora. Tente de novo.")
                return
            }
            let built = try await BridgeEngine.shared.plan(fresh, walletID: wallet.id, account: account, destination: destination, nonceQueue: queue)
            guard planMatches(built, quote: fresh) else {
                error = String(localized: "O plano montado não confere com a ponte pedida. Nada foi assinado.")
                return
            }
            quote = fresh
            plan = built
            stage = .review
        } catch {
            if (error as? SendEngineError)?.isLocalNonceQueueAhead == true {
                NonceQueue.clear(session, wallet: wallet.id, chain: intent.from.chain, address: account.address)
            }
            self.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Não foi possível montar agora. Tente de novo.")
        }
    }

    /// Desta carteira e da rede de origem; sai exatamente o valor pedido; chega pelo
    /// menos o minimo mostrado, na rede de destino; e quem recebe e a propria conta.
    private func planMatches(_ plan: SigningPlan, quote: ValidatedBridgeQuote) -> Bool {
        guard let wallet = session.selectedWallet, plan.walletID == wallet.id, plan.chain.id == intent.from.chain.id,
              let sell = sellAsset, let receive = receiveAsset, quote.intent == intent else { return false }
        do {
            try PlanIntentCheck.bridge(plan.review, sell: sell, amount: intent.amount, from: intent.from.chain, receive: receive,
                                       minimumOut: quote.minimumReceived, to: intent.to.chain, owner: intent.recipientText)
            return true
        } catch {
            return false
        }
    }

    private var fiat: Double? {
        guard let sell = sellAsset, let price = sell.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }) else { return item.fiat }
        return Fmt.double(intent.amount, decimals: sell.decimals) * price
    }

    private func confirm() async {
        guard let plan, let quote else { return }
        guard !plan.isExpired() else {
            await makePlan()
            error = String(localized: "Os dados da rede venceram. Confira de novo.")
            return
        }
        guard planMatches(plan, quote: quote) else { return }
        guard await VoiceGate.shared.confirm(.send(fiat: fiat), session: session) else { return }
        // Carteira com passphrase: a passphrase antes do Face ID ou do PIN, conferida dentro
        // do assinador (pedido do dono, 16/10/2026).
        var typedPassphrase: SecureBytes?
        if PassphraseGate.needed(session.metadata.wallets.first { $0.id == plan.walletID }),
           let wallet = session.metadata.wallets.first(where: { $0.id == plan.walletID }) {
            guard let typed = await PassphraseGate.shared.ask(wallet) else { return }
            typedPassphrase = typed
        }
        defer { typedPassphrase?.wipe() }
        let checkPassphrase = typedPassphrase
        // A tentativa conta antes de o cofre conferir; com muitas erradas, espera.
        if checkPassphrase != nil, let wait = PassphraseGate.shared.begin(session) {
            self.error = wait
            return
        }
        let signed: [SignedTransaction]
        do {
            guard let result = try await auth.perform(session, reason: plan.review.title, { rk in
                try Signer.sign(plan, rootKey: rk, vault: KeyServices.wallets, passphrase: checkPassphrase)
            }) else {
                if checkPassphrase != nil { PassphraseGate.shared.refund(session) }
                return
            }
            signed = result
            // A passphrase confere (o assinador assinou): a conta zera, e o buffer sai ja.
            if checkPassphrase != nil {
                PassphraseGate.shared.passed(session)
                PassphraseGate.shared.confirmGrace(plan.walletID)
            }
            checkPassphrase?.wipe()
        } catch {
            checkPassphrase?.wipe()
            if (error as? Signer.Failure) == .passphraseMismatch { PassphraseGate.shared.failed(session) }
            self.error = (error as? Signer.Failure) == .passphraseMismatch ? PassphraseGate.mismatchMessage
                : AuthCoordinator.refusalMessage(error) ?? (error as? LocalizedError)?.errorDescription ?? String(localized: "A ponte não saiu. Nada foi debitado.")
            stage = .review
            return
        }
        await transmit(signed, plan: plan, quote: quote)
    }

    private func transmit(_ signed: [SignedTransaction], plan: SigningPlan, quote: ValidatedBridgeQuote) async {
        guard let wallet = session.selectedWallet, let account = wallet.account(intent.from.chain) else { return }
        NonceQueue.record(session, wallet: wallet.id, chain: intent.from.chain, address: account.address, plan: plan, signed: signed)
        stage = .sending
        do {
            VoiceGate.shared.noteSendTransmitted(session: session)
            let hash = try await BridgeEngine.shared.submit(signed, plan: plan)
            unsureSigned = nil
            let saved = BridgeRecord(quote: quote, walletID: wallet.id, depositTxHash: hash)
            BridgeCenter.shared.add(saved, session: session)
            record = saved
            stage = .done
            portfolio.show(session.selectedWallet, session: session, force: true)
        } catch {
            unsureSigned = signed
            unsureDetail = (error as? LocalizedError)?.errorDescription
            // O deposito pode ter saido: registrado pelo hash local, a ponte e acompanhada
            // igual, e some sozinha se a rede nunca viu a transacao.
            if let last = signed.last {
                BridgeCenter.shared.add(BridgeRecord(quote: quote, walletID: wallet.id, depositTxHash: last.id), session: session)
            }
            stage = .unsure
        }
    }
}

/// O andamento de uma ponte, lido de novo a cada 6 segundos enquanto esta na tela.
struct BridgeProgressPanel: View {
    @Environment(AppSession.self) private var session
    let recordID: UUID

    private var record: BridgeRecord? { session.metadata.bridges?.first { $0.id == recordID } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let record {
                let text = BridgeText.status(record, BridgeCenter.shared.progress[record.id])
                HStack(spacing: Space.sm) {
                    if text.done {
                        Image(systemName: record.state == .arrived ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                            .font(.system(size: 40)).foregroundStyle(record.state == .arrived ? Palette.up : Palette.inkSoft)
                    } else {
                        ProgressView().controlSize(.large).tint(Palette.accent)
                    }
                }
                Text(text.title).typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.xs)
                Text(text.detail).typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                if let from = record.from, let url = from.chain.explorerURL(tx: record.depositTxHash) {
                    Link("Depósito no \(from.chain.explorerName)", destination: url).typeStyle(.note).foregroundStyle(Palette.ink)
                        .padding(.top, Space.xs)
                }
                if record.state == .arrived, let to = record.to, let hash = record.settledTxHash, let url = to.chain.explorerURL(tx: hash) {
                    Link("Entrega no \(to.chain.explorerName)", destination: url).typeStyle(.note).foregroundStyle(Palette.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: recordID) {
            while !Task.isCancelled, record?.state == .pending {
                await BridgeCenter.shared.refresh(session: session)
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }
}
