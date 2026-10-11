import EscaliburNetwork
import Foundation

/// A busca de Receber no CoinGecko (`CoinCatalog`): so o que o dono digitou, e as redes
/// de uma moeda quando ele toca nela. Guarda as respostas na memoria enquanto o app esta
/// aberto: voltar a uma busca ou a uma moeda nao pergunta de novo.
@MainActor
@Observable
final class CoinSearchStore {
    static let shared = CoinSearchStore()

    enum Status: Equatable {
        case loading
        /// O CoinGecko limitou (429) ou nao respondeu: tentando de novo.
        case retrying
        case loaded([CoinSearchResult])
        case failed
    }

    private(set) var searches: [String: Status] = [:]
    private(set) var coins: [String: CatalogCoin] = [:]
    private(set) var coinFailures: Set<String> = []
    /// Moedas cujas redes estao esperando o CoinGecko liberar (429).
    private(set) var coinRetrying: Set<String> = []

    /// Espera antes de cada tentativa, em segundos: a primeira na hora. O limite por IP do
    /// CoinGecko sem chave dura por volta de um minuto, e as tentativas cobrem esse tempo.
    static let retryDelays: [Double] = [0, 4, 10, 20, 30]

    static func key(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func status(_ query: String) -> Status? { searches[Self.key(query)] }

    /// Chamada pela tela a cada mudanca do texto, dentro de uma tarefa que o SwiftUI
    /// cancela quando o texto muda de novo: a espera curta antes de perguntar evita uma
    /// chamada por letra.
    func search(_ query: String) async {
        let key = Self.key(query)
        guard key.count >= 2 else { return }
        if case .loaded? = searches[key] { return }
        searches[key] = .loading
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else {
            searches[key] = nil
            return
        }
        for (attempt, delay) in Self.retryDelays.enumerated() {
            if attempt > 0 {
                searches[key] = .retrying
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else {
                    searches[key] = nil
                    return
                }
            }
            if let found = try? await CoinCatalog.search(key) {
                searches[key] = .loaded(found)
                return
            }
            guard !Task.isCancelled else {
                searches[key] = nil
                return
            }
        }
        searches[key] = .failed
    }

    func retry(_ query: String) { searches[Self.key(query)] = nil }

    /// As redes de uma moeda, lidas uma vez por abertura do app.
    func coin(_ id: String) async {
        guard coins[id] == nil else { return }
        coinFailures.remove(id)
        defer { coinRetrying.remove(id) }
        for (attempt, delay) in Self.retryDelays.enumerated() {
            if attempt > 0 {
                coinRetrying.insert(id)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            if let coin = try? await CoinCatalog.coin(id: id) {
                coins[id] = coin
                return
            }
            guard !Task.isCancelled else { return }
        }
        coinFailures.insert(id)
    }
}
