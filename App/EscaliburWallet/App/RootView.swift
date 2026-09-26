import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(AuthCoordinator.self) private var auth
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var offeredBiometry = false

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
        .sheet(item: Bindable(auth).pinRequest) { request in
            PINRequestSheet(request: request, coordinator: auth)
        }
        .sheet(item: Bindable(VoiceGate.shared).challenge) { challenge in
            VoiceChallengeSheet(challenge: challenge)
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
            if session.metadata.wallets.isEmpty {
                if !offeredBiometry, KeyServices.biometryAvailable, !session.biometryEnabled {
                    BiometryOfferView { offeredBiometry = true }
                } else {
                    AddWalletView(isFirst: true) {}
                }
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

    var body: some View {
        TabView(selection: Bindable(router).tab) {
            WalletHomeView()
                .tabItem { Label("Carteira", systemImage: "wallet.pass") }
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
