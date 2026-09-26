import EscaliburChains
import EscaliburNetwork
import SwiftUI
import UIKit

/// O logo de uma moeda, embarcado no app, com o selo da rede quando o ativo nao
/// esta na rede nativa dele (USDC na Base leva selo; ETH na Ethereum nao).
struct CoinLogo: View {
    let coingeckoID: String?
    var symbol: String = ""
    var size: CGFloat = 40
    var network: Chain? = nil
    var networkCount: Int = 1
    var remoteURL: URL? = nil
    var ringColor: Color = Palette.void

    @State private var remote: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            base
                .frame(width: size, height: size)
            if let network, !isNative(on: network) {
                NetworkBadge(chain: network, size: size * 0.4, ring: ringColor)
                    .offset(x: size * 0.08, y: size * 0.08)
            } else if networkCount > 1 {
                Text("\(networkCount)")
                    .font(.system(size: size * 0.24, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Circle().fill(Palette.control))
                    .overlay(Circle().stroke(ringColor, lineWidth: 2))
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .accessibilityHidden(true)
        .task(id: remoteURL) {
            guard bundled == nil, let remoteURL, let data = await ImageLoader.shared.data(for: remoteURL) else { return }
            remote = UIImage(data: data)
        }
    }

    private var bundled: UIImage? { coingeckoID.flatMap { UIImage(named: "logo-\($0)") } }

    @ViewBuilder
    private var base: some View {
        if let image = bundled ?? remote {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(Circle())
                .background(Circle().fill(Self.darkLogos.contains(coingeckoID ?? "") ? Palette.logoDisc : Color.clear))
        } else {
            Circle().fill(Palette.control)
                .overlay(Text(String(symbol.prefix(2)).uppercased()).font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(Palette.inkSoft))
        }
    }

    /// Logos escuros que somem no preto ganham um disco claro atras.
    static let darkLogos: Set<String> = ["ripple", "stellar"]

    private func isNative(on chain: Chain) -> Bool {
        coingeckoID == chain.coingeckoID
    }
}

struct NetworkBadge: View {
    let chain: Chain
    var size: CGFloat = 16
    var ring: Color = Palette.void

    var body: some View {
        Group {
            if let image = UIImage(named: "rede-\(chain.id)") ?? UIImage(named: "logo-\(chain.coingeckoID)") {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit().clipShape(Circle())
                    .background(Circle().fill(chain.id == "xrpl" || chain.id == "stellar" ? Palette.logoDisc : Palette.control))
            } else {
                Circle().fill(Palette.control)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(ring, lineWidth: 2))
    }
}
