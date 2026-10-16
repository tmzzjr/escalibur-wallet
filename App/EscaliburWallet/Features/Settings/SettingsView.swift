import EscaliburChains
import EscaliburCore
import EscaliburKeys
import SwiftUI

/// S1: Ajustes.
struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var openingEnvelope = false
    @State private var alerts: PriceAlertFile?
    @State private var receipts: ReceiptWatchFile?

    private var alertsValue: String? {
        guard let alerts else { return nil }
        guard alerts.enabled, !alerts.coins.isEmpty else { return String(localized: "Desligados") }
        return alerts.coins.count == 1 ? String(localized: "1 moeda") : String(localized: "\(alerts.coins.count) moedas")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TabTitle(String(localized: "Ajustes"))

                    SettingsGroup {
                        NavigationLink { WalletsListView() } label: {
                            SettingsRow(icon: MainTabs.walletSymbol, title: String(localized: "Carteiras"), value: "\(session.metadata.wallets.count)")
                        }
                        NavigationLink { SecuritySettingsView() } label: {
                            SettingsRow(icon: "lock", title: String(localized: "Segurança"))
                        }
                        NavigationLink { ContactsView() } label: {
                            SettingsRow(icon: "book.closed", title: String(localized: "Endereços salvos"), value: session.metadata.contacts.isEmpty ? nil : "\(session.metadata.contacts.count)")
                        }
                        Button { openingEnvelope = true } label: {
                            SettingsRow(icon: "envelope.open", title: String(localized: "Abrir um envelope"))
                        }
                    }
                    .padding(.top, Space.lg)

                    SettingsSection(title: String(localized: "Preferências")) {
                        NavigationLink { NetworksSettingsView() } label: {
                            SettingsRow(icon: "network", title: String(localized: "Redes"),
                                        value: String(localized: "\(Chain.all.count - session.metadata.settings.disabledChainIDs.count) ligadas"))
                        }
                        NavigationLink { PriceAlertsView() } label: {
                            SettingsRow(icon: "bell", title: String(localized: "Alertas de preço"), value: alertsValue)
                        }
                        .accessibilityIdentifier("ajustes-alertas")
                        NavigationLink { ReceiptWatchView() } label: {
                            SettingsRow(icon: "arrow.down.circle", title: String(localized: "Aviso de recebimento"),
                                        value: receipts.map { $0.enabled ? String(localized: "Ligado") : String(localized: "Desligado") })
                        }
                        .accessibilityIdentifier("ajustes-recebimento")
                    }

                    SettingsSection(title: String(localized: "Sobre")) {
                        NavigationLink { SupportView() } label: {
                            SettingsRow(icon: "questionmark.circle", title: String(localized: "Suporte"))
                        }
                        .accessibilityIdentifier("ajustes-suporte")
                        NavigationLink { AboutView() } label: {
                            SettingsRow(icon: "info.circle", title: String(localized: "Taxas, código aberto e versão"))
                        }
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .statusBarBackdrop()
            .onAppear {
                Task { alerts = await PriceAlertCenter.shared.file() }
                Task { receipts = await ReceiptWatchCenter.shared.file() }
            }
        }
        .fullScreenCover(isPresented: $openingEnvelope) {
            OpenEnvelopeFlow(initialURL: nil) { openingEnvelope = false }
        }
    }
}

// MARK: Componentes de ajuste

struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .buttonStyle(RowStyle(surface: .body))
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .padding(.horizontal, Space.gutter)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.horizontal, Space.gutter)
            SettingsGroup { content }
        }
        .padding(.top, Space.lg)
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    var value: String? = nil
    var valueColor: Color = Palette.inkSoft
    var chevron = true

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular)).foregroundStyle(Palette.inkSoft).frame(width: 28)
            Text(title).typeStyle(.body).foregroundStyle(Palette.ink)
            Spacer()
            if let value { Text(value).typeStyle(.note).foregroundStyle(valueColor) }
            if chevron { Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted) }
        }
        .padding(.horizontal, Space.md)
        .frame(minHeight: Height.rowCompact)
        .contentShape(Rectangle())
    }
}

// MARK: Carteiras

