import SwiftUI

@main
struct EscaliburWalletApp: App {
    @UIApplicationDelegateAdaptor(PlatformGuards.self) private var guards
    @State private var session = AppSession()
    @State private var toasts = ToastCenter()
    @State private var auth = AuthCoordinator()
    @State private var router = Router()
    @State private var portfolio = Portfolio()

    init() {
        PlatformGuards.install()
        NotificationRelay.install()
        UITabBar.appearance().unselectedItemTintColor = UIColor(Palette.inkMuted)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // O texto acompanha o tamanho escolhido no iPhone ate os tres primeiros
                // tamanhos de acessibilidade; acima disso, endereco e valor deixam de
                // caber sem quebrar no meio.
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .environment(session)
                .environment(toasts)
                .environment(auth)
                .environment(router)
                .environment(portfolio)
                .preferredColorScheme(.dark)
                .tint(Palette.ink)
        }
        // Alertas de preco: o iOS acorda o app de tempos em tempos, quando ele quer.
        .backgroundTask(.appRefresh(PriceAlertCenter.taskID)) {
            await PriceAlertCenter.shared.backgroundRun()
        }
    }
}
