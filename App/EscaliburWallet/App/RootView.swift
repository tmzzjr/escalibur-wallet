import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.void.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Space.md) {
                WalletBadge(size: 56)
                Text("Escalibur Wallet").typeStyle(.title).foregroundStyle(Palette.ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, Space.gutter)
            if let toast = toasts.current {
                ToastView(toast: toast).padding(.bottom, Space.sm)
            }
        }
    }
}
