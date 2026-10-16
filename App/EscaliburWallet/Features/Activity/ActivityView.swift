import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import EscaliburNetwork
import SwiftUI

/// O historico da carteira escolhida, compartilhado: a leitura comeca logo depois de
/// destravar (`WalletHomeView`), e a aba so mostra o que ja chegou.
///
/// Abre com o ultimo historico guardado (`CachedActivity`) e troca rede por rede conforme
/// cada uma responde. Rede que falhou agora fica com o que estava guardado, com o aviso.
///
/// So pergunta a rede que pode ter mudado (`ActivityFetch`): nunca lida, saldo diferente
/// do da ultima leitura, envio pendente, ou leitura velha (10 minutos; rede vazia, 12
/// horas). As outras ficam com o guardado. No maximo 4 redes por vez, as com saldo
/// primeiro: 26 de uma vez estouravam o limite dos provedores gratis (429 na Solana e no
/// Bitcoin, print do iPhone de 15/10/2026). Puxar para atualizar le todas.
@MainActor
@Observable
final class ActivityFeed {
    static let shared = ActivityFeed()

    private(set) var entries: [ActivityEntry] = []
    /// Redes que falharam agora (rede fora do ar, limite do provedor): vale tentar de novo.
    private(set) var failed: [Chain] = []
    /// Redes cujo historico esta versao nao le, com o motivo dito pelo motor. Tentar de
    /// novo nao muda nada, entao nao ha botao.
    private(set) var unavailable: [(chain: Chain, reason: String)] = []
    private(set) var loading = false
    private(set) var loadedOnce = false
    private(set) var suspiciousCount = 0

    enum Outcome: Sendable {
        case items([ActivityEntry])
        case unavailable(String)
        case failed
    }

    /// Redes que ainda nao responderam nesta leitura.
    private(set) var remaining = 0

    /// Esperas antes de cada nova tentativa das redes que falharam. Na abertura do app o
    /// saldo, os tokens, o mercado e o historico disparam juntos, e os provedores gratis
    /// cortam a rajada por alguns segundos (relatado no iPhone com Base, Polkadot e
    /// Solana). So o que falhar tres vezes fica no aviso.
    static let retryDelays: [Duration] = [.seconds(2), .seconds(5)]

    /// Cada rede entra na tela assim que responde, em vez de todas esperarem a mais
    /// lenta (uma varredura UTXO, um provedor no limite). Na primeira leitura a lista vai
    /// crescendo; ao atualizar uma lista que ja existe, ela so troca no fim, sem piscar.
    func load(
        _ wallet: WalletMeta?, disabled: Set<String>, session: AppSession,
        balances: [String: ChainBalance] = [:], force: Bool = false
    ) async {
        guard let wallet else { return }
        if shownWalletID != wallet.id { showCached(wallet, session: session) }
        // Leitura em andamento da mesma carteira: espera por ela em vez de comecar outra.
        if let current, currentWalletID == wallet.id {
            await current.value
            return
        }
        current?.cancel()
        // Numa tarefa propria, que a troca de aba nao cancela: antes, sair da Atividade
        // no meio cancelava os pedidos que faltavam, e as redes mais lentas (Base e
        // Ethereum pelo Blockscout) viravam "nao foi possivel ler" (print do iPhone).
        generation += 1
        let mine = generation
        let job = Task { await run(wallet, disabled: disabled, balances: balances, force: force, generation: mine, session: session) }
        current = job
        currentWalletID = wallet.id
        await job.value
        if currentWalletID == wallet.id {
            current = nil
            currentWalletID = nil
        }
    }

    private var current: Task<Void, Never>?
    private var currentWalletID: UUID?
    /// A leitura valida: uma de carteira trocada no meio termina sem mexer na tela.
    private var generation = 0
    /// A carteira cujo historico esta na tela, e ele por rede.
    private var shownWalletID: UUID?
    private var byChain: [String: [ActivityEntry]] = [:]

