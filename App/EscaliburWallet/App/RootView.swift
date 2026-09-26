import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(AuthCoordinator.self) private var auth
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var offeredBiometry = false
    /// A primeira carteira e guardada antes de as palavras aparecerem. Sem esta
    /// marca, a raiz trocava para a tela principal no instante do guardar e derrubava
    /// o fluxo em tela cheia: o dono caia na carteira sem ver as palavras.
    @State private var firstRun = false

    /// O modo demo (so em DEBUG) importa a carteira de teste sozinho: nao ha primeira
    /// carteira para acompanhar.
    private static var isDemo: Bool {
        #if DEBUG
        return DebugDemo.enabled
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.void.ignoresSafeArea()
            content
            if let toast = toasts.current {
                ToastView(toast: toast).padding(.bottom, 72)
            }
        }
        .onChange(of: scenePhase) { _, phase in session.scenePhaseChanged(phase) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            session.deviceWillLock()
        }
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "esclbr" { router.incomingEnvelope = url }
        }
        .onAppear { EnvelopeFile.sweepInbox() }
        #if DEBUG
        .task { await DebugDemo.prepare(session: session, router: router) }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .onboarding:
            OnboardingFlow().transition(.opacity)
        case .locked:
            LockView().transition(.opacity)
        case .unlocked:
            if session.metadata.wallets.isEmpty || firstRun {
                Group {
                    if !offeredBiometry, KeyServices.biometryAvailable, !session.biometryEnabled {
                        BiometryOfferView { offeredBiometry = true }
                    } else {
                        AddWalletView(isFirst: true) { firstRun = false }
                    }
                }
                .onAppear { if session.metadata.wallets.isEmpty, !Self.isDemo { firstRun = true } }
            } else {
                MainTabs()
                    .fullScreenCover(item: Binding(
                        get: { router.incomingEnvelope.map { IncomingEnvelope(url: $0) } },
                        set: { if $0 == nil { router.incomingEnvelope = nil } }
                    )) { incoming in
                        OpenEnvelopeFlow(initialURL: incoming.url) { router.incomingEnvelope = nil }
                    }
            }
        }
    }

    struct IncomingEnvelope: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }
}

struct MainTabs: View {
    @Environment(Router.self) private var router

    /// `wallet.bifold` existe a partir do iOS 18; antes, a prancheta do `wallet.pass`.
    static var walletSymbol: String {
        if #available(iOS 18.0, *) { return "wallet.bifold" }
        return "wallet.pass"
    }

    var body: some View {
        TabView(selection: Bindable(router).tab) {
            WalletHomeView()
                .tabItem { Label("Carteira", systemImage: Self.walletSymbol) }
                .tag(Router.Tab.wallet)
            MarketView()
                .tabItem { Label("Mercado", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(Router.Tab.market)
            TradeView()
                .tabItem { Label("Trocar", systemImage: "arrow.left.arrow.right") }
                .tag(Router.Tab.trade)
            ActivityView()
                .tabItem { Label("Atividade", systemImage: "clock.arrow.circlepath") }
                .tag(Router.Tab.activity)
            SettingsView()
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
                .tag(Router.Tab.settings)
        }
        .tint(Palette.ink)
        .fullScreenCover(item: Bindable(router).flow) { flow in
            switch flow {
            case .send(let asset): SendFlow(initialAsset: asset)
            }
        }
    }
}
