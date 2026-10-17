import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import UserNotifications

// Aviso de moeda recebida sem servidor: o proprio iPhone confere o saldo das contas de
// tempos em tempos (quando o iOS deixa, a mesma checagem dos alertas de preco) e avisa
// com notificacao local. Nenhuma notificacao remota, nenhum servidor sabendo os enderecos.
//
// O preco disso, dito no botao que liga: para conferir com o iPhone bloqueado, os
// enderecos publicos das contas ficam num arquivo proprio, com a protecao ate o primeiro
// desbloqueio (classe C), fora dos metadados cifrados. Nada de chave, frase ou nome de
// carteira. Oferecido a todos desde 14/10/2026, a pedido do dono, numa folha que diz o
// preco em Ajustes (`ReceiptWatchOffer.price`); desligar apaga o arquivo e vale para sempre.
//
// Este arquivo nao toca no cofre, no chaveiro nem nos metadados cifrados, e verificar.sh
// confere: os enderecos chegam de fora, pelo app destravado (`sync`).

/// O que o aviso guarda: as contas a conferir e o ultimo saldo visto de cada ativo.
struct ReceiptWatchFile: Codable, Equatable {
    struct Account: Codable, Equatable, Hashable {
        let chainID: String
        /// Um endereco; nas redes UTXO, os de recebimento e troco ja usados e o proximo.
        let addresses: [String]
    }

    struct Seen: Codable, Equatable {
        var amount: BigUInt
        let symbol: String
        let decimals: Int
    }

    var enabled = false
    /// Valor e moeda na notificacao. Desligado, a tela bloqueada so diz que entrou moeda.
    /// Comeca desligado (pentest de 14/10/2026, B1): o aviso vem ligado por padrao, e
    /// "Recebeu 10.000 USDT" na tela bloqueada, no relogio ou no Mac marca o dono como alvo.
    var showDetails = false
    var accounts: [Account] = []
    /// "rede|endereco|ativo" -> o ultimo saldo visto.
    var seen: [String: Seen] = [:]
    var lastCheck: Date?
}

