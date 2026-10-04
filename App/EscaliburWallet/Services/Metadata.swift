import CryptoKit
import EscaliburChains
import EscaliburCore
import EscaliburEngines
import EscaliburKeys
import EscaliburNetwork
import Foundation

/// Tudo que a carteira sabe e nao e segredo, mas e privacidade: nomes, enderecos,
/// xpubs, contatos, ajustes, cache de saldo, ordens abertas.
///
/// Cifrado com a chave de indice (derivada da RK) num arquivo com
/// `NSFileProtectionComplete` e fora do backup. Quem pega o aparelho bloqueado nao
/// le, e o iCloud nunca recebe.
struct Metadata: Codable, Equatable {
    var version = 1
    var wallets: [WalletMeta] = []
    var selectedWalletID: UUID?
    var settings = Settings()
    var contacts: [Contact] = []
    /// Enderecos para onde esta carteira ja enviou, por rede. Alimenta o aviso de
    /// primeiro envio e a deteccao de endereco parecido (envenenamento).
    var sentTo: [String: [String]] = [:]
    var balanceCache: [UUID: [String: ChainBalance]] = [:]
    var quoteCache: [String: Quote] = [:]
    var cachedAt: Date?
    /// Transacoes EVM transmitidas e ainda em transito, por carteira, rede e conta
    /// (`NonceQueue`). Opcional para os metadados gravados antes deste campo abrirem.
    var pendingEVM: [String: [PendingEVMTransaction]]?
    /// O ultimo aceite da tela de seguranca e responsabilidade (`ResponsibilityView`):
    /// quando e em qual versao do texto. Opcionais para os metadados gravados antes
    /// destes campos abrirem.
    var responsibilityAccepted: Date?
    var responsibilityVersion: Int?

    var selectedWallet: WalletMeta? {
        wallets.first { $0.id == selectedWalletID } ?? wallets.first
    }
}

struct WalletMeta: Codable, Equatable, Identifiable, Hashable {
    enum Kind: Codable, Equatable, Hashable {
        case phrase(wordCount: Int)
        case watch(chainID: String)
    }

    enum Origin: String, Codable {
        case created, importedPhrase, importedEnvelope, watch
    }

    let id: UUID
    var name: String
    let kind: Kind
    let origin: Origin
    let createdAt: Date
    var accounts: [DerivedAccount]
    /// Os 4 bytes do fingerprint BIP-32 da raiz, para conferir a 25a palavra.
    var fingerprint: String?
    var hasPassphrase: Bool
    /// Copia no papel confirmada (O4) ou carteira importada (a copia ja existe).
    var backupConfirmedAt: Date?
    var envelopeSealedAt: Date?
    var lastRevealedAt: Date?
    var hiddenAssetIDs: Set<String> = []
    /// Enderecos UTXO ja usados, por rede: indices de recebimento e troco.
    var utxoUsage: [String: UTXOUsage] = [:]

    var isWatchOnly: Bool { if case .watch = kind { return true }; return false }
    var hasBackup: Bool { backupConfirmedAt != nil || origin != .created }

    func account(_ chain: Chain) -> DerivedAccount? { accounts.first { $0.chainID == chain.id } }
}


struct Contact: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var chainID: String
    var address: String
    var tag: String?
}

struct Settings: Codable, Equatable {
    var currency: String = "brl"
    /// Unidade do saldo total na tela da carteira (`Fmt.DisplayUnit`). Nil: a moeda do app.
    var totalUnit: String?
    /// Moedas marcadas com coracao (ids do CoinGecko), fixadas no topo do Mercado.
    var favoriteCoins: [String]?
    var hideBalances = false
    var biometryEnabled = false
    var autoLockSeconds: Int = 60
    var voice = VoiceSettings()
    var disabledChainIDs: Set<String> = []
    var mevProtection = true
    var voicePhraseHash: String?
    var voicePhraseSalt: String?
}

struct VoiceSettings: Codable, Equatable {
    var enabled = false
    var onReveal = true
    var onEnvelope = true
    var onSendAboveFiat: Double? = 5000
    /// Desafios de voz falhos em seguida (tres tentativas cada). Opcional para os
    /// metadados gravados antes deste campo continuarem abrindo.
    var failedChallenges: Int?
    /// Depois de tres desafios falhos, as acoes com voz esperam ate aqui. So para
    /// mostrar a hora; quem decide e o prazo monotono abaixo.
    var lockedUntil: Date?
    /// A pausa no relogio monotono: prazo em segundos desde o boot, e o boot em hex.
    /// Adiantar o relogio do iPhone nao encurta a espera (auditoria 2, B3).
    var lockUptimeDeadline: TimeInterval?
    var lockBoot: String?

    mutating func startLock(seconds: TimeInterval) {
        lockedUntil = Date.now.addingTimeInterval(seconds)
        lockUptimeDeadline = PINPolicy.uptime + seconds
        lockBoot = Hex.encode(PINPolicy.bootSession)
    }

    mutating func clearLock() {
        failedChallenges = nil
        lockedUntil = nil
        lockUptimeDeadline = nil
        lockBoot = nil
    }
}

/// O arquivo de metadados, cifrado.
enum MetadataStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Carteira", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("metadados.bin") }

    static func load(key: SymmetricKey) throws -> Metadata {
        guard FileManager.default.fileExists(atPath: file.path) else { return Metadata() }
        let sealed = try Data(contentsOf: file)
        let plain = try IndexCipher.open(sealed, key: key)
        return try JSONDecoder().decode(Metadata.self, from: plain)
    }

    static func save(_ metadata: Metadata, key: SymmetricKey) throws {
        try prepareDirectory()
        let plain = try JSONEncoder().encode(metadata)
        let sealed = try IndexCipher.seal(plain, key: key)
        try sealed.write(to: file, options: [.atomic, .completeFileProtection])
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func deleteFile() {
        try? FileManager.default.removeItem(at: file)
    }

    /// O diretorio nasce fora do backup, e isso e conferido, nao presumido.
    private static func prepareDirectory() throws {
        var url = directory
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