struct WalletsListView: View {
    @Environment(AppSession.self) private var session
    @State private var adding = false
    @State private var reorder = WalletReorder()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup {
                    let wallets = session.metadata.wallets
                    ForEach(Array(wallets.enumerated()), id: \.element.id) { index, wallet in
                        NavigationLink { WalletSettingsView(walletID: wallet.id) } label: {
                            HStack(spacing: Space.sm) {
                                WalletGlyph(id: wallet.id, size: 32, selected: true, watchOnly: wallet.isWatchOnly)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: wallet.name).typeStyle(.row).foregroundStyle(Palette.ink)
                                    Text(wallet.hasBackup || wallet.isWatchOnly ? originText(wallet) : String(localized: "Sem cópia"))
                                        .typeStyle(.note).foregroundStyle(wallet.hasBackup || wallet.isWatchOnly ? Palette.inkSoft : Palette.caution)
                                }
                                Spacer()
                                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                            }
                            .padding(.horizontal, Space.md).frame(height: Height.row)
                            .background(reorder.dragging == wallet.id ? Palette.rail : Color.clear)
                        }
                        .disabled(reorder.justDropped)
                        .walletReorder(reorder, id: wallet.id, index: index, count: wallets.count, rowHeight: Height.row, session: session)
                    }
                }
                .padding(.top, Space.md)
                if session.metadata.wallets.count > 1 {
                    Text("Segure uma carteira e arraste para mudar a ordem.").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                        .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
                }
                SecondaryButton(title: String(localized: "Adicionar carteira")) { adding = true }
                    .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
            }
        }
        .scrollDisabled(reorder.dragging != nil)
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Carteiras")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $adding) { AddWalletView(isFirst: false) { adding = false } }
    }

    private func originText(_ wallet: WalletMeta) -> String {
        switch wallet.origin {
        case .created: if case .phrase(let n) = wallet.kind { return String(localized: "\(n) palavras") }; return ""
        case .importedPhrase: return String(localized: "Importada com a senha da carteira")
        case .importedEnvelope: return String(localized: "Importada de envelope")
        case .watch: return String(localized: "Só observar")
        }
    }
}

