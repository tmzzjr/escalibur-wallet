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
    /// Token fora da lista (custom ou descoberto): nunca o logo que o proprio token
    /// declara, e as letras so em ASCII, brancas no cinza escuro. O logo de um token de
    /// golpe e parte da isca.
    var unverified: Bool = false
    /// O token cuja logo vem pelo contrato exato (`TokenLogoResolver`: repositorio da
    /// Trust Wallet, depois o CoinGecko). Vale tambem para token fora da lista: segue o
    /// contrato, nao o nome, e o golpe que copia o nome do USDT nao tem o contrato do
    /// USDT. Suspeito nunca recebe.
    var logoAsset: Asset? = nil

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
        .task(id: logoAsset?.id ?? remoteURL?.absoluteString) {
            if let logoAsset {
                guard bundled == nil, let url = await TokenLogoResolver.shared.logo(for: logoAsset),
                      let data = await ImageLoader.shared.data(for: url) else { return }
                remote = UIImage(data: data)
                return
            }
            guard !unverified, bundled == nil, let remoteURL, let data = await ImageLoader.shared.data(for: remoteURL) else { return }
            remote = UIImage(data: data)
        }
    }

    private var bundled: UIImage? { coingeckoID.flatMap { UIImage(named: "logo-\($0)") } }

    @ViewBuilder
    private var base: some View {
        if unverified, logoAsset != nil, let remote {
            Image(uiImage: remote)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(Circle())
        } else if unverified {
            let letters = TokenGlyph.letters(symbol)
            Circle().fill(Palette.control)
                .overlay {
                    if letters.isEmpty {
                        Image(systemName: "questionmark").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(Palette.ink)
                    } else {
                        Text(letters).font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(Palette.ink)
                    }
                }
        } else if let image = bundled ?? remote {
            if Self.bareLogos.contains(coingeckoID ?? "") {
                // Logo sem circulo proprio (o losango do ETH, as faixas do SOL): vai
                // num disco, com o glifo a 62%, para a coluna de circulos nao quebrar.
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.19)
                    .background(Circle().fill(Palette.control))
            } else {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(Circle())
                    .background(Circle().fill(Self.darkLogos.contains(coingeckoID ?? "") ? Palette.logoDisc : Color.clear))
            }
        } else {
            Circle().fill(Palette.control)
                .overlay(Text(String(symbol.prefix(2)).uppercased()).font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(Palette.inkSoft))
        }
    }

    /// Logos escuros que somem no preto ganham um disco claro atras.
    static let darkLogos: Set<String> = ["ripple", "stellar"]
    static let bareLogos: Set<String> = ["ethereum", "solana", "tether", "weth"]

    private func isNative(on chain: Chain) -> Bool {
        coingeckoID == chain.coingeckoID
    }
}

struct NetworkBadge: View {
    static let bareNetworks: Set<String> = []
    let chain: Chain
    var size: CGFloat = 16
    var ring: Color = Palette.void

    var body: some View {
        Group {
            if chain.id == "base" {
                // A marca da Base (o quadrado) num disco azul cheio: o arquivo da
                // plataforma e um quadrado solto, que num circulo parece icone quebrado.
                Circle().fill(Color(hex: 0x0052FF))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.06, style: .continuous).fill(Color.white).frame(width: size * 0.38, height: size * 0.38))
            } else if Self.bareNetworks.contains(chain.id), let image = UIImage(named: "rede-\(chain.id)") ?? UIImage(named: "logo-\(chain.coingeckoID)") {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit().padding(size * 0.18)
                    .background(Circle().fill(Palette.control))
            } else if let image = UIImage(named: "rede-\(chain.id)") ?? UIImage(named: "logo-\(chain.coingeckoID)") {
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
