import SwiftUI
import UIKit

/// A escala tipografica. Uma familia so (SF Pro do sistema), e nada fora desta lista.
///
/// Numero que muda ao vivo ou fica em coluna leva `.monospacedDigit()`: so os
/// digitos ganham largura fixa, letras e "R$" continuam proporcionais. Isso nao e
/// fonte monoespacada. Mono de verdade existe em dois estilos, e so para endereco e
/// palavra da frase.
enum TypeStyle {
    case hero, display, figure, key, title, heading, action, row, body, note, label, axis, mono, monoSmall

    /// Tamanho no tamanho de texto padrao do iPhone.
    var baseSize: CGFloat {
        switch self {
        case .hero: return 34
        case .display: return 40
        case .figure: return 32
        case .key: return 30
        case .title: return 24
        case .heading: return 20
        case .action: return 17
        case .row, .mono: return 16
        case .body: return 15
        case .note, .monoSmall: return 13
        case .label: return 12
        case .axis: return 11
        }
    }

    private var weight: Font.Weight {
        switch self {
        case .hero, .display, .figure, .title: return .bold
        case .key, .axis, .mono: return .medium
        case .heading, .action, .row, .label: return .semibold
        case .body, .note, .monoSmall: return .regular
        }
    }

    /// O estilo do sistema que dita quanto este cresce com o tamanho de texto do dono.
    private var textStyle: UIFont.TextStyle {
        switch self {
        case .hero, .display: return .largeTitle
        case .figure, .key: return .title1
        case .title: return .title2
        case .heading: return .title3
        case .action: return .headline
        case .row, .body, .mono: return .body
        case .note, .monoSmall: return .footnote
        case .label: return .caption1
        case .axis: return .caption2
        }
    }

    /// Quanto pode crescer. Saldo e titulo grandes crescem menos: a 34 pt, o dobro
    /// ja nao cabe numa linha do iPhone.
    private var maxScale: CGFloat {
        switch self {
        case .hero, .display, .figure, .key: return 1.3
        case .title, .heading: return 1.6
        case .axis: return 1.4
        default: return 2.2
        }
    }

    /// No tamanho de texto padrao. Para quem so precisa da fonte, sem acompanhar o ajuste.
    var font: Font { font(size: baseSize) }

    /// No tamanho de texto que o dono escolheu no iPhone (Dynamic Type).
    func font(for dynamicType: DynamicTypeSize) -> Font {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicType))
        let scaled = UIFontMetrics(forTextStyle: textStyle).scaledValue(for: baseSize, compatibleWith: traits)
        return font(size: min(scaled, baseSize * maxScale))
    }

    private func font(size: CGFloat) -> Font {
        switch self {
        case .mono, .monoSmall: return .system(size: size, weight: weight, design: .monospaced)
        case .display, .figure, .row, .note, .axis: return .system(size: size, weight: weight).monospacedDigit()
        default: return .system(size: size, weight: weight)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .hero: return -0.8
        case .display: return -1.0
        case .figure: return -0.6
        case .title: return -0.6
        case .heading: return -0.3
        case .row: return -0.1
        default: return 0
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .body: return 4
        case .note: return 3
        case .title, .hero: return 2
        default: return 0
        }
    }
}

/// Aplica o estilo acompanhando o tamanho de texto do iPhone.
struct TypeStyleModifier: ViewModifier {
    let style: TypeStyle
    @Environment(\.dynamicTypeSize) private var dynamicType

    func body(content: Content) -> some View {
        content
            .font(style.font(for: dynamicType))
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

extension View {
    func typeStyle(_ style: TypeStyle) -> some View {
        modifier(TypeStyleModifier(style: style))
    }
}

extension Text {
    func style(_ style: TypeStyle) -> Text {
        font(style.font).tracking(style.tracking)
    }
}