/// S2: uma carteira.
struct WalletSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    let walletID: UUID

    @State private var name = ""
    @State private var revealing = false
    @State private var sealing = false
    @State private var confirmRemove = false

    private var wallet: WalletMeta? { session.metadata.wallets.first { $0.id == walletID } }

    var body: some View {
        ScrollView {
            if let wallet {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("", text: $name)
                        .typeStyle(.title).foregroundStyle(Palette.ink)
                        .onSubmit { rename(wallet) }
                        .padding(.horizontal, Space.gutter)

                    if !wallet.isWatchOnly {
                        SettingsSection(title: String(localized: "Cópias")) {
                            SettingsRow(icon: "doc.text", title: String(localized: "Papel"),
                                        value: wallet.hasBackup ? (wallet.backupConfirmedAt.map { String(localized: "confirmado em \(Self.day($0))") } ?? String(localized: "importada")) : String(localized: "não confirmado"),
                                        valueColor: wallet.hasBackup ? Palette.inkSoft : Palette.caution, chevron: false)
                            SettingsRow(icon: "envelope", title: String(localized: "Envelope Escalibur"),
                                        value: wallet.envelopeSealedAt.map { String(localized: "lacrado em \(Self.day($0))") } ?? String(localized: "nenhum"), chevron: false)
                        }
                        if let last = wallet.lastRevealedAt {
                            Text("Última vez que a senha da carteira foi exibida: \(Fmt.relative(last, inSentence: true)).")
                                .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.horizontal, Space.gutter).padding(.top, Space.xs)
                        }
                        SettingsGroup {
                            Button { revealing = true } label: { SettingsRow(icon: "eye", title: String(localized: "Ver a senha da carteira")) }
                            Button { sealing = true } label: { SettingsRow(icon: "envelope.badge.shield.half.filled", title: String(localized: "Guardar num envelope Escalibur")) }
                            NavigationLink { PassphraseWalletView(base: wallet) } label: {
                                SettingsRow(icon: "key.horizontal", title: String(localized: "Abrir ou criar com passphrase"))
                            }
                        }
                        .padding(.top, Space.lg)
                    }

                    SettingsSection(title: String(localized: "Endereços")) {
                        ForEach(wallet.accounts, id: \.chainID) { account in
                            if let chain = Chain.find(account.chainID) {
                                Button {
                                    Pasteboard.copyAddress(account.address)
                                    toasts.show(String(localized: "Endereço copiado."))
                                } label: {
                                    HStack(spacing: Space.sm) {
                                        NetworkBadge(chain: chain, size: 24, ring: Palette.body)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(chain.name).typeStyle(.note).foregroundStyle(Palette.ink)
                                            Text(verbatim: Fmt.address(account.address, head: 8, tail: 6)).typeStyle(.monoSmall).foregroundStyle(Palette.inkSoft)
                                        }
                                        Spacer()
                                        Image(systemName: "doc.on.doc").font(.system(size: 13)).foregroundStyle(Palette.inkMuted)
                                    }
                                    .padding(.horizontal, Space.md).frame(minHeight: Height.row)
                                }
                            }
                        }
                    }

                    DestructiveButton(title: String(localized: "Remover deste iPhone")) { confirmRemove = true }
                        .padding(.horizontal, Space.gutter).padding(.top, Space.xl)
                }
                .padding(.vertical, Space.md)
                .onAppear { name = wallet.name }
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $revealing) {
            if let wallet { RevealFlow(wallet: wallet, purpose: wallet.hasBackup ? .reveal : .backup) { revealing = false } }
        }
        .fullScreenCover(isPresented: $sealing) {
            if let wallet { SealEnvelopeFlow(wallet: wallet) { sealing = false } }
        }
        .alert("Remover \(wallet?.name ?? "") deste iPhone?", isPresented: $confirmRemove) {
            Button("Remover permanentemente", role: .destructive) { Task { await remove() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(wallet?.hasBackup == false
                 ? "Esta carteira não tem cópia confirmada. Removida, o saldo fica inacessível para sempre."
                 : "O saldo continua na blockchain. Sem a senha da carteira ou um envelope, você não volta a acessá-lo.")
        }
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).locale(Fmt.locale))
    }

    private func rename(_ wallet: WalletMeta) {
        var updated = wallet
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updated.name = String(trimmed.prefix(40))
        session.update(updated)
    }

    private func remove() async {
        guard let wallet else { return }
        if !wallet.isWatchOnly {
            guard (try? await auth.perform(session, reason: String(localized: "Remover \(wallet.name) deste iPhone"), requirePIN: true, { _ in true })) == true else { return }
        }
        session.remove(wallet)
        dismiss()
    }
}

// MARK: Seguranca

/// S3: Seguranca.
struct SecuritySettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @State private var biometryPIN = false
    @State private var changingPIN = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup {
                    Button { changingPIN = true } label: { SettingsRow(icon: "circle.grid.3x3", title: String(localized: "Mudar o PIN")) }
                    Toggle(isOn: Binding(get: { session.biometryEnabled }, set: { on in
                        if on { biometryPIN = true } else { session.disableBiometry() }
                    })) {
                        HStack(spacing: Space.sm) {
                            Image(systemName: KeyServices.biometryIcon).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.inkSoft).frame(width: 24)
                            Text("\(KeyServices.biometryName)").typeStyle(.body).foregroundStyle(KeyServices.biometryAvailable ? Palette.ink : Palette.inkMuted)
                        }
                    }
                    .tint(Palette.accent)
                    .disabled(!KeyServices.biometryAvailable)
                    .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                    NavigationLink { VoiceSettingsView() } label: {
                        SettingsRow(icon: "waveform", title: String(localized: "Confirmação por voz"), value: session.metadata.settings.voice.enabled ? String(localized: "Ligada") : String(localized: "Desligada"))
                    }
                    NavigationLink { AutoLockView() } label: {
                        SettingsRow(icon: "lock.rotation", title: String(localized: "Bloquear o app"), value: AutoLockView.label(session.metadata.settings.autoLockSeconds))
                    }
                }
                .padding(.top, Space.md)

                Text(KeyServices.biometryAvailable
                     ? String(localized: "Depois de reiniciar o iPhone ou de a bateria acabar, o \(KeyServices.biometryName) só volta a valer depois do PIN digitado uma vez.")
                     : (KeyServices.biometryName == "Touch ID" ? String(localized: "Para usar o Touch ID aqui, cadastre uma digital em Ajustes do iPhone, em Touch ID e código.") : String(localized: "Para usar o \(KeyServices.biometryName) aqui, cadastre um rosto em Ajustes do iPhone, em \(KeyServices.biometryName) e código.")))
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)

                if let wallet = session.selectedWallet, !wallet.isWatchOnly {
                    SettingsGroup {
                        NavigationLink { PassphraseWalletView(base: wallet) } label: {
                            SettingsRow(icon: "key.horizontal", title: String(localized: "Carteira com passphrase"))
                        }
                    }
                    .padding(.top, Space.lg)
                    Text("Outra carteira, aberta pela senha de \(wallet.name) com uma passphrase que só você sabe.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                        .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsGroup {
                    NavigationLink { WipeSettingsView() } label: {
                        SettingsRow(icon: "trash", title: String(localized: "Apagar depois de PINs errados"), value: WipeSettingsView.label(KeyServices.root.wipeThreshold))
                    }
                }
                .padding(.top, Space.lg)

                Text("Todo envio, troca e ordem pede \(KeyServices.biometryName) ou PIN.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Segurança")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $biometryPIN) { EnableBiometrySheet { biometryPIN = false } }
        .fullScreenCover(isPresented: $changingPIN) { ChangePINFlow { changingPIN = false } }
    }

}

