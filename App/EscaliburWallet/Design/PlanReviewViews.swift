import EscaliburChains
import SwiftUI

/// Os valores do plano que se conferem caractere por caractere (destino, tag, memo,
/// contrato, oferta), exatamente como o planejador os pos na transacao. Envio e troca
/// usam a mesma placa: a revisao mostra o plano, nunca a intencao.
struct PlanVerbatimPlate: View {
    let review: PlanReview
    /// Na troca e na ordem, os enderecos (destinatario, que e a propria conta, contratos e
    /// quem fica autorizado) ficam atras de um toque. No envio, o destino fica sempre a
    /// vista: e o que a pessoa confere antes de assinar.
    var collapsible = false
    /// No envio, so o destino e o que vai com ele (tag, memo): contrato, mint e emissor do
    /// token ficam de fora (pedido do dono, 14/10/2026).
    var onlyDestination = false
    @State private var expanded = false

    var body: some View {
        let lines = review.lines.filter { $0.verbatim && !(onlyDestination && $0.role == .assetReference) }
        if !lines.isEmpty, collapsible, !expanded {
            Button { withAnimation(Motion.fade) { expanded = true } } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.inkSoft)
                    Text(lines.count == 1 ? "Ver o endereço" : "Ver endereços e contratos (\(lines.count))")
                        .typeStyle(.row).foregroundStyle(Palette.ink)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                }
                .padding(.horizontal, Space.md).frame(minHeight: Height.row)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("revisao-enderecos")
        } else if !lines.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(line.role == .recipient ? KnownExchanges.name(for: line.value).map { String(localized: "Para \($0)") } ?? line.label : line.label)
                            .typeStyle(.note).foregroundStyle(Palette.plateMuted)
                        if Self.looksLikeAddress(line.value) {
                            AddressBlocks(address: line.value, onPlate: true)
                        } else {
                            Text(verbatim: line.value).font(TypeStyle.mono.font).fontWeight(.bold).foregroundStyle(Palette.plateInk)
                        }
                    }
                    .padding(.top, index == 0 ? 0 : Space.xs)
                }
            }
            .padding(Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LacquerPlate(cut: 20).fill(Palette.live))
            .onTapGesture { if collapsible { withAnimation(Motion.fade) { expanded = false } } }
        }
    }

    static func looksLikeAddress(_ value: String) -> Bool {
        value.count >= 26 && !value.contains(" ")
    }
}

/// As demais linhas do plano, rotulo a esquerda e valor a direita.
struct PlanDetailLines: View {
    let review: PlanReview
    var extra: [(String, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array((review.lines.filter { !$0.verbatim }.map { ($0.label, $0.value) } + extra).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top) {
                    Text(line.0).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    Spacer()
                    Text(line.1).typeStyle(.note).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

/// O texto de cada aviso do plano, igual em todas as telas que assinam.
enum PlanWarningText {
    /// O que a rede pede junto do endereco. A frase muda inteira com o nome (genero e
    /// ordem mudam de idioma para idioma), por isso o tipo e nao o substantivo.
    enum TagKind { case tag, memo, comment }

    static func text(_ warning: PlanReview.Warning, tag: TagKind = .tag, chain: Chain? = nil) -> String {
        switch warning {
        case .firstSendToAddress: return String(localized: "Primeira vez que você envia para este endereço.")
        case .lookalikeAddress(let known): return String(localized: "Endereço parecido com \(Fmt.address(known, chain: chain)).")
        case .noDestinationTag:
            switch tag {
            case .tag: return String(localized: "Sem tag de destino. Se o destino for uma exchange, confira na tela de depósito se ela pede: sem isso o valor não chega na sua conta de lá.")
            case .memo: return String(localized: "Sem memo. Se o destino for uma exchange, confira na tela de depósito se ela pede: sem isso o valor não chega na sua conta de lá.")
            case .comment: return String(localized: "Sem comentário. Se o destino for uma exchange, confira na tela de depósito se ela pede: sem isso o valor não chega na sua conta de lá.")
            }
        case .destinationIsContract: return String(localized: "O destino é um contrato, não uma carteira comum.")
        case .highFee(let percent): return String(localized: "A taxa é \(Fmt.grouped(percent, fractionDigits: 1))% do valor.")
        case .activatesAccount(let minimum): return String(localized: "Este envio ativa a conta de destino (mínimo \(minimum)).")
        case .unverifiedToken(let symbol): return String(localized: "\(symbol) não está na lista de tokens verificados.")
        case .unlimitedApproval: return String(localized: "Autorização sem limite.")
        case .highPriceImpact(let percent): return String(localized: "Impacto no preço de \(Fmt.grouped(percent, fractionDigits: 1))%.")
        case .binancePeg(let symbol):
            let original = symbol == "USDC" ? String(localized: "USDC da Circle")
                : symbol == "USDT" ? String(localized: "USDT da Tether") : String(localized: "ETH da rede Ethereum")
            return String(localized: "Na BNB, o \(symbol) é o da Binance (Binance-Peg). Ele vale enquanto a Binance mantiver o lastro e o resgate: não é o \(original).")
        case .publicMempool:
            return String(localized: "Nesta rede a troca passa pela fila pública, sem proteção contra robôs: eles podem comprar antes e vender depois. O mínimo garantido continua valendo, mas o que ficar entre a estimativa e ele pode não chegar.")
        }
    }
}
