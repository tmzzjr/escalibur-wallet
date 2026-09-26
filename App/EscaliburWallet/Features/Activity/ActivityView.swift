import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import SwiftUI

@MainActor
@Observable
final class ActivityFeed {
    private(set) var entries: [ActivityEntry] = []
    private(set) var failed: [Chain] = []
    private(set) var loading = false
    private(set) var suspiciousCount = 0

    func load(_ wallet: WalletMeta?, disabled: Set<String>) async {
        guard let wallet, !loading else { return }
        loading = true
        defer { loading = false }
        var collected: [ActivityEntry] = []
        var failures: [Chain] = []
        await withTaskGroup(of: (Chain, [ActivityEntry]?).self) { group in
            for account in wallet.accounts {
                guard let chain = Chain.find(account.chainID), !disabled.contains(chain.id),
                      let source = ActivitySources.source(for: chain) else { continue }
                let usage = wallet.utxoUsage[chain.id]
                group.addTask { (chain, try? await source.history(chain: chain, account: account, usage: usage)) }
            }
            for await (chain, items) in group {
                if let items { collected += items } else { failures.append(chain) }
            }
        }
        suspiciousCount = collected.filter(\.suspicious).count
        entries = collected.filter { !$0.suspicious }.sorted { $0.date > $1.date }
        failed = failures
    }
}

/// H1: Atividade.
struct ActivityView: View {
    @Environment(AppSession.self) private var session
    @Environment(Router.self) private var router
    @State private var feed = ActivityFeed()
    @State private var receiving = false

    private var pending: [ActivityEntry] {
        feed.entries.filter { if case .pending = $0.status { return true }; return false }
    }

    private var grouped: [(String, [ActivityEntry])] {
        let calendar = Calendar(identifier: .gregorian)
        let done = feed.entries.filter { if case .pending = $0.status { return false }; return true }
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

                    if let failed = feed.failed.first {
                        Banner(kind: .neutral, title: "Não foi possível ler o histórico \(failed.id == "xrpl" ? "do" : "da") \(failed.name).",
                               actionTitle: "Tentar de novo") { Task { await reload() } }
                            .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                    }

                    if feed.entries.isEmpty && !feed.loading {
                        empty.padding(.top, Space.lg)
                    }

                    if !pending.isEmpty {
                        section("Pendentes", pending)
                    }
                    ForEach(grouped, id: \.0) { title, items in
                        section(title, items)
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
            .navigationDestination(for: ActivityEntry.self) { entry in ActivityDetailView(entry: entry) }
        }
        .task(id: session.selectedWallet?.id) { await reload() }
        .sheet(isPresented: $receiving) { ReceiveSheet(preselected: nil) }
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

    private var empty: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Nada aconteceu nesta carteira ainda").typeStyle(.row).foregroundStyle(Palette.ink)
            Text("Envios, recebimentos, trocas e ordens aparecem aqui, com o status de cada um.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "Receber") { receiving = true }.padding(.top, Space.xs)
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
        .padding(.horizontal, Space.gutter)
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry
    let currency: Fmt.Currency
    var hidden = false

    private var icon: String {
        switch entry.direction {
        case .sent: return "arrow.up"
        case .received: return "arrow.down"
        case .swap: return "arrow.left.arrow.right"
        case .approval: return "signature"
        case .order: return "scope"
        case .other: return "circle"
        }
    }

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
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Palette.rail))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                Text(subtitle).typeStyle(.note).foregroundStyle(isFailed ? Palette.down : Palette.inkSoft).lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            if let asset = entry.asset {
                Text(hidden ? Redaction.short : (sign + Fmt.crypto(entry.amount, decimals: asset.decimals, symbol: asset.symbol)))
                    .typeStyle(.row)
                    .foregroundStyle(entry.direction == .received ? Palette.up : Palette.ink)
            }
        }
        .padding(.horizontal, Space.gutter)
        .frame(height: Height.row)
        .contentShape(Rectangle())
    }

    private var isFailed: Bool { if case .failed = entry.status { return true }; return false }
    private var sign: String { entry.direction == .received ? "+" : (entry.direction == .sent ? Fmt.minus : "") }
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
