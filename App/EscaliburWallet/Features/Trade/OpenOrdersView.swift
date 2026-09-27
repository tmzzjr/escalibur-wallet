import EscaliburChains
import EscaliburCore
import EscaliburEngines
import SwiftUI

/// As ordens limite abertas desta carteira numa rede, lidas da rede, ali mesmo na tela
/// da ordem limite, e o cancelamento (auditoria 2, A3). O cancelamento passa pela mesma
/// revisao, PIN e assinatura de qualquer plano.
struct OpenOrdersSection: View {
    @Environment(AppSession.self) private var session
    let chain: Chain
    /// Muda quando uma ordem foi criada ou cancelada fora daqui: a lista rele.
    var refresh: Int = 0

    enum Load { case loading, loaded([OpenOrder]), failed(String) }
    @State private var load: Load = .loading
    @State private var choosing: OpenOrder?
    @State private var reviewing: TradeReviewFlow.Item?

    private var engine: (any TradeEngine)? { TradeEngines.engine(for: chain) }
    private var canSign: Bool { session.selectedWallet?.isWatchOnly == false }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Ordens abertas").typeStyle(.heading).foregroundStyle(Palette.ink)
            content
        }
        .task(id: "\(chain.id)-\(refresh)") { await reload() }
        .confirmationDialog("Cancelar esta ordem?", isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                            titleVisibility: .visible, presenting: choosing) { order in
            ForEach(order.cancellations, id: \.self) { via in
                Button(Self.title(via)) { reviewing = TradeReviewFlow.Item(kind: .cancel(order, via), chain: chain, fiat: nil) }
            }
            Button("Manter a ordem", role: .cancel) {}
        } message: { order in
            Text(Self.explanation(order.cancellations))
        }
        .fullScreenCover(item: $reviewing) { item in
            TradeReviewFlow(item: item) { completed in
                reviewing = nil
                if completed { Task { await reload() } }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            HStack(spacing: Space.sm) {
                ProgressView().tint(Palette.inkSoft)
                Text("Lendo as ordens na rede.").typeStyle(.note).foregroundStyle(Palette.inkSoft)
            }
            .frame(minHeight: 44)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(message).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                TertiaryButton(title: "Tentar de novo") { Task { await reload() } }
            }
        case .loaded(let orders) where orders.isEmpty:
            Text("Nenhuma ordem aberta \(chain.id == "xrpl" ? "no" : "na") \(chain.name). A que você criar aparece aqui até executar, vencer ou você cancelar.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
        case .loaded(let orders):
            VStack(spacing: 0) {
                ForEach(orders) { order in row(order) }
            }
            if !canSign {
                Text("Esta carteira só acompanha: para cancelar, abra a carteira que assina.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Toque numa ordem para cancelar.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
            }
        }
    }

    private func row(_ order: OpenOrder) -> some View {
        Button { choosing = order } label: {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: order.sell?.coingeckoID, symbol: order.sell?.symbol ?? "?", size: 36, network: chain)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vende \(Self.amount(order.remainingSell, order.sell))").typeStyle(.row).foregroundStyle(Palette.ink)
                    Text("por no mínimo \(Self.amount(order.minimumBuy, order.buy))").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                Spacer(minLength: Space.sm)
                Text(Self.expiry(order.expiresAt)).typeStyle(.note).foregroundStyle(Palette.inkSoft).multilineTextAlignment(.trailing)
            }
            .frame(minHeight: Height.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSign || order.cancellations.isEmpty)
        .accessibilityHint(canSign ? "Cancelar a ordem" : "")
    }

    private func reload() async {
        guard let engine, let account = session.selectedWallet?.account(chain) else {
            load = .failed("Esta carteira não tem conta nesta rede.")
            return
        }
        load = .loading
        do {
            load = .loaded(try await engine.openOrders(account: account))
        } catch {
            load = .failed((error as? LocalizedError)?.errorDescription ?? "Não foi possível ler as ordens agora. Tente de novo.")
        }
    }

    // MARK: Textos

    /// Ativo fora da lista (ordem criada fora da carteira) nao ganha nome nem casas da
    /// rede: aparece como tal, sem numero que poderia estar errado.
    static func amount(_ value: BigUInt, _ asset: Asset?) -> String {
        guard let asset else { return "um token fora da lista" }
        return Fmt.crypto(value, decimals: asset.decimals, symbol: asset.symbol)
    }

    static func expiry(_ date: Date?) -> String {
        guard let date else { return "Até cancelar" }
        let relative = date.formatted(Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .wide).locale(Fmt.locale))
        return "Vence \(relative)"
    }

    static func title(_ via: OpenOrder.Cancellation) -> String {
        switch via {
        case .offchain: return "Cancelar sem taxa, sem garantia"
        case .onchain: return "Cancelar na rede, com taxa, garantido"
        }
    }

    static func explanation(_ options: [OpenOrder.Cancellation]) -> String {
        let offchain = "Sem taxa: um pedido à CoW para parar de oferecer a ordem. Um solver que já estiver executando ainda pode concluí-la."
        let onchain = "Na rede: uma transação com a taxa da rede, que invalida a ordem de vez depois de confirmada."
        switch (options.contains(.offchain), options.contains(.onchain)) {
        case (true, true): return offchain + "\n\n" + onchain
        case (true, false): return offchain
        default: return onchain
        }
    }
}
