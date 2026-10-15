import SwiftUI

/// A paleta da carteira: a do Escalibur, mais tres matizes que so marcam estado.
///
/// Todo valor aqui e hex solido. Alfa sobre fundos diferentes muda a cor aparente, e
/// um verde que muda de tom entre a lista e a folha e ruido que o olho registra.
/// Especificacao completa em docs/design/sistema-visual.md.
enum Palette {
    // Fundo e superficies, do mais fundo ao mais alto.
    static let void = Color(hex: 0x0B0B0C)
    static let body = Color(hex: 0x151518)
    static let rail = Color(hex: 0x1E1E22)
    static let control = Color(hex: 0x26262B)
    static let edge = Color(hex: 0x2A2A2F)
    static let edgeStrong = Color(hex: 0x3A3A40)

    // Tinta.
    static let ink = Color(hex: 0xF5F5F6)
    static let inkSoft = Color(hex: 0xA8A8AE)
    static let inkMuted = Color(hex: 0x8A8A92)
    static let inkDead = Color(hex: 0x434349)

    // A laca: o unico acento. Acao principal, foco, selecao.
    static let live = Color(hex: 0xF5F5F6)
    static let livePress = Color(hex: 0xC9C9CE)
    static let onLive = Color(hex: 0x070708)

    // Mercado e estado.
    // Alta em lima, a cor da marca junto do roxo (decisao do dono, 27/09/2026).
    static let up = Color(hex: 0xC4F135)
    /// Conferido e aprovado: o verde do sistema no escuro, so para o "tudo certo" de uma
    /// checagem (o lima fica para alta e ganho).
    static let success = Color(hex: 0x32D74B)
    static let upTint = Color(hex: 0x1F260B)
    static let down = Color(hex: 0xFF4D3D)
    static let downTint = Color(hex: 0x2D1413)
    /// Vermelho cheio e saturado para fundo com texto branco (4,6:1); o `down` e para texto e linha.
    static let downSolid = Color(hex: 0xE8112D)
    static let downPress = Color(hex: 0x3C1816)
    static let caution = Color(hex: 0xF5A524)
    // As cores da marca (decisao do dono, 27/09/2026): lima na acao principal, na aba
    // escolhida e na alta; roxo na selecao. Chapadas.
    /// O mesmo rosa do app (11/10/2026: o rosa claro de selecao destoava ao lado do
    /// rosa dos botoes e interruptores).
    static let purple = Color(hex: 0xFF007B)
    /// O roxo do icone do app, mais vivo que o de selecao.
    static let brand = Color(hex: 0xFF007B)
    static let purpleDeep = Color(hex: 0x99004A)
    static let lime = Color(hex: 0xC4F135)
    static let limePress = Color(hex: 0xA8D21F)
    static let onLime = Color(hex: 0x0B0D05)
    /// A cor do app na acao principal, na aba escolhida, nos interruptores e na
    /// selecao (decisao do dono, 11/10/2026: o rosa no lugar do lima, que fica so para
    /// alta e ganho). Texto branco por cima.
    static let accent = Color(hex: 0xFF007B)
    static let accentPress = Color(hex: 0xD10065)
    static let onAccent = Color.white
    static let cautionTint = Color(hex: 0x2C210F)
    /// Marca-texto das pontas do endereco (pedido do dono, 14/10/2026: amarelo no lugar do
    /// rosa, que e a cor das acoes). Letra escura por cima, legivel na placa clara e no fundo escuro.
    static let highlight = Color(hex: 0xFFD60A)
    static let onHighlight = Color(hex: 0x0B0B0C)

    // A placa clara: so onde se confere caractere por caractere.
    static let plateInk = Color(hex: 0x070708)
    static let plateMuted = Color(hex: 0x5C5C63)
    static let plateRule = Color(hex: 0xDADADF)

    /// Disco atras de logo escuro (XRP, XLM), para ele nao sumir no preto.
    static let logoDisc = Color(hex: 0xE4E4E7)

    /// Pressionado sobre cada superficie.
    static func pressed(on surface: Surface) -> Color {
        switch surface {
        case .void: return body
        case .body: return rail
        case .rail: return edge
        }
    }

    enum Surface { case void, body, rail }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