/// Quantos PINs errados apagam as carteiras deste iPhone, ou nunca.
struct WipeSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @State private var current = KeyServices.root.wipeThreshold
    @State private var error: String?

    static let options: [UInt32?] = [nil] + PINPolicy.wipeOptions.map { Optional($0) }

    static func label(_ threshold: UInt32?) -> String {
        threshold.map { String(localized: "Depois de \($0) erros") } ?? String(localized: "Nunca")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup {
                    ForEach(Self.options, id: \.self) { option in
                        Button { Task { await choose(option) } } label: {
                            HStack {
                                Text(Self.label(option)).typeStyle(.body).foregroundStyle(Palette.ink)
                                Spacer()
                                if current == option {
                                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                                }
                            }
                            .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, Space.md)
                Text(error ?? String(localized: "Contra quem pega o iPhone e tenta adivinhar o PIN. Depois do número escolhido de PINs errados seguidos, este iPhone apaga as carteiras; só a senha de cada carteira ou um envelope traz de volta. Mudar pede o PIN."))
                    .typeStyle(.note).foregroundStyle(error == nil ? Palette.inkMuted : Palette.down)
                    .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Apagar depois de erros")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Qualquer mudanca pede o PIN: ligar e uma forma de destruir as carteiras errando
    /// de proposito; desligar ou afrouxar tira a barreira contra quem tenta adivinhar.
    private func choose(_ option: UInt32?) async {
        guard option != current else { return }
        if option != nil, let missing = session.metadata.wallets.first(where: { !$0.hasBackup && !$0.isWatchOnly }) {
            error = String(localized: "Confirme a cópia de \(missing.name) antes de ligar.")
            return
        }
        error = nil
        let reason = option.map { String(localized: "Apagar depois de \($0) PINs errados") } ?? String(localized: "Nunca apagar por PINs errados")
        guard (try? await auth.perform(session, reason: reason, requirePIN: true, { _ in true })) == true else { return }
        do {
            try KeyServices.root.setWipeAfterErrors(option)
            current = option
        } catch {
            self.error = String(localized: "Não foi possível mudar agora. Tente de novo.")
        }
    }
}

struct EnableBiometrySheet: View {
    @Environment(AppSession.self) private var session
    let onDone: () -> Void
    @State private var entry = PINEntry()
    @State private var working = false

    var body: some View {
        PINScreen(title: String(localized: "Confirme com o PIN"), subtitle: String(localized: "Para ligar o \(KeyServices.biometryName)."), entry: entry, working: working, onComplete: {
            Task {
                working = true
                defer { working = false }
                do {
                    try await session.enableBiometry(pin: entry.take())
                    onDone()
                } catch RootKeyVault.Failure.wrongPIN {
                    entry.fail(String(localized: "PIN incorreto."))
                } catch RootKeyVault.Failure.throttled(let seconds) {
                    entry.fail(String(localized: "Tentativas demais. Tente de novo em \(LockView.duration(seconds))."))
                } catch RootKeyVault.Failure.cancelled {
                    entry.fail(String(localized: "O \(KeyServices.biometryName) não confirmou. Ele continua desligado."))
                } catch {
                    entry.fail(String(localized: "Não foi possível ligar o \(KeyServices.biometryName) agora."))
                }
            }
        }) {
            TertiaryButton(title: String(localized: "Cancelar"), action: onDone)
        }
    }
}

struct ChangePINFlow: View {
    @Environment(AppSession.self) private var session
    let onDone: () -> Void
    @State private var step = 0
    @State private var entry = PINEntry()
    @State private var current: SecureBytes?
    @State private var newPIN: SecureBytes?
    @State private var working = false

    var body: some View {
        PINScreen(
            title: [String(localized: "Digite o PIN atual"), String(localized: "Escolha o novo PIN"), String(localized: "Repita o novo PIN")][step],
            subtitle: step == 1 ? String(localized: "Não use o código do iPhone: quem rouba o iPhone geralmente já viu esse código.") : nil,
            entry: entry, working: working, onComplete: advance
        ) {
            TertiaryButton(title: String(localized: "Cancelar")) { current?.wipe(); newPIN?.wipe(); onDone() }
        }
    }

    /// Antes do ponto sem volta, qualquer falha deixa o PIN atual valendo.
    static func message(for error: Error) -> String {
        switch error as? RootKeyVault.Failure {
        case .wrongPIN: return String(localized: "O PIN atual não confere.")
        case .throttled(let seconds): return String(localized: "Tentativas demais. Tente de novo em \(LockView.duration(seconds)).")
        case .malformedPIN: return "O PIN precisa ter 6 números."
        default: return String(localized: "Não foi possível trocar. O PIN atual continua valendo.")
        }
    }

    private func advance() {
        let pin = entry.take()
        switch step {
        case 0:
            current = pin
            step = 1
        case 1:
            newPIN = pin
            step = 2
        default:
            guard let current, let newPIN else { return }
            let same = Hash.constantTimeEqual(newPIN, pin)
            pin.wipe()
            guard same else {
                entry.fail(String(localized: "Os dois não conferem. Escolha de novo."))
                step = 1
                return
            }
            working = true
            Task {
                do {
                    try await Offload.run {
                        defer { current.wipe(); newPIN.wipe() }
                        let rk = try KeyServices.root.unlock(pin: current)
                        defer { rk.wipe() }
                        try KeyServices.root.changePIN(rk: rk, newPIN: newPIN)
                    }
                    onDone()
                } catch RootKeyVault.Failure.wiped {
                    session.eraseEverything()
                    onDone()
                } catch {
                    working = false
                    step = 0
                    entry.fail(Self.message(for: error))
                }
            }
        }
    }
}

struct AutoLockView: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @State private var error: String?
    static let options = [0, 30, 60]

    /// O maior prazo oferecido. Um valor gravado por uma versao anterior (5 ou 15
    /// minutos) vale como este.
    static func clamped(_ seconds: Int) -> Int { min(max(seconds, 0), options.last ?? 60) }

    /// O motivo que o Face ID mostra ao mudar o prazo.
    static func reason(_ seconds: Int) -> String {
        switch clamped(seconds) {
        case 0: return String(localized: "Bloquear o app ao sair dele")
        case 30: return String(localized: "Bloquear o app depois de 30 segundos")
        default: return String(localized: "Bloquear o app depois de 1 minuto")
        }
    }

    static func label(_ seconds: Int) -> String {
        switch clamped(seconds) {
        case 0: return String(localized: "Ao sair do app")
        case 30: return String(localized: "Depois de 30 segundos")
        default: return String(localized: "Depois de 1 minuto")
        }
    }

    var body: some View {
        ScrollView {
            SettingsGroup {
                ForEach(Self.options, id: \.self) { seconds in
                    Button {
                        Task { await choose(seconds) }
                    } label: {
                        HStack {
                            Text(Self.label(seconds)).typeStyle(.body).foregroundStyle(Palette.ink)
                            Spacer()
                            if Self.clamped(session.metadata.settings.autoLockSeconds) == seconds {
                                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                            }
                        }
                        .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                    }
                }
            }
            .padding(.top, Space.md)
            Text(error ?? String(localized: "Encurtar vale na hora. Alongar pede o PIN."))
                .typeStyle(.note).foregroundStyle(error == nil ? Palette.inkMuted : Palette.down)
                .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Bloquear o app")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Encurtar so reduz a janela de quem pega o iPhone destravado. Alongar amplia, e
    /// por isso pede o PIN.
    private func choose(_ seconds: Int) async {
        error = nil
        let current = Self.clamped(session.metadata.settings.autoLockSeconds)
        guard seconds != current else { return }
        if seconds > current {
            guard (try? await auth.perform(session, reason: Self.reason(seconds), requirePIN: true, { _ in true })) == true else { return }
        }
        let previous = session.metadata.settings.autoLockSeconds
        session.metadata.settings.autoLockSeconds = seconds
        do {
            try session.persist()
        } catch {
            session.metadata.settings.autoLockSeconds = previous
            self.error = String(localized: "Não foi possível salvar. Tente de novo.")
        }
    }
}

struct NetworksSettingsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Para ler saldos, cotações e enviar, o app fala direto com nós públicos de cada rede, de empresas diferentes. Não existe servidor da Escalibur no meio.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.horizontal, Space.gutter).padding(.top, Space.md)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsGroup {
                    ForEach(Chain.all) { chain in
                        Toggle(isOn: Binding(
                            get: { !session.metadata.settings.disabledChainIDs.contains(chain.id) },
                            set: { on in
                                if on { session.metadata.settings.disabledChainIDs.remove(chain.id) } else { session.metadata.settings.disabledChainIDs.insert(chain.id) }
                                try? session.persist()
                            }
                        )) {
                            HStack(spacing: Space.sm) {
                                NetworkBadge(chain: chain, size: 24, ring: Palette.body)
                                Text(chain.name).typeStyle(.body).foregroundStyle(Palette.ink)
                            }
                        }
                        .tint(Palette.accent)
                        .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                    }
                }
                .padding(.top, Space.md)
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Redes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    @State private var legalDocument: LegalDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Taxas").typeStyle(.heading).foregroundStyle(Palette.ink)
                    Text("A Escalibur não cobra taxa sobre envios, recebimentos, trocas ou ordens. Você paga só a taxa da rede e, nas trocas, a do provedor, que já vem dentro do valor que você recebe.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Código aberto").typeStyle(.heading).foregroundStyle(Palette.ink)
                    Text("Todo o código que guarda chaves, assina e fala com as redes é aberto e conferível. As bibliotecas de criptografia são compiladas do fonte e travadas por digesto.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    Text("Versão \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Preços").typeStyle(.heading).foregroundStyle(Palette.ink)
                    Text("Preços e dados de mercado: CoinGecko, com CoinPaprika e OKX de reserva. Os saldos e as transações vêm direto das redes.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                // A licenca CC BY pede o autor, o link da licenca e o que foi alterado.
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Créditos").typeStyle(.heading).foregroundStyle(Palette.ink)
                    Text("A moeda 3D do tour usa a textura de “Bit Coin”, de marcio3d (sketchfab.com), com licença CC BY 4.0 (creativecommons.org/licenses/by/4.0). A textura foi recortada para a frente, o verso e a borda da moeda.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                SettingsGroup {
                    Button { legalDocument = .terms } label: { SettingsRow(icon: "doc.text", title: String(localized: "Termos de uso")) }
                    Button { legalDocument = .privacy } label: { SettingsRow(icon: "hand.raised", title: String(localized: "Política de privacidade")) }
                }
                // O grupo ja traz a margem da tela; aqui ela vem do VStack, e somar as duas
                // desalinhava os botoes do texto acima.
                .padding(.horizontal, -Space.gutter)
            }
            .padding(Space.gutter)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Sobre")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $legalDocument) { LegalDocumentView(document: $0) }
    }
}
