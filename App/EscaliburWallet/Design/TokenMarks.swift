import EscaliburChains
import SwiftUI

/// O selo de um token que nao e da lista conferida: "Custom" (o dono adicionou),
/// "Não verificado" (chegou na conta) ou "Suspeito" (cara de golpe). Texto em caixa
/// normal, sem cor de marca: a cor so aparece no suspeito, em ambar.
struct TokenBadge: View {
    enum Kind { case custom, unverified, suspicious }
    let kind: Kind

    var body: some View {
        Text(title)
            .typeStyle(.label)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: Height.badge)
            .background(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous).fill(background))
            .accessibilityLabel(title)
    }

    private var title: String {
        switch kind {
        case .custom: return "Custom"
        case .unverified: return "Não verificado"
        case .suspicious: return "Suspeito"
        }
    }

    private var foreground: Color {
        switch kind {
        case .custom: return Palette.ink
        case .unverified: return Palette.inkSoft
        case .suspicious: return Palette.caution
        }
    }

    private var background: Color {
        switch kind {
        case .custom: return Palette.control
        case .unverified: return Palette.rail
        case .suspicious: return Palette.cautionTint
        }
    }

    init(_ kind: Kind) { self.kind = kind }

    /// O selo de um ativo, ou nenhum para a lista conferida.
    init?(asset: Asset, suspicious: Bool = false) {
        if suspicious { kind = .suspicious; return }
        switch asset.origin {
        case .custom: kind = .custom
        case .discovered: kind = .unverified
        case nil: return nil
        }
    }
}

/// O que a tela diz de cada motivo de suspeita.
enum TokenReasonText {
    static func text(_ reason: TokenSafety.Reason) -> String {
        switch reason {
        case .link: return "O nome ou o símbolo traz um site ou um @. É o jeito mais comum de levar alguém a uma página que pede a senha da carteira."
        case .bait: return "O nome usa isca: resgate, prêmio, bônus, airdrop, visite."
        case .imitation: return "O símbolo imita o de uma moeda conhecida, com outro contrato."
        case .dust: return "Chegou uma quantia mínima sem você pedir. Serve para o endereço de quem mandou aparecer no seu histórico."
        case .flaggedBySource: return "A própria fonte da rede marca este token como golpe."
        case .hiddenCharacters: return "O nome tem caracteres invisíveis ou que invertem o texto."
        }
    }

    /// O aviso que vale para todo token fora da lista.
    static let anyoneCanCreate = "Qualquer pessoa cria um token com qualquer nome e qualquer símbolo. Este não está na lista conferida da Escalibur: o nome e o símbolo foram escritos por quem criou o contrato. Não abra sites que aparecem no nome e não conecte esta carteira a nada que o token peça."
}

/// Letras do simbolo para o logo de um token sem logo embarcado: so letras e digitos
/// ASCII, ate dois. Simbolo de golpe com letra cirilica ou emoji nao chega ao logo.
enum TokenGlyph {
    static func letters(_ symbol: String) -> String {
        String(symbol.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.prefix(2).map(Character.init)).uppercased()
    }
}