    /// O historico guardado da carteira, na tela antes de qualquer rede responder.
    private func showCached(_ wallet: WalletMeta, session: AppSession) {
        shownWalletID = wallet.id
        let cached = (session.metadata.activityCache?[wallet.id] ?? []).compactMap(\.entry)
        byChain = Dictionary(grouping: cached, by: \.chainID)
        failed = []
        unavailable = []
        loadedOnce = !cached.isEmpty
        publish(failures: [], missing: [])
    }

    /// Quantas redes leem ao mesmo tempo.
    static let parallelReads = 4

    private typealias Job = (chain: Chain, account: DerivedAccount, source: any ActivitySource, usage: UTXOUsage?)

    private func run(
        _ wallet: WalletMeta, disabled: Set<String>, balances: [String: ChainBalance], force: Bool,
        generation mine: Int, session: AppSession
    ) async {
        loading = true
        defer { if generation == mine { loading = false; remaining = 0 } }
        var failures: [Chain] = []
        var missing: [(chain: Chain, reason: String)] = []
        let jobs: [Job] = wallet.accounts.compactMap { account in
            guard let chain = Chain.find(account.chainID), !disabled.contains(chain.id),
                  let source = ActivitySources.source(for: chain) else { return nil }
            return (chain, account, source, wallet.utxoUsage[chain.id])
        }
        // Rede desligada ou sem conta sai da tela.
        let active = Set(jobs.map(\.chain.id))
        byChain = byChain.filter { active.contains($0.key) }
        var records = session.metadata.activityFetched?[wallet.id] ?? [:]
        let toRead = jobs.filter { job in
            force || needsRead(job.chain, record: records[job.chain.id], balance: balances[job.chain.id])
        }
        .sorted { Self.priority($0.chain, balances: balances, cached: byChain) > Self.priority($1.chain, balances: balances, cached: byChain) }
        var pending = toRead
        for attempt in 0...Self.retryDelays.count {
            if attempt > 0 { try? await Task.sleep(for: Self.retryDelays[attempt - 1]) }
            guard !Task.isCancelled, generation == mine, !pending.isEmpty else { break }
            remaining = pending.count
            failures = []
            await withTaskGroup(of: (Chain, Outcome).self) { group in
                var queue = pending[...]
                func next() {
                    guard let (chain, account, source, usage) = queue.popFirst() else { return }
                    group.addTask { (chain, await Self.read(source, chain: chain, account: account, usage: usage)) }
                }
                for _ in 0..<Self.parallelReads { next() }
                for await (chain, outcome) in group {
                    remaining -= 1
                    next()
                    guard generation == mine else { continue }
                    switch outcome {
                    case .items(let items):
                        byChain[chain.id] = items
                        records[chain.id] = ActivityFetch(at: .now, balanceMark: ActivityFetch.mark(balances[chain.id]), empty: items.isEmpty)
                    case .unavailable(let reason):
                        byChain[chain.id] = nil
                        missing.append((chain, reason))
                    // Falhou agora: fica o que estava guardado dessa rede.
                    case .failed: failures.append(chain)
                    }
                    publish(failures: failures, missing: missing)
                }
            }
            pending = toRead.filter { job in failures.contains { $0.id == job.chain.id } }
        }
        guard !Task.isCancelled, generation == mine else { return }
        publish(failures: failures, missing: missing)
        loadedOnce = true
        guard !toRead.isEmpty else { return }
        let all = byChain.values.flatMap { $0 }.sorted { $0.date > $1.date }.prefix(CachedActivity.limit)
        var cache = session.metadata.activityCache ?? [:]
        cache[wallet.id] = all.map(CachedActivity.init)
        session.metadata.activityCache = cache
        var fetched = session.metadata.activityFetched ?? [:]
        fetched[wallet.id] = records
        session.metadata.activityFetched = fetched
        try? session.persist()
    }

    /// A rede precisa ser lida agora? Rede sem historico nesta versao (X Layer, Sonic) e
    /// sempre lida: o motor responde na hora, sem rede, e o aviso dela depende disso.
    private func needsRead(_ chain: Chain, record: ActivityFetch?, balance: ChainBalance?) -> Bool {
        guard let record else { return true }
        if byChain[chain.id] == nil, !record.empty { return true }
        if ActivitySources.source(for: chain) is EVMUnavailableActivitySource { return true }
        let pending = byChain[chain.id]?.contains { if case .pending = $0.status { return true } else { return false } } ?? false
        return record.isStale(balanceMark: ActivityFetch.mark(balance), hasPending: pending)
    }

