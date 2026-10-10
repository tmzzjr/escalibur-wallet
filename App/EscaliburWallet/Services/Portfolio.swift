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
    /// Token fora da lista que o CoinGecko lista com o contrato exato: nome, simbolo e
    /// logo de la, sem o selo de nao verificado. Reconhecido nao e verificado: sem troca.
    var recognized: TokenIdentity? = nil

    var decimals: Int { positions.first?.asset.decimals ?? 0 }
    var chains: [Chain] { positions.compactMap(\.asset.chain) }

    var totalAmount: BigUInt { positions.reduce(BigUInt()) { $0 + $1.amount } }

    var fiatValue: Double? {
        guard let price else { return nil }
        return positions.reduce(0) { $0 + Fmt.double($1.amount, decimals: $1.asset.decimals) * price }
    }

    /// Logo: o da moeda; se o ativo so existe numa rede que nao e a dele, leva selo.
    var logoName: String? { coingeckoID.map { "logo-\($0)" } }

    /// `.custom` numa moeda que o dono adicionou; nil na lista conferida e nas nativas.
    var origin: Asset.Origin? { positions.first?.asset.origin }
    var isCustom: Bool { origin == .custom }
    /// Da lista conferida da Escalibur (ou moeda nativa): so ela tem troca.
    var isCurated: Bool { positions.allSatisfy { $0.asset.isVerified } }
    /// O ativo cuja logo vem pelo contrato: moeda custom ou reconhecida.
    var contractLogoAsset: Asset? { isCustom || recognized != nil ? positions.first?.asset : nil }
}

/// Um token fora da lista e das moedas custom, para "Outros tokens" e "Mostrar
/// suspeitos". O preco so existe se uma fonte confiavel tiver o contrato.
struct OtherToken: Identifiable, Hashable {
    let holding: UnlistedHolding
    let price: Double?
    let change24h: Double?

    var id: String { holding.asset.id }
    var asset: Asset { holding.asset }
    var isSuspicious: Bool { holding.isSuspicious }

    var fiatValue: Double? {
        guard let price, !isSuspicious else { return nil }
        return Fmt.double(holding.amount, decimals: holding.asset.decimals) * price
    }
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
    /// Tokens fora da lista em redes que so dizem quantos sao (Sui), escondidos.
    private(set) var unknownTokens = 0
    /// Tokens fora da lista e das moedas custom, sem suspeita: "Outros tokens".
    private(set) var others: [OtherToken] = []
    /// Todos os outros tokens, inclusive os que o dono escondeu (para Gerenciar ativos).
    private(set) var allOthers: [OtherToken] = []
    /// Os que tem cara de golpe: atras de "Mostrar suspeitos".
    private(set) var suspicious: [OtherToken] = []
    /// Preco por contrato (moeda custom e outros tokens), por `Asset.id`.
    private(set) var tokenQuotes: [String: Quote] = [:]
    private(set) var lastUpdated: Date?
    private(set) var offline = false
    private(set) var balances: [String: ChainBalance] = [:]
    private(set) var quotes: [String: Quote] = [:]
    /// Preco do bitcoin em cada moeda ("brl", "usd", "eur"): converte o total para as
    /// outras unidades com a mesma cotacao de referencia.
    private(set) var bitcoinPrices: [String: Double] = [:]

    private var walletID: UUID?
    /// Carteiras cujos saldos ja foram lidos da rede nesta sessao.
    private var refreshedIDs: Set<UUID> = []

    /// Mostra o cache na hora e atualiza por baixo.
    func show(_ wallet: WalletMeta?, session: AppSession, force: Bool = false) {
        guard let wallet else {
            rows = []
            total = 0
            walletID = nil
            return
        }
        sessionCustomIDs = session.metadata.customTokens.map(\.id)
        recognizedTokens = session.metadata.recognizedTokens ?? [:]
        if force, walletID == wallet.id {
            recompute(wallet)
            return
        }
        if walletID != wallet.id {
            walletID = wallet.id
            balances = session.metadata.balanceCache[wallet.id] ?? [:]
            quotes = session.metadata.quoteCache.filter { !$0.key.hasPrefix(Self.contractQuotePrefix) }
            tokenQuotes = Dictionary(uniqueKeysWithValues: session.metadata.quoteCache.compactMap { key, quote in
                key.hasPrefix(Self.contractQuotePrefix) ? (String(key.dropFirst(Self.contractQuotePrefix.count)), quote) : nil
            })
            lastUpdated = session.metadata.cachedAt
            recompute(wallet)
        }
    }

