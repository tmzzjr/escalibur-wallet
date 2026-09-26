import EscaliburChains
import SwiftUI

/// Os valores do plano que se conferem caractere por caractere (destino, tag, memo,
/// contrato, oferta), exatamente como o planejador os pos na transacao. Envio e troca
/// usam a mesma placa: a revisao mostra o plano, nunca a intencao.
struct PlanVerbatimPlate: View {
    let review: PlanReview

    var body: some View {
        let lines = review.lines.filter(\.verbatim)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(line.label == "Para" ? KnownExchanges.name(for: line.value).map { "Para \($0)" } ?? "Para" : line.label)
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
    static func text(_ warning: PlanReview.Warning, tagNoun: String = "tag") -> String {
        switch warning {
        case .firstSendToAddress: return "Primeira vez que você envia para este endereço."
        case .lookalikeAddress(let known): return "Endereço parecido com \(Fmt.address(known))."
        case .noDestinationTag: return "Sem \(tagNoun)."
        case .destinationIsContract: return "O destino é um contrato, não uma carteira comum."
        case .highFee(let percent): return "A taxa é \(Fmt.grouped(percent, fractionDigits: 1))% do valor."
        case .activatesAccount(let minimum): return "Este envio ativa a conta de destino (mínimo \(minimum))."
        case .unverifiedToken(let symbol): return "\(symbol) não está na lista de tokens verificados."
        case .unlimitedApproval: return "Autorização sem limite."
        case .highPriceImpact(let percent): return "Impacto no preço de \(Fmt.grouped(percent, fractionDigits: 1))%."
        }
    }
}
