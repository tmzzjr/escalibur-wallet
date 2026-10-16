import AVFoundation
import SwiftUI
import VisionKit

/// Le um QR pela camera. Nenhuma imagem e guardada; so o texto do codigo sai daqui.
/// Sem a permissao, a tela explica e leva direto a pagina do app nos Ajustes.
struct QRScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var access: Access = .checking

    enum Access { case checking, allowed, denied, unsupported }

    var body: some View {
        Group {
            switch access {
            case .checking:
                Palette.void.ignoresSafeArea()
            case .allowed:
                ZStack(alignment: .bottom) {
                    Scanner(onScan: onScan).ignoresSafeArea()
                    SecondaryButton(title: String(localized: "Cancelar")) { dismiss() }.padding(Space.gutter)
                }
            case .denied, .unsupported:
                CameraAccessView(unsupported: access == .unsupported) { dismiss() }
            }
        }
        .task { await check() }
        // Quem volta dos Ajustes com a camera ligada ja encontra o leitor.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, access == .denied { Task { await check() } }
        }
    }

    private func check() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-camera-negada") { access = .denied; return }
        #endif
        guard DataScannerViewController.isSupported else { access = .unsupported; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: access = DataScannerViewController.isAvailable ? .allowed : .denied
        case .notDetermined: access = await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
        default: access = .denied
        }
    }

    private struct Scanner: UIViewControllerRepresentable {
        let onScan: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let controller = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])],
                qualityLevel: .balanced, recognizesMultipleItems: false,
                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true
            )
            controller.delegate = context.coordinator
            try? controller.startScanning()
            return controller
        }

        func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onScan: (String) -> Void
            var done = false
            init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

            func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
                guard !done else { return }
                for item in items {
                    if case .barcode(let code) = item, let text = code.payloadStringValue, text.count <= 512 {
                        done = true
                        scanner.stopScanning()
                        onScan(text)
                        return
                    }
                }
            }
        }
    }
}

/// Sem camera: o visor que procura um QR, o que o app faz com a camera e o caminho nos
/// Ajustes, com o interruptor da Camera ligando. "Abrir Ajustes" usa o unico link
/// publico (`openSettingsURLString`): no iOS 17 ele cai na pagina do app; no iOS 26 cai
/// na raiz dos Ajustes (conferido no simulador 26.5, 15/10/2026), e por isso a tela
/// diz o caminho inteiro. Os atalhos `App-Prefs:` sao privados e a Apple recusa.
private struct CameraAccessView: View {
    let unsupported: Bool
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var switchOn = false

    /// Do iOS 18 em diante, a pagina de cada app fica em Ajustes, Apps.
    static var path: String {
        if #available(iOS 18, *) { return String(localized: "Em Ajustes, Apps, Escalibur, ligue:") }
        return String(localized: "Nos Ajustes da Escalibur, ligue:")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.lg)
            Viewfinder(reduceMotion: reduceMotion)
                .frame(width: 180, height: 180)
                .accessibilityHidden(true)
            Text(unsupported ? "Este iPhone não lê QR pela câmera" : "Libere a câmera para ler o QR")
                .typeStyle(.title).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .padding(.top, Space.lg)
            Text(unsupported ? "Cole ou digite o endereço no campo." : "A câmera só lê o código, aqui no iPhone. Nenhuma imagem é guardada nem sai do aparelho.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.xs)
            if !unsupported {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(Self.path).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.sm) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: 0x8E8E93)))
                        Text("Câmera").typeStyle(.row).foregroundStyle(Palette.ink)
                        Spacer(minLength: Space.sm)
                        SettingsSwitch(on: switchOn)
                    }
                    .padding(.horizontal, Space.md)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                }
                .padding(.top, Space.lg)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: Space.lg)
            if unsupported {
                PrimaryButton(title: String(localized: "Voltar")) { onCancel() }
            } else {
                PrimaryButton(title: String(localized: "Abrir Ajustes")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("abrir-ajustes-camera")
                TertiaryButton(title: String(localized: "Agora não")) { onCancel() }
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.void.ignoresSafeArea())
        .task {
            guard !unsupported else { return }
            if reduceMotion { switchOn = true; return }
            // O interruptor liga, espera, desliga sem animacao e liga de novo.
            while !Task.isCancelled {
                switchOn = false
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { switchOn = true }
                try? await Task.sleep(for: .seconds(2.6))
            }
        }
    }
}