    /// Para as telas fora da Carteira (Trocar, Enviar): o saldo nao pode depender de a
    /// aba Carteira ja ter aparecido. Mostra o cache e, se esta carteira ainda nao foi
    /// lida da rede nesta sessao, le. Leitura em andamento nao e repetida.
    func ensureLoaded(_ wallet: WalletMeta?, session: AppSession) async {
        guard let wallet else { return }
        show(wallet, session: session)
        guard !refreshedIDs.contains(wallet.id) else { return }
        await refresh(wallet, session: session)
    }

    func refresh(_ wallet: WalletMeta?, session: AppSession) async {
        guard let wallet else { return }
        // Pedido no meio de uma leitura (moeda custom recem adicionada): roda de novo no
        // fim, com a lista nova, em vez de se perder.
        guard !loading else { pendingRefresh = true; return }
        loading = true
        // A leitura e da carteira, nao da tela que pediu: numa tarefa propria, que a
        // troca de aba nao cancela. Antes, sair da tela no meio cancelava os pedidos que
        // faltavam, e cada rede ainda sem resposta virava "nao foi possivel ler o saldo"
        // (relatado no iPhone com Litecoin, BNB Chain e Ethereum).
        let job = Task {
            await read(wallet, session: session)
            while pendingRefresh, walletID == wallet.id {
                pendingRefresh = false
                await read(wallet, session: session)
            }
            pendingRefresh = false
            loading = false
        }
        await job.value
    }

    private var pendingRefresh = false
    /// Os reconhecimentos guardados nos metadados, para montar as linhas.
    private var recognizedTokens: [String: TokenIdentity] = [:]

    /// A ultima leitura boa da rede nao tinha saldo nem token nenhum.
    static func knownEmpty(_ balance: ChainBalance?) -> Bool {
        guard let balance else { return false }
        return balance.holdings.allSatisfy { $0.amount.isZero } && (balance.unlisted ?? []).isEmpty
    }