/// O arquivo do aviso, num diretorio proprio com protecao ate o primeiro desbloqueio
/// (classe C), fora do backup: a checagem roda com o iPhone bloqueado.
enum ReceiptWatchStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recebimentos", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("recebimentos.json") }

    static func load() -> ReceiptWatchFile {
        guard let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(ReceiptWatchFile.self, from: data) else {
            return ReceiptWatchFile()
        }
        return decoded
    }

    static func save(_ value: ReceiptWatchFile) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(value)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func erase() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func prepareDirectory() throws {
        let files = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        if files.fileExists(atPath: directory.path) {
            try files.setAttributes(protection, ofItemAtPath: directory.path)
        } else {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        }
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

/// O que entrou numa conta: o ativo, quanto e em que rede.
struct ReceiptEvent: Equatable {
    let chainID: String
    let symbol: String
    let decimals: Int
    let amount: BigUInt
    /// Para o widget passar a mostrar a moeda que chegou (so ids da lista curada).
    var coingeckoID: String? = nil
    var name: String? = nil
}

/// Quem confere e avisa. Um ator: a checagem do segundo plano, a da abertura e a tela
/// de ajustes nunca gravam o arquivo ao mesmo tempo.
actor ReceiptWatchCenter {
    static let shared = ReceiptWatchCenter()

    nonisolated static let category = "recebimentos"
    /// Com o app aberto, uma checagem a cada 2 minutos no maximo.
    static let foregroundInterval: TimeInterval = 2 * 60
    static let maxPerCheck = 4

    private var current: ReceiptWatchFile?
    private var checking = false

    func file() -> ReceiptWatchFile {
        if let current { return current }
        let loaded = ReceiptWatchStore.load()
        current = loaded
        return loaded
    }

    @discardableResult
    func update(_ change: @Sendable (inout ReceiptWatchFile) -> Void) -> ReceiptWatchFile {
        var value = file()
        change(&value)
        current = value
        try? ReceiptWatchStore.save(value)
        BackgroundCheck.reschedule()
        return value
    }

    /// Liga com as contas de agora. A primeira leitura so marca o saldo de partida: ligar
    /// nao avisa do que ja estava na carteira.
    func enable(accounts: [ReceiptWatchFile.Account]) async {
        update { file in
            file.enabled = true
            file.accounts = accounts
            file.seen = [:]
        }
        // A primeira leitura, a que marca o saldo de partida, segue por baixo: esperando por
        // ela, o "Ligar o aviso" ficava carregando o tempo de ler todas as redes (visto pelo
        // dono, 16/10/2026).
        Task { await check(force: true) }
    }

    /// Desliga e apaga: os enderecos nao ficam no aparelho sem uso.
    func disable() {
        current = ReceiptWatchFile()
        ReceiptWatchStore.erase()
        BackgroundCheck.reschedule()
    }

    /// As contas de agora, do app destravado. Conta que saiu leva junto o saldo visto.
    func sync(accounts: [ReceiptWatchFile.Account]) {
        guard file().enabled, file().accounts != accounts else { return }
        let keep = Set(accounts.flatMap { account in account.addresses.map { "\(account.chainID)|\($0)" } })
        update { file in
            file.accounts = accounts
            file.seen = file.seen.filter { key, _ in keep.contains(key.split(separator: "|").prefix(2).joined(separator: "|")) }
        }
    }

    func setShowDetails(_ on: Bool) {
        update { $0.showDetails = on }
    }

    func backgroundRun() async {
        guard file().enabled else { return }
        await check(force: true)
    }

    /// Le o saldo de cada conta, compara com o ultimo visto e avisa o que subiu. Token
    /// fora da lista nao conta: e por onde chega o spam.
    func check(force: Bool = false, now: Date = .now) async {
        let before = file()
        guard before.enabled, !before.accounts.isEmpty, !checking else { return }
        if !force, let last = before.lastCheck, now.timeIntervalSince(last) < Self.foregroundInterval { return }
        checking = true
        defer { checking = false }

        let balances = await withTaskGroup(of: (ReceiptWatchFile.Account, ChainBalance?).self) { group in
            for account in before.accounts {
                guard let chain = Chain.all.first(where: { $0.id == account.chainID }), !account.addresses.isEmpty else { continue }
                // So o que ja entrou num bloco, e nas redes UTXO em dois provedores: o aviso
                // diz que o saldo ja esta na carteira (pentest de 14/10/2026, M1).
                group.addTask { (account, try? await BalanceService.shared.receiptBalance(chain: chain, addresses: account.addresses)) }
            }
            var out: [(ReceiptWatchFile.Account, ChainBalance)] = []
            for await (account, balance) in group { if let balance { out.append((account, balance)) } }
            return out
        }

        var value = file()
        guard value.enabled else { return }
        let events = Self.compare(balances, seen: &value.seen)
        value.lastCheck = now
        current = value
        try? ReceiptWatchStore.save(value)
        guard !events.isEmpty else { return }
        await Self.post(events, showDetails: value.showDetails)
        // O widget da tela bloqueada mostraria a moeda que entrou, que o aviso discreto
        // esconde: so com o valor e a moeda ligados no aviso (auditoria 4, R7-B3).
        if value.showDetails, let event = events.first(where: { $0.coingeckoID != nil }), let id = event.coingeckoID {
            await WidgetFeed.shared.received(coinID: id, symbol: event.symbol, name: event.name ?? event.symbol)
        }
    }

    /// O que subiu desde o ultimo saldo visto, atualizando o visto. Ativo visto pela
    /// primeira vez so marca a base; ativo que saiu do saldo (enviado inteiro) volta a
    /// zero, e o proximo que chegar avisa, mesmo menor que o saldo antigo.
    static func compare(_ balances: [(ReceiptWatchFile.Account, ChainBalance)], seen: inout [String: ReceiptWatchFile.Seen]) -> [ReceiptEvent] {
        var events: [ReceiptEvent] = []
        for (account, balance) in balances {
            let owner = account.addresses.first ?? ""
            let prefix = "\(account.chainID)|\(owner)|"
            let present = Set(balance.holdings.map { "\(prefix)\($0.asset.id)" })
            for key in seen.keys where key.hasPrefix(prefix) && !present.contains(key) { seen[key]?.amount = 0 }
            for holding in balance.holdings {
                let key = "\(prefix)\(holding.asset.id)"
                if let previous = seen[key], holding.amount > previous.amount {
                    events.append(ReceiptEvent(chainID: account.chainID, symbol: holding.asset.symbol, decimals: holding.asset.decimals,
                                               amount: holding.amount - previous.amount,
                                               coingeckoID: holding.asset.coingeckoID, name: holding.asset.name))
                }
                seen[key] = .init(amount: holding.amount, symbol: holding.asset.symbol, decimals: holding.asset.decimals)
            }
        }
        return events
    }

    // MARK: Notificacao

    private static func post(_ events: [ReceiptEvent], showDetails: Bool) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        guard showDetails else {
            let content = content(title: String(localized: "Entrou moeda na carteira"), body: String(localized: "Abra a Escalibur para ver."))
            try? await center.add(UNNotificationRequest(identifier: "recebimento.discreto", content: content, trigger: nil))
            return
        }
        for event in events.prefix(maxPerCheck) {
            let text = ReceiptText.describe(event)
            let id = "recebimento.\(event.chainID).\(event.symbol).\(Int(Date().timeIntervalSince1970))"
            try? await center.add(UNNotificationRequest(identifier: id, content: content(title: text.title, body: text.body), trigger: nil))
        }
        if events.count > maxPerCheck {
            let rest = events.count - maxPerCheck
            try? await center.add(UNNotificationRequest(
                identifier: "recebimento.mais", content: content(title: String(localized: "Mais \(rest) recebimentos"), body: String(localized: "Abra a Atividade para ver.")), trigger: nil
            ))
        }
    }

    private static func content(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["recebimento": true]
        return content
    }
}

/// O texto do aviso: o simbolo e o nome da rede vem da lista do app, e o valor sai do
/// saldo lido na rede.
enum ReceiptText {
    static func describe(_ event: ReceiptEvent) -> (title: String, body: String) {
        let chain = Chain.all.first { $0.id == event.chainID }?.name ?? event.chainID
        let symbol = PriceAlertText.safeSymbol(event.symbol)
        let amount = Fmt.crypto(event.amount, decimals: event.decimals, symbol: symbol)
        return (String(localized: "Recebeu \(amount)"), String(localized: "Na \(chain). O saldo novo já está na carteira."))
    }
}

/// A checagem em segundo plano e uma so para os alertas de preco, o aviso de
/// recebimento e as ordens limite abertas: fica na agenda enquanto um deles precisar.
enum BackgroundCheck {
    static func reschedule() {
        let prices = PriceAlertStore.load()
        let receipts = ReceiptWatchStore.load()
        if (prices.enabled && !prices.coins.isEmpty) || receipts.enabled || !LimitOrderWatchStore.load().orders.isEmpty
            || WidgetSnapshot.read() != nil {
            PriceAlertCenter.schedule()
        } else {
            PriceAlertCenter.cancelSchedule()
        }
    }
}
