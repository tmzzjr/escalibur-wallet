import EscaliburChains
import EscaliburCore
import EscaliburEngines
import SwiftUI

/// As ordens limite abertas desta carteira numa rede, lidas da rede, e o cancelamento
/// (auditoria 2, A3): a revisao da ordem diz que da para cancelar, e e aqui que cancela.
/// O cancelamento passa pela mesma revisao, PIN e assinatura de qualquer plano.
struct OpenOrdersView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let chain: Chain

    enum Load { case loading, loaded([OpenOrder]), failed(String) }
    @State private var load: Load = .loading
    @State private var choosing: OpenOrder?
    @State private var reviewing: TradeReviewFlow.Item?

    private var engine: (any TradeEngine)? { TradeEngines.engine(for: chain) }
    private var canSign: Bool { session.selectedWallet?.isWatchOnly == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Ordens abertas") { dismiss() }
            Text("\(chain.id == "xrpl" ? "No" : "Na") \(chain.name). Cada ordem fica aberta até executar, vencer ou você cancelar.")
                .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
            content.padding(.top, Space.md)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
        .task { await reload() }
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
            .padding(.horizontal, Space.gutter)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.md) {
                Banner(kind: .failure, title: message)
                SecondaryButton(title: "Tentar de novo") { Task { await reload() } }
            }
            .padding(.horizontal, Space.gutter)
        case .loaded(let orders) where orders.isEmpty:
            Text("Nenhuma ordem aberta nesta carteira.").typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .padding(.horizontal, Space.gutter)
        case .loaded(let orders):
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(orders) { order in row(order) }
                }
                if !canSign {
                    Text("Esta carteira só acompanha: para cancelar, abra a carteira que assina.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                }
            }
        }
    }

    private func row(_ order: OpenOrder) -> some View {
        Button { choosing = order } label: {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: order.sell?.coingeckoID, symbol: order.sell?.symbol ?? "?", size: 40, network: chain)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vende \(Self.amount(order.remainingSell, order.sell))").typeStyle(.row).foregroundStyle(Palette.ink)
                    Text("por no mínimo \(Self.amount(order.minimumBuy, order.buy))").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                Spacer(minLength: Space.sm)
                Text(Self.expiry(order.expiresAt)).typeStyle(.note).foregroundStyle(Palette.inkSoft).multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowStyle())
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
