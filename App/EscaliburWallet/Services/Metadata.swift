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
    /// Moedas custom: tokens que o dono adicionou colando o contrato, lidos na rede
    /// antes de salvar (`TokenInspector`). Valem para todas as carteiras que tem a rede.
    /// Opcional para os metadados gravados antes deste campo abrirem.
    var customAssets: [Asset]?

    var customTokens: [Asset] { customAssets ?? [] }
    /// Tokens fora da lista que o CoinGecko lista com o contrato exato
    /// (`TokenRecognitionRules`), por `Asset.id`. Opcional para os metadados antigos.
    var recognizedTokens: [String: TokenIdentity]?
    /// Quando cada token fora da lista foi conferido e o CoinGecko nao reconheceu: nao
    /// pergunta de novo antes de 7 dias.
    var unrecognizedChecks: [String: Date]?
    /// Ordens limite que o dono pediu para refazer quando vencerem (`LimitRenewal`).
    /// Opcional para os metadados gravados antes deste campo abrirem.
    var limitRenewals: [LimitRenewal]?
    /// O ultimo historico lido de cada carteira (`CachedActivity`), para a Atividade abrir
    /// na hora. Opcional para os metadados gravados antes deste campo abrirem.
    var activityCache: [UUID: [CachedActivity]]?
    /// Quando o historico de cada rede de cada carteira foi lido, e o saldo daquela hora
    /// (`ActivityFetch`): a Atividade so pergunta de novo a rede que pode ter mudado.
    var activityFetched: [UUID: [String: ActivityFetch]]?
    /// O endereco da logo de cada token fora da lista ja achada (`TokenLogoResolver`),
    /// por `Asset.id`: na abertura seguinte ela aparece na hora, sem a fila do CoinGecko.
    var tokenLogos: [String: URL]?
    /// Tokens fora da lista usados numa ordem ou troca (`TradedAssets`): as ordens abertas
    /// mostram nome, casas e logo deles mesmo depois que saem do saldo.
    var tradedAssets: [Asset]?
    /// Pontes entre redes (`BridgeRecord`): a transferencia assinada e o deposito, para
    /// acompanhar ate a entrega conferida no destino. Nada de segredo.
    var bridges: [BridgeRecord]?

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
    /// A passphrase digitada de novo pelo dono, de onde a anotou (auditoria 4, C7-02). So
    /// vale para a carteira com passphrase. Opcional para os metadados antigos abrirem.
    var passphraseConfirmedAt: Date?
    /// Carteira com passphrase: pedir a passphrase antes de mover saldo (envio, troca,
    /// ponte). Nil vale ligado, o padrao (pedido do dono, 16/10/2026). Ver `PassphraseGate`.
    var passphraseToSend: Bool?
    /// Na importacao, a rede mostrou outra chave no controle da conta da Tron (o golpe da
    /// "frase com saldo"): o Receber da Tron nesta carteira fica fechado. O envio ja recusa
    /// pela leitura das permissoes (`TronSendEngine`). Opcional para os metadados antigos.
    var tronForeignControl: Bool?
    var envelopeSealedAt: Date?
    var lastRevealedAt: Date?
    var hiddenAssetIDs: Set<String> = []
    /// Enderecos UTXO ja usados, por rede: indices de recebimento e troco.
    var utxoUsage: [String: UTXOUsage] = [:]

    var isWatchOnly: Bool { if case .watch = kind { return true }; return false }
    /// As palavras anotadas: copia no papel confirmada, ou carteira importada.
    var wordsConfirmed: Bool { backupConfirmedAt != nil || origin != .created }
    /// Sem passphrase, nao ha o que conferir.
    var passphraseConfirmed: Bool { !hasPassphrase || passphraseConfirmedAt != nil }
    /// A carteira pode receber: as palavras e, se houver, a passphrase conferidas.
    var hasBackup: Bool { wordsConfirmed && passphraseConfirmed }

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
    /// A moeda em que os precos sao buscados ("brl", "usd", "eur"). Segue a unidade
    /// escolhida em Ativos (`choose`), a unica escolha de moeda do app desde 12/10/2026;
    /// com o bitcoin escolhido, o dolar. Quem instala comeca na moeda da regiao do aparelho.
    var currency: String = Settings.regionCurrency

    /// Real no Brasil, euro na zona do euro, dolar no resto do mundo.
    static var regionCurrency: String {
        switch Locale.current.currency?.identifier {
        case "BRL": return "brl"
        case "EUR": return "eur"
        default: return "usd"
        }
    }
    /// Unidade escolhida em Ativos (`Fmt.DisplayUnit`). Nil: a moeda do app.
    var totalUnit: String?

    /// A unidade escolhida em Ativos.
    var displayUnit: Fmt.DisplayUnit {
        totalUnit.flatMap(Fmt.DisplayUnit.init(rawValue:)) ?? Fmt.DisplayUnit(Fmt.Currency(rawValue: currency.uppercased()) ?? .brl)
    }

    /// Escolhe a unidade em Ativos, e com ela a moeda de todos os precos do app.
    /// Devolve se a moeda dos precos mudou (os precos guardados sao da antiga).
    @discardableResult
    mutating func choose(_ unit: Fmt.DisplayUnit) -> Bool {
        totalUnit = unit.rawValue
        let fetch = unit.fiat.coingeckoID
        guard currency != fetch else { return false }
        currency = fetch
        return true
    }

    /// A moeda dos alertas de preco: a escolhida em Ativos (real, dolar ou euro). Com o
    /// bitcoin escolhido, o dolar: um alerta "BTC passou de 1 BTC" nao diz nada.
    var alertCurrency: String {
        switch totalUnit.flatMap(Fmt.DisplayUnit.init(rawValue:)) {
        case .brl?: return "brl"
        case .usd?: return "usd"
        case .eur?: return "eur"
        case .btc?: return "usd"
        case nil: return ["brl", "usd", "eur"].contains(currency) ? currency : "usd"
        }
    }
    /// Moedas marcadas com coracao (ids do CoinGecko), fixadas no topo do Mercado.
    var favoriteCoins: [String]?
    var hideBalances = false
    var biometryEnabled = false
    var autoLockSeconds: Int = 60
    var voice = VoiceSettings()
    /// Passphrases erradas, somadas entre todas as portas que conferem uma (enviar, ver,
    /// criptografar, desligar o pedido, conferir a copia, criar a carteira), e a espera
    /// depois delas (revisao de seguranca de 16/10/2026). Opcional para os metadados antigos.
    var passphraseGuard: PassphraseGuard?
    var disabledChainIDs: Set<String> = []
    var mevProtection = true
    /// O teclado proprio para as palavras (`WordKeyboardView`). Nil: desligado, o padrao;
    /// opcional para os metadados gravados antes deste campo continuarem abrindo. No modo
    /// reforcado ele vale ligado, qualquer que seja este valor.
    var ownKeyboard: Bool?
    /// Envios que a rede aceitou, e se o pedido de nota do app ja apareceu: depois do
    /// segundo envio, a Apple pergunta a nota uma vez (pedido do dono, 16/10/2026).
    var completedSends: Int?
    var reviewAsked: Bool?
    var voicePhraseHash: String?
    var voicePhraseSalt: String?
}

