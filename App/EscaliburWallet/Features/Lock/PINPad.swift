import EscaliburCore
import EscaliburKeys
import SwiftUI

/// O PIN em digitacao. Os digitos vao direto para um buffer seguro de capacidade
/// fixa: o PIN nunca vira `String`, nem `@State` de texto, nem passa por teclado do
/// sistema (que aprende o que se digita).
@MainActor
@Observable
final class PINEntry {
    private(set) var count = 0
    private var buffer = SecureBytes(capacity: PINPolicy.digits)
    var error: String?
    var shake = 0

    func append(_ digit: Int) {
        guard count < PINPolicy.digits else { return }
        buffer.append(UInt8(0x30 + digit))
        count = buffer.count
        error = nil
    }

    func deleteLast() {
        buffer.removeLast(1)
        count = buffer.count
    }

    var isComplete: Bool { count == PINPolicy.digits }

    /// Entrega o PIN digitado (o chamador zera) e comeca um buffer novo.
    func take() -> SecureBytes {
        let taken = buffer
        buffer = SecureBytes(capacity: PINPolicy.digits)
        count = 0
        return taken
    }

    func fail(_ message: String) {
        error = message
        shake += 1
        buffer.wipe()
        count = 0
    }

    func reset() {
        buffer.wipe()
        count = 0
        error = nil
    }
}

/// Os seis pontos. Erro: pontos em vermelho e uma sacudida curta.
struct PINDots: View {
    let filled: Int
    var failed: Bool = false
    var shake: Int = 0

    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<PINPolicy.digits, id: \.self) { index in
                Circle()
                    .fill(failed ? Palette.down : (index < filled ? Palette.ink : Palette.rail))
                    .frame(width: 12, height: 12)
            }
        }
        .modifier(Shake(animatableData: CGFloat(shake)))
        .animation(.easeOut(duration: 0.26), value: shake)
        .accessibilityElement()
        .accessibilityLabel("\(filled) de \(PINPolicy.digits) digitos")
    }
}

private struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 6), y: 0))
    }
}

/// O teclado do PIN: plano, sem letras, com a geometria do Escalibur.
struct PINPad: View {
    let entry: PINEntry
    var biometryIcon: String? = nil
    var onBiometry: (() -> Void)? = nil
    var onComplete: () -> Void

    private let rows: [[Int?]] = [[1, 2, 3], [4, 5, 6], [7, 8, 9], [nil, 0, -1]]

    var body: some View {
        VStack(spacing: 18) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: 26) {
                    ForEach(0..<3, id: \.self) { column in
                        key(rows[row][column], column: column)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func key(_ value: Int?, column: Int) -> some View {
        switch value {
        case .some(-1):
            functionKey(systemImage: "delete.left", label: "Apagar") { entry.deleteLast() }
        case .some(let digit):
            Button {
                entry.append(digit)
                if entry.isComplete { onComplete() }
            } label: {
                Text("\(digit)")
                    .typeStyle(.key)
                    .foregroundStyle(Palette.ink)
                    .frame(width: Height.pinKey, height: Height.pinKey)
            }
            .buttonStyle(PINKeyStyle())
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: entry.count)
            .accessibilityLabel("\(digit)")
            .accessibilityIdentifier("tecla-\(digit)")
        case .none:
            if let biometryIcon, let onBiometry {
                functionKey(systemImage: biometryIcon, label: "Usar Face ID", action: onBiometry)
            } else {
                Color.clear.frame(width: Height.pinKey, height: Height.pinKey)
            }
        }
    }

    private func functionKey(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.inkSoft)
                .frame(width: Height.pinKey, height: Height.pinKey)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

private struct PINKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(configuration.isPressed ? Palette.edge : Palette.rail))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Tela de PIN completa: titulo, texto, pontos, erro, teclado e rodape.
struct PINScreen<Footer: View>: View {
    let title: String
    let subtitle: String?
    let entry: PINEntry
    var biometryIcon: String? = nil
    var onBiometry: (() -> Void)? = nil
    var working = false
    let onComplete: () -> Void
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.lg)
            VStack(spacing: Space.xs) {
                WalletBadge(size: 44).padding(.bottom, Space.md)
                Text(title).typeStyle(.title).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle).typeStyle(.body).foregroundStyle(Palette.inkSoft)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.xl)
                }
            }
            Spacer(minLength: Space.lg)
            ZStack {
                if working {
                    ProgressView().tint(Palette.inkSoft)
                } else {
                    PINDots(filled: entry.count, failed: entry.error != nil, shake: entry.shake)
                }
            }
            .frame(height: 24)
            Text(entry.error ?? " ")
                .typeStyle(.note)
                .foregroundStyle(Palette.down)
                .multilineTextAlignment(.center)
                .frame(minHeight: 40)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.sm)
            Spacer(minLength: Space.md)
            PINPad(entry: entry, biometryIcon: biometryIcon, onBiometry: onBiometry, onComplete: onComplete)
                .disabled(working)
            footer
                .padding(.top, Space.md)
                .padding(.bottom, Space.xs)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.void.ignoresSafeArea())
        .sensoryFeedback(.error, trigger: entry.shake)
    }
}
