import CryptoKit
import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Observation
import SwiftUI
import UserNotifications

/// Como o dono prova presenca para uma operacao que precisa da chave raiz.
enum Credential: Sendable {
    case pin(SecureBytes)
    case biometry(reason: String)
    /// O PIN e, com o Face ID ligado, o rosto tambem (A1): ver as palavras, lacrar o
    /// envelope, remover carteira, desligar o Face ID.
    case pinAndBiometry(SecureBytes, reason: String)
    /// Modo reforcado: o PIN e o rosto pela criptografia, em tudo (docs/seguranca.md §2.6).
    case hardened(SecureBytes, reason: String)
}

/// O estado de alto nivel do app.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        /// Primeira abertura: boas-vindas e escolha do PIN.
        case onboarding
        case locked
        case unlocked
    }

    private(set) var phase: Phase
    var metadata = Metadata()
    /// A chave dos metadados. Existe so enquanto o app esta destrancado.
    private var indexKey: SymmetricKey?
    /// Instante da ida para o segundo plano no relogio monotonico, que conta o tempo
    /// dormindo e nao anda com o relogio de parede: atrasar o relogio nao evita o
    /// bloqueio automatico.
    private var backgroundedAt: TimeInterval?

    init() {
        #if DEBUG
        // Testes de interface comecam do zero, como uma instalacao nova.
        if ProcessInfo.processInfo.arguments.contains("-reset") {
            KeyServices.root.wipeAll()
            MetadataStore.deleteFile()
            PriceAlertStore.erase()
        }
        #endif
        // Os alertas de preco abrem o app em segundo plano, as vezes com o iPhone
        // bloqueado: ai o chaveiro nao responde. `isSetUp` le "nao sei" como configurado,
        // e o app abre travado, nunca na criacao do PIN.
        phase = KeyServices.root.isSetUp ? .locked : .onboarding
        launchChecks()
        // Este init roda antes de o iOS terminar de abrir o app, e ai
        // `isProtectedDataAvailable` ainda diz "nao" com o iPhone desbloqueado (visto em
        // 16/10/2026): a limpeza da instalacao nova nunca rodava, e quem reinstalava o app
        // achava o PIN e o cofre da instalacao anterior no chaveiro. As conferencias de
        // abertura rodam de novo quando o app termina de abrir e quando os dados
        // protegidos ficam disponiveis (o app aberto em segundo plano antes do primeiro
        // desbloqueio), uma vez so.
        guard !launchChecked else { return }
        launchObservers = [UIApplication.didFinishLaunchingNotification, UIApplication.protectedDataDidBecomeAvailableNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.launchChecks() }
            }
        }
    }

    /// As conferencias de abertura, que precisam do chaveiro e dos arquivos protegidos:
    /// a limpeza da instalacao nova, o relogio das tentativas e, sem cofre, os arquivos
    /// do segundo plano. So rodam com os dados protegidos disponiveis, e uma vez so.
    @ObservationIgnored private var launchChecked = false
    @ObservationIgnored private var launchObservers: [any NSObjectProtocol] = []

    private func launchChecks() {
        guard !launchChecked, UIApplication.shared.isProtectedDataAvailable else { return }
        launchChecked = true
        launchObservers.forEach(NotificationCenter.default.removeObserver)
        launchObservers = []
        // A limpeza apagou o cofre de uma instalacao anterior: o app abre na criacao do
        // PIN, nunca no PIN que sobrou no chaveiro, e nada da sessao fica de pe, qualquer
        // que seja a fase.
        if KeyServices.firstLaunchCleanup() {
            indexKey = nil
            metadata = Metadata()
            phase = .onboarding
        }
        // A contagem de tentativas que veio de outro boot; com o chaveiro mudo, fica para
        // a volta ao primeiro plano (`scenePhaseChanged`).
        KeyServices.root.rebaseAttempts()
        if phase == .locked, !KeyServices.root.isSetUp { phase = .onboarding }
        // Sem chaves (o codigo do iPhone foi tirado e o chaveiro apagou o cofre, ou uma
        // instalacao nova): o que o segundo plano guardava fora do cofre nao tem mais dono
        // (pentest de 14/10/2026, B6).
        if phase == .onboarding {
            Self.eraseBackgroundFiles()
            Preferences.receiptWatchChosen = false
            Preferences.receiptOfferSeen = false
            Preferences.priceAlertsChosen = false
        }
    }

    /// O que o segundo plano guarda fora do cofre (enderecos e ultimo saldo do aviso de
    /// recebimento, UIDs das ordens, alertas de preco), apagado na hora, com a agenda e os
    /// avisos pendentes junto. Nada disso espera um `Task`: o app pode fechar antes.
    static func eraseBackgroundFiles() {
        ReceiptWatchStore.erase()
        LimitOrderWatchStore.erase()
        PriceAlertStore.erase()
        WidgetFeed.erase()
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        BackgroundCheck.reschedule()
    }

    var selectedWallet: WalletMeta? { metadata.selectedWallet }
    var currency: Fmt.Currency { Fmt.Currency(rawValue: metadata.settings.currency.uppercased()) ?? .brl }

    // MARK: PIN e desbloqueio

    /// Cadastra o PIN. O Argon2 do PIN roda fora do MainActor.
    func setUpPIN(_ pin: SecureBytes) async throws {
        let key: SymmetricKey = try await Offload.run {
            defer { pin.wipe() }
            let rk = try KeyServices.root.setUp(pin: pin)
            defer { rk.wipe() }
            return IndexCipher.key(from: rk)
        }
        indexKey = key
        metadata = Metadata()
        try persist()
        phase = .unlocked
    }

    func unlock(pin: SecureBytes) async throws {
        let reason = String(localized: "Destravar a Escalibur")
        let (key, updates) = try await Offload.run {
            defer { pin.wipe() }
            // No modo reforcado, abrir o app tambem pede o rosto depois do PIN.
            let rk = KeyServices.root.securityMode == .hardened
                ? try KeyServices.root.unlockHardened(pin: pin, reason: reason)
                : try KeyServices.root.unlock(pin: pin)
            defer { rk.wipe() }
            return (IndexCipher.key(from: rk), Self.missingAccounts(rk: rk))
        }
        try open(with: key, adding: updates)
    }

    func unlockWithBiometry() async throws {
        let (key, updates) = try await Offload.run {
            let rk = try KeyServices.root.unlockWithBiometry(reason: String(localized: "Destravar a Escalibur"))
            defer { rk.wipe() }
            return (IndexCipher.key(from: rk), Self.missingAccounts(rk: rk))
        }
        try open(with: key, adding: updates)
    }

    /// Redes que entraram numa versao nova ainda nao tem endereco nas carteiras
    /// antigas. Como a RK ja esta aberta neste desbloqueio, os enderecos que faltam
    /// sao derivados agora, sem pedir o Face ID de novo. Cada registro e zerado ao
    /// fim da derivacao.
    nonisolated private static func missingAccounts(rk: SecureBytes) -> [UUID: [DerivedAccount]] {
        guard let metadata = try? MetadataStore.load(key: IndexCipher.key(from: rk)) else { return [:] }
        var updates: [UUID: [DerivedAccount]] = [:]
        // Carteira so de observacao de endereco EVM: o mesmo endereco vale nas redes EVM
        // novas, como em `addWatchWallet`. Nada e derivado; so se repete o endereco.
        for wallet in metadata.wallets where wallet.isWatchOnly {
            guard let evm = wallet.accounts.first(where: { Chain.find($0.chainID)?.family == .evm }) else { continue }
            let have = Set(wallet.accounts.map(\.chainID))
            let missing = Chain.evmChains.filter { !have.contains($0.id) }
            guard !missing.isEmpty else { continue }
            updates[wallet.id] = missing.map {
                DerivedAccount(chainID: $0.id, path: evm.path, address: evm.address, publicKey: evm.publicKey, accountXPub: nil)
            }
        }
        for wallet in metadata.wallets where !wallet.isWatchOnly {
            let have = Set(wallet.accounts.map(\.chainID))
            let missing = Chain.all.filter { !have.contains($0.id) }
            guard !missing.isEmpty, let secret = try? KeyServices.wallets.open(walletID: wallet.id, rk: rk) else { continue }
            defer { secret.wipe() }
            if let (accounts, _) = try? AccountDeriver.derive(secret, chains: missing), !accounts.isEmpty {
                updates[wallet.id] = accounts
            }
        }
        return updates
    }

    private func open(with key: SymmetricKey, adding updates: [UUID: [DerivedAccount]] = [:]) throws {
        metadata = try MetadataStore.load(key: key)
        indexKey = key
        // A moeda dos precos segue a unidade de Ativos. Metadados de antes de 12/10/2026
        // podiam ter as duas diferentes (Ajustes em real, Ativos em dolar).
        if metadata.settings.choose(metadata.settings.displayUnit) {
            metadata.quoteCache = [:]
            try? persist()
        }
        if !updates.isEmpty {
            for (id, accounts) in updates {
                guard let index = metadata.wallets.firstIndex(where: { $0.id == id }) else { continue }
                metadata.wallets[index].accounts += accounts
            }
            try? persist()
        }
        withAnimation(Motion.fade) { phase = .unlocked }
    }

    func lock() {
        indexKey = nil
        metadata = Metadata()
        withAnimation(Motion.fade) { phase = .locked }
    }

    /// Trava ao voltar do segundo plano depois do tempo escolhido (padrao 1 minuto).
    /// Sair do app ja cobre a tela na hora; isto decide se pede o PIN de novo.
    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .background:
            backgroundedAt = PINPolicy.uptime
        case .active:
            // Fora da thread principal: com um PIN sendo cadastrado ou conferido (dois
            // Argon2, segundos), o cofre fica trancado, e esperar por ele aqui congelava
            // a tela inteira (amostra de 15/10/2026: a espada da abertura parada no
            // mutex). O `unlock` refaz esta conta por conta propria, dentro do cofre.
            Task { await Offload.compute { KeyServices.root.rebaseAttempts() } }
            if phase == .unlocked, let since = backgroundedAt,
               PINPolicy.uptime - since >= Double(AutoLockView.clamped(metadata.settings.autoLockSeconds)) {
                lock()
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    /// O iPhone foi bloqueado: os dados protegidos vao sumir. Trava na hora.
    func deviceWillLock() {
        if phase == .unlocked { lock() }
    }

    // MARK: Operacoes com a chave raiz

    /// Destranca a RK com presenca nova e executa `body` com ela, de forma
    /// sincrona, fora do MainActor. A RK nao atravessa nenhum `await`: nasce, e usada
    /// e zerada dentro da mesma funcao sincrona (docs/seguranca.md §2.9).
    func withRootKey<T: Sendable>(_ credential: Credential, _ body: @escaping @Sendable (SecureBytes) throws -> T) async throws -> T {
        do {
            return try await rootKeyTask(credential, body)
        } catch RootKeyVault.Failure.wiped {
            // O decimo erro veio de uma folha de PIN no meio de uma operacao: o cofre
            // ja apagou as chaves, e os metadados vao junto.
            eraseEverything()
            throw RootKeyVault.Failure.wiped
        }
    }

    private func rootKeyTask<T: Sendable>(_ credential: Credential, _ body: @escaping @Sendable (SecureBytes) throws -> T) async throws -> T {
        try await Offload.run {
            let rk: SecureBytes
            switch credential {
            case .pin(let pin):
                defer { pin.wipe() }
                rk = try KeyServices.root.unlock(pin: pin)
            case .biometry(let reason):
                rk = try KeyServices.root.unlockWithBiometry(reason: reason)
            case .pinAndBiometry(let pin, let reason):
                defer { pin.wipe() }
                rk = try KeyServices.root.unlockWithPINAndBiometry(pin: pin, reason: reason)
            case .hardened(let pin, let reason):
                defer { pin.wipe() }
                rk = try KeyServices.root.unlockHardened(pin: pin, reason: reason)
            }
            defer { rk.wipe() }
            return try body(rk)
        }
    }

    var biometryEnabled: Bool { KeyServices.root.isBiometryEnabled }

    /// Liga o Face ID. O cofre confere na hora que o slot novo abre com o rosto e devolve a
    /// mesma RK, e decide se a espera do A1 comeca (religar depois de uma queda).
    func enableBiometry(pin: SecureBytes) async throws {
        let reason = String(localized: "Confirme o \(KeyServices.biometryName) para ligar")
        do {
            try await Offload.run {
                defer { pin.wipe() }
                let rk = try KeyServices.root.unlock(pin: pin)
                defer { rk.wipe() }
                try KeyServices.root.enableBiometry(rk: rk, reason: reason)
            }
        } catch RootKeyVault.Failure.wiped {
            // O PIN errado desta folha foi o que disparou o apagar apos erros: o cofre ja
            // apagou as chaves, e a sessao vai junto (auditoria 4, C7-10).
            eraseEverything()
            throw RootKeyVault.Failure.wiped
        }
        metadata.settings.biometryEnabled = true
        try persist()
    }

    /// Desliga o Face ID com o PIN e o rosto (A1): com ele desligado, ver as palavras passa
    /// a pedir so o PIN. A credencial vem de `AuthCoordinator.retrying(presence:
    /// .pinAndBiometry)`.
    func disableBiometry(_ credential: Credential) async throws {
        guard case .pinAndBiometry(let pin, let reason) = credential else { throw RootKeyVault.Failure.biometryRequired }
        do {
            try await Offload.run {
                defer { pin.wipe() }
                try KeyServices.root.disableBiometry(pin: pin, reason: reason)
            }
        } catch RootKeyVault.Failure.wiped {
            eraseEverything()
            throw RootKeyVault.Failure.wiped
        }
        metadata.settings.biometryEnabled = false
        try? persist()
    }

    // MARK: Modo reforcado

    var hardenedModeOn: Bool { KeyServices.root.securityMode == .hardened }

    /// Liga o modo reforcado. O cofre pede o PIN e o rosto pelo slot de hoje, roda a
    /// conferencia das palavras com a RK aberta (`check`), grava o rk.and, abre de novo com
    /// PIN e rosto, e so entao apaga o slot so-PIN.
    func enableHardened(pin: SecureBytes, check: @escaping @Sendable (SecureBytes) throws -> Void) async throws {
        let reason = String(localized: "Ligar o modo reforçado")
        let confirm = String(localized: "Confirme o \(KeyServices.biometryName) para conferir o modo reforçado")
        do {
            try await Offload.run {
                defer { pin.wipe() }
                try KeyServices.root.enableHardened(pin: pin, reason: reason, confirmReason: confirm, check: check)
            }
        } catch RootKeyVault.Failure.wiped {
            eraseEverything()
            throw RootKeyVault.Failure.wiped
        }
        metadata.settings.biometryEnabled = false
        try? persist()
    }

    /// Desliga o modo reforcado: o slot do PIN e o Face ID voltam, conferidos. Devolve se o
    /// Face ID voltou (o segundo rosto pode ser recusado; ai fica desligado).
    func disableHardened(pin: SecureBytes) async throws -> Bool {
        let reason = String(localized: "Desligar o modo reforçado")
        let biometry = String(localized: "Confirme o \(KeyServices.biometryName) para religar")
        let restored: Bool
        do {
            restored = try await Offload.run {
                defer { pin.wipe() }
                return try KeyServices.root.disableHardened(pin: pin, reason: reason, biometryReason: biometry)
            }
        } catch RootKeyVault.Failure.wiped {
            eraseEverything()
            throw RootKeyVault.Failure.wiped
        }
        metadata.settings.biometryEnabled = restored
        try? persist()
        return restored
    }

    // MARK: Carteiras

    /// Guarda uma carteira nova ou importada. A RK so existe durante esta chamada.
    /// `select` falso guarda sem trocar a carteira em uso (envelope, que pode ter vindo de
    /// outra pessoa). Nome repetido ganha a origem junto: o envelope de terceiro chamado
    /// "Carteira principal" nunca se confunde com a do dono.
    func addWallet(
        secret: WalletSecret, name: String, origin: WalletMeta.Origin, wordCount: Int,
        backupConfirmed: Bool, select: Bool = true, tronForeignControl: Bool = false, credential: Credential
    ) async throws -> WalletMeta {
        let id = UUID()
        let hasPassphrase = secret.passphrase.count > 0
        let (accounts, fingerprint): ([DerivedAccount], [UInt8]) = try await withRootKey(credential) { rk in
            defer { secret.wipe() }
            try KeyServices.wallets.save(secret, walletID: id, rk: rk)
            return try AccountDeriver.derive(secret)
        }
        if let existing = metadata.wallets.first(where: { $0.fingerprint == fingerprint.hex && !$0.isWatchOnly }) {
            try? KeyServices.wallets.delete(id)
            throw WalletError.alreadyImported(existing.name)
        }
        var wallet = WalletMeta(
            id: id, name: uniqueName(name, origin: origin), kind: .phrase(wordCount: wordCount), origin: origin, createdAt: .now,
            accounts: accounts, fingerprint: fingerprint.hex, hasPassphrase: hasPassphrase,
            backupConfirmedAt: backupConfirmed ? .now : nil
        )
        if tronForeignControl { wallet.tronForeignControl = true }
        metadata.wallets.append(wallet)
        if select || metadata.selectedWalletID == nil { metadata.selectedWalletID = id }
        try persist()
        return wallet
    }

    private func uniqueName(_ name: String, origin: WalletMeta.Origin) -> String {
        let taken = Set(metadata.wallets.map { Self.nameSkeleton($0.name) })
        guard taken.contains(Self.nameSkeleton(name)) else { return name }
        let tag = origin == .importedEnvelope ? String(localized: "envelope") : String(localized: "importada")
        var candidate = "\(name) (\(tag))"
        var number = 2
        while taken.contains(Self.nameSkeleton(candidate)) {
            candidate = "\(name) (\(tag) \(number))"
            number += 1
        }
        return String(candidate.prefix(48))
    }

    /// O nome como o olho le: transliterado para o alfabeto latino, sem acento, em
    /// minusculas e sem espacos nas pontas. "Carteira principаl" com um "а" cirilico e
    /// "Carteira principal" dao o mesmo (revisao da auditoria 4, C7-05).
    static func nameSkeleton(_ name: String) -> String {
        let latin = name.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? name
        return latin.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A carteira da 25ª palavra: a frase de `base` com uma palavra a mais, escolhida pelo
    /// dono, abre outra carteira, com outros enderecos (a carteira oculta da Ledger e da
    /// Trezor). A frase nunca sai do cofre: abre, deriva e e gravada dentro da mesma
    /// funcao sincrona, com uma confirmacao so.
    func addPassphraseWallet(base: WalletMeta, passphrase: SecureBytes, name: String, credential: Credential) async throws -> WalletMeta {
        guard case .phrase(let wordCount) = base.kind else { throw WalletError.notPhraseWallet }
        let baseID = base.id
        let id = UUID()
        let (accounts, fingerprint): ([DerivedAccount], [UInt8]) = try await withRootKey(credential) { rk in
            let original = try KeyServices.wallets.open(walletID: baseID, rk: rk)
            defer { original.wipe() }
            let entropy = SecureBytes(capacity: original.entropy.count)
            original.entropy.withUnsafeBytes { entropy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
            // A 25a palavra em NFKD, como a importacao grava. A seed BIP-39 normaliza sozinha,
            // mas a chave da Cardano (Icarus) usa os bytes como estao: com os bytes do teclado
            // (NFC), "ação" aqui dava outra conta da Cardano que a da importacao das mesmas
            // palavras (revisao do modo reforcado, N1).
            let normalized = passphrase.withUnsafeBytes({ raw in raw.contains { $0 >= 0x80 } }) ? BIP39.nfkd(passphrase) : passphrase
            let secret = WalletSecret(entropy: entropy, language: original.language, passphrase: normalized)
            defer { secret.wipe() }
            try KeyServices.wallets.save(secret, walletID: id, rk: rk)
            return try AccountDeriver.derive(secret)
        }
        // A mesma frase com a mesma passphrase abre a mesma carteira: se ela ja esta aqui,
        // abrir e so passar a usa-la.
        if let existing = metadata.wallets.first(where: { $0.fingerprint == fingerprint.hex && !$0.isWatchOnly }) {
            try? KeyServices.wallets.delete(id)
            metadata.selectedWalletID = existing.id
            try persist()
            return existing
        }
        let wallet = WalletMeta(
            id: id, name: name, kind: .phrase(wordCount: wordCount), origin: base.origin, createdAt: .now,
            accounts: accounts, fingerprint: fingerprint.hex, hasPassphrase: true,
            backupConfirmedAt: base.backupConfirmedAt
        )
        metadata.wallets.append(wallet)
        metadata.selectedWalletID = id
        try persist()
        return wallet
    }

    func addWatchWallet(chain: Chain, address: String, name: String) throws -> WalletMeta {
        // Endereco EVM vale em todas as redes EVM: observa todas.
        let chains = chain.family == .evm ? Chain.evmChains : [chain]
        let accounts = chains.map {
            DerivedAccount(chainID: $0.id, path: DerivationPath(components: []), address: address, publicKey: [], accountXPub: nil)
        }
        let wallet = WalletMeta(
            id: UUID(), name: name, kind: .watch(chainID: chain.id), origin: .watch, createdAt: .now,
            accounts: accounts, fingerprint: nil, hasPassphrase: false, backupConfirmedAt: nil
        )
        metadata.wallets.append(wallet)
        metadata.selectedWalletID = wallet.id
        try persist()
        return wallet
    }

    func select(_ wallet: WalletMeta) {
        metadata.selectedWalletID = wallet.id
        try? persist()
    }

    func update(_ wallet: WalletMeta) {
        guard let index = metadata.wallets.firstIndex(where: { $0.id == wallet.id }) else { return }
        metadata.wallets[index] = wallet
        try? persist()
    }

    /// Grava o aceite de responsabilidade: a data e a versao do texto aceito.
    func acceptResponsibility(version: Int) {
        metadata.responsibilityAccepted = .now
        metadata.responsibilityVersion = version
        try? persist()
    }

    /// A carteira so sai da lista depois de o chaveiro confirmar que a frase saiu. Antes,
    /// uma falha do chaveiro tirava a carteira da lista e deixava a frase la, sem caminho
    /// para apagar (auditoria 4, C7-20).
    func remove(_ wallet: WalletMeta) throws {
        if !wallet.isWatchOnly {
            try? KeyServices.wallets.delete(wallet.id)
            guard KeyServices.wallets.probe(wallet.id) == .absent else { throw WalletError.removeFailed }
        }
        metadata.wallets.removeAll { $0.id == wallet.id }
        metadata.balanceCache[wallet.id] = nil
        if metadata.selectedWalletID == wallet.id { metadata.selectedWalletID = metadata.wallets.first?.id }
        try? persist()
    }

    /// Apaga tudo deste aparelho: chaves do SE e itens do chaveiro primeiro.
    func eraseEverything() {
        KeyServices.root.wipeAll()
        MetadataStore.deleteFile()
        Self.eraseBackgroundFiles()
        Preferences.receiptWatchChosen = false
        Preferences.receiptOfferSeen = false
        Preferences.priceAlertsChosen = false
        // Os atores zeram o que tinham em memoria; os arquivos ja sairam acima.
        Task {
            await ReceiptWatchCenter.shared.disable()
            await LimitOrderWatch.shared.erase()
            await PriceAlertCenter.shared.erase()
        }
        indexKey = nil
        metadata = Metadata()
        phase = .onboarding
    }

    func persist() throws {
        guard let indexKey else { return }
        try MetadataStore.save(metadata, key: indexKey)
    }
}

enum WalletError: LocalizedError {
    case alreadyImported(String)
    case notPhraseWallet
    case removeFailed

    var errorDescription: String? {
        switch self {
        case .alreadyImported(let name): return String(localized: "Esta carteira já está aqui, como \(name).")
        case .notPhraseWallet: return String(localized: "Esta carteira só acompanha um endereço. A passphrase precisa da senha de 12 ou 24 palavras.")
        case .removeFailed: return String(localized: "Não foi possível apagar a carteira deste iPhone agora. Ela continua aqui; tente de novo.")
        }
    }
}
