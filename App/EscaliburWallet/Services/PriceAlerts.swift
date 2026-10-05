import BackgroundTasks
import EscaliburChains
import EscaliburNetwork
import Foundation
import UserNotifications

// Alertas de preco sem servidor: o proprio iPhone confere os precos de tempos em tempos
// (quando o iOS deixa) e avisa com notificacao local. Nenhuma notificacao remota,
// nenhum token de push, nenhum servidor da Escalibur.
//
// Este arquivo nao toca no cofre, no chaveiro nem nos metadados cifrados, e
// verificar.sh confere: a checagem roda com o app aberto em segundo plano e o iPhone
// bloqueado, quando nada disso abre.

/// O que os alertas guardam. Fica fora do cofre, para a checagem rodar com o iPhone
/// bloqueado: so as moedas escolhidas uma a uma, as regras e o ultimo preco visto.
/// Nada de saldo, endereco ou carteira.
struct PriceAlertFile: Codable, Equatable {
    var enabled = false
    var roundNumbers = true
    /// Variacao em 24 h que avisa, em %; nil desliga.
    var moveThreshold: Double? = 10
    var currency = "brl"
    /// Moeda e preco na notificacao. Desligado, a tela bloqueada so diz "Alerta de preço".
    var showDetails = true
    var coins: [WatchedCoin] = []
    var memory: [String: PriceAlertMemory] = [:]
    var lastCheck: Date?

    static let maxCoins = 30
    static let thresholds: [Double] = [5, 10, 15, 20]

    func watches(_ id: String) -> Bool { coins.contains { $0.id == id } }
}

/// O arquivo dos alertas, num diretorio proprio com protecao ate o primeiro
/// desbloqueio (classe C), fora do backup.
///
/// E a unica excecao ao `NSFileProtectionComplete` do app alem do marcador de
/// instalacao. Com a Complete, a checagem com o iPhone bloqueado nao le o arquivo e o
/// alerta so chegaria com a tela aberta. A excecao vale porque nada aqui diz o que a
/// carteira tem: a lista comeca vazia e o dono marca cada moeda.
enum PriceAlertStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Alertas", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("alertas.json") }

    static func load() -> PriceAlertFile {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(PriceAlertFile.self, from: data)
        else { return PriceAlertFile() }
        return decoded
    }

    static func save(_ value: PriceAlertFile) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(value)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func erase() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// O diretorio nasce com a classe C: o temporario da gravacao atomica nasce dentro
    /// dele e herda a classe, e nao a Complete do conteiner, que falharia com o iPhone
    /// bloqueado.
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