    private func read(_ wallet: WalletMeta, session: AppSession) async {
        let disabled = session.metadata.settings.disabledChainIDs
        let targets: [(Chain, [String])] = wallet.accounts.compactMap { account in
            guard let chain = Chain.find(account.chainID), !disabled.contains(chain.id) else { return nil }
            return (chain, Self.addresses(for: account, chain: chain, usage: wallet.utxoUsage[chain.id]))
        }

        var fresh: [String: ChainBalance] = [:]
        var failed: [Chain] = []
        let custom = session.metadata.customTokens
        sessionCustomIDs = custom.map(\.id)
        // As cotacoes saem junto com os saldos, nao depois deles.
        let ids = Set(Chain.all.map(\.coingeckoID) + TokenRegistry.tokens.compactMap(\.coingeckoID))
        let base = session.metadata.settings.currency
        async let quoted = try? MarketService.shared.quotes(ids: Array(ids), currency: base)
        let referencePrices = Task { await Self.bitcoinPrices(excluding: base) }
        // A cotacao do bitcoin nas outras moedas entra assim que chega, sem esperar os
        // saldos de todas as redes: tocar no preco para ver em dolar responde na hora,
        // mesmo com uma rede lenta ou repetindo a leitura.
        Task {
            let others = await referencePrices.value
            guard !others.isEmpty,
                  let own = try? await MarketService.shared.quotes(ids: ["bitcoin"], currency: base)["bitcoin"]?.price
            else { return }
            bitcoinPrices.merge(others) { $1 }
            bitcoinPrices[base] = own
        }
        await withTaskGroup(of: (Chain, ChainBalance?).self) { group in
            for (chain, addresses) in targets {
                group.addTask {
                    let balance = try? await BalanceService.shared.balance(chain: chain, addresses: addresses, custom: custom)
                    return (chain, balance)
                }
            }
            // Cada rede aparece quando chega: a rede lenta (muitos tokens para ler) nao
            // segura as outras.
            for await (chain, balance) in group {
                if let balance {
                    fresh[chain.id] = balance
                    if walletID == wallet.id {
                        balances[chain.id] = balance
                        recompute(wallet)
                    }
                } else {
                    failed.append(chain)
                }
            }
        }
        // Mais duas tentativas para quem falhou, 2 s e 6 s depois: provedor gratis corta
        // rajada (a Atividade varre dezenas de enderecos UTXO ao mesmo tempo), e uma
        // recusa de passagem virava "Nao foi possivel ler o saldo" (relatado no iPhone com
        // a Litecoin). So o que falhar tres vezes vai para o aviso.
        for delay in [2, 6] where !failed.isEmpty {
            try? await Task.sleep(for: .seconds(delay))
            let retry = targets.filter { target in failed.contains { $0.id == target.0.id } }
            failed = []
            await withTaskGroup(of: (Chain, ChainBalance?).self) { group in
                for (chain, addresses) in retry {
                    group.addTask {
                        let balance = try? await BalanceService.shared.balance(chain: chain, addresses: addresses, custom: custom)
                        return (chain, balance)
                    }
                }
                for await (chain, balance) in group {
                    if let balance {
                        fresh[chain.id] = balance
                        if walletID == wallet.id {
                            balances[chain.id] = balance
                            recompute(wallet)
                        }
                    } else {
                        failed.append(chain)
                    }
                }
            }
        }

        let newQuotes = await quoted
        var prices = await referencePrices.value
        if let btc = newQuotes?["bitcoin"]?.price { prices[base] = btc }
        if prices.count > 1 || !prices.isEmpty { bitcoinPrices = prices }

        offline = fresh.isEmpty && newQuotes == nil && !targets.isEmpty
        if !fresh.isEmpty { refreshedIDs.insert(wallet.id) }
        guard walletID == wallet.id else { return }
        for (id, balance) in fresh { balances[id] = balance }
        if let newQuotes, !newQuotes.isEmpty { quotes = newQuotes }
        // Rede cuja ultima leitura boa nao tinha nada (o Litecoin de quem nunca teve
        // Litecoin): a falha de agora nao muda o que a tela mostra, e o aviso so
        // assustaria. Fica o zero guardado ate a proxima leitura responder.
        failedChains = failed.filter { !Self.knownEmpty(balances[$0.id]) }.sorted { $0.name < $1.name }
        if !fresh.isEmpty { lastUpdated = .now }
        recompute(wallet)
        // Preco por contrato: moedas custom e outros tokens sem suspeita. Nunca pelo
        // simbolo; o que nao tiver preco fica fora do total. Vem depois do saldo, que ja
        // esta na tela.
        let priced = Self.contractPriced(balances)
        if !priced.isEmpty {
            let found = await MarketService.shared.tokenQuotes(priced, currency: base)
            guard walletID == wallet.id else { return }
            tokenQuotes.merge(found) { $1 }
            recompute(wallet)
        }
        await recognize(wallet, session: session)

        session.metadata.balanceCache[wallet.id] = balances
        var cache = quotes
        for (id, quote) in tokenQuotes { cache[Self.contractQuotePrefix + id] = quote }
        session.metadata.quoteCache = cache
        session.metadata.cachedAt = lastUpdated
        try? session.persist()
    }

    /// No cache de cotacoes, o preco por contrato vai com este prefixo antes do
    /// `Asset.id`, para nunca se confundir com um id do CoinGecko.
    static let contractQuotePrefix = "contrato:"

    /// Os ativos cujo preco se busca por contrato: as moedas custom com saldo e os outros
    /// tokens sem suspeita. Suspeito nunca: preco de golpe nao entra na tela.
    /// A ordem conta: o CoinGecko sem chave responde poucos contratos por vez, e as
    /// moedas custom e as stablecoins oficiais fora da lista vem primeiro.
    static func contractPriced(_ balances: [String: ChainBalance]) -> [Asset] {
        var custom: [Asset] = []
        var official: [Asset] = []
        var others: [Asset] = []
        for chain in Chain.all {
            guard let balance = balances[chain.id] else { continue }
            custom += balance.holdings.filter { $0.asset.isCustom && !$0.amount.isZero }.map(\.asset)
            for holding in balance.unlisted ?? [] where !holding.isSuspicious {
                if TokenSafety.officialOutsideList.contains(holding.asset.id) { official.append(holding.asset) } else { others.append(holding.asset) }
            }
        }
        return custom + official + others
    }

    /// O preco de um ativo: pelo id do CoinGecko na lista; por contrato fora dela.
    func price(of asset: Asset) -> Double? {
        if let id = asset.coingeckoID { return quotes[id]?.price }
        return tokenQuotes[asset.id]?.price
    }

