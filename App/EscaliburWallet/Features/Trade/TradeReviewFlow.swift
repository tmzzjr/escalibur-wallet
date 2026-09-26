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
    }

    struct Item: Identifiable {
        let id = UUID()
        let kind: Kind
        let chain: Chain
        /// Valor vendido em moeda do dono, para a camada de voz; nil sem cotacao.
        let fiat: Double?
    }

    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(Portfolio.self) private var portfolio
    let item: Item
    let onClose: (_ completed: Bool) -> Void

    enum Stage { case planning, review, sending, done }
    @State private var stage: Stage = .planning
    @State private var plan: SigningPlan?
    @State private var error: String?
    @State private var ids: [String] = []

    private var engine: (any TradeEngine)? { TradeEngines.engine(for: item.chain) }
    private var isLimit: Bool { if case .limit = item.kind { return true }; return false }

    private var assets: (sell: Asset, buy: Asset) {
        switch item.kind {
        case .swap(let request, _): return (request.sell, request.buy)
        case .limit(let request): return (request.sell, request.buy)
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
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var planning: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let error {
                Text(isLimit ? "A ordem não foi montada" : "A troca não foi montada").typeStyle(.title).foregroundStyle(Palette.ink)
                Banner(kind: .failure, title: error)
                Spacer()
                PrimaryButton(title: "Tentar de novo") { Task { await makePlan() } }
                    .padding(.bottom, Space.xs)
            } else {
                Spacer()
                SwapProcessingIndicator(sell: assets.sell, buy: assets.buy).frame(maxWidth: .infinity)
                Text(isLimit ? "Montando a ordem e conferindo os dados da rede." : "Recotando e simulando a troca antes de mostrar.")
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
                    Text(plan.review.title).typeStyle(.title).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fiat = item.fiat {
                        Text("cerca de \(Fmt.fiat(fiat, session.currency))").typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, 2)
                    }
                    PlanVerbatimPlate(review: plan.review).padding(.top, Space.lg)
                    PlanDetailLines(review: plan.review, extra: [("De", session.selectedWallet?.name ?? "")])
                        .padding(.top, Space.lg)
                    if plan.review.transactionCount > 1 {
                        Banner(kind: .neutral, title: "Você vai assinar \(plan.review.transactionCount) transações de uma vez",
                               message: "A autorização do token vai antes e a troca logo depois, em transações separadas. Se a troca não sair, a autorização continua valendo, só para este valor e só para o contrato desta troca.")
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
            PrimaryButton(title: plan?.review.title ?? "Confirmar") { Task { await confirm() } }
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xs)
                .background(Palette.void)
        }
    }

    private var sending: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Spacer()
            SwapProcessingIndicator(sell: assets.sell, buy: assets.buy).frame(maxWidth: .infinity)
            Text(isLimit ? "Enviando a ordem" : "Enviando a troca").typeStyle(.title).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity).padding(.top, Space.lg)
            Text("Não feche o app até terminar.").typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Palette.up)
            Text(isLimit ? "Ordem limite criada" : "Troca enviada").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
            Text(isLimit
                 ? "A ordem fica aberta até executar, vencer ou você cancelar."
                 : "O saldo novo aparece quando a rede confirmar.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !isLimit, let last = ids.last, let url = item.chain.explorerURL(tx: last) {
                Link(destination: url) {
                    Text("Ver no \(item.chain.explorerName)").typeStyle(.action)
                        .frame(maxWidth: .infinity).frame(height: Height.secondary)
                }
                .buttonStyle(SecondaryStyle())
            }
            PrimaryButton(title: "Concluir") { onClose(true) }.padding(.top, Space.sm).padding(.bottom, Space.xs)
        }
        .sensoryFeedback(.success, trigger: stage == .done)
    }

    // MARK: Acoes

    private func makePlan() async {
        guard let engine else {
            error = "Troca nesta rede ainda não está disponível."
            return
        }
        error = nil
        stage = .planning
        do {
            let built: SigningPlan
            switch item.kind {
            case .swap(let request, let quote): built = try await engine.plan(request, quote: quote)
            case .limit(let request): built = try await engine.planLimitOrder(request)
            }
            guard planMatches(built) else {
                error = "O plano montado não confere com a troca pedida. Nada foi assinado."
                return
            }
            plan = built
            stage = .review
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Não foi possível montar agora. Tente de novo."
        }
    }

    /// Desta carteira, desta rede e do tipo pedido. O resto do conteudo foi validado
    /// pelo planejador da rede (minimo decodificado da transacao, contrato na lista).
    private func planMatches(_ plan: SigningPlan) -> Bool {
        guard let wallet = session.selectedWallet, plan.walletID == wallet.id, plan.chain.id == item.chain.id else { return false }
        switch item.kind {
        case .swap: return plan.review.kind == .swap
        case .limit: return plan.review.kind == .limitOrder
        }
    }

    private func confirm() async {
        guard let plan, let engine else { return }
        guard !plan.isExpired() else {
            await makePlan()
            error = "Os dados da rede venceram. Confira de novo."
            return
        }
        guard planMatches(plan) else { return }
        guard await VoiceGate.shared.confirm(.send(fiat: item.fiat), session: session) else { return }
        do {
            guard let signed = try await auth.perform(session, reason: plan.review.title, { rk in
                try Signer.sign(plan, rootKey: rk, vault: KeyServices.wallets)
            }) else { return }
            stage = .sending
            ids = try await engine.submit(signed, plan: plan)
            stage = .done
            portfolio.show(session.selectedWallet, session: session, force: true)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? (isLimit ? "A ordem não saiu. Nada foi debitado." : "A troca não saiu. Nada foi debitado.")
            stage = .review
        }
    }
}