/// Quem confere e avisa. Um ator: a checagem em segundo plano, a da abertura e a tela
/// de ajustes nunca gravam o arquivo ao mesmo tempo.
actor PriceAlertCenter {
    static let shared = PriceAlertCenter()

    nonisolated static let taskID = "com.thomazjr.escalibur.wallet.precos"
    nonisolated static let category = "precos"
    /// O iOS decide quando roda; isto e so o mais cedo que pode.
    static let refreshInterval: TimeInterval = 20 * 60
    /// Com o app aberto, uma checagem a cada 10 minutos no maximo.
    static let foregroundInterval: TimeInterval = 10 * 60
    static let maxPerCheck = 4

    private var current: PriceAlertFile?
    private var checking = false

    func file() -> PriceAlertFile {
        if let current { return current }
        let loaded = PriceAlertStore.load()
        current = loaded
        return loaded
    }

    /// Muda e grava. Ligado e com moedas, agenda a proxima checagem; senao, cancela.
    @discardableResult
    func update(_ change: @Sendable (inout PriceAlertFile) -> Void) -> PriceAlertFile {
        var value = file()
        change(&value)
        value.memory = value.memory.filter { id, _ in value.watches(id) }
        current = value
        try? PriceAlertStore.save(value)
        if value.enabled, !value.coins.isEmpty { Self.schedule() } else { Self.cancelSchedule() }
        return value
    }

    /// Na ida para o segundo plano: garante a proxima checagem na agenda.
    func reschedule() {
        let value = file()
        if value.enabled, !value.coins.isEmpty { Self.schedule() }
    }

    /// A moeda do app mudou: os precos guardados eram de outra moeda e viram base nova.
    func syncCurrency(_ currency: String) {
        guard file().currency != currency else { return }
        update { file in
            file.currency = currency
            file.memory = [:]
        }
    }

    /// Apaga tudo: arquivo, agenda e as notificacoes ja na tela. Vale para todo caminho
    /// que apaga as carteiras, para nenhum alerta sobrar na tela bloqueada.
    func erase() {
        current = PriceAlertFile()
        PriceAlertStore.erase()
        Self.cancelSchedule()
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    /// A checagem do segundo plano: agenda a proxima antes, para um corte do iOS no
    /// meio nao encerrar a serie.
    func backgroundRun() async {
        let value = file()
        guard value.enabled, !value.coins.isEmpty else { return }
        Self.schedule()
        await check(force: true)
    }

    /// Le os precos confirmados, aplica as regras e avisa. Sem `force`, so se a ultima
    /// checagem tiver mais de 10 minutos.
    func check(force: Bool = false, now: Date = .now) async {
        let before = file()
        guard before.enabled, !before.coins.isEmpty, !checking else { return }
        if !force, let last = before.lastCheck, now.timeIntervalSince(last) < Self.foregroundInterval { return }
        checking = true
        defer { checking = false }
        let quotes = await MarketService.shared.alertQuotes(ids: before.coins.map(\.id), currency: before.currency)

        // A tela de ajustes pode ter mudado o arquivo durante a leitura: vale o de agora.
        var value = file()
        guard value.enabled, value.currency == before.currency else { return }
        var alerts: [(WatchedCoin, PriceAlertEvent, Quote)] = []
        for coin in value.coins {
            guard let quote = quotes[coin.id] else { continue }
            var memory = value.memory[coin.id] ?? PriceAlertMemory()
            let events = PriceAlertRules.evaluate(
                price: quote.price, change24h: quote.change24h, memory: &memory,
                roundNumbers: value.roundNumbers, moveThreshold: value.moveThreshold, now: now
            )
            value.memory[coin.id] = memory
            alerts += events.map { (coin, $0, quote) }
        }
        value.lastCheck = now
        current = value
        try? PriceAlertStore.save(value)
        guard !alerts.isEmpty else { return }
        await Self.post(alerts, file: value)
    }

    // MARK: Notificacao

    private static func post(_ alerts: [(WatchedCoin, PriceAlertEvent, Quote)], file: PriceAlertFile) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        let currency = Fmt.Currency(rawValue: file.currency.uppercased()) ?? .brl

        guard file.showDetails else {
            // Discreto: um aviso so, sem moeda e sem valor.
            let content = Self.content(title: "Alerta de preço", body: "Abra o app para ver o que mudou.", coin: nil)
            try? await center.add(UNNotificationRequest(identifier: "precos.discreto", content: content, trigger: nil))
            return
        }

        let shown = alerts.count > maxPerCheck ? Array(alerts.prefix(maxPerCheck - 1)) : alerts
        for (coin, event, quote) in shown {
            let text = PriceAlertText.describe(event, coin: coin, quote: quote, currency: currency)
            let content = Self.content(title: text.title, body: text.body, coin: coin.id)
            try? await center.add(UNNotificationRequest(identifier: "preco.\(coin.id)", content: content, trigger: nil))
        }
        if alerts.count > shown.count {
            let rest = alerts.count - shown.count
            let content = Self.content(title: "Mais \(rest) alertas de preço", body: "Abra o Mercado para ver.", coin: nil)
            try? await center.add(UNNotificationRequest(identifier: "precos.mais", content: content, trigger: nil))
        }
    }

    private static func content(title: String, body: String, coin: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = category
        content.categoryIdentifier = category
        if let coin { content.userInfo = ["moeda": coin] }
        return content
    }

    // MARK: Agenda

    nonisolated static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    nonisolated static func cancelSchedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
    }

    /// Pede a permissao de notificar. Devolve se ficou permitido.
    nonisolated static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    nonisolated static func permissionDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}

/// O texto de cada alerta. O nome vem da lista compilada do app, nunca do provedor:
/// o texto do provedor e texto de quem quiser na tela bloqueada. Fora da lista, so o
/// simbolo, filtrado.
enum PriceAlertText {
    static func name(_ coin: WatchedCoin) -> String {
        if let chain = Chain.all.first(where: { $0.coingeckoID == coin.id }) { return Asset.native(chain).name }
        if let token = TokenRegistry.tokens.first(where: { $0.coingeckoID == coin.id }) { return token.name }
        return safeSymbol(coin.symbol)
    }

    static func safeSymbol(_ symbol: String) -> String {
        let clean = symbol.uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        let text = String(String.UnicodeScalarView(clean).prefix(10))
        return text.isEmpty ? "Moeda" : text
    }

    /// "R$ 81.000" no nivel inteiro; "R$ 1,10" e "R$ 0,000012" abaixo disso.
    static func level(_ value: Double, _ currency: Fmt.Currency) -> String {
        if value >= 1, value == value.rounded() {
            return "\(currency.symbol)\u{00A0}\(Fmt.grouped(value, fractionDigits: 0))"
        }
        return Fmt.price(value, currency)
    }

    static func percent(_ value: Double) -> String {
        "\(Fmt.grouped(abs(value), fractionDigits: 1))%"
    }

    static func describe(_ event: PriceAlertEvent, coin: WatchedCoin, quote: Quote, currency: Fmt.Currency) -> (title: String, body: String) {
        let name = name(coin)
        let now = "Agora \(Fmt.price(quote.price, currency))"
        let day = quote.change24h.map { ", \(Fmt.percent($0)) em 24 h." } ?? "."
        switch event {
        case .crossedUp(let mark):
            return ("\(name) passou de \(level(mark, currency))", now + day)
        case .crossedDown(let mark):
            return ("\(name) caiu abaixo de \(level(mark, currency))", now + day)
        case .moved(let change):
            return (change >= 0 ? "\(name) subiu \(percent(change)) em 24 h" : "\(name) caiu \(percent(change)) em 24 h", now + ".")
        }
    }
}