    /// O preco do bitcoin nas moedas que nao sao a do app, para as outras unidades do
    /// total. Falha de uma moeda so tira essa unidade da tela.
    nonisolated private static func bitcoinPrices(excluding base: String) async -> [String: Double] {
        var out: [String: Double] = [:]
        for currency in ["brl", "usd", "eur"] where currency != base {
            if let price = try? await MarketService.shared.quotes(ids: ["bitcoin"], currency: currency)["bitcoin"]?.price {
                out[currency] = price
            }
        }
        return out
    }

    /// Um valor na moeda do app levado para outra unidade, pela cotacao do bitcoin.
    func convert(_ value: Double, to unit: Fmt.DisplayUnit, base: Fmt.Currency) -> Double? {
        guard let btcInBase = bitcoinPrices[base.coingeckoID], btcInBase > 0 else {
            return unit == Fmt.DisplayUnit(base) ? value : nil
        }
        switch unit {
        case .btc: return value / btcInBase
        default:
            guard let btcInUnit = bitcoinPrices[unit.rawValue] else { return nil }
            return value * btcInUnit / btcInBase
        }
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
        var unlisted: [UnlistedHolding] = []
        // Moeda custom removida pelo dono sai da tela na hora, mesmo com o cache antigo.
        let custom = Set(sessionCustomIDs)
        for chain in Chain.all {
            guard let balance = balances[chain.id] else { continue }
            if let list = balance.unlisted { unlisted += list } else { unknown += balance.unknownTokenCount }
            for holding in balance.holdings where !holding.amount.isZero {
                if holding.asset.isCustom, !custom.contains(holding.asset.id) { continue }
                // A moeda custom nunca se junta a um ativo da lista pelo simbolo: a chave
                // dela e o proprio id (rede e contrato).
                let key = holding.asset.coingeckoID ?? holding.asset.id
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(holding)
            }
        }
        let curatedRows = order.compactMap { key -> PortfolioRow? in
            guard let holdings = grouped[key], let first = holdings.first?.asset else { return nil }
            let quote = first.coingeckoID.map { quotes[$0] } ?? tokenQuotes[first.id]
            return PortfolioRow(
                id: key, symbol: first.symbol, name: first.name, coingeckoID: first.coingeckoID,
                isStablecoin: first.isStablecoin, positions: holdings, price: quote?.price, change24h: quote?.change24h
            )
        }

        let tokens = unlisted.map { holding in
            let quote = holding.isSuspicious ? nil : tokenQuotes[holding.asset.id]
            return OtherToken(holding: holding, price: quote?.price, change24h: quote?.change24h)
        }
        // Reconhecidos pelo CoinGecko pelo contrato exato viram linha de Ativos, juntos so
        // entre si (chave "rec:" e o id), nunca com uma linha da lista conferida. Suspeito
        // continua suspeito, reconhecido ou nao.
        var recognizedGroups: [String: (identity: TokenIdentity, tokens: [OtherToken])] = [:]
        var recognizedOrder: [String] = []
        var plain: [OtherToken] = []
        for token in tokens where !token.isSuspicious && !custom.contains(token.id) {
            if let identity = recognizedTokens[token.id], TokenRecognitionRules.isValid(identity, for: token.asset, now: identity.checkedAt) {
                let key = "rec:" + identity.coingeckoID
                if recognizedGroups[key] == nil {
                    recognizedOrder.append(key)
                    recognizedGroups[key] = (identity, [])
                }
                recognizedGroups[key]?.tokens.append(token)
            } else {
                plain.append(token)
            }
        }
        let recognizedRows = recognizedOrder.compactMap { key -> PortfolioRow? in
            guard let group = recognizedGroups[key] else { return nil }
            let priced = group.tokens.first { $0.price != nil }
            return PortfolioRow(
                id: key, symbol: group.identity.symbol, name: group.identity.name, coingeckoID: nil, isStablecoin: false,
                positions: group.tokens.map { Holding(asset: $0.asset, amount: $0.holding.amount) },
                price: priced?.price, change24h: priced?.change24h, recognized: group.identity
            )
        }
        allRows = (curatedRows + recognizedRows).sorted { ($0.fiatValue ?? 0) > ($1.fiatValue ?? 0) }
        rows = allRows.filter { !wallet.hiddenAssetIDs.contains($0.id) }

        allOthers = plain
            .sorted { (($0.fiatValue ?? 0), $1.asset.symbol.lowercased()) > (($1.fiatValue ?? 0), $0.asset.symbol.lowercased()) }
        // Escondido em Gerenciar ativos: some da Carteira e do total, como os da lista.
        others = allOthers.filter { !wallet.hiddenAssetIDs.contains($0.id) }
        suspicious = tokens.filter(\.isSuspicious)

        // O total so soma o que tem preco: os ativos visiveis e os outros tokens com
        // preco por contrato. Sem preco confiavel, fora.
        let priced = rows.compactMap(\.fiatValue) + others.compactMap(\.fiatValue)
        total = priced.reduce(0, +)
        let moves = rows.map { ($0.fiatValue, $0.change24h) } + others.map { ($0.fiatValue, $0.change24h) }
        change24hFiat = moves.reduce(0) { sum, item in
            guard let value = item.0, let change = item.1 else { return sum }
            return sum + value - value / (1 + change / 100)
        }
        unknownTokens = unknown
    }

