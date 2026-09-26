import CryptoKit
import SwiftUI

/// A espada do Escalibur, como geometria. Proporcoes medidas no icone de 1024 do
/// app irmao; a carteira usa a mesma forma para a familia se ler sem peca nova.
struct EscaliburMark: Shape {
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let x = { (t: CGFloat) in rect.minX + t * w }
        let shift: CGFloat = closed ? -0.088 : 0
        let y = { (t: CGFloat) in rect.minY + (t + shift) * h }
        var path = Path()
        path.addRect(CGRect(x: x(0.4297), y: y(0.2900), width: w * 0.1396, height: h * 0.0616))  // pomo
        path.addRect(CGRect(x: x(0.4639), y: y(0.3516), width: w * 0.0713, height: h * 0.1435))  // punho
        path.addRect(CGRect(x: x(0.2041), y: y(0.4951), width: w * 0.5908, height: h * 0.0488))  // travessao
        let bladeBottom: CGFloat = closed ? 0.94 : 1.0
        path.addRect(CGRect(x: x(0.4375), y: y(0.5439), width: w * 0.1240, height: h * (bladeBottom - 0.5439)))  // lamina
        return path
    }
}

/// O selo da carteira: a inversao do icone do Escalibur (laca com espada preta).
struct WalletBadge: View {
    var size: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        shape
            .fill(Palette.live)
            .frame(width: size, height: size)
            .overlay { EscaliburMark().fill(Palette.onLive) }
            .clipShape(shape)
            .accessibilityHidden(true)
    }
}

/// A marca de uma carteira: o glifo 4x4 do Escalibur, derivado do identificador.
/// Monocromatico, estavel para sempre, e nunca um avatar de cor sorteada.
struct WalletGlyph: View {
    let id: UUID
    var size: CGFloat = 36
    var selected: Bool = false

    private var bits: [Bool] {
        let digest = SHA256.hash(data: withUnsafeBytes(of: id.uuid) { Data($0) })
        let two = Array(digest.prefix(2))
        return (0..<16).map { index in (two[index / 8] >> UInt8(7 - index % 8)) & 1 == 1 }
    }

    var body: some View {
        let cell = size * 0.16
        let gap = size * 0.04
        RoundedRectangle(cornerRadius: size <= 24 ? 6 : Radius.card, style: .continuous)
            .fill(Palette.rail)
            .frame(width: size, height: size)
            .overlay {
                VStack(spacing: gap) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<4, id: \.self) { column in
                                Rectangle()
                                    .fill(bits[row * 4 + column] ? (selected ? Palette.ink : Palette.inkMuted) : .clear)
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

/// A placa clara, com o canto superior direito chanfrado a 45 graus. Aparece so no
/// que se confere caractere por caractere: palavras da frase, QR de receber, destino
/// na revisao de envio.
struct LacquerPlate: Shape {
    var cut: CGFloat = 24
    var radius: CGFloat = Radius.button

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = radius
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
