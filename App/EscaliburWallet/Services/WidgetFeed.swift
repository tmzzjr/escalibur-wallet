import EscaliburNetwork
import Foundation
import UIKit
import WidgetKit

/// Escreve o que os widgets mostram (`WidgetSnapshot`): a ultima moeda que o dono abriu
/// ou que chegou na carteira, com o preco, a variacao e a linha de 24 horas.
///
/// A pagina da moeda ja baixou o grafico do dia: o widget aproveita, sem chamada nova.
/// No segundo plano (o mesmo despertar dos alertas de preco), o preco e a linha da moeda
/// do widget sao lidos de novo nos mesmos servicos de preco do app.
///
/// O que entra no arquivo e publico: qual moeda e quanto ela vale. Este servico nao le
/// cofre, chaveiro, metadados nem saldo (tools/verificar.sh confere). O arquivo fica na
/// pasta do App Group, fora do backup, legivel depois do primeiro desbloqueio, para o
/// widget da tela bloqueada conseguir ler; apagar o app apaga a pasta.
@MainActor
final class WidgetFeed {
    static let shared = WidgetFeed()
    static let kind = "preco-recente"

    /// A pagina da moeda atualiza o preco a cada 15 segundos: o widget so e regravado
    /// quando a moeda muda ou a cada 5 minutos.
    private static let minimumInterval: TimeInterval = 300

    /// A pagina de uma moeda mostrou o grafico de 24 horas: ela vira a do widget.
    func viewed(coinID: String, symbol: String, name: String, points: [PricePoint], price: Double?, change: Double?, currency: Fmt.Currency) {
        guard let price = price ?? points.last?.price else { return }
        let current = WidgetSnapshot.read()
        if let current, current.coinID == coinID, current.currency == currency.rawValue,
           Date().timeIntervalSince(current.updated) < Self.minimumInterval {
            return
        }
        write(coinID: coinID, symbol: symbol, name: name, reason: .viewed, price: price, change: change,
              points: points, currency: currency, previous: current)
    }

    /// Chegou moeda na carteira (aviso de recebimento): o widget passa a mostrar ela. Le
    /// o preco e a linha do dia, na moeda que o widget ja usa.
    func received(coinID: String, symbol: String, name: String) async {
        let current = WidgetSnapshot.read()
        let currency = current.flatMap { Fmt.Currency(rawValue: $0.currency) } ?? Fmt.Currency(rawValue: Settings.regionCurrency.uppercased()) ?? .usd
        await load(coinID: coinID, symbol: symbol, name: name, reason: .received, currency: currency, previous: current)
    }

    /// Segundo plano: a moeda do widget com o preco de agora.
    func refresh() async {
        guard let current = WidgetSnapshot.read(), let currency = Fmt.Currency(rawValue: current.currency) else { return }
        await load(coinID: current.coinID, symbol: current.symbol, name: current.name, reason: current.reason, currency: currency, previous: current)
    }

    private func load(coinID: String, symbol: String, name: String, reason: WidgetSnapshot.Reason, currency: Fmt.Currency, previous: WidgetSnapshot?) async {
        let id = currency.coingeckoID
        guard let points = try? await MarketService.shared.chart(id: coinID, currency: id, range: .day), !points.isEmpty else { return }
        let quote = await MarketService.shared.alertQuotes(ids: [coinID], currency: id)[coinID]
        write(coinID: coinID, symbol: symbol, name: name, reason: reason, price: quote?.price ?? points.last?.price ?? 0,
              change: quote?.change24h, points: points, currency: currency, previous: previous)
    }

    private func write(
        coinID: String, symbol: String, name: String, reason: WidgetSnapshot.Reason, price: Double, change: Double?,
        points: [PricePoint], currency: Fmt.Currency, previous: WidgetSnapshot?
    ) {
        guard price.isFinite, price > 0, let file = WidgetSnapshot.file else { return }
        let snapshot = WidgetSnapshot(
            coinID: coinID, symbol: String(symbol.prefix(12)), name: String(name.prefix(40)), reason: reason,
            currency: currency.rawValue,
            priceText: Fmt.price(price, currency),
            shortPriceText: price >= 10_000 ? Fmt.compact(price, currency) : Fmt.price(price, currency),
            changeText: change.map(Fmt.percent) ?? "",
            change: change,
            points: Self.thin(points.map(\.price)),
            updated: .now
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            Self.excludeFromBackup(file)
            if previous?.coinID != coinID { writeLogo(coinID) }
        } catch {
            return
        }
        WidgetCenter.shared.reloadTimelines(ofKind: Self.kind)
    }

    /// Apagar tudo: o widget perde a ultima moeda e o logo dela e volta ao exemplo, e o
    /// segundo plano deixa de ter widget para atualizar (auditoria de 15/10, N3).
    static func erase() {
        for url in [WidgetSnapshot.file, WidgetSnapshot.logo].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    /// O logo embarcado da moeda, para o widget (que nao tem os logos do app).
    private func writeLogo(_ coinID: String) {
        guard let url = WidgetSnapshot.logo else { return }
        guard let png = UIImage(named: "logo-\(coinID)")?.pngData() else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? png.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        Self.excludeFromBackup(url)
    }

    private static func excludeFromBackup(_ url: URL) {
        var copy = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? copy.setResourceValues(values)
    }

    /// Ate 48 pontos, mantendo o primeiro e o ultimo.
    static func thin(_ values: [Double]) -> [Double] {
        let clean = values.filter { $0.isFinite && $0 > 0 }
        guard clean.count > 48 else { return clean }
        let step = Double(clean.count - 1) / 47
        return (0..<48).map { clean[Int((Double($0) * step).rounded())] }
    }
}
