import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import UserNotifications

// Os avisos da ordem limite sem servidor (pedido do dono, 14/10/2026): um dia antes de
// vencer, e quando ela executa.
//
// O de 24 horas e um alarme local, marcado quando a ordem passa a ser acompanhada: nao
// precisa de rede. O de executada precisa: o proprio iPhone pergunta a CoW pelo andamento
// de cada ordem acompanhada, na checagem de segundo plano dos alertas de preco e na
// abertura do app.
//
// Para perguntar com o iPhone bloqueado, o UID de cada ordem aberta (que traz o endereco
// do dono e o prazo, os mesmos dados que a CoW publica) fica num arquivo proprio com a
// protecao ate o primeiro desbloqueio (classe C), fora dos metadados cifrados. A ordem sai
// do arquivo quando termina, e o arquivo some quando nao sobra nenhuma.
//
// Este arquivo nao toca no cofre, no chaveiro nem nos metadados cifrados, e verificar.sh
// confere: as ordens chegam de fora, pelo app destravado (`track`).

/// O que o aviso guarda: as ordens abertas a acompanhar.
struct LimitOrderWatchFile: Codable, Equatable {
    struct Order: Codable, Equatable {
        /// O UID da ordem na CoW, em hex.
        let id: String
        let chainID: String
        let expiresAt: Date
    }

    var orders: [Order] = []
}

/// O arquivo das ordens acompanhadas, num diretorio proprio com protecao ate o primeiro
/// desbloqueio (classe C), fora do backup: a checagem roda com o iPhone bloqueado.
enum LimitOrderWatchStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ordens", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("ordens.json") }

    static func load() -> LimitOrderWatchFile {
        guard let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(LimitOrderWatchFile.self, from: data) else {
            return LimitOrderWatchFile()
        }
        return decoded
    }

    static func save(_ value: LimitOrderWatchFile) throws {
        guard !value.orders.isEmpty else {
            erase()
            return
        }
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

/// Quem acompanha e avisa. Um ator: a checagem do segundo plano, a da abertura e a lista
/// de ordens abertas nunca gravam o arquivo ao mesmo tempo.
actor LimitOrderWatch {
    static let shared = LimitOrderWatch()

    /// Quanto antes do fim do prazo sai o aviso.
    static let warningLead: TimeInterval = 24 * 60 * 60
    /// Ordem que vence em menos que isto nao ganha aviso de vencimento: ele chegaria
    /// junto com a propria ordem.
    static let warningFloor: TimeInterval = 60 * 60

    private var current: LimitOrderWatchFile?
    private var checking = false

    func file() -> LimitOrderWatchFile {
        if let current { return current }
        let loaded = LimitOrderWatchStore.load()
        current = loaded
        return loaded
    }

    private func store(_ value: LimitOrderWatchFile) {
        current = value
        try? LimitOrderWatchStore.save(value)
        BackgroundCheck.reschedule()
    }

    /// Uma ordem da CoW, nova ou vista na lista de abertas: passa a ser acompanhada e
    /// ganha o aviso de 24 horas antes do fim do prazo. Ja acompanhada, nada muda.
    func track(id: String, chainID: String, expiresAt: Date, now: Date = .now) {
        guard expiresAt > now, id.hasPrefix("0x"), Hex.decode(id)?.count == CoWProtocol.uidLength else { return }
        var value = file()
        guard !value.orders.contains(where: { $0.id == id }) else { return }
        value.orders.append(.init(id: id, chainID: chainID, expiresAt: expiresAt))
        store(value)
        Self.scheduleWarning(id: id, expiresAt: expiresAt, now: now)
    }

    /// A ordem terminou (ou o dono cancelou): sai do arquivo, e o aviso de vencimento
    /// marcado sai da agenda.
    func forget(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.warningID(id)])
        var value = file()
        guard value.orders.contains(where: { $0.id == id }) else { return }
        value.orders.removeAll { $0.id == id }
        store(value)
    }

    /// Apagar tudo: o arquivo e os avisos de vencimento marcados.
    func erase() {
        let ids = file().orders.map { Self.warningID($0.id) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        current = LimitOrderWatchFile()
        LimitOrderWatchStore.erase()
        BackgroundCheck.reschedule()
    }

    /// A lista de ordens abertas viu a ordem sair com o andamento final. Executada avisa
    /// (se ainda estava acompanhada: o aviso sai uma vez so); o resto so sai do arquivo.
    func settle(_ id: String, filled: Bool) async {
        let watched = file().orders.contains { $0.id == id }
        forget(id)
        if filled, watched { await Self.postFilled(id: id) }
    }

    /// Pergunta a CoW pelo andamento de cada ordem acompanhada. Sem resposta, fica para a
    /// proxima vez.
    func check(now: Date = .now) async {
        let orders = file().orders
        guard !orders.isEmpty, !checking else { return }
        checking = true
        defer { checking = false }
        let client = CoWClient()
        for order in orders {
            guard let chain = Chain.all.first(where: { $0.id == order.chainID }), let uid = Hex.decode(order.id) else {
                forget(order.id)
                continue
            }
            guard let status = try? await client.order(uid: uid, chain: chain) else { continue }
            switch status.status {
            case .fulfilled:
                await settle(order.id, filled: true)
            case .cancelled, .expired:
                forget(order.id)
            case .open, .presignaturePending, .unknown:
                if status.invalidated || TimeInterval(status.validTo) <= now.timeIntervalSince1970 { forget(order.id) }
            }
        }
    }

    // MARK: Notificacao

    static func warningID(_ id: String) -> String { "ordem-limite.24h.\(id)" }

    /// Os avisos nao dizem ativo nem valor: a tela bloqueada nao conta o que a carteira
    /// tem (a mesma regra do aviso de prazo de `LimitRenewalCenter`).
    static func scheduleWarning(id: String, expiresAt: Date, now: Date) {
        let fireIn = expiresAt.timeIntervalSince(now) - warningLead
        guard fireIn >= warningFloor else { return }
        let request = UNNotificationRequest(
            identifier: warningID(id),
            content: content(id: id, title: String(localized: "Sua ordem limite vence em 24 horas"), body: String(localized: "Se ela ainda não executou, abra a Escalibur para ver ou mudar o preço.")),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func postFilled(id: String) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let request = UNNotificationRequest(
            identifier: "ordem-limite.executada.\(id)",
            content: content(id: id, title: String(localized: "Sua ordem limite foi executada"), body: String(localized: "A troca saiu no seu preço. O saldo novo já está na carteira.")),
            trigger: nil
        )
        try? await center.add(request)
    }

    private static func content(id: String, title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = LimitRenewalCenter.category
        content.userInfo = ["ordem": id]
        return content
    }
}
