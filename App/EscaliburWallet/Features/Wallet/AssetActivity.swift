import EscaliburChains
import EscaliburEngines
import SwiftUI

/// Os movimentos de um ativo, para a pagina dele: so as redes onde a carteira tem o
/// ativo, e so as linhas em que ele saiu ou entrou (inclusive como o lado recebido de
/// uma troca). O que a Atividade esconde como suspeito fica escondido aqui tambem.
@MainActor
@Observable
final class AssetActivityLoader {
    private(set) var entries: [ActivityEntry] = []
    private(set) var loading = false
    private(set) var loadedOnce = false
    /// Nenhuma rede respondeu.
    private(set) var failed = false
    /// Todas as redes do ativo estao sem historico nesta versao (BNB Chain, X Layer,
    /// Sonic): o motivo dito pelo motor.
    private(set) var unavailable: String?
    private var job: Task<Void, Never>?

    func load(wallet: WalletMeta?, assetIDs: Set<String>, chains: [Chain]) async {
        guard let wallet else { return }
        if let job { return await job.value }
        // Tarefa propria: sair da pagina no meio nao vira "nao foi possivel ler".
        let task = Task { await run(wallet: wallet, assetIDs: assetIDs, chains: chains) }
        job = task
        await task.value
        job = nil
    }

    private func run(wallet: WalletMeta, assetIDs: Set<String>, chains: [Chain]) async {
        loading = true
        defer { loading = false; loadedOnce = true }
        let jobs: [(Chain, DerivedAccount, any ActivitySource)] = chains.compactMap { chain in
            guard let account = wallet.account(chain), let source = ActivitySources.source(for: chain) else { return nil }
            return (chain, account, source)
        }
        var collected: [ActivityEntry] = []
        var reasons: [String] = []
        var answered = 0
        var pending = jobs
        // Uma segunda tentativa, 3 s depois, para a rede que falhou.
        for delay in [0, 3] where !pending.isEmpty {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            var failedIDs = Set<String>()
            await withTaskGroup(of: (String, [ActivityEntry]?, String?, Bool).self) { group in
                for (chain, account, source) in pending {
                    let usage = wallet.utxoUsage[chain.id]
                    group.addTask {
                        do {
                            return (chain.id, try await source.history(chain: chain, account: account, usage: usage), nil, true)
                        } catch SendEngineError.unavailable(let reason) {
                            return (chain.id, nil, reason, true)
                        } catch {
                            return (chain.id, nil, nil, false)
                        }
                    }
                }
                for await (id, items, reason, ok) in group {
                    if ok { answered += 1 } else { failedIDs.insert(id) }
                    if let items { collected += items }
                    if let reason { reasons.append(reason) }
                }
            }
            pending = jobs.filter { failedIDs.contains($0.0.id) }
        }
        entries = collected
            .filter { entry in
                guard !entry.suspicious, entry.direction != .other else { return false }
                return entry.asset.map { assetIDs.contains($0.id) } == true || entry.receivedAsset.map { assetIDs.contains($0.id) } == true
            }
            .sorted { $0.date > $1.date }
        failed = answered == 0 && !jobs.isEmpty
        unavailable = !reasons.isEmpty && reasons.count == jobs.count ? reasons.first : nil
    }
}

/// A secao "Atividade" da pagina do ativo: as ultimas oito, e o caminho para a lista
/// inteira na aba Atividade.
struct AssetActivitySection: View {
    @Environment(AppSession.self) private var session
    @Environment(Router.self) private var router
    let row: PortfolioRow
    @State private var loader = AssetActivityLoader()

    private static let shown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Atividade").typeStyle(.heading).foregroundStyle(Palette.ink)
                .padding(.horizontal, Space.gutter).padding(.bottom, Space.xs)
            if loader.entries.isEmpty {
                placeholder
            } else {
                ForEach(loader.entries.prefix(Self.shown)) { entry in
                    NavigationLink {
                        ActivityDetailView(entry: entry)
                    } label: {
                        ActivityRow(entry: entry, currency: session.currency, hidden: session.metadata.settings.hideBalances)
                    }
                    .buttonStyle(RowStyle())
                }
                if loader.entries.count > Self.shown {
                    TertiaryButton(title: "Ver tudo na Atividade") { router.tab = .activity }
                        .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
                }
            }
        }
        .task(id: session.selectedWallet?.id) {
            await loader.load(wallet: session.selectedWallet, assetIDs: Set(row.positions.map(\.asset.id)), chains: row.chains)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if !loader.loadedOnce || loader.loading {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: Space.sm) {
                        Circle().fill(Palette.body).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 8) { SkeletonBar(width: 120); SkeletonBar(width: 80) }
                        Spacer()
                        SkeletonBar(width: 72, height: 16)
                    }
                    .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
                }
            }
            .accessibilityLabel("Lendo os movimentos")
        } else if let reason = loader.unavailable {
            note(reason)
        } else if loader.failed {
            Banner(kind: .neutral, title: "Não foi possível ler os movimentos agora.", actionTitle: "Tentar de novo") {
                Task {
                    await loader.load(wallet: session.selectedWallet, assetIDs: Set(row.positions.map(\.asset.id)), chains: row.chains)
                }
            }
            .padding(.horizontal, Space.gutter)
        } else {
            note("Nenhum movimento de \(row.symbol) ainda. Envios, recebimentos e trocas aparecem aqui.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.gutter)
    }
}