/// O interruptor do iOS, desenhado: verde ligado, cinza desligado.
private struct SettingsSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Palette.success : Palette.control)
            .frame(width: 51, height: 31)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 27, height: 27).padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
    }
}

/// O visor: os quatro cantos de mira em volta de um QR desenhado, e uma linha que corre
/// de cima a baixo. Com Reduzir Movimento, parado.
private struct Viewfinder: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let sweep = reduceMotion ? 0.5 : (sin(t * 2 * .pi / 2.6) + 1) / 2
            let breathe = reduceMotion ? 1 : 1 + 0.025 * sin(t * 2 * .pi / 2.6)
            Canvas { context, size in
                let side = min(size.width, size.height)
                let qr = CGRect(x: side * 0.2, y: side * 0.2, width: side * 0.6, height: side * 0.6)
                Self.drawCode(in: qr, context: context)
                // A linha que le, com um rastro suave.
                let y = qr.minY + qr.height * sweep
                context.fill(Path(CGRect(x: qr.minX - 6, y: y - 18, width: qr.width + 12, height: 18)),
                             with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.10)]),
                                                   startPoint: CGPoint(x: 0, y: y - 18), endPoint: CGPoint(x: 0, y: y)))
                context.fill(Path(roundedRect: CGRect(x: qr.minX - 6, y: y - 1, width: qr.width + 12, height: 2), cornerRadius: 1),
                             with: .color(Palette.ink))
                // Os cantos da mira.
                let inset = side * 0.04
                let arm = side * 0.2
                let frame = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
                var corners = Path()
                for (corner, dx, dy) in [(CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
                                         (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0)] {
                    corners.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
                    corners.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * 10))
                    corners.addQuadCurve(to: CGPoint(x: corner.x + dx * 10, y: corner.y), control: corner)
                    corners.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                }
                context.stroke(corners, with: .color(Palette.ink), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            .scaleEffect(breathe)
        }
    }

    /// Um QR de enfeite: tres olhos nos cantos e modulos fixos (nao e um codigo valido).
    private static let modules: [(Int, Int)] = {
        var cells: [(Int, Int)] = []
        var seed: UInt32 = 0x9E3779B9
        for row in 0..<21 {
            for column in 0..<21 {
                let inEye = (row < 8 && column < 8) || (row < 8 && column > 12) || (row > 12 && column < 8)
                seed = seed &* 1_664_525 &+ 1_013_904_223
                if !inEye, seed >> 29 < 4 { cells.append((row, column)) }
            }
        }
        return cells
    }()

    private static func drawCode(in rect: CGRect, context: GraphicsContext) {
        let cell = rect.width / 21
        let ink = GraphicsContext.Shading.color(Palette.inkSoft.opacity(0.55))
        for (row, column) in modules {
            context.fill(Path(roundedRect: CGRect(x: rect.minX + CGFloat(column) * cell + 0.5, y: rect.minY + CGFloat(row) * cell + 0.5,
                                                  width: cell - 1, height: cell - 1), cornerRadius: cell * 0.25), with: ink)
        }
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 14, y: 0), CGPoint(x: 0, y: 14)] {
            let outer = CGRect(x: rect.minX + origin.x * cell, y: rect.minY + origin.y * cell, width: cell * 7, height: cell * 7)
            context.stroke(Path(roundedRect: outer.insetBy(dx: cell / 2, dy: cell / 2), cornerRadius: cell * 1.2),
                           with: .color(Palette.ink.opacity(0.8)), lineWidth: cell)
            context.fill(Path(roundedRect: outer.insetBy(dx: cell * 2, dy: cell * 2), cornerRadius: cell * 0.6),
                         with: .color(Palette.ink.opacity(0.8)))
        }
    }
}
