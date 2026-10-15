import SwiftUI
import UIKit
import WidgetKit

/// Os widgets da Escalibur: o preco da ultima moeda que o dono abriu ou recebeu, na tela
/// bloqueada (linha, circulo e retangulo) e na tela de inicio (pequeno e medio).
///
/// O widget so le o arquivo que o app grava (`WidgetSnapshot`): nao fala com a rede, nao
/// le a carteira e nao formata nada (tools/verificar.sh confere). Sem arquivo, mostra o
/// exemplo na galeria e, ja instalado, pede para abrir uma moeda no app.
@main
struct EscaliburWidgets: WidgetBundle {
    var body: some Widget {
        PriceWidget()
    }
}

struct PriceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "preco-recente", provider: PriceProvider()) { entry in
            FamilyReader(entry: entry)
        }
        .configurationDisplayName(String(localized: "Preço recente"))
        .description(String(localized: "O preço da última moeda que você abriu ou recebeu na Escalibur."))
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular, .systemSmall, .systemMedium])
    }
}

/// Le o tamanho do widget e passa adiante: o desenho (`PriceWidgetView`) recebe o tamanho
/// como valor, para o app conseguir mostrar os cinco numa tela de teste.
struct FamilyReader: View {
    @Environment(\.widgetFamily) private var family
    let entry: PriceEntry

    var body: some View {
        PriceWidgetView(entry: entry, family: family)
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium { WidgetColor.void } else { Color.clear }
            }
    }
}

struct PriceProvider: TimelineProvider {
    func placeholder(in context: Context) -> PriceEntry {
        PriceEntry(date: .now, snapshot: .sample, logo: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PriceEntry) -> Void) {
        completion(Self.current() ?? PriceEntry(date: .now, snapshot: .sample, logo: nil))
    }

    /// Uma entrada so: quem atualiza e o app, quando grava o arquivo.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PriceEntry>) -> Void) {
        completion(Timeline(entries: [Self.current() ?? PriceEntry(date: .now, snapshot: nil, logo: nil)], policy: .never))
    }

    static func current() -> PriceEntry? {
        guard let snapshot = WidgetSnapshot.read() else { return nil }
        let logo = WidgetSnapshot.logo.flatMap { url -> UIImage? in
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 512 * 1024 else { return nil }
            return UIImage(contentsOfFile: url.path)
        }
        return PriceEntry(date: .now, snapshot: snapshot, logo: logo)
    }
}

