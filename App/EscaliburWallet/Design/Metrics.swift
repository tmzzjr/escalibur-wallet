import SwiftUI

/// Espaco: oito valores, nada fora. O vao entre blocos e pelo menos 1,75 vez o
/// maior vao dentro deles.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let base: CGFloat = 20
    static let lg: CGFloat = 28
    static let xl: CGFloat = 40
    static let xxl: CGFloat = 64

    /// Margem lateral de toda tela.
    static let gutter: CGFloat = 20
}

/// Raio cresce com o tamanho do objeto. Nunca pilula em botao de acao.
enum Radius {
    static let badge: CGFloat = 6
    static let chip: CGFloat = 8
    static let track: CGFloat = 10
    static let card: CGFloat = 12
    static let button: CGFloat = 14
    static let sheet: CGFloat = 28
}

enum Height {
    static let primary: CGFloat = 56
    static let secondary: CGFloat = 52
    static let row: CGFloat = 64
    static let rowCompact: CGFloat = 52
    static let bar: CGFloat = 44
    static let field: CGFloat = 48
    static let tokenChip: CGFloat = 40
    static let chip: CGFloat = 32
    static let pill: CGFloat = 28
    static let badge: CGFloat = 22
    static let quickAction: CGFloat = 52
    static let pinKey: CGFloat = 78
    static let touch: CGFloat = 44
}

/// Movimento. Reduzir movimento vira fade de 150ms em todo lugar que usa isto.
enum Motion {
    static let press = Animation.easeOut(duration: 0.1)
    static let select = Animation.snappy(duration: 0.22)
    static let number = Animation.snappy(duration: 0.3)
    static let flip = Animation.snappy(duration: 0.24)
    static let fade = Animation.easeInOut(duration: 0.15)
    static let crossfade = Animation.easeInOut(duration: 0.18)
    static let toastIn = Animation.spring(response: 0.3, dampingFraction: 0.86)
}

extension Shape {
    /// Contorno de 1px de verdade sobre o preenchimento.
    func surface(_ fill: Color, edge: Color? = Palette.edge) -> some View {
        self.fill(fill).overlay(self.stroke(edge ?? .clear, lineWidth: 1))
    }
}
