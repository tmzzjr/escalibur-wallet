import SwiftUI

/// T1: Trocar. O motor de cotacao e a validacao entram com a camada de troca.
struct TradeView: View {
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Trocar").typeStyle(.title).foregroundStyle(Palette.ink)
                Picker("", selection: Bindable(router).tradeMode) {
                    Text("Agora").tag(Router.TradeMode.now)
                    Text("Ordem limite").tag(Router.TradeMode.limit)
                }
                .pickerStyle(.segmented)
                .padding(.top, Space.md)
                Spacer()
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