    /// Ordem de leitura: a rede com saldo, depois a com historico guardado, depois o resto.
    private static func priority(_ chain: Chain, balances: [String: ChainBalance], cached: [String: [ActivityEntry]]) -> Int {
        if balances[chain.id]?.holdings.isEmpty == false { return 2 }
        if cached[chain.id]?.isEmpty == false { return 1 }
        return 0
    }

    nonisolated private static func read(_ source: any ActivitySource, chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async -> Outcome {
        do {
            return .items(try await source.history(chain: chain, account: account, usage: usage))
        } catch SendEngineError.unavailable(let reason) {
            return .unavailable(reason)
        } catch {
            return .failed
        }
    }

    private func publish(failures: [Chain], missing: [(chain: Chain, reason: String)]) {
        let collected = byChain.values.flatMap { $0 }
        suspiciousCount = collected.filter(\.suspicious).count
        entries = collected.filter { !$0.suspicious }.sorted { $0.date > $1.date }
        failed = failures.sorted { $0.name < $1.name }
        unavailable = missing.sorted { $0.chain.name < $1.chain.name }
    }
}

/// H1: Atividade.
struct ActivityView: View {
    @Environment(AppSession.self) private var session
    @Environment(Router.self) private var router
    @Environment(Portfolio.self) private var portfolio
    @Environment(\.openURL) private var openURL
    private var feed: ActivityFeed { .shared }
    @State private var receiving = false
    /// Quantas movimentacoes ja concluidas aparecem: 20 por vez, mais 20 ao chegar no fim.
    @State private var visibleCount = 20

    private var pending: [ActivityEntry] {
        feed.entries.filter { if case .pending = $0.status { return true }; return false }
    }

    private var doneEntries: [ActivityEntry] {
        feed.entries.filter { if case .pending = $0.status { return false }; return true }
    }

