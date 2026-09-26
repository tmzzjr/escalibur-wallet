import EscaliburChains
import SwiftUI

/// E1 a E8: enviar. A revisao e a assinatura entram com o planejamento de cada rede.
struct SendFlow: View {
    @Environment(\.dismiss) private var dismiss
    let initialAsset: Asset?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text("Enviar").typeStyle(.title).foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.void.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                    }
                }
            }
        }
    }
}