    /// As moedas custom salvas agora (ids), lidas a cada recalculo.
    private var sessionCustomIDs: [String] = []

    /// Chamado quando o dono adiciona ou remove uma moeda custom.
    /// Pergunta ao CoinGecko pelos tokens fora da lista, sem suspeita, que ainda nao tem
    /// resposta de menos de 7 dias: no maximo 8 por leitura, um a cada 1,5 s (a cota sem
    /// chave e a mesma do Mercado). "Nao listado" tira o reconhecimento na hora; sem
    /// resposta, fica o que havia, e nada e promovido.
    private func recognize(_ wallet: WalletMeta, session: AppSession) async {
        let now = Date.now
        var known = session.metadata.recognizedTokens ?? [:]
        var misses = session.metadata.unrecognizedChecks ?? [:]
        let custom = Set(session.metadata.customTokens.map(\.id))
        let assets = Chain.all.compactMap { balances[$0.id]?.unlisted }.flatMap { $0 }
            .filter { !$0.isSuspicious && !custom.contains($0.asset.id) }.map(\.asset)
        let pending = assets.filter { asset in
            if let identity = known[asset.id] { return !TokenRecognitionRules.isValid(identity, for: asset, now: now) }
            if let checked = misses[asset.id] { return now.timeIntervalSince(checked) >= TokenRecognitionRules.lifetime }
            return true
        }
        guard !pending.isEmpty else { return }
        var changed = false
        for (index, asset) in pending.prefix(8).enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(1500)) }
            do {
                if let identity = try await MarketService.shared.tokenIdentity(asset, now: now) {
                    known[asset.id] = identity
                    misses[asset.id] = nil
                } else {
                    known[asset.id] = nil
                    misses[asset.id] = now
                }
                changed = true
            } catch {
                continue
            }
        }
        guard changed, walletID == wallet.id else { return }
        session.metadata.recognizedTokens = known
        session.metadata.unrecognizedChecks = misses
        try? session.persist()
        recognizedTokens = known
        recompute(wallet)
    }

    /// Le uma rede so, agora, fora da leitura geral: a moeda custom recem adicionada
    /// aparece em segundos, sem esperar terminar a leitura de todas as redes que estiver
    /// em andamento (com as novas tentativas, passava de um minuto). Tarefa propria, que
    /// sair da tela nao cancela.
    func refreshChain(_ chain: Chain, wallet: WalletMeta?, session: AppSession) async {
        guard let wallet, let account = wallet.account(chain), !session.metadata.settings.disabledChainIDs.contains(chain.id) else { return }
        let addresses = Self.addresses(for: account, chain: chain, usage: wallet.utxoUsage[chain.id])
        let custom = session.metadata.customTokens
        let currency = session.metadata.settings.currency
        let job = Task {
            guard let balance = try? await BalanceService.shared.balance(chain: chain, addresses: addresses, custom: custom),
                  walletID == wallet.id else { return }
            balances[chain.id] = balance
            failedChains.removeAll { $0.id == chain.id }
            recompute(wallet)
            let priced = Self.contractPriced([chain.id: balance])
            guard !priced.isEmpty else { return }
            let found = await MarketService.shared.tokenQuotes(priced, currency: currency)
            guard walletID == wallet.id else { return }
            tokenQuotes.merge(found) { $1 }
            recompute(wallet)
        }
        await job.value
    }

    func customChanged(_ wallet: WalletMeta?, session: AppSession) {
        sessionCustomIDs = session.metadata.customTokens.map(\.id)
        if let wallet { recompute(wallet) }
    }

    var change24hPercent: Double {
        let before = total - change24hFiat
        return before > 0 ? change24hFiat / before * 100 : 0
    }

    func balance(_ chain: Chain) -> ChainBalance? { balances[chain.id] }
}
