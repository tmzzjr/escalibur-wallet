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
        // Antes de qualquer texto: os separadores dos numeros ficam os da regiao, fixos
        // durante a sessao (`NumberStyle`).
        Fmt.adoptRegion()
        PlatformGuards.install()
        NotificationRelay.install()
        UITabBar.appearance().unselectedItemTintColor = UIColor(Palette.inkMuted)
        // Alertas e menus de confirmacao do sistema: botoes em branco. Sem isto, o alerta
        // aberto de uma tela com tint rosa (campo, alternador) herdava o rosa da acao.
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = UIColor(Palette.ink)
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
        // Alertas de preco, aviso de recebimento e ordens limite abertas: o iOS acorda o
        // app de tempos em tempos, quando ele quer. A proxima vez entra na agenda antes de conferir.
        .backgroundTask(.appRefresh(PriceAlertCenter.taskID)) {
            BackgroundCheck.reschedule()
            await PriceAlertCenter.shared.backgroundRun()
            await ReceiptWatchCenter.shared.backgroundRun()
            await LimitOrderWatch.shared.check()
            await WidgetFeed.shared.refresh()
        }
    }
}
