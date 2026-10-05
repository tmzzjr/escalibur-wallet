import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import EscaliburNetwork
import SwiftUI

@MainActor
@Observable
final class ActivityFeed {
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
    func load(_ wallet: WalletMeta?, disabled: Set<String>) async {
        guard let wallet, !loading else { return }
        loading = true
        defer { loading = false; remaining = 0 }
        let progressive = entries.isEmpty
        var collected: [ActivityEntry] = []
        var failures: [Chain] = []
        var missing: [(chain: Chain, reason: String)] = []
        let jobs: [(Chain, DerivedAccount, any ActivitySource, UTXOUsage?)] = wallet.accounts.compactMap { account in
            guard let chain = Chain.find(account.chainID), !disabled.contains(chain.id),
                  let source = ActivitySources.source(for: chain) else { return nil }
            return (chain, account, source, wallet.utxoUsage[chain.id])
        }
        var pending = jobs
        for attempt in 0...Self.retryDelays.count {
            if attempt > 0 { try? await Task.sleep(for: Self.retryDelays[attempt - 1]) }
            remaining = pending.count
            failures = []
            await withTaskGroup(of: (Chain, Outcome).self) { group in
                for (chain, account, source, usage) in pending {
                    group.addTask { (chain, await Self.read(source, chain: chain, account: account, usage: usage)) }
                }
                for await (chain, outcome) in group {
                    remaining -= 1
                    switch outcome {
                    case .items(let items): collected += items
                    case .unavailable(let reason): missing.append((chain, reason))
                    case .failed: failures.append(chain)
                    }
                    if progressive { publish(collected, failures, missing) }
                }
            }
            pending = jobs.filter { job in failures.contains { $0.id == job.0.id } }
            if pending.isEmpty { break }
        }
        publish(collected, failures, missing)
        loadedOnce = true
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

    private func publish(_ collected: [ActivityEntry], _ failures: [Chain], _ missing: [(chain: Chain, reason: String)]) {
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
    @State private var feed = ActivityFeed()
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
            if calendar.isDateInToday(entry.date) { title = "Hoje" }
            else if calendar.isDateInYesterday(entry.date) { title = "Ontem" }
            else { title = entry.date.formatted(.dateTime.day().month(.wide).locale(Fmt.locale)) }
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TabTitle("Atividade")

                    if !feed.failed.isEmpty {
                        Banner(kind: .neutral, title: "Não foi possível ler o histórico de \(Self.names(feed.failed)) agora.",
                               message: Self.debugDetail, actionTitle: "Tentar de novo") { Task { await reload() } }
                            .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                    }

                    if feed.entries.isEmpty {
                        if feed.loading || !feed.loadedOnce {
                            ActivityLoading(chains: session.selectedWallet?.accounts.compactMap { Chain.find($0.chainID) } ?? [])
                                .frame(maxWidth: .infinity)
                                .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length * 0.72 }
                        } else {
                            empty
                                .frame(maxWidth: .infinity)
                                .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length * 0.8 }
                        }
                    }

                    if !pending.isEmpty {
                        section("Pendentes", pending)
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
                        SecondaryButton(title: "Mostrar mais") { visibleCount += 20 }
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
                        Text("\(feed.suspiciousCount) \(feed.suspiciousCount == 1 ? "recebimento suspeito escondido" : "recebimentos suspeitos escondidos"). São envios de valor zero ou de tokens fora da lista, muitas vezes de endereços parecidos com os seus.")
                            .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                            .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .refreshable { await reload() }
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
        let recent = NetworkDiagnostics.shared.recent()
        return recent.isEmpty ? nil : "Teste: " + recent.prefix(8).joined(separator: "; ")
        #else
        return nil
        #endif
    }

    static func names(_ chains: [Chain]) -> String {
        let names = chains.map(\.name)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) e \(names[1])"
        case 3: return "\(names[0]), \(names[1]) e \(names[2])"
        default: return "\(names[0]), \(names[1]) e mais \(names.count - 2) redes"
        }
    }

    private func reload() async {
        await feed.load(session.selectedWallet, disabled: session.metadata.settings.disabledChainIDs)
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
            PrimaryButton(title: "Receber") { receiving = true }.padding(.top, Space.lg)
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
        case .sent: return "Enviado · \(symbol)"
        case .received: return "Recebido · \(symbol)"
        case .swap: return "Troca · \(symbol)"
        case .approval: return "Autorização · \(symbol)"
        case .order: return "Ordem · \(symbol)"
        case .other: return entry.chain?.name ?? ""
        }
    }

    private var subtitle: String {
        let time = entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Fmt.locale))
        switch entry.status {
        case .pending(let detail): return detail ?? "Aguardando confirmação"
        case .failed: return "Falhou"
        case .confirmed:
            guard let counterparty = entry.counterparty else { return time }
            let preposition = entry.direction == .received ? "De" : "Para"
            return "\(preposition) \(Fmt.address(counterparty)) · \(time)"
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
            if let asset = entry.asset {
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
    let entry: ActivityEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                if let asset = entry.asset {
                    Text((entry.direction == .received ? "+" : "") + Fmt.crypto(entry.amount, decimals: asset.decimals, symbol: asset.symbol, style: .full))
                        .typeStyle(.figure).foregroundStyle(Palette.ink)
                }
                status
                VStack(alignment: .leading, spacing: Space.xs) {
                    if let counterparty = entry.counterparty {
                        Text(entry.direction == .received ? "De" : "Para").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        AddressBlocks(address: counterparty)
                    }
                    line("Rede", entry.chain?.name ?? "")
                    line("Data", entry.date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Fmt.locale)))
                    if let fee = entry.fee, let chain = entry.chain {
                        line("Taxa da rede", Fmt.crypto(fee, decimals: chain.nativeDecimals, symbol: chain.nativeSymbol, style: .full))
                    }
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Identificador").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    Text(verbatim: entry.hash).typeStyle(.monoSmall).foregroundStyle(Palette.ink)
                    HStack(spacing: Space.sm) {
                        Button {
                            Pasteboard.copyAddress(entry.hash)
                            toasts.show("Identificador copiado.")
                        } label: {
                            Text("Copiar").typeStyle(.note).fontWeight(.semibold).foregroundStyle(Palette.ink)
                        }
                        if let chain = entry.chain, let url = chain.explorerURL(tx: entry.hash) {
                            Link(destination: url) {
                                HStack(spacing: 4) {
                                    Text("Ver no \(chain.explorerName)").typeStyle(.note).fontWeight(.semibold)
                                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(Palette.ink)
                            }
                        }
                    }
                }
            }
            .padding(Space.gutter)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var status: some View {
        switch entry.status {
        case .pending(let detail): StatusBadge(kind: .pending, text: detail ?? "Pendente")
        case .confirmed: StatusBadge(kind: .done, text: "Confirmada")
        case .failed(let reason): StatusBadge(kind: .failed, text: reason ?? "Falhou")
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            Spacer()
            Text(value).typeStyle(.note).foregroundStyle(Palette.ink)
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
                Text(chains.count > 1 ? "\(chains.count) redes, cada uma direto dos provedores públicos." : "Direto dos provedores públicos da rede.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Space.gutter)
        .accessibilityElement(children: .combine)
    }
}
