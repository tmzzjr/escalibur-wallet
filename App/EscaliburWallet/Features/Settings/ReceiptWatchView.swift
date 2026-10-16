import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import SwiftUI

/// As contas que o aviso de recebimento confere: as das carteiras que podem receber, nas
/// redes ligadas, so os enderecos publicos.
///
/// A carteira com passphrase fica de fora (auditoria 4, C7-03): o arquivo do aviso abre
/// com o iPhone bloqueado depois do primeiro desbloqueio, e com ela nele quem extrai os
/// dados do aparelho nesse estado acha a carteira que o dono quis esconder. A que ainda nao
/// tem copia conferida tambem: ela nao recebe.
enum ReceiptAccounts {
    @MainActor
    static func all(_ session: AppSession) -> [ReceiptWatchFile.Account] {
        let disabled = session.metadata.settings.disabledChainIDs
        var out: [ReceiptWatchFile.Account] = []
        var seen = Set<String>()
        for wallet in session.metadata.wallets where !wallet.hasPassphrase && (wallet.hasBackup || wallet.isWatchOnly) {
            for account in wallet.accounts {
                guard let chain = Chain.all.first(where: { $0.id == account.chainID }), !disabled.contains(chain.id) else { continue }
                // A conta da Tron com outra chave no controle nao recebe por caminho nenhum.
                if chain.family == .tron, wallet.tronForeignControl == true { continue }
                let addresses = Portfolio.addresses(for: account, chain: chain, usage: wallet.utxoUsage[chain.id])
                guard seen.insert("\(chain.id)|\(addresses.first ?? "")").inserted else { continue }
                out.append(.init(chainID: chain.id, addresses: addresses))
            }
        }
        return out
    }

    /// Oferecido na primeira vez que a carteira abre (pedido do dono, 14/10/2026: o aviso
    /// vem para todo mundo). A permissao de notificacao nao vale como aceite do arquivo
    /// legivel com o iPhone bloqueado (auditoria 4, C7-03): antes dela, uma folha diz o
    /// preco, e o dono escolhe (`ReceiptWatchOffer`). Quem ja tinha o aviso ligado pelo
    /// padrao antigo, sem folha, ve a folha uma vez; "Agora nao" desliga.
    @MainActor
    static func shouldOffer(_ session: AppSession) -> Bool {
        guard !Preferences.receiptOfferSeen, session.phase == .unlocked, !session.metadata.wallets.isEmpty else { return false }
        #if DEBUG
        if DebugDemo.enabled { return false }
        #endif
        return true
    }

    /// O "sim" da folha: pede a permissao de notificacao e liga. Sem permissao, fica
    /// desligado. Qualquer resposta vale para sempre.
    @MainActor
    static func accept(_ session: AppSession) async {
        Preferences.receiptWatchChosen = true
        Preferences.receiptOfferSeen = true
        let accounts = all(session)
        guard await PriceAlertCenter.requestPermission() else { return }
        await ReceiptWatchCenter.shared.enable(accounts: accounts)
    }

    /// Muda quando as contas mudam: carteira nova, rede ligada ou desligada, endereco
    /// UTXO novo, copia conferida (a carteira passa a poder receber). Barato: sem derivar
    /// endereco.
    @MainActor
    static func signature(_ session: AppSession) -> String {
        let wallets = session.metadata.wallets.map { wallet in
            "\(wallet.id):\(wallet.accounts.count):\(wallet.hasBackup):" + wallet.utxoUsage.map { "\($0.key)\($0.value.receiveUsed)/\($0.value.changeUsed)" }.sorted().joined()
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
                        label("bell", String(localized: "Avisar quando chegar moeda"))
                    }
                    .tint(Palette.accent)
                    .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                    .accessibilityIdentifier("recebimento-ligar")
                    if file.enabled {
                        Toggle(isOn: Binding(get: { file.showDetails }, set: { on in
                            file.showDetails = on
                            Task { await ReceiptWatchCenter.shared.setShowDetails(on) }
                        })) {
                            label("eye", String(localized: "Valor e moeda no aviso"), file.showDetails ? String(localized: "Ex.: Recebeu 100 USDT, na Tron") : String(localized: "A tela bloqueada só diz que entrou moeda"))
                        }
                        .tint(Palette.accent)
                        .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                    }
                }
                .padding(.top, Space.lg)