    private var grouped: [(String, [ActivityEntry])] {
        let calendar = Calendar(identifier: .gregorian)
        let done = doneEntries.prefix(visibleCount)
        var order: [String] = []
        var groups: [String: [ActivityEntry]] = [:]
        for entry in done {
            let title: String
            if calendar.isDateInToday(entry.date) { title = String(localized: "Hoje") }
            else if calendar.isDateInYesterday(entry.date) { title = String(localized: "Ontem") }
            else { title = entry.date.formatted(.dateTime.day().month(.wide).locale(Fmt.locale)) }
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// Sem nada na lista e lendo pela primeira vez: o carregando no meio da tela.
    private var loadingFirstTime: Bool { feed.entries.isEmpty && (feed.loading || !feed.loadedOnce) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TabTitle(String(localized: "Atividade"))

                    if !feed.failed.isEmpty {
                        RefreshNotice(chains: Self.names(feed.failed), retry: { Task { await reload(force: true) } })
                            .padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                    }

                    if feed.entries.isEmpty {
                        if loadingFirstTime {
                            // O carregando fica por cima da lista, no meio da tela (abaixo).
                            Color.clear.frame(height: 1)
                        } else {
                            empty
                                .frame(maxWidth: .infinity)
                                .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length * 0.8 }
                        }
                    }

                    if !pending.isEmpty {
                        section(String(localized: "Pendentes"), pending)
                    }
                    if feed.loading, !feed.entries.isEmpty, feed.remaining > 0 {
                        HStack(spacing: Space.xs) {
                            ProgressView().controlSize(.small).tint(Palette.inkSoft)
                            Text(feed.remaining == 1 ? "Lendo mais 1 rede" : "Lendo mais \(feed.remaining) redes")
                                .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                        }
                        .padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                    }
                    ForEach(grouped, id: \.0) { title, items in
                        section(title, items)
                    }
                    if doneEntries.count > visibleCount {
                        // Chegar ao fim da lista ja traz as proximas 20; o botao fica para
                        // quem navega pelo VoiceOver.
                        SecondaryButton(title: String(localized: "Mostrar mais")) { visibleCount += 20 }
                            .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                            .onAppear { visibleCount += 20 }
                    }

                    // Redes sem historico publico: uma linha so, e so se esta carteira tem
                    // saldo nelas. Para quem nao usa essas redes, nao ha o que avisar.
                    if !unavailableWithBalance.isEmpty {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text("O histórico de \(Self.names(unavailableWithBalance)) não aparece aqui: nenhum serviço gratuito publica o histórico dessas redes sem cadastro. O saldo aparece na Carteira, e o histórico completo, no explorador da rede.")
                                .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(unavailableWithBalance, id: \.id) { chain in
                                if let address = session.selectedWallet?.account(chain)?.address, let url = chain.explorerURL(address: address) {
                                    Button { openURL(url) } label: {
                                        HStack(spacing: Space.xs) {
                                            NetworkBadge(chain: chain, size: 20, ring: Palette.body)
                                            Text("Ver o histórico no \(chain.explorerName)").typeStyle(.note).fontWeight(.semibold).foregroundStyle(Palette.ink)
                                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                                        }
                                        .padding(.horizontal, Space.sm).frame(height: 36)
                                        .background(Capsule().fill(Palette.rail))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                    }

                    if feed.suspiciousCount > 0 {
                        Text(feed.suspiciousCount == 1
                             ? "1 recebimento suspeito escondido. São envios de valor zero ou de tokens fora da lista, muitas vezes de endereços parecidos com os seus."
                             : "\(feed.suspiciousCount) recebimentos suspeitos escondidos. São envios de valor zero ou de tokens fora da lista, muitas vezes de endereços parecidos com os seus.")
                            .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                            .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .refreshable { await reload(force: true) }
            .overlay {
                if loadingFirstTime {
                    ActivityLoading(chains: session.selectedWallet?.accounts.compactMap { Chain.find($0.chainID) } ?? [])
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .statusBarBackdrop()
            .navigationDestination(for: ActivityEntry.self) { entry in ActivityDetailView(entry: entry) }
        }
        .task(id: session.selectedWallet?.id) { visibleCount = 20; await reload() }
        // O aviso das redes sem historico depende do saldo: quem abre direto na
        // Atividade ainda nao carregou a carteira.
        .task(id: session.selectedWallet?.id) { await portfolio.ensureLoaded(session.selectedWallet, session: session) }
        .sheet(isPresented: $receiving) { ReceiveSheet(preselected: nil) }
    }

    /// "Stellar", "Stellar e Dogecoin", "Stellar, Dogecoin e mais 2 redes".
    /// So no build de teste: as ultimas falhas de rede, para o print do iPhone dizer o
    /// motivo (limite do provedor, tempo esgotado). Na distribuicao, nada.
    static var debugDetail: String? {
        #if DEBUG
        // Os indexadores de historico primeiro: sao eles que a Atividade le.
        let history = ["blockscout", "routescan", "explorer", "novasama", "solana", "vibestation", "trongrid", "toncenter", "tonapi", "horizon", "koios", "fastnear", "aptos", "sui", "ripple", "xrpl"]
        let recent = NetworkDiagnostics.shared.recent()
        let sorted = recent.filter { line in history.contains { line.contains($0) } } + recent.filter { line in !history.contains { line.contains($0) } }
        return sorted.isEmpty ? nil : "Teste: " + sorted.prefix(12).joined(separator: "; ")
        #else
        return nil
        #endif
    }

    static func names(_ chains: [Chain]) -> String {
        let names = chains.map(\.name)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2, 3: return names.formatted(.list(type: .and).locale(Fmt.locale))
        default: return String(localized: "\(names[0]), \(names[1]) e mais \(names.count - 2) redes")
        }
    }

    /// Ao abrir, so o que pode ter mudado; ao puxar ou tentar de novo, todas as redes.
    private func reload(force: Bool = false) async {
        await feed.load(session.selectedWallet, disabled: session.metadata.settings.disabledChainIDs, session: session,
                        balances: portfolio.balances, force: force)
    }

    private func section(_ title: String, _ items: [ActivityEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).typeStyle(.heading).foregroundStyle(Palette.ink)
                .padding(.horizontal, Space.gutter).padding(.top, Space.lg).padding(.bottom, Space.xs)
            ForEach(items) { entry in
                NavigationLink(value: entry) { ActivityRow(entry: entry, currency: session.currency, hidden: session.metadata.settings.hideBalances) }
                    .buttonStyle(RowStyle())
            }
        }
    }

    private var unavailableWithBalance: [Chain] {
        feed.unavailable.map(\.chain).filter { chain in
            portfolio.balance(chain)?.holdings.contains { !$0.amount.isZero } ?? false
        }
    }

    private var empty: some View {
        VStack(spacing: 0) {
            ActivityEmptyArt(height: 230)
            VStack(spacing: Space.sm) {
                Text("Sua atividade aparece aqui").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Envios, recebimentos, trocas e ordens, cada um com o seu status.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.top, Space.md)
            PrimaryButton(title: String(localized: "Receber")) { receiving = true }.padding(.top, Space.lg)
        }
        .padding(.horizontal, Space.gutter)
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry
    let currency: Fmt.Currency
    var hidden = false

    private var title: String {
        let symbol = entry.asset?.symbol ?? entry.chain?.nativeSymbol ?? ""
        switch entry.direction {
        case .sent: return String(localized: "Enviado · \(symbol)")
        case .received: return String(localized: "Recebido · \(symbol)")
        case .swap: return entry.receivedAsset.map { String(localized: "Troca · \(symbol) por \($0.symbol)") } ?? String(localized: "Troca · \(symbol)")
        case .approval: return String(localized: "Autorização · \(symbol)")
        case .order: return String(localized: "Ordem · \(symbol)")
        case .other: return entry.chain?.name ?? ""
        }
    }

    private var subtitle: String {
        let time = entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Fmt.locale))
        switch entry.status {
        case .pending(let detail): return detail ?? String(localized: "Aguardando confirmação")
        case .failed: return String(localized: "Falhou")
        case .confirmed:
            // Troca: o que saiu fica embaixo; o que entrou vai a direita.
            if entry.direction == .swap, entry.receivedAsset != nil, let asset = entry.asset, !hidden {
                return "\(Fmt.minus)\(Fmt.crypto(entry.amount, decimals: asset.decimals, symbol: asset.symbol, style: .list)) · \(time)"
            }
            guard let counterparty = entry.counterparty else { return time }
            let preposition = entry.direction == .received ? "De" : String(localized: "Para")
            return "\(preposition) \(Fmt.address(counterparty, chain: entry.chain)) · \(time)"
        }
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            // O logo da moeda com a bolinha da rede; a direcao esta no titulo e no sinal.
            CoinLogo(coingeckoID: entry.asset?.coingeckoID ?? entry.chain?.coingeckoID,
                     symbol: entry.asset?.symbol ?? entry.chain?.nativeSymbol ?? "", size: 40, network: entry.chain)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
                Text(subtitle).typeStyle(.note).foregroundStyle(isFailed ? Palette.down : Palette.inkSoft).lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            if entry.direction == .swap, let received = entry.receivedAsset, let amount = entry.receivedAmount {
                Text(hidden ? Redaction.short : ((isFailed ? "" : "+") + Fmt.crypto(amount, decimals: received.decimals, symbol: received.symbol, style: .list)))
                    .typeStyle(.row)
                    .foregroundStyle(isFailed ? Palette.inkMuted : Palette.up)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .strikethrough(isFailed)
            } else if let asset = entry.asset {
                Text(hidden ? Redaction.short : (sign + Fmt.crypto(entry.amount, decimals: asset.decimals, symbol: asset.symbol, style: .list)))
                    .typeStyle(.row)
                    .foregroundStyle(isFailed ? Palette.inkMuted : (entry.direction == .received ? Palette.up : Palette.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .strikethrough(isFailed)
            }
        }
        .padding(.horizontal, Space.gutter)
        .frame(minHeight: Height.row)
        .contentShape(Rectangle())
    }

    private var isFailed: Bool { if case .failed = entry.status { return true }; return false }
    /// Sem sinal quando nada se moveu: valor zero, ou transacao que falhou.
    private var sign: String {
        guard !entry.amount.isZero, !isFailed else { return "" }
        return entry.direction == .received ? "+" : (entry.direction == .sent ? Fmt.minus : "")
    }
}

/// H2: detalhe da transacao.
struct ActivityDetailView: View {
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    let entry: ActivityEntry
    /// Recebimento EVM conferido em dois RPCs (auditoria 3, M2). Nil: ainda nao.
    @State private var check: Check?

    enum Check: Equatable { case checking, confirmed(UInt64), notFound, mismatch, unverifiable, failed }

    /// Recebimento numa rede EVM, que o indexador mostrou: confere na rede.
    private var verifiable: Bool {
        entry.direction == .received && entry.chain?.family == .evm && entry.status == .confirmed
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.lg) {
                hero
                facts
                if let counterparty = entry.counterparty {
                    // Sem botao de copiar: endereco de quem mandou pode ser isca (secao 4.10).
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(entry.direction == .received ? "De" : "Para").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        AddressBlocks(address: counterparty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.base)
                    .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                }
                identifier
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    /// O que se moveu: o logo grande (na troca, o que saiu e o que entrou), o tipo, o
    /// valor e a situacao.
    private var hero: some View {
        VStack(spacing: Space.xs) {
            if entry.direction == .swap, let asset = entry.asset, let received = entry.receivedAsset {
                HStack(spacing: Space.sm) {
                    logo(asset, size: 56)
                    Image(systemName: "arrow.forward").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.inkMuted)
                    logo(received, size: 56)
                }
                .padding(.bottom, Space.xs)
            } else {
                logo(entry.asset, size: 72)
                    .padding(Space.sm)
                    .background(Circle().fill(Palette.body))
                    .padding(.bottom, Space.xxs)
            }
            HStack(spacing: Space.xs) {
                Text(kind).typeStyle(.row).foregroundStyle(Palette.inkSoft)
                if entry.suspicious { TokenBadge(.suspicious) }
            }
            if entry.direction == .swap, let asset = entry.asset, let received = entry.receivedAsset, let amount = entry.receivedAmount {
                Text("+" + Fmt.crypto(amount, decimals: received.decimals, symbol: received.symbol, style: .full))
                    .typeStyle(.figure).foregroundStyle(isFailed ? Palette.inkMuted : Palette.up)
                    .strikethrough(isFailed)
                Text("por \(Fmt.crypto(entry.amount, decimals: asset.decimals, symbol: asset.symbol, style: .full))")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft)
            } else if let asset = entry.asset {
                Text(sign + Fmt.crypto(entry.amount, decimals: asset.decimals, symbol: asset.symbol, style: .full))
                    .typeStyle(.figure)
                    .foregroundStyle(isFailed ? Palette.inkMuted : (entry.direction == .received ? Palette.up : Palette.ink))
                    .strikethrough(isFailed)
                if let fiat = todayValue(of: asset, entry.amount) {
                    Text("≈ \(fiat) hoje").typeStyle(.body).foregroundStyle(Palette.inkSoft)
                }
            }
            status
                .task { await verify() }
                .padding(.top, Space.xs)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, Space.sm)
    }

    /// Moeda, rede (com o logo de cada uma), data e taxa.
    private var facts: some View {
        VStack(spacing: 0) {
            if entry.direction != .swap, let asset = entry.asset {
                factRow(String(localized: "Moeda")) {
                    logo(asset, size: 22, badge: false)
                    Text(verbatim: asset.name).typeStyle(.row).foregroundStyle(Palette.ink)
                }
            }
            if let chain = entry.chain {
                factRow(String(localized: "Rede")) {
                    NetworkBadge(chain: chain, size: 22, ring: .clear)
                    Text(verbatim: chain.name).typeStyle(.row).foregroundStyle(Palette.ink)
                }
            }
            factRow(String(localized: "Data")) {
                Text(entry.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Fmt.locale)))
                    .typeStyle(.row).foregroundStyle(Palette.ink)
            }
            if let fee = entry.fee, let chain = entry.chain {
                factRow(String(localized: "Taxa da rede")) {
                    Text(Fmt.crypto(fee, decimals: chain.nativeDecimals, symbol: chain.nativeSymbol, style: .full))
                        .typeStyle(.row).foregroundStyle(Palette.ink)
                }
            }
        }
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
    }

    /// O identificador da transacao, para copiar ou abrir no explorador da rede.
    private var identifier: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Identificador").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                .padding(.top, Space.base)
            Text(verbatim: entry.hash).typeStyle(.monoSmall).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.xxs)
                .padding(.bottom, Space.xs)
            Button {
                Pasteboard.copyAddress(entry.hash)
                toasts.show(String(localized: "Identificador copiado."))
            } label: {
                actionRow(String(localized: "Copiar"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            if let chain = entry.chain, let url = chain.explorerURL(tx: entry.hash) {
                Link(destination: url) {
                    actionRow(String(localized: "Ver no \(chain.explorerName)"), systemImage: "arrow.up.right")
                }
            }
        }
        .padding(.horizontal, Space.base)
        .padding(.bottom, Space.xxs)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
    }

    private var kind: String {
        switch entry.direction {
        case .sent: return String(localized: "Enviado")
        case .received: return String(localized: "Recebido")
        case .swap: return String(localized: "Troca")
        case .approval: return String(localized: "Autorização")
        case .order: return String(localized: "Ordem")
        case .other: return String(localized: "Transação")
        }
    }

    private var isFailed: Bool { if case .failed = entry.status { return true }; return false }
    private var sign: String {
        guard !entry.amount.isZero, !isFailed else { return "" }
        return entry.direction == .received ? "+" : (entry.direction == .sent ? Fmt.minus : "")
    }

    /// Quanto vale hoje, so para moeda da lista: token de fora pode ter preco de isca.
    private func todayValue(of asset: Asset, _ amount: BigUInt) -> String? {
        guard asset.origin == nil, !entry.suspicious, !amount.isZero, !isFailed, let price = portfolio.price(of: asset) else { return nil }
        return Fmt.fiat(Fmt.double(amount, decimals: asset.decimals) * price, session.currency)
    }

    @ViewBuilder
    private func logo(_ asset: Asset?, size: CGFloat, badge: Bool = true) -> some View {
        let unverified = asset?.origin != nil || entry.suspicious
        CoinLogo(coingeckoID: asset?.coingeckoID ?? entry.chain?.coingeckoID, symbol: asset?.symbol ?? entry.chain?.nativeSymbol ?? "",
                 size: size, network: badge ? entry.chain : nil, ringColor: Palette.body, unverified: unverified,
                 logoAsset: unverified && !entry.suspicious ? asset : nil)
            .overlay(alignment: .bottomTrailing) {
                if badge, let chain = entry.chain, isETHAwayFromHome(asset) {
                    NetworkBadge(chain: chain, size: size * 0.4, ring: Palette.body)
                        .offset(x: size * 0.08, y: size * 0.08)
                }
            }
    }

    /// O CoinLogo trata ETH na Base ou na Arbitrum como moeda nativa, sem selo; no
    /// detalhe a rede aparece sempre, menos na Ethereum.
    private func isETHAwayFromHome(_ asset: Asset?) -> Bool {
        guard let chain = entry.chain, (asset?.coingeckoID ?? chain.coingeckoID) == chain.coingeckoID else { return false }
        return chain.coingeckoID == Chain.ethereum.coingeckoID && chain.id != Chain.ethereum.id
    }

    private func factRow<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(spacing: Space.xs) {
            Text(label).typeStyle(.body).foregroundStyle(Palette.inkSoft)
            Spacer(minLength: Space.sm)
            value()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(minHeight: Height.rowCompact)
    }

    private func actionRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Space.sm) {
            Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
            Spacer(minLength: Space.sm)
            Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.inkSoft)
        }
        .frame(minHeight: Height.rowCompact)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var status: some View {
        if verifiable {
            // O indexador e um so: "Confirmada" so depois de dois RPCs mostrarem o valor
            // chegando a esta conta.
            switch check {
            case .confirmed(let confirmations):
                StatusBadge(kind: .done, text: confirmations > 1 ? String(localized: "Conferida na rede, \(Fmt.grouped(Double(confirmations), fractionDigits: 0)) confirmações") : String(localized: "Conferida na rede"))
            case .notFound:
                StatusBadge(kind: .pending, text: String(localized: "Segundo o indexador. A rede ainda não mostra esta transação"))
            case .mismatch:
                StatusBadge(kind: .failed, text: String(localized: "A rede não confirma este recebimento"))
            case .unverifiable:
                StatusBadge(kind: .pending, text: String(localized: "Segundo o indexador. Chegou por transação interna, que o recibo não mostra"))
            case .failed:
                StatusBadge(kind: .pending, text: String(localized: "Segundo o indexador. Não deu para conferir na rede agora"))
            case .checking, nil:
                StatusBadge(kind: .pending, text: String(localized: "Segundo o indexador. Conferindo na rede"))
            }
        } else {
            switch entry.status {
            case .pending(let detail): StatusBadge(kind: .pending, text: detail ?? String(localized: "Pendente"))
            case .confirmed: StatusBadge(kind: .done, text: String(localized: "Confirmada"))
            case .failed(let reason): StatusBadge(kind: .failed, text: reason ?? String(localized: "Falhou"))
            }
        }
    }

