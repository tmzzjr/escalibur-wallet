import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import SwiftUI

/// As contas que o aviso de recebimento confere: as de todas as carteiras, nas redes
/// ligadas, so os enderecos publicos.
enum ReceiptAccounts {
    @MainActor
    static func all(_ session: AppSession) -> [ReceiptWatchFile.Account] {
        let disabled = session.metadata.settings.disabledChainIDs
        var out: [ReceiptWatchFile.Account] = []
        var seen = Set<String>()
        for wallet in session.metadata.wallets {
            for account in wallet.accounts {
                guard let chain = Chain.all.first(where: { $0.id == account.chainID }), !disabled.contains(chain.id) else { continue }
                let addresses = Portfolio.addresses(for: account, chain: chain, usage: wallet.utxoUsage[chain.id])
                guard seen.insert("\(chain.id)|\(addresses.first ?? "")").inserted else { continue }
                out.append(.init(chainID: chain.id, addresses: addresses))
            }
        }
        return out
    }

    /// Ligado por padrao (pedido do dono, 14/10/2026): na primeira vez que a carteira abre
    /// com o dono sem ter escolhido, pede a permissao de notificacao e liga. Desligar em
    /// Ajustes vale para sempre; sem permissao, fica desligado.
    @MainActor
    static func enableByDefault(_ session: AppSession) async {
        guard !Preferences.receiptWatchChosen, session.phase == .unlocked, !session.metadata.wallets.isEmpty else { return }
        #if DEBUG
        if DebugDemo.enabled { return }
        #endif
        Preferences.receiptWatchChosen = true
        let accounts = all(session)
        guard await PriceAlertCenter.requestPermission() else { return }
        await ReceiptWatchCenter.shared.enable(accounts: accounts)
    }

    /// Muda quando as contas mudam: carteira nova, rede ligada ou desligada, endereco
    /// UTXO novo. Barato: sem derivar endereco.
    @MainActor
    static func signature(_ session: AppSession) -> String {
        let wallets = session.metadata.wallets.map { wallet in
            "\(wallet.id):\(wallet.accounts.count):" + wallet.utxoUsage.map { "\($0.key)\($0.value.receiveUsed)/\($0.value.changeUsed)" }.sorted().joined()
        }
        return wallets.joined(separator: ",") + "|" + session.metadata.settings.disabledChainIDs.sorted().joined(separator: ",")
    }
}

/// Ajustes: avisar quando chegar moeda, sem servidor.
struct ReceiptWatchView: View {
    @Environment(AppSession.self) private var session
    @State private var file = ReceiptWatchFile()
    @State private var denied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: Space.xs) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Palette.control))
                    Text("Aviso de recebimento").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.xs)
                    Text("O próprio iPhone confere o saldo das suas contas e avisa quando entra moeda. Sem servidor da Escalibur no caminho.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                .padding(.horizontal, Space.gutter).padding(.top, Space.md)

                SettingsGroup {
                    Toggle(isOn: Binding(get: { file.enabled }, set: { setEnabled($0) })) {
                        label("bell", "Avisar quando chegar moeda")
                    }
                    .tint(Palette.accent)
                    .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                    .accessibilityIdentifier("recebimento-ligar")
                    if file.enabled {
                        Toggle(isOn: Binding(get: { file.showDetails }, set: { on in
                            file.showDetails = on
                            Task { await ReceiptWatchCenter.shared.setShowDetails(on) }
                        })) {
                            label("eye", "Valor e moeda no aviso", file.showDetails ? "Ex.: Recebeu 100 USDT, na Tron" : "A tela bloqueada só diz que entrou moeda")
                        }
                        .tint(Palette.accent)
                        .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                    }
                }
                .padding(.top, Space.lg)

                if denied {
                    Banner(kind: .caution, title: "As notificações da Escalibur estão desligadas no iPhone.",
                           message: "Ligue em Ajustes do iPhone, Notificações, Escalibur Wallet.",
                           actionTitle: "Abrir Ajustes do iPhone") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                }

                VStack(alignment: .leading, spacing: Space.sm) {
                    note("Sem servidor, quem decide a hora de conferir é o iOS: algumas vezes por hora com o iPhone em uso, menos quando ele está parado ou com pouca bateria. O aviso pode chegar alguns minutos depois de a moeda entrar. Com o app aberto, a conferência é a cada 2 minutos.")
                    note("Para conferir com o iPhone bloqueado, os endereços públicos das suas contas ficam num arquivo à parte, que abre depois do primeiro desbloqueio do iPhone, fora dos dados cifrados da carteira. Nenhuma chave, frase ou nome de carteira entra nele. Vem ligado; desligar apaga o arquivo.")
                    note("Contam a moeda de cada rede e os tokens da lista conferida. Token fora da lista não avisa: é por ele que chega o spam.")
                }
                .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
            }
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            file = await ReceiptWatchCenter.shared.file()
            denied = file.enabled ? await PriceAlertCenter.permissionDenied() : false
        }
    }

    private func setEnabled(_ on: Bool) {
        Preferences.receiptWatchChosen = true
        file.enabled = on
        guard on else {
            denied = false
            Task { await ReceiptWatchCenter.shared.disable() }
            return
        }
        let accounts = ReceiptAccounts.all(session)
        Task {
            guard await PriceAlertCenter.requestPermission() else {
                denied = true
                file.enabled = false
                return
            }
            denied = false
            await ReceiptWatchCenter.shared.enable(accounts: accounts)
            file = await ReceiptWatchCenter.shared.file()
        }
    }

    private func label(_ icon: String, _ title: String, _ subtitle: String? = nil) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.inkSoft).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typeStyle(.body).foregroundStyle(Palette.ink)
                if let subtitle { Text(subtitle).typeStyle(.note).foregroundStyle(Palette.inkSoft) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
    }
}
