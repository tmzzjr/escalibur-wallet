import SwiftUI

/// A escala tipografica. Uma familia so (SF Pro do sistema), e nada fora desta lista.
///
/// Numero que muda ao vivo ou fica em coluna leva `.monospacedDigit()`: so os
/// digitos ganham largura fixa, letras e "R$" continuam proporcionais. Isso nao e
/// fonte monoespacada. Mono de verdade existe em dois estilos, e so para endereco e
/// palavra da frase.
enum TypeStyle {
    case hero, display, figure, key, title, heading, action, row, body, note, label, axis, mono, monoSmall

    var font: Font {
        switch self {
        case .hero: return .system(size: 34, weight: .bold)
        case .display: return .system(size: 40, weight: .bold).monospacedDigit()
        case .figure: return .system(size: 32, weight: .bold).monospacedDigit()
        case .key: return .system(size: 30, weight: .medium)
        case .title: return .system(size: 24, weight: .bold)
        case .heading: return .system(size: 20, weight: .semibold)
        case .action: return .system(size: 17, weight: .semibold)
        case .row: return .system(size: 16, weight: .semibold).monospacedDigit()
        case .body: return .system(size: 15, weight: .regular)
        case .note: return .system(size: 13, weight: .regular).monospacedDigit()
        case .label: return .system(size: 12, weight: .semibold)
        case .axis: return .system(size: 11, weight: .medium).monospacedDigit()
        case .mono: return .system(size: 16, weight: .medium, design: .monospaced)
        case .monoSmall: return .system(size: 13, weight: .regular, design: .monospaced)
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

extension View {
    func typeStyle(_ style: TypeStyle) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

extension Text {
    func style(_ style: TypeStyle) -> Text {
        font(style.font).tracking(style.tracking)
    }
}
