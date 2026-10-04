import CryptoKit
import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Observation
import SwiftUI

/// Como o dono prova presenca para uma operacao que precisa da chave raiz.
enum Credential: Sendable {
    case pin(SecureBytes)
    case biometry(reason: String)
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
        }
        #endif
        KeyServices.firstLaunchCleanup()
        KeyServices.root.rebaseAttempts()
        phase = KeyServices.root.isSetUp ? .locked : .onboarding
    }

    var selectedWallet: WalletMeta? { metadata.selectedWallet }
    var currency: Fmt.Currency { Fmt.Currency(rawValue: metadata.settings.currency.uppercased()) ?? .brl }

    // MARK: PIN e desbloqueio

    /// Cadastra o PIN. O Argon2 do PIN roda fora do MainActor.
    func setUpPIN(_ pin: SecureBytes) async throws {
        let key: SymmetricKey = try await Task.detached(priority: .userInitiated) {
            defer { pin.wipe() }
            let rk = try KeyServices.root.setUp(pin: pin)
            defer { rk.wipe() }
            return IndexCipher.key(from: rk)
        }.value
        indexKey = key
        metadata = Metadata()
        try persist()
        phase = .unlocked
    }

    func unlock(pin: SecureBytes) async throws {
        let (key, updates) = try await Task.detached(priority: .userInitiated) {
            defer { pin.wipe() }
            let rk = try KeyServices.root.unlock(pin: pin)
            defer { rk.wipe() }
            return (IndexCipher.key(from: rk), Self.missingAccounts(rk: rk))
        }.value
        try open(with: key, adding: updates)
    }

    func unlockWithBiometry() async throws {
        let (key, updates) = try await Task.detached(priority: .userInitiated) {
            let rk = try KeyServices.root.unlockWithBiometry(reason: "Destravar a Escalibur Wallet")
            defer { rk.wipe() }
            return (IndexCipher.key(from: rk), Self.missingAccounts(rk: rk))
        }.value
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
            KeyServices.root.rebaseAttempts()
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
        try await Task.detached(priority: .userInitiated) {
            let rk: SecureBytes
            switch credential {
            case .pin(let pin):
                defer { pin.wipe() }
                rk = try KeyServices.root.unlock(pin: pin)
            case .biometry(let reason):
                rk = try KeyServices.root.unlockWithBiometry(reason: reason)
            }
            defer { rk.wipe() }
            return try body(rk)
        }.value
    }

    var biometryEnabled: Bool { KeyServices.root.isBiometryEnabled }

    /// Liga o Face ID e confere na hora: o slot novo precisa abrir com o rosto e
    /// devolver a mesma RK. Sem essa prova, o dono descobriria que o atalho nao
    /// funciona no dia em que precisasse dele.
    func enableBiometry(pin: SecureBytes) async throws {
        try await Task.detached(priority: .userInitiated) {
            defer { pin.wipe() }
            let rk = try KeyServices.root.unlock(pin: pin)
            defer { rk.wipe() }
            try KeyServices.root.enableBiometry(rk: rk)
            do {
                let check = try KeyServices.root.unlockWithBiometry(reason: "Confirme o \(KeyServices.biometryName) para ligar")
                defer { check.wipe() }
                guard Hash.constantTimeEqual(check, rk) else { throw RootKeyVault.Failure.storage }
            } catch {
                KeyServices.root.disableBiometry()
                throw error
            }
        }.value
        metadata.settings.biometryEnabled = true
        try persist()
    }

    func disableBiometry() {
        KeyServices.root.disableBiometry()
        metadata.settings.biometryEnabled = false
        try? persist()
    }

    // MARK: Carteiras

    /// Guarda uma carteira nova ou importada. A RK so existe durante esta chamada.
    func addWallet(
        secret: WalletSecret, name: String, origin: WalletMeta.Origin, wordCount: Int,
        backupConfirmed: Bool, credential: Credential
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
        let wallet = WalletMeta(
            id: id, name: name, kind: .phrase(wordCount: wordCount), origin: origin, createdAt: .now,
            accounts: accounts, fingerprint: fingerprint.hex, hasPassphrase: hasPassphrase,
            backupConfirmedAt: backupConfirmed ? .now : nil
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

    func remove(_ wallet: WalletMeta) {
        try? KeyServices.wallets.delete(wallet.id)
        metadata.wallets.removeAll { $0.id == wallet.id }
        metadata.balanceCache[wallet.id] = nil
        if metadata.selectedWalletID == wallet.id { metadata.selectedWalletID = metadata.wallets.first?.id }
        try? persist()
    }

    /// Apaga tudo deste aparelho: chaves do SE e itens do chaveiro primeiro.
    func eraseEverything() {
        KeyServices.root.wipeAll()
        MetadataStore.deleteFile()
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

    var errorDescription: String? {
        switch self {
        case .alreadyImported(let name): return "Esta carteira já está aqui, como \(name)."
        }
    }
}