struct VoiceSettings: Codable, Equatable {
    var enabled = false
    var onReveal = true
    var onEnvelope = true
    var onSendAboveFiat: Double? = 5000
    /// Desafios de voz falhos em seguida (tres tentativas cada). Opcional para os
    /// metadados gravados antes deste campo continuarem abrindo. Antigo: a conta agora e
    /// por tentativa (`failedAttempts`).
    var failedChallenges: Int?
    /// Frases erradas seguidas, somadas entre desafios, gravadas antes de cada conferencia:
    /// fechar a folha nao zera (desenho de voz de 14/10/2026, Q1 e Q2).
    var failedAttempts: Int?
    /// Depois de tres desafios falhos, as acoes com voz esperam ate aqui. So para
    /// mostrar a hora; quem decide e o prazo monotono abaixo.
    var lockedUntil: Date?
    /// A pausa no relogio monotono: prazo em segundos desde o boot, e o boot em hex.
    /// Adiantar o relogio do iPhone nao encurta a espera (auditoria 2, B3).
    var lockUptimeDeadline: TimeInterval?
    var lockBoot: String?
    /// A lingua em que a frase e dita e ouvida. Nil: portugues (o padrao antes de
    /// existir a escolha).
    var language: VoiceLanguage?
    /// Envios seguidos sem a frase (abaixo do valor) antes de o proximo pedir a frase.
    /// Nil: sem limite.
    var maxSendsWithoutVoice: Int?
    /// Quantos envios sairam sem a frase desde a ultima frase conferida.
    var sendsWithoutVoice: Int?

