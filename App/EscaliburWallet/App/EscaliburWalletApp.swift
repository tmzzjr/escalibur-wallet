import SwiftUI

@main
struct EscaliburWalletApp: App {
    @UIApplicationDelegateAdaptor(PlatformGuards.self) private var guards
    @State private var session = AppSession()
    @State private var toasts = ToastCenter()

    init() {
        PlatformGuards.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(toasts)
                .preferredColorScheme(.dark)
                .tint(Palette.ink)
        }
    }
}
