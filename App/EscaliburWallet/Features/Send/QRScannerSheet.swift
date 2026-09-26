import AVFoundation
import SwiftUI
import VisionKit

/// Le um QR pela camera. Nenhuma imagem e guardada; so o texto do codigo sai daqui.
struct QRScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if DataScannerViewController.isSupported, DataScannerViewController.isAvailable, !denied {
                Scanner(onScan: onScan).ignoresSafeArea()
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Para ler o QR, o app precisa da câmera.").typeStyle(.row).foregroundStyle(Palette.ink)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link(destination: url) {
                            Text("Abrir Ajustes do iPhone").typeStyle(.action).frame(maxWidth: .infinity).frame(height: Height.secondary)
                        }
                        .buttonStyle(SecondaryStyle())
                    }
                }
                .padding(Space.gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.void)
            }
            SecondaryButton(title: "Cancelar") { dismiss() }.padding(Space.gutter)
        }
        .task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined { denied = !(await AVCaptureDevice.requestAccess(for: .video)) }
            else { denied = status != .authorized }
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
