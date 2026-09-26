import SwiftUI
import UIKit

/// A cor que predomina no logo de uma moeda, tirada do proprio arquivo embarcado.
///
/// O logo e reduzido a 32 x 32 e cada pixel opaco cai numa caixa de cor (4 bits por
/// canal). Vence a caixa mais cheia entre as cores com saturacao; logo so de cinza
/// (o X do XRP, o losango do ETH) fica com o cinza mais frequente, clareado para
/// aparecer no fundo escuro. Calculado uma vez por moeda.
@MainActor
enum LogoColor {
    private static var cache: [String: Color] = [:]

    static func dominant(for coingeckoID: String?) -> Color {
        guard let id = coingeckoID else { return Palette.inkMuted }
        if let cached = cache[id] { return cached }
        let color = UIImage(named: "logo-\(id)").flatMap(compute) ?? Palette.inkMuted
        cache[id] = color
        return color
    }

    private static func compute(_ image: UIImage) -> Color? {
        let side = 32
        guard let cg = image.cgImage,
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var saturated: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        var neutral: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for index in 0..<(side * side) {
            let alpha = Int(pixels[index * 4 + 3])
            guard alpha > 200 else { continue }
            let r = Int(pixels[index * 4]), g = Int(pixels[index * 4 + 1]), b = Int(pixels[index * 4 + 2])
            let high = max(r, g, b), low = min(r, g, b)
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            if high > 40, high - low > 48 {
                let entry = saturated[key] ?? (0, 0, 0, 0)
                saturated[key] = (entry.count + 1, entry.r + r, entry.g + g, entry.b + b)
            } else {
                let entry = neutral[key] ?? (0, 0, 0, 0)
                neutral[key] = (entry.count + 1, entry.r + r, entry.g + g, entry.b + b)
            }
        }
        if let best = saturated.values.max(by: { $0.count < $1.count }), best.count >= 12 {
            return Color(red: Double(best.r) / Double(best.count) / 255, green: Double(best.g) / Double(best.count) / 255,
                         blue: Double(best.b) / Double(best.count) / 255)
        }
        guard let gray = neutral.values.max(by: { $0.count < $1.count }) else { return nil }
        let level = Double(gray.r + gray.g + gray.b) / Double(gray.count * 3) / 255
        // Preto some no fundo escuro; branco puro brilha demais. Cinza visivel.
        return Color(white: min(max(level, 0.55), 0.85))
    }
}
