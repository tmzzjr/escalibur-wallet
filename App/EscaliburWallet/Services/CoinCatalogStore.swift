import EscaliburNetwork
import Foundation

/// A lista completa de moedas para a busca de Receber (`CoinCatalog`), guardada no
/// aparelho por um dia.
///
/// E publica e igual para todo mundo, sem nada da carteira: fica em Caches (fora do
/// backup), com a protecao padrao do app. Sem rede, vale a ultima guardada. A posicao no
/// mercado e a logo vem da lista da aba Mercado, que o `MarketService` ja guarda.
@MainActor
@Observable
final class CoinCatalogStore {
    static let shared = CoinCatalogStore()

    private(set) var coins: [CatalogCoin] = []
    private(set) var byID: [String: CatalogCoin] = [:]
    /// Id do CoinGecko -> posicao no mercado, para ordenar a busca.
    private(set) var rank: [String: Int] = [:]
    private(set) var images: [String: URL] = [:]
    /// Sem lista nenhuma (nem a guardada): a busca mostra so a lista conferida.
    private(set) var unavailable = false
    private var loading = false
    private var savedAt: Date?

    struct File: Codable {
        let savedAt: Date
        let coins: [CatalogCoin]
    }

    nonisolated static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Catalogo", isDirectory: true).appendingPathComponent("moedas.json")
    }

    nonisolated static func read() -> File? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    nonisolated static func write(_ value: File) {
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    /// Carrega a guardada e, se tem mais de um dia (ou nao ha), baixa de novo.
    func ensureLoaded(currency: String) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if coins.isEmpty, let cached = await Task.detached(priority: .userInitiated, operation: { Self.read() }).value {
            apply(cached.coins, savedAt: cached.savedAt)
        }
        if rank.isEmpty, let snapshot = try? await MarketService.shared.marketSnapshot(currency: currency) {
            for coin in snapshot.coins {
                if let position = coin.rank { rank[coin.id] = position }
                if let image = coin.imageURL { images[coin.id] = image }
            }
        }
        if let savedAt, Date().timeIntervalSince(savedAt) < CoinCatalog.lifetime, savedAt <= Date() { return }
        // O CoinGecko sem chave limita por IP, e o app ja fala com ele na abertura: com
        // 429 ou sem rede, tenta de novo enquanto a tela esta aberta (a tarefa da tela
        // cancela o resto quando ela fecha).
        for (attempt, delay) in Self.retryDelays.enumerated() {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            do {
                let fresh = try await CoinCatalog.fetch()
                let now = Date()
                apply(fresh, savedAt: now)
                Task.detached(priority: .utility) { Self.write(File(savedAt: now, coins: fresh)) }
                return
            } catch {
                // So depois da ultima tentativa a tela diz que nao carregou.
                unavailable = coins.isEmpty && attempt == Self.retryDelays.count - 1
            }
        }
    }

    /// Espera antes de cada tentativa, em segundos: a primeira na hora.
    static let retryDelays: [Double] = [0, 20, 45, 90]

    /// Pre-carga uma vez por dia, longe da rajada de chamadas da abertura do app: quando o
    /// dono abrir Receber, a lista ja esta no aparelho.
    func prefetch(currency: String) {
        guard prefetchTask == nil else { return }
        prefetchTask = Task {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            await ensureLoaded(currency: currency)
        }
    }

    private var prefetchTask: Task<Void, Never>?

    private func apply(_ list: [CatalogCoin], savedAt: Date) {
        coins = list
        byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.savedAt = savedAt
        unavailable = false
    }
}
