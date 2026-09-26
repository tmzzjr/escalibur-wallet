import EscaliburChains
import EscaliburCore
import EscaliburKeys
import SwiftUI

/// O que a carteira importada vai ser, mostrado antes de guardar: os primeiros
/// enderecos e a impressao digital.
///
/// Frase com uma palavra trocada que ainda fecha o checksum, ou 25a palavra diferente,
/// abrem outra carteira, valida e vazia, sem aviso nenhum. Quem ja usou a carteira
/// reconhece os enderecos; a impressao digital e a mesma que carteiras de hardware e
/// o Sparrow mostram.
struct ImportPreview: Sendable {
    let fingerprint: String
    let addresses: [(chain: Chain, address: String)]

    static let chains: [Chain] = [.bitcoin, .ethereum, .solana]

    /// Deriva fora da thread principal. O segredo nao e zerado aqui: quem chama
    /// ainda vai guarda-lo ou descarta-lo.
    static func make(_ secret: WalletSecret) async throws -> ImportPreview {
        try await Task.detached(priority: .userInitiated) {
            let (accounts, fingerprint) = try AccountDeriver.derive(secret, chains: chains)
            let addresses = chains.compactMap { chain in accounts.first { $0.chainID == chain.id }.map { (chain, $0.address) } }
            return ImportPreview(fingerprint: fingerprint.hex.uppercased(), addresses: addresses)
        }.value
    }
}

struct ImportPreviewView: View {
    let preview: ImportPreview
    let hasPassphrase: Bool
    let saving: Bool
    let onSave: () -> Void
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Confira antes de guardar").typeStyle(.title).foregroundStyle(Palette.ink)
                Text(hasPassphrase
                     ? "Se esta carteira já recebeu antes, estes endereços são os que você conhece. Se não baterem, a frase ou a 25ª palavra está diferente, e o que abriria aqui é outra carteira, vazia."
                     : "Se esta carteira já recebeu antes, estes endereços são os que você conhece. Se não baterem, alguma palavra está diferente, e o que abriria aqui é outra carteira, vazia.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(preview.addresses, id: \.chain.id) { item in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack(spacing: Space.xs) {
                                NetworkBadge(chain: item.chain, size: 20, ring: Palette.body)
                                Text(item.chain.name).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                            }
                            AddressBlocks(address: item.address)
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Impressão digital da carteira").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        Text(verbatim: preview.fingerprint).typeStyle(.row).foregroundStyle(Palette.ink)
                        Text("A mesma que carteiras de hardware mostram para esta frase.")
                            .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    }
                }
                .padding(.top, Space.lg)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
        }
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                PrimaryButton(title: "Guardar esta carteira", loading: saving, action: onSave)
                TertiaryButton(title: "Voltar e conferir", action: onBack)
            }
        }
        .background(Palette.void.ignoresSafeArea())
    }
}