                if denied {
                    Banner(kind: .caution, title: String(localized: "As notificações da Escalibur estão desligadas no iPhone."),
                           message: String(localized: "Ligue em Ajustes do iPhone, Notificações, Escalibur."),
                           actionTitle: String(localized: "Abrir Ajustes do iPhone")) {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .padding(.horizontal, Space.gutter).padding(.top, Space.sm)
                }

                VStack(alignment: .leading, spacing: Space.sm) {
                    note(String(localized: "Por segurança, a Escalibur não tem servidor: não existe ninguém para avisar o iPhone na hora em que a moeda chega. Quem confere é o próprio iPhone, quando o iOS deixa: algumas vezes por hora em uso, menos parado ou com pouca bateria. Por isso o aviso pode chegar alguns minutos depois. Com o app aberto, a conferência é a cada 2 minutos."))
                    note(ReceiptWatchOffer.price)
                    note(String(localized: "Carteiras com passphrase e carteiras com as palavras ainda não confirmadas ficam de fora. Desligar apaga o arquivo."))
                    note(String(localized: "Contam a moeda de cada rede e os tokens da lista conferida. Token fora da lista não avisa: é por ele que chega o spam."))
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
        Preferences.receiptOfferSeen = true
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
            // Ligar o aviso liga junto o valor e a moeda (pedido do dono, 16/10/2026); da para
            // desligar em seguida, e a tela bloqueada volta a dizer so que entrou moeda.
            await ReceiptWatchCenter.shared.setShowDetails(true)
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

/// A folha que oferece o aviso de recebimento, com o preco dito antes do "sim".
struct ReceiptWatchOffer: View {
    @Environment(AppSession.self) private var session
    let onDone: () -> Void
    @State private var working = false
    @State private var shownArrival = false
    /// Quantas vezes o dono girou a moeda: cada giro troca o valor que chegou.
    @State private var arrivals = 0

    /// O fundo da folha: quase preto, um cinza bem escuro (pedido do dono, 16/10/2026).
    static let sheetColor = Color(hex: 0x0E0E10)

    /// Valores de exemplo, nunca um saldo de verdade.
    private static let samples: [Double] = [0.0042, 0.015, 0.0008, 0.12]

    /// O aviso de exemplo, como o iPhone mostraria.
    private var arrival: some View {
        let amount = Self.samples[arrivals % Self.samples.count]
        return HStack(spacing: Space.xs) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.success)
            Text("Chegou \(amount.formatted(.number.precision(.fractionLength(2...4)).locale(Fmt.locale))) BTC")
                .typeStyle(.row).foregroundStyle(Palette.ink)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.md).frame(height: 40)
        .background(Capsule().fill(Palette.control))
        .overlay(Capsule().stroke(Palette.edge, lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// O preco do aviso, dito em Ajustes, Aviso de recebimento.
    static var price: String {
        String(localized: "Para conferir com o iPhone bloqueado, os endereços públicos das suas carteiras e o último saldo visto de cada moeda ficam num arquivo à parte, que abre depois do primeiro desbloqueio do iPhone, fora dos dados cifrados da carteira. Quem extrair os dados de um iPhone nesse estado lê esses endereços. Nenhuma chave, frase ou nome de carteira entra nele.")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // A moeda girando, que o dedo gira, e o aviso de que ela chegou (pedido do
                // dono, 16/10/2026). Cada giro do dono faz chegar mais uma.
                ZStack(alignment: .top) {
                    SpinningCoin { withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { arrivals += 1 } }
                        .frame(height: 200)
                        // Um respiro entre a notificacao e a moeda (pedido do dono, 16/10/2026).
                        .padding(.top, 60)
                    if shownArrival {
                        arrival
                            .id(arrivals)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
                .frame(height: 268)
                .frame(maxWidth: .infinity)

                Text("Avisar quando chegar moeda?").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
                    .fixedSize(horizontal: false, vertical: true)
                Text("O próprio iPhone confere o saldo e avisa, sem servidor da Escalibur no caminho.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)

                // Os dois itens do arquivo a parte sairam a pedido do dono (16/10/2026): o preco
                // inteiro continua em Ajustes, Aviso de recebimento (`price`).
                Text("Carteiras com passphrase ficam de fora. Dá para mudar em Ajustes, Aviso de recebimento.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.lg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.gutter)
            // Tudo um pouco mais para baixo, mais perto do centro da folha.
            .padding(.top, Space.xl + Space.sm)
            .padding(.bottom, Space.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.sm) {
                PrimaryButton(title: String(localized: "Ligar o aviso"), loading: working) {
                    working = true
                    Task {
                        await ReceiptAccounts.accept(session)
                        working = false
                        onDone()
                    }
                }
                .accessibilityIdentifier("recebimento-oferta-ligar")
                SecondaryButton(title: String(localized: "Agora não")) {
                    Preferences.receiptWatchChosen = true
                    Preferences.receiptOfferSeen = true
                    // Ligado pelo padrao antigo, sem a folha: o "nao" desliga e apaga o arquivo.
                    Task { await ReceiptWatchCenter.shared.disable() }
                    onDone()
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xs)
            .background(Self.sheetColor)
        }
        .task {
            guard !shownArrival else { return }
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { shownArrival = true }
        }
        .sensoryFeedback(.success, trigger: arrivals)
        .presentationDetents([.large])
        .presentationBackground(Self.sheetColor)
        .presentationCornerRadius(Radius.sheet)
        .interactiveDismissDisabled()
    }
}
