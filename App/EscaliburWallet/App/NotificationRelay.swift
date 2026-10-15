import Observation
import UserNotifications

/// Recebe as notificacoes locais dos alertas de preco e do fim do prazo das ordens
/// limite. So abre o app: nenhuma acao na notificacao. Depois do PIN ou do Face ID, o
/// alerta leva ao Mercado e a ordem, a Trocar, onde o app pergunta se refaz.
///
/// Os metodos sao `nonisolated` e assincronos: o iOS chama o delegado fora da fila
/// principal, e um fechamento criado no MainActor e chamado de outra fila derruba o app
/// no Swift 6 (o mesmo que ja aconteceu com a voz).
final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationRelay()

    /// Chamado uma vez, na abertura, antes de o iOS entregar o toque que abriu o app.
    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        // Com a previa escondida nos Ajustes do iPhone, a tela bloqueada mostra so isto.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: PriceAlertCenter.category, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "Alerta de preço"), options: []
            ),
            UNNotificationCategory(
                identifier: LimitRenewalCenter.category, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "Ordem limite"), options: []
            ),
            UNNotificationCategory(
                identifier: ReceiptWatchCenter.category, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "Recebimento"), options: []
            ),
            UNNotificationCategory(
                identifier: BridgeCenter.category, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "Ponte"), options: []
            ),
        ])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let coin = info["moeda"] as? String
        let order = info["ordem"] as? String
        let receipt = info["recebimento"] as? Bool ?? false
        await MainActor.run { NotificationInbox.shared.request = .init(coinID: coin, orderID: order, receipt: receipt) }
    }
}

/// O toque numa notificacao esperando o app destravar.
@MainActor
@Observable
final class NotificationInbox {
    static let shared = NotificationInbox()

    struct Request: Equatable {
        let token = UUID()
        let coinID: String?
        /// O fim do prazo de uma ordem limite: abre Trocar, na ordem limite.
        var orderID: String? = nil
        /// Moeda recebida: abre a Atividade.
        var receipt = false
    }

    var request: Request?
}