    private func verify() async {
        guard verifiable, check == nil, let chain = entry.chain,
              let text = session.selectedWallet?.account(chain)?.address, let owner = try? EVMAddress(text) else { return }
        check = .checking
        var contract: EVMAddress?
        if case .token(let address) = entry.asset?.kind { contract = try? EVMAddress(address.lowercased()) }
        if entry.asset?.kind != .native, contract == nil { check = .unverifiable; return }
        let result = await Task {
            try? await EVMReader.shared.verifyIncoming(chain: chain, hash: entry.hash, owner: owner, contract: contract, amount: entry.amount)
        }.value
        switch result {
        case .confirmed(let confirmations): check = .confirmed(confirmations)
        case .notFound: check = .notFound
        case .mismatch: check = .mismatch
        case .unverifiable: check = .unverifiable
        case nil: check = .failed
        }
    }

}

/// Enquanto o historico chega: as redes da carteira acendendo uma de cada vez, no meio
/// da tela. Com Reduzir Movimento, parado.
struct ActivityLoading: View {
    let chains: [Chain]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [Chain] { Array(chains.prefix(7)) }

    var body: some View {
        VStack(spacing: Space.md) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / 1.6
                HStack(spacing: -8) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, chain in
                        let wave = (sin((phase - Double(index) / Double(max(shown.count, 1))) * 2 * .pi) + 1) / 2
                        NetworkBadge(chain: chain, size: 36, ring: Palette.void)
                            .scaleEffect(reduceMotion ? 1 : 0.9 + 0.12 * wave)
                            .opacity(reduceMotion ? 1 : 0.45 + 0.55 * wave)
                            .zIndex(wave)
                    }
                }
            }
            VStack(spacing: Space.xxs) {
                Text("Lendo o histórico").typeStyle(.row).foregroundStyle(Palette.ink)
                Text(chains.count > 1 ? String(localized: "\(chains.count) redes, cada uma direto dos provedores públicos.") : String(localized: "Direto dos provedores públicos da rede."))
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Space.gutter)
        .accessibilityElement(children: .combine)
    }
}

/// Rede que nao respondeu agora: uma linha, sem cartao. O que estava guardado dela
/// continua na lista. No build de teste, o motivo tecnico fica atras de um toque.
private struct RefreshNotice: View {
    let chains: String
    let retry: () -> Void
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                Text("\(chains) não atualizou agora. Mostrando o que já estava salvo.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.xs)
                Button(action: retry) {
                    Text("Tentar de novo").typeStyle(.note).fontWeight(.semibold).foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
            }
            #if DEBUG
            if let detail = ActivityView.debugDetail {
                Button { details.toggle() } label: {
                    Text(details ? detail : "Ver detalhe técnico").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
            #endif
        }
    }
}
