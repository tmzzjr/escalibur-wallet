import Observation
import UserNotifications

/// Recebe as notificacoes locais dos alertas de preco. So abre o app: nenhuma acao
/// na notificacao, e tocar nela leva ao Mercado depois do PIN ou do Face ID.
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
                hiddenPreviewsBodyPlaceholder: "Alerta de preço", options: []
            ),
        ])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let coin = response.notification.request.content.userInfo["moeda"] as? String
        await MainActor.run { NotificationInbox.shared.request = .init(coinID: coin) }
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
    }

    var request: Request?
}
