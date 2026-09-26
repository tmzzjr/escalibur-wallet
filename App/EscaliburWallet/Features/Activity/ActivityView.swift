import SwiftUI

/// H1: Atividade.
struct ActivityView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Atividade").typeStyle(.title).foregroundStyle(Palette.ink)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Nada aconteceu nesta carteira ainda").typeStyle(.row).foregroundStyle(Palette.ink)
                    Text("Envios, recebimentos, trocas e ordens aparecem aqui, com o status de cada um.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
                .padding(.top, Space.lg)
                Spacer()
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
            .background(Palette.void.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