    var phraseLanguage: VoiceLanguage { language ?? .portuguese }
    /// A moeda em que o valor do limite foi escolhido ("brl", "usd"). Nil: a moeda
    /// padrao, o real. Se a moeda do app mudar, todo envio pede a frase ate o dono
    /// conferir o valor de novo (auditoria 3, A2: trocar real por dolar multiplicava o
    /// limite por 5).
    var limitCurrency: String?
    /// Envios que sairam sem a frase, para o limite acumulado de 24 h.
    var recentSends: [VoiceSend]?
    /// "Esqueci a frase": o pedido de mexer nos ajustes so com o PIN, valido depois de
    /// 72 h no relogio monotono deste boot.
    var resetUptimeDeadline: TimeInterval?
    var resetBoot: String?
    var resetRequestedAt: Date?

    /// Uma frase dita e conferida conta, certa ou errada; a certa zera depois.
    mutating func countAttempt() { failedAttempts = (failedAttempts ?? 0) + 1 }

    /// Quantas frases ainda cabem antes da pausa.
    func attemptsLeft(limit: Int) -> Int { max(0, limit - (failedAttempts ?? 0)) }

    mutating func startLock(seconds: TimeInterval) {
        lockedUntil = Date.now.addingTimeInterval(seconds)
        lockUptimeDeadline = PINPolicy.uptime + seconds
        lockBoot = Hex.encode(PINPolicy.bootSession)
    }

    mutating func clearResetRequest() {
        resetUptimeDeadline = nil
        resetBoot = nil
        resetRequestedAt = nil
    }

    mutating func clearLock() {
        failedChallenges = nil
        failedAttempts = nil
        lockedUntil = nil
        lockUptimeDeadline = nil
        lockBoot = nil
    }
}

/// Um envio sem a frase de voz: quando (relogio de parede e monotono, com o boot) e
/// quanto, na moeda do limite.
/// A conta de passphrases erradas e a espera, no relogio monotono como a da voz: adiantar a
/// hora do iPhone nao encurta.
struct PassphraseGuard: Codable, Equatable {
    /// Tentativas sem acerto, contadas antes de cada conferencia: fechar o app no meio nao
    /// apaga a tentativa.
    var failures = 0
    /// So para mostrar a hora; quem decide e o prazo monotono.
    var lockedUntil: Date?
    var lockUptimeDeadline: TimeInterval?
    var lockBoot: String?

    mutating func startLock(seconds: TimeInterval) {
        lockedUntil = Date.now.addingTimeInterval(seconds)
        lockUptimeDeadline = PINPolicy.uptime + seconds
        lockBoot = Hex.encode(PINPolicy.bootSession)
    }

    mutating func clearLock() {
        lockedUntil = nil
        lockUptimeDeadline = nil
        lockBoot = nil
    }
}

struct VoiceSend: Codable, Equatable {
    let at: Date
    let uptime: TimeInterval
    let boot: String
    let fiat: Double
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
