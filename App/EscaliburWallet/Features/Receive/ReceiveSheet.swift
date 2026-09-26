import CoreImage
import CoreImage.CIFilterBuiltins
import EscaliburChains
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// QR com correcao de erro nivel H, modulos quadrados, sem suavizacao.
enum QRCode {
    static func image(_ text: String, size: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(size * UIScreen.main.scale / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg, scale: UIScreen.main.scale, orientation: .up)
    }
}

/// Area de transferencia so para endereco: local (nao sincroniza com outros
/// aparelhos) e com validade de 2 minutos. A frase nunca passa por aqui.
enum Pasteboard {
    static func copyAddress(_ address: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: address]], options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(120),
        ])
    }
}

/// R1 e R2: escolher o que receber e mostrar o endereco.
struct ReceiveSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(Portfolio.self) private var portfolio
    @Environment(\.dismiss) private var dismiss
    let preselected: Asset?

    @State private var query = ""
    @State private var backingUp = false

    private var wallet: WalletMeta? { session.selectedWallet }

    var body: some View {
        NavigationStack {
            Group {
                if let wallet, !wallet.hasBackup, !wallet.isWatchOnly {
                    blocked
                } else if let preselected, let chain = preselected.chain {
                    addressView(asset: preselected, chain: chain)
                } else {
                    chooser
                }
            }
            .background(Palette.body.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Asset.self) { item in
                if let chain = item.chain {
                    addressView(asset: item, chain: chain)
                        .background(Palette.body.ignoresSafeArea())
                        .toolbar(.visible, for: .navigationBar)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
        .fullScreenCover(isPresented: $backingUp) {
            if let wallet { RevealFlow(wallet: wallet, purpose: .backup) { backingUp = false } }
        }
    }

    private var blocked: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Spacer(); closeButton }
            Text("Grave a senha da carteira antes de receber").typeStyle(.title).foregroundStyle(Palette.ink)
            Text("Esta carteira ainda não tem cópia. Se o iPhone sumir antes disso, o que chegar aqui se perde. Leva 2 minutos.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm).fixedSize(horizontal: false, vertical: true)
            Spacer()
            PrimaryButton(title: "Gravar agora") { backingUp = true }
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.md).padding(.bottom, Space.xs)
    }

    // MARK: R1

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                .frame(width: Height.touch, height: Height.touch)
        }
        .accessibilityLabel("Fechar")
    }

    private var chooser: some View {
        let accounts = Set(wallet?.accounts.map(\.chainID) ?? [])
        let all = Chain.all.filter { accounts.contains($0.id) }.flatMap { TokenRegistry.assets(on: $0) }
        let filtered = query.isEmpty ? all : all.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        let held = Set(Chain.all.compactMap { portfolio.balance($0) }.flatMap(\.holdings).filter { !$0.amount.isZero }.map(\.asset.id))
        let inWallet = filtered.filter { held.contains($0.id) }
        let others = filtered.filter { !held.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Receber") { dismiss() }
            SearchField(prompt: "Buscar", text: $query, surface: Palette.rail)
                .padding(.horizontal, Space.gutter).padding(.top, Space.md)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !inWallet.isEmpty {
                        sectionTitle("Na carteira")
                        ForEach(inWallet) { assetRow($0) }
                        sectionTitle("Todos")
                    }
                    ForEach(others) { assetRow($0) }
                }
                .padding(.top, Space.xs)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, Space.gutter).padding(.top, Space.md).padding(.bottom, Space.xxs)
    }

    private func assetRow(_ item: Asset) -> some View {
        NavigationLink(value: item) {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: item.coingeckoID, symbol: item.symbol, size: 36, network: item.chain, ringColor: Palette.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.symbol).typeStyle(.row).foregroundStyle(Palette.ink)
                    Text(item.kind == .native ? (item.chain?.name ?? "") : "\(item.name) · \(item.chain?.name ?? "")")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
        }
        .buttonStyle(RowStyle(surface: .body))
    }

    // MARK: R2

    private func addressView(asset: Asset, chain: Chain) -> some View {
        let address = wallet?.account(chain)?.address ?? ""
        let balance = portfolio.balance(chain)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if preselected != nil { HStack { Spacer(); closeButton } }
                Text("Receber \(asset.symbol)").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("pela rede \(chain.name)").typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xxs)

                qrPlate(address: address, chain: chain).padding(.top, Space.lg)

                AddressBlocks(address: address).padding(.top, Space.base)

                warning(chain: chain, asset: asset, exists: balance?.accountExists ?? true)
                    .padding(.top, Space.md)

                PrimaryButton(title: "Copiar endereço") {
                    Pasteboard.copyAddress(address)
                    toasts.show("Endereço copiado. Depois de colar, confira os 6 primeiros e os 6 últimos caracteres.")
                }
                .padding(.top, Space.lg)
                ShareLink(item: address) {
                    Text("Compartilhar").typeStyle(.action).frame(maxWidth: .infinity).frame(height: Height.secondary)
                }
                .buttonStyle(SecondaryStyle())
                .padding(.top, Space.sm)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
            .padding(.bottom, Space.lg)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: toasts.current?.id)
    }

    private func qrPlate(address: String, chain: Chain) -> some View {
        ZStack {
            if let image = QRCode.image(address, size: 232) {
                Image(uiImage: image).interpolation(.none).resizable().frame(width: 232, height: 232)
            }
            NetworkBadge(chain: chain, size: 48, ring: Palette.live)
                .padding(4)
                .background(Circle().fill(Palette.live))
        }
        .frame(width: 280, height: 280)
        .background(LacquerPlate(cut: 24, radius: Radius.button).fill(Palette.live))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("QR do endereço")
    }

    @ViewBuilder
    private func warning(chain: Chain, asset: Asset, exists: Bool) -> some View {
        let text: String = {
            switch chain.family {
            case .evm:
                return "Na exchange, escolha a rede \(chain.name). Se vier por outra rede EVM, o saldo aparece naquela rede, desde que ela esteja ligada em Ajustes."
            case .utxo:
                return "Envie só \(chain.nativeName.lowercased()), pela rede \(chain.name). Outra moeda enviada para este endereço se perde."
            case .xrpl:
                return exists
                    ? "Não precisa de tag de destino. Se a exchange pedir, marque que o endereço não tem tag."
                    : "Esta conta ainda não existe no XRP Ledger. O primeiro recebimento precisa ser de 1 XRP ou mais, e 1 XRP fica reservado pela rede."
            case .stellar:
                return exists
                    ? "Não precisa de memo. Se a exchange pedir, marque que o endereço não tem memo."
                    : "Esta conta ainda não existe na Stellar. O primeiro recebimento precisa ser de 1 XLM ou mais, e parte fica reservada pela rede."
            case .solana:
                return "Envie só pela rede Solana. Tokens de outras redes enviados para este endereço se perdem."
            case .tron:
                return exists
                    ? "Envie só pela rede Tron (TRC-20). USDT de outra rede enviado para este endereço se perde."
                    : "Esta conta Tron ainda não está ativa. Ela ativa no primeiro recebimento de TRX ou de token."
            case .ton:
                return "Envie só pela rede TON. Não precisa de comentário."
            }
        }()
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
    }
}

