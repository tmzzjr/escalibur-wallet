import EscaliburChains
import EscaliburCore
import EscaliburEngines
import SwiftUI

/// A pergunta de refazer uma ordem limite vencida, por cima de qualquer aba, quando o
/// app abre destravado. Refazer abre a revisao de sempre, com a ordem nova montada e
/// conferida pelo motor; nada e assinado sem o dono.
struct LimitRenewalPrompts: ViewModifier {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @State private var reviewing: TradeReviewFlow.Item?
    /// A revisao esperando a folha fechar: apresentar uma por cima da outra que sai
    /// derruba a segunda.
    @State private var queued: TradeReviewFlow.Item?
    @State private var keepRenewing = true
    private var center: LimitRenewalCenter { .shared }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { queued == nil && reviewing == nil && !center.pending.isEmpty },
                set: { shown in
                    // Arrastar para baixo: pergunta de novo so na proxima abertura.
                    if !shown, queued == nil, reviewing == nil { center.postponed.formUnion(center.pending.map(\.id)) }
                }
            ), onDismiss: {
                if let queued {
                    reviewing = queued
                    self.queued = nil
                }
            }) {
                if let due = center.pending.first {
                    LimitRenewalSheet(
                        due: due, more: center.pending.count - 1, marketRate: marketRate(due), keepRenewing: $keepRenewing,
                        onRenew: { renew(due) },
                        onDrop: { center.forget(due.id, session: session) },
                        onLater: { center.postponed.insert(due.id) }
                    )
                }
            }
            .fullScreenCover(item: $reviewing) { item in
                TradeReviewFlow(item: item) { completed in
                    if !completed, let id = item.replacesRenewal { center.postponed.insert(id) }
                    reviewing = nil
                }
            }
            .task(id: session.selectedWallet?.id) { await center.refresh(session: session) }
    }

    /// Quanto 1 unidade do vendido vale no comprado, pelos precos do app.
    private func marketRate(_ due: DueRenewal) -> Double? {
        guard let sell = due.sell.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }),
              let buy = due.buy.coingeckoID.flatMap({ portfolio.quotes[$0]?.price }), sell > 0, buy > 0 else { return nil }
        return sell / buy
    }

    private func renew(_ due: DueRenewal) {
        guard let wallet = session.selectedWallet, let account = wallet.account(due.chain) else { return }
        let request = LimitOrderRequest(
            walletID: wallet.id, chain: due.chain, account: account, sell: due.sell, buy: due.buy, amountIn: due.amountIn,
            minimumOut: due.minimumOut, validFor: due.record.validFor
        )
        let fiat = due.sell.coingeckoID.flatMap { portfolio.quotes[$0]?.price }.map { Fmt.double(due.amountIn, decimals: due.sell.decimals) * $0 }
        queued = TradeReviewFlow.Item(kind: .limit(request), chain: due.chain, fiat: fiat, renewLimit: keepRenewing,
                                      replacesRenewal: due.record.orderID)
    }
}

/// Uma ordem vencida: o que ela vendia, por quanto, quanto ja tinha saido, e se o
/// mercado ja passou do preco dela.
struct LimitRenewalSheet: View {
    let due: DueRenewal
    let more: Int
    let marketRate: Double?
    @Binding var keepRenewing: Bool
    let onRenew: () -> Void
    let onDrop: () -> Void
    let onLater: () -> Void

    private var targetRate: Double {
        let amount = Fmt.double(due.amountIn, decimals: due.sell.decimals)
        return amount > 0 ? Fmt.double(due.minimumOut, decimals: due.buy.decimals) / amount : 0
    }

    /// O mercado ja paga mais que o preco da ordem: refeita, ela sai na hora.
    private var belowMarket: Bool {
        guard let marketRate, targetRate > 0 else { return false }
        return targetRate < marketRate * 0.98
    }

    static func validity(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 86_400: return String(localized: "1 dia")
        case 604_800: return String(localized: "7 dias")
        case 2_592_000: return String(localized: "30 dias")
        default:
            let days = max(1, Int((seconds / 86_400).rounded()))
            return days == 1 ? String(localized: "1 dia") : String(localized: "\(days) dias")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Uma ordem limite venceu")) { onLater() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Space.sm) {
                        CoinLogo(coingeckoID: due.sell.coingeckoID, symbol: due.sell.symbol, size: 40, network: due.chain, ringColor: Palette.body)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vender \(Fmt.crypto(due.amountIn, decimals: due.sell.decimals, symbol: due.sell.symbol))")
                                .typeStyle(.row).foregroundStyle(Palette.ink)
                            Text("por no mínimo \(Fmt.crypto(due.minimumOut, decimals: due.buy.decimals, symbol: due.buy.symbol))")
                                .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        }
                    }
                    Text("1 \(due.sell.symbol) a \(Fmt.grouped(targetRate, fractionDigits: 6, trimZeros: true)) \(due.buy.symbol), na \(due.chain.name). Refeita, vale por mais \(Self.validity(due.record.validFor)).")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.md)
                    if due.filledFraction > 0 {
                        Text("\(FillRing.percentText(due.filledFraction)) da ordem chegou a sair antes de vencer. Refazer vende o que falta, no mesmo preço.")
                            .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.sm)
                    }
                    if belowMarket {
                        Text("O mercado já paga mais que o preço desta ordem. Refeita agora, ela sai na hora, ao preço de mercado ou melhor.")
                            .typeStyle(.note).foregroundStyle(Palette.caution).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.sm)
                    }
                    Toggle(isOn: $keepRenewing) {
                        Text("Perguntar de novo quando vencer").typeStyle(.row).foregroundStyle(Palette.ink)
                    }
                    .tint(Palette.accent)
                    .padding(.top, Space.lg)
                    Text("Refazer pede o seu Face ID ou PIN: sem você, ninguém assina uma ordem nova com a sua chave.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.xs)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
            }
            VStack(spacing: Space.xs) {
                PrimaryButton(title: String(localized: "Refazer a ordem")) { onRenew() }
                TertiaryButton(title: String(localized: "Não refazer")) { onDrop() }
                if more > 0 {
                    Text(more == 1 ? "Mais 1 ordem vencida depois desta" : "Mais \(more) ordens vencidas depois desta")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xs)
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
        .accessibilityIdentifier("refazer-pergunta")
    }
}
