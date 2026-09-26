import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Observation

/// Um ativo na lista da carteira: o mesmo ativo em varias redes vira uma linha so.
struct PortfolioRow: Identifiable, Hashable {
    let id: String
    let symbol: String
    let name: String
    let coingeckoID: String?
    let isStablecoin: Bool
    /// Cada rede onde a carteira tem este ativo, com a quantidade.
    let positions: [Holding]
    let price: Double?
    let change24h: Double?

    var decimals: Int { positions.first?.asset.decimals ?? 0 }
    var chains: [Chain] { positions.compactMap(\.asset.chain) }

    var totalAmount: BigUInt { positions.reduce(BigUInt()) { $0 + $1.amount } }

    var fiatValue: Double? {
        guard let price else { return nil }
        return positions.reduce(0) { $0 + Fmt.double($1.amount, decimals: $1.asset.decimals) * price }
    }

    /// Logo: o da moeda; se o ativo so existe numa rede que nao e a dele, leva selo.
    var logoName: String? { coingeckoID.map { "logo-\($0)" } }
}

@MainActor
@Observable
final class Portfolio {
    private(set) var rows: [PortfolioRow] = []
    /// Todas as linhas, inclusive as que o dono escondeu (para Gerenciar ativos).
    private(set) var allRows: [PortfolioRow] = []
    private(set) var total: Double = 0
    private(set) var change24hFiat: Double = 0
    private(set) var loading = false
    private(set) var failedChains: [Chain] = []
    private(set) var unknownTokens = 0
    private(set) var lastUpdated: Date?
    private(set) var offline = false
    private(set) var balances: [String: ChainBalance] = [:]
    private(set) var quotes: [String: Quote] = [:]

    private var walletID: UUID?

    /// Mostra o cache na hora e atualiza por baixo.
    func show(_ wallet: WalletMeta?, session: AppSession, force: Bool = false) {
        guard let wallet else {
            rows = []
            total = 0
            walletID = nil
            return
        }
        if force, walletID == wallet.id {
            recompute(wallet)
            return
        }
        if walletID != wallet.id {
            walletID = wallet.id
            balances = session.metadata.balanceCache[wallet.id] ?? [:]
            quotes = session.metadata.quoteCache
            lastUpdated = session.metadata.cachedAt
            recompute(wallet)
        }
    }

    func refresh(_ wallet: WalletMeta?, session: AppSession) async {
        guard let wallet, !loading else { return }
        loading = true
        defer { loading = false }
        let disabled = session.metadata.settings.disabledChainIDs
        let targets: [(Chain, [String])] = wallet.accounts.compactMap { account in
            guard let chain = Chain.find(account.chainID), !disabled.contains(chain.id) else { return nil }
            return (chain, Self.addresses(for: account, chain: chain, usage: wallet.utxoUsage[chain.id]))
        }

        var fresh: [String: ChainBalance] = [:]
        var failed: [Chain] = []
        await withTaskGroup(of: (Chain, ChainBalance?).self) { group in
            for (chain, addresses) in targets {
                group.addTask {
                    let balance = try? await BalanceService.shared.balance(chain: chain, addresses: addresses)
                    return (chain, balance)
                }
            }
            for await (chain, balance) in group {
                if let balance { fresh[chain.id] = balance } else { failed.append(chain) }
            }
        }

        let ids = Set(Chain.all.map(\.coingeckoID) + TokenRegistry.tokens.compactMap(\.coingeckoID))
        let newQuotes = try? await MarketService.shared.quotes(ids: Array(ids), currency: session.metadata.settings.currency)

        offline = fresh.isEmpty && newQuotes == nil && !targets.isEmpty
        guard walletID == wallet.id else { return }
        for (id, balance) in fresh { balances[id] = balance }
        if let newQuotes, !newQuotes.isEmpty { quotes = newQuotes }
        failedChains = failed.sorted { $0.name < $1.name }
        if !fresh.isEmpty { lastUpdated = .now }
        recompute(wallet)

        session.metadata.balanceCache[wallet.id] = balances
        session.metadata.quoteCache = quotes
        session.metadata.cachedAt = lastUpdated
        try? session.persist()
    }

    /// Enderecos a consultar: um por rede, e nas UTXO os de recebimento e troco ja
    /// usados mais o proximo, derivados da xpub (a seed nao e tocada).
    static func addresses(for account: DerivedAccount, chain: Chain, usage: UTXOUsage?) -> [String] {
        guard chain.family == .utxo, let xpub = account.accountXPub else { return [account.address] }
        let usage = usage ?? UTXOUsage()
        var out: [String] = []
        for (branch, used) in [(UInt32(0), usage.receiveUsed), (UInt32(1), usage.changeUsed)] {
            for index in 0...UInt32(max(0, used)) {
                if let key = try? xpub.derive([branch, index]), let address = try? Address.from(publicKey: key.publicKey, chain: chain) {
                    out.append(address)
                }
            }
        }
        return out.isEmpty ? [account.address] : out
    }

    private func recompute(_ wallet: WalletMeta) {
        var grouped: [String: [Holding]] = [:]
        var order: [String] = []
        var unknown = 0
        for chain in Chain.all {
            guard let balance = balances[chain.id] else { continue }
            unknown += balance.unknownTokenCount
            for holding in balance.holdings where !holding.amount.isZero {
                let key = holding.asset.coingeckoID ?? holding.asset.id
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(holding)
            }
        }
        allRows = order.compactMap { key in
            guard let holdings = grouped[key], let first = holdings.first?.asset else { return nil }
            let quote = first.coingeckoID.flatMap { quotes[$0] }
            return PortfolioRow(
                id: key, symbol: first.symbol, name: first.name, coingeckoID: first.coingeckoID,
                isStablecoin: first.isStablecoin, positions: holdings, price: quote?.price, change24h: quote?.change24h
            )
        }
        .sorted { ($0.fiatValue ?? 0) > ($1.fiatValue ?? 0) }
        rows = allRows.filter { !wallet.hiddenAssetIDs.contains($0.id) }

        total = rows.reduce(0) { $0 + ($1.fiatValue ?? 0) }
        change24hFiat = rows.reduce(0) { sum, row in
            guard let value = row.fiatValue, let change = row.change24h else { return sum }
            return sum + value - value / (1 + change / 100)
        }
        unknownTokens = unknown
    }

    var change24hPercent: Double {
        let before = total - change24hFiat
        return before > 0 ? change24hFiat / before * 100 : 0
    }

    func balance(_ chain: Chain) -> ChainBalance? { balances[chain.id] }
}
