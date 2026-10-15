import Foundation

/// O que os widgets mostram, escrito pelo app e lido pelo widget, na pasta do App Group.
///
/// So dado publico: qual moeda, o preco, a variacao do dia e a linha de 24 horas, ja
/// formatados pelo app (o widget nao formata, nao calcula e nao fala com a rede). Nunca
/// saldo, endereco, carteira, quanto entrou ou de onde. O arquivo abre depois do
/// primeiro desbloqueio, para o widget da tela bloqueada conseguir ler.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Por que esta moeda: a ultima aberta no app, ou a ultima que chegou na carteira.
    enum Reason: String, Codable, Sendable { case viewed, received }

    var coinID: String
    var symbol: String
    var name: String
    var reason: Reason
    /// A moeda dos precos ("BRL", "USD", "EUR"): a do app quando o widget foi gravado.
    var currency: String
    /// "R$ 612.340,12": o preco, no formato e na moeda do app.
    var priceText: String
    /// "R$ 612 mil": para os widgets pequenos da tela bloqueada.
    var shortPriceText: String
    /// "+2,31%", ou vazio sem variacao.
    var changeText: String
    /// Para a cor e a seta: subiu, caiu ou ficou.
    var change: Double?
    /// A linha das ultimas 24 horas, ate 48 pontos, do mais antigo ao mais novo.
    var points: [Double]
    var updated: Date

    static let appGroup = "group.app.escalibur.wallet"
    static let fileName = "widget.json"
    static let logoName = "widget-logo.png"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var file: URL? { directory?.appendingPathComponent(fileName) }
    static var logo: URL? { directory?.appendingPathComponent(logoName) }

    /// O que esta gravado, ou nil (sem arquivo ou ilegivel). Le no maximo 64 KB.
    static func read() -> WidgetSnapshot? {
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Um exemplo para a galeria de widgets, antes de o dono abrir uma moeda: o bitcoin,
    /// no formato da regiao do aparelho.
    static var sample: WidgetSnapshot {
        let money = NumberFormatter()
        money.numberStyle = .currency
        money.currencyCode = "USD"
        money.maximumFractionDigits = 0
        let percent = NumberFormatter()
        percent.numberStyle = .percent
        percent.positivePrefix = "+" + percent.positivePrefix
        percent.minimumFractionDigits = 2
        percent.maximumFractionDigits = 2
        let price = money.string(from: 67_420) ?? "67420"
        return WidgetSnapshot(
            coinID: "bitcoin", symbol: "BTC", name: "Bitcoin", reason: .viewed, currency: "USD",
            priceText: price, shortPriceText: price, changeText: percent.string(from: 0.0231) ?? "+2.31%", change: 2.31,
            points: [61, 62, 61.5, 63, 62.4, 64, 63.2, 65, 64.6, 66, 65.4, 67, 66.8, 68, 67.4],
            updated: .now
        )
    }
}
