import CoreImage
import CoreImage.CIFilterBuiltins
import EscaliburChains
import EscaliburNetwork
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// QR com correcao de erro nivel H, modulos quadrados, sem suavizacao.
enum QRCode {
    /// `scale`: a escala da tela onde o QR aparece (`displayScale` do SwiftUI).
    static func image(_ text: String, size: CGFloat, scale screenScale: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(size * screenScale / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg, scale: screenScale, orientation: .up)
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
    @Environment(\.displayScale) private var displayScale
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
            .navigationDestination(for: ReceiveCoin.self) { coin in
                Group {
                    if coin.assets.count == 1, let only = coin.assets.first, let chain = only.chain {
                        addressView(asset: only, chain: chain)
                    } else {
                        networkPicker(coin)
                    }
                }
                .background(Palette.body.ignoresSafeArea())
                .toolbar(.visible, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
            }
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
        VStack(spacing: 0) {
            HStack { Spacer(); closeButton }
            BackupFirstArt(height: 280)
            VStack(spacing: Space.sm) {
                Text("Grave a senha da carteira antes de receber").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Esta carteira ainda não tem cópia. Se o iPhone sumir antes disso, o que chegar aqui se perde.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                Label("Leva 2 minutos", systemImage: "clock")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .padding(.top, Space.xxs)
            }
            .multilineTextAlignment(.center)
            .padding(.top, Space.md)
            Spacer(minLength: Space.md)
            PrimaryButton(title: "Gravar agora") { backingUp = true }
            SecondaryButton(title: "Agora não") { dismiss() }.padding(.top, Space.sm)
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

    /// R1: so as moedas. A mesma moeda em redes diferentes (USDT na Tron, na Ethereum,
    /// na Solana) e uma linha so; a rede vem depois, quando a moeda estiver escolhida.
    private var chooser: some View {
        let accounts = Set(wallet?.accounts.map(\.chainID) ?? [])
        // As moedas custom entram como qualquer outra, cada uma na sua linha (nunca junto
        // de um ativo da lista com o mesmo simbolo).
        let custom = session.metadata.customTokens.filter { accounts.contains($0.chainID) }
        let all = Chain.all.filter { accounts.contains($0.id) }.flatMap { TokenRegistry.assets(on: $0) } + custom
        let coins = ReceiveCoin.group(all)
        let filtered = query.isEmpty ? coins : coins.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        let held = Set(Chain.all.compactMap { portfolio.balance($0) }.flatMap(\.holdings).filter { !$0.amount.isZero }.map(\.asset.id))
        let inWallet = filtered.filter { coin in coin.assets.contains { held.contains($0.id) } }
        let others = filtered.filter { coin in !coin.assets.contains { held.contains($0.id) } }
        return VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Receber") { dismiss() }
            SearchField(prompt: "Buscar moeda", text: $query, surface: Palette.rail)
                .padding(.horizontal, Space.gutter).padding(.top, Space.md)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !inWallet.isEmpty {
                        sectionTitle("Na carteira")
                        ForEach(inWallet) { coinRow($0) }
                        sectionTitle("Todas")
                    }
                    ForEach(others) { coinRow($0) }
                }
                .padding(.top, Space.xs)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, Space.gutter).padding(.top, Space.md).padding(.bottom, Space.xxs)
    }

    private func coinRow(_ coin: ReceiveCoin) -> some View {
        NavigationLink(value: coin) {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: coin.coingeckoID, symbol: coin.symbol, size: 36, network: coin.isCustom ? coin.assets.first?.chain : nil,
                         ringColor: Palette.body, unverified: coin.isCustom,
                         contractLogo: coin.isCustom ? coin.assets.first.flatMap(TokenLogos.url(for:)) : nil)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: coin.symbol).typeStyle(.row).foregroundStyle(Palette.ink)
                        if coin.isCustom { TokenBadge(.custom) }
                    }
                    Text(verbatim: coin.isCustom ? "\(coin.name) na \(coin.assets.first?.chain?.name ?? "")" : coin.name)
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                Spacer()
                if coin.assets.count > 1 {
                    Text("\(coin.assets.count) redes").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
        }
        .buttonStyle(RowStyle(surface: .body))
    }

    /// R1b: a rede. Quem envia escolhe a rede do lado de la; as duas tem de ser a mesma.
    private func networkPicker(_ coin: ReceiveCoin) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.sm) {
                    CoinLogo(coingeckoID: coin.coingeckoID, symbol: coin.symbol, size: 32, network: nil, ringColor: Palette.body)
                    Text("Receber \(coin.symbol)").typeStyle(.title).foregroundStyle(Palette.ink)
                }
                Text("Escolha a rede. Tem de ser a mesma que quem envia escolher: \(coin.symbol) enviado por outra rede não chega a este endereço.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(coin.assets) { asset in
                        if let chain = asset.chain {
                            NavigationLink(value: asset) {
                                HStack(spacing: Space.sm) {
                                    NetworkBadge(chain: chain, size: 32, ring: Palette.body)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chain.name).typeStyle(.row).foregroundStyle(Palette.ink)
                                        if asset.kind != .native {
                                            Text(ReceiveCoin.standard(chain)).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                                }
                                .frame(minHeight: Height.row)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, Space.md)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
        }
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
                if asset.isCustom, let reference = CustomToken.reference(asset.kind) {
                    // Moeda custom: quem envia tem de mandar este contrato, nao outro com o
                    // mesmo simbolo.
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: 6) {
                            TokenBadge(.custom)
                            Text("Quem envia tem de usar exatamente \(CustomToken.usesIssuer(chain) ? "este emissor" : "este contrato"):")
                                .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                        }
                        AddressBlocks(address: reference)
                    }
                    .padding(.top, Space.sm)
                }
                if case .issued = asset.kind, asset.isCustom, balance?.holdings.contains(where: { $0.asset.id == asset.id }) != true {
                    Text("Para receber \(asset.symbol), esta conta precisa antes de uma linha de confiança com o emissor. A Escalibur ainda não abre linha de confiança para moeda custom: sem ela, o envio de quem manda não passa e o valor fica com quem enviou.")
                        .typeStyle(.note).foregroundStyle(Palette.caution).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.sm)
                } else if case .issued = asset.kind, balance?.holdings.contains(where: { $0.asset.id == asset.id }) != true {
                    // Token emitido (XRP Ledger, Stellar): sem linha de confianca, o envio
                    // de quem manda nao passa e volta; nada se perde, mas nao chega.
                    Text("Para receber \(asset.symbol), esta conta precisa antes de uma linha de confiança com o emissor do \(asset.symbol). Sem ela, o envio de quem manda não passa e o valor fica com quem enviou. A linha é criada na primeira troca por \(asset.symbol) aqui na carteira.")
                        .typeStyle(.note).foregroundStyle(Palette.caution).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.sm)
                }

                CopyButton {
                    Pasteboard.copyAddress(address)
                    toasts.show("Endereço copiado. Depois de colar, confira o endereço inteiro, inclusive o meio.")
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
            if let image = QRCode.image(address, size: 232, scale: displayScale) {
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
            case .sui:
                return "Na exchange, escolha a rede Sui. O endereço tem o mesmo formato dos endereços Aptos, e um envio pela Aptos não chega aqui."
            case .cardano:
                return "Na exchange, escolha a rede Cardano. Envie só ADA: tokens nativos que chegarem aqui ainda não podem ser movidos pela Escalibur."
            case .polkadot:
                return exists
                    ? "Na exchange, escolha a rede Polkadot Asset Hub e envie só DOT. DOT enviado pela relay chain antiga não aparece aqui."
                    : "Na exchange, escolha a rede Polkadot Asset Hub. O primeiro recebimento precisa ser de 0,01 DOT ou mais, o mínimo da rede para a conta existir."
            case .near:
                return exists
                    ? "Na exchange, escolha a rede NEAR e envie só NEAR. Esta é a conta implícita da carteira, com 64 caracteres, e não precisa de memo."
                    : "Na exchange, escolha a rede NEAR. Esta é a conta implícita da carteira: ela passa a existir no primeiro recebimento, de qualquer valor, e não precisa de memo."
            case .aptos:
                return "Na exchange, escolha a rede Aptos e envie só APT. O endereço tem o mesmo formato dos endereços Sui, e um envio pela Sui não chega aqui. A conta passa a existir no primeiro recebimento, de qualquer valor."
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

    /// Os primeiros caracteres destacados: 4, mais o prefixo fixo da rede quando ele
    /// existe ("0x" na EVM, "bc1q" no bech32), que sozinho nao diferencia endereco.
    static func headLength(_ address: String) -> Int {
        if address.hasPrefix("0x") || address.hasPrefix("0X") { return 6 }
        if let separator = address.firstIndex(of: "1") {
            let hrp = address[..<separator]
            if (2...4).contains(hrp.count), hrp.allSatisfy({ $0.isLowercase }) { return hrp.count + 2 + 4 }
        }
        return 4
    }

    /// Primeiro bloco com o comeco destacado, o meio em blocos de 4, e o ultimo bloco com
    /// os 4 finais destacados: e o que se confere contra a origem num relance.
    static func blocks(_ address: String) -> (blocks: [String], highlighted: Set<Int>) {
        let chars = Array(address)
        let head = min(headLength(address), chars.count)
        let tail = min(4, max(chars.count - head, 0))
        guard chars.count > head + tail else { return ([address], [0]) }
        let middle = Array(chars[head..<(chars.count - tail)])
        var blocks = [String(chars[0..<head])]
        blocks += stride(from: 0, to: middle.count, by: 4).map { String(middle[$0..<min($0 + 4, middle.count)]) }
        blocks.append(String(chars[(chars.count - tail)...]))
        return (blocks, [0, blocks.count - 1])
    }

    var body: some View {
        let (blocks, highlighted) = Self.blocks(address)
        let soft = onPlate ? Palette.plateMuted : Palette.inkSoft
        return FlowText(blocks: blocks) { index, block in
            if highlighted.contains(index) {
                // Marca-texto: letra escura em lima, na placa clara e no fundo escuro.
                var text = AttributedString(block)
                text.backgroundColor = Palette.lime
                text.foregroundColor = Palette.onLime
                return Text(text).font(TypeStyle.mono.font).fontWeight(.bold)
            }
            return Text(verbatim: block).font(TypeStyle.mono.font).foregroundColor(soft)
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

/// Uma moeda na lista de receber, com as redes em que a carteira recebe essa moeda.
struct ReceiveCoin: Identifiable, Hashable {
    let id: String
    let symbol: String
    let name: String
    let coingeckoID: String?
    let assets: [Asset]

    var isCustom: Bool { assets.first?.isCustom == true }

    /// Agrupa pelo identificador de preco (USDT e USDT em outra rede sao a mesma moeda).
    /// Primeiro as moedas nativas, na ordem das redes; depois os tokens, na ordem da lista
    /// curada (os mais antigos e, dali em diante, por valor de mercado). Com dezenas de
    /// tokens na Ethereum, a ordem das redes enterraria SOL, XRP e BNB no fim da lista.
    static func group(_ assets: [Asset]) -> [ReceiveCoin] {
        var order: [String] = []
        var byKey: [String: [Asset]] = [:]
        for asset in assets {
            let key = asset.coingeckoID ?? (asset.isCustom ? asset.id : "\(asset.symbol):\(asset.chainID)")
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(asset)
        }
        let coins: [ReceiveCoin] = order.compactMap { key in
            guard let items = byKey[key], let first = items.first else { return nil }
            let native = items.first { $0.kind == .native }
            let name = native.map { $0.chain?.nativeName ?? $0.name } ?? first.name
            return ReceiveCoin(id: key, symbol: first.symbol, name: name, coingeckoID: first.coingeckoID, assets: items)
        }
        var rank: [String: Int] = [:]
        for (index, token) in TokenRegistry.tokens.enumerated() where rank[token.coingeckoID ?? token.id] == nil {
            rank[token.coingeckoID ?? token.id] = index
        }
        let natives = coins.filter { coin in coin.assets.contains { $0.kind == .native } }
        let tokens = coins.filter { coin in !coin.assets.contains { $0.kind == .native } }
        return natives + tokens.sorted { (rank[$0.id] ?? .max, $0.id) < (rank[$1.id] ?? .max, $1.id) }
    }

    /// O padrao do token na rede, para quem envia de uma corretora achar a opcao certa.
    static func standard(_ chain: Chain) -> String {
        switch chain.family {
        case .evm: return chain.id == "bnb" ? "BEP-20" : "ERC-20"
        case .tron: return "TRC-20"
        case .solana: return "SPL"
        case .ton: return "Jetton"
        case .stellar, .xrpl: return "Ativo emitido"
        case .utxo: return ""
        // A carteira ainda nao lista moeda da Sui alem do SUI.
        case .sui: return ""
        // A carteira ainda nao lista token nativo da Cardano.
        case .cardano: return ""
        // A carteira ainda nao lista ativo da Polkadot Asset Hub alem do DOT.
        case .polkadot: return ""
        // A carteira ainda nao lista token NEP-141 da NEAR.
        case .near: return ""
        // A carteira ainda nao lista fungible asset da Aptos alem do APT.
        case .aptos: return ""
        }
    }
}