/// Endereco inteiro em mono, em blocos de 4, com as pontas em destaque: e o que a
/// pessoa confere.
struct AddressBlocks: View {
    let address: String
    var onPlate: Bool = false

    var body: some View {
        let chars = Array(address)
        let blocks = stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }
        let strong = onPlate ? Palette.plateInk : Palette.ink
        let soft = onPlate ? Palette.plateMuted : Palette.inkSoft
        return FlowText(blocks: blocks) { index, block in
            let start = index * 4
            let end = start + block.count
            return Text(verbatim: block)
                .font(TypeStyle.mono.font)
                .fontWeight(start < 6 || end > chars.count - 6 ? .bold : .regular)
                .foregroundColor(start < 6 || end > chars.count - 6 ? strong : soft)
        }
        .textSelection(.disabled)
        .accessibilityLabel(address)
    }
}

/// Blocos de texto em linhas que quebram, com espaco visual entre eles (a copia
/// continua sem espacos).
struct FlowText: View {
    let blocks: [String]
    let content: (Int, String) -> Text

    var body: some View {
        var text = Text("")
        for (index, block) in blocks.enumerated() {
            text = text + content(index, block) + Text(verbatim: index < blocks.count - 1 ? "  " : "").font(.system(size: 8))
        }
        return text.lineSpacing(6).fixedSize(horizontal: false, vertical: true)
    }
}
