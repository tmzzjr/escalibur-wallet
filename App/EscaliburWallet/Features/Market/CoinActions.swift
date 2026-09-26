import EscaliburChains
import EscaliburEngines
import SwiftUI

/// O coracao do topo do detalhe: fixa a moeda no topo do Mercado.
struct FavoriteButton: View {
    @Environment(AppSession.self) private var session
    let coingeckoID: String?

    private var isFavorite: Bool {
        guard let coingeckoID else { return false }
        return session.metadata.settings.favoriteCoins?.contains(coingeckoID) == true
    }

    var body: some View {
        if let coingeckoID {
            Button {
                var list = session.metadata.settings.favoriteCoins ?? []
                if let index = list.firstIndex(of: coingeckoID) { list.remove(at: index) } else { list.append(coingeckoID) }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { session.metadata.settings.favoriteCoins = list }
                try? session.persist()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isFavorite ? Palette.down : Palette.inkSoft)
                    .scaleEffect(isFavorite ? 1.08 : 1)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: Height.touch, height: Height.touch)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: isFavorite)
            .accessibilityLabel(isFavorite ? "Tirar dos favoritos" : "Fixar no topo do Mercado")
        }
    }
}

/// Onde esta moeda pode ser trocada: o primeiro ativo da lista com esse id numa rede
/// com troca ligada.
enum CoinTrade {
    static func asset(for coingeckoID: String?) -> Asset? {
        guard let coingeckoID else { return nil }
        let chains = TradeEngines.chains
        for chain in chains {
            if chain.coingeckoID == coingeckoID { return .native(chain) }
            if let token = TokenRegistry.tokens.first(where: { $0.chainID == chain.id && $0.coingeckoID == coingeckoID }) { return token }
        }
        return nil
    }
}

/// "Sobre o mercado": tres numeros lado a lado, grandes, com o rotulo embaixo.
struct MarketStats: View {
    let items: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Sobre o mercado").typeStyle(.heading).foregroundStyle(Palette.ink)
            HStack(alignment: .top, spacing: Space.md) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.value).typeStyle(.row).foregroundStyle(Palette.ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(item.label).typeStyle(.note).foregroundStyle(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
