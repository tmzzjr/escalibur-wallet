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

/// Area de transferencia: local (nao sincroniza com outros aparelhos) e com validade.
/// O endereco vale 2 minutos. A frase so passa por aqui depois da tela de aviso
/// (`CopyPhraseSheet`, pedido do dono de 15/10/2026), e vale 1 minuto.
enum Pasteboard {
    static func copyAddress(_ address: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: address]], options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(120),
        ])
    }

    static func copyPhrase(_ words: [String]) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: words.joined(separator: " ")]], options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(60),
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
    /// A rede trocada no seletor da tela do endereco, por moeda.
    @State private var chosenNetwork: [String: Asset] = [:]
    /// Moeda da lista completa que o dono quer ver no saldo: abre o Adicionar moeda.
    @State private var adding: AddPick?

    struct AddPick: Identifiable {
        let id = UUID()
        let preset: AddCustomTokenView.Preset
    }

    /// Uma moeda da lista completa, e a rede quando ja escolhida.
    struct CatalogPick: Hashable {
        let coin: CatalogCoin
        let network: CatalogCoin.Network?
    }

    private var wallet: WalletMeta? { session.selectedWallet }
    private var search: CoinSearchStore { .shared }

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
                    if coin.assets.count == 1, extraNetworks(coin).isEmpty, otherForms(coin).isEmpty, let only = coin.assets.first, let chain = only.chain {
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
            .navigationDestination(for: CoinSearchResult.self) { result in
                catalogLookup(result)
                    .background(Palette.body.ignoresSafeArea())
                    .toolbar(.visible, for: .navigationBar)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: CatalogPick.self) { pick in
                Group {
                    let networks = freshNetworks(pick.coin)
                    if let network = pick.network ?? (networks.count == 1 ? networks.first : nil), let chain = network.chain,
                       let asset = Self.catalogAsset(pick.coin, network) {
                        addressContent(asset: asset, chain: chain, siblings: [], key: pick.coin.id, catalog: (pick.coin, network))
                    } else {
                        catalogNetworkPicker(pick.coin, networks: networks)
                    }
                }
                .background(Palette.body.ignoresSafeArea())
                .toolbar(.visible, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $adding) { pick in
            NavigationStack { AddCustomTokenView(preset: pick.preset) { adding = nil } }
                .presentationBackground(Palette.void)
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
            PrimaryButton(title: String(localized: "Gravar agora")) { backingUp = true }
            SecondaryButton(title: String(localized: "Agora não")) { dismiss() }.padding(.top, Space.sm)
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
    ///
    /// Buscando, aparece qualquer moeda: depois das da carteira e das verificadas, o que
    /// o CoinGecko acha para o texto digitado (`CoinCatalog`). As redes de cada moeda so
    /// sao lidas quando o dono toca nela.
    private var chooser: some View {
        let coins = ReceiveCoin.group(receivable)
        let searching = query.trimmingCharacters(in: .whitespaces).count >= 2
        let filtered = query.isEmpty ? coins : coins.filter { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
        let held = Set(Chain.all.compactMap { portfolio.balance($0) }.flatMap(\.holdings).filter { !$0.amount.isZero }.map(\.asset.id))
        let inWallet = filtered.filter { coin in coin.assets.contains { held.contains($0.id) } }
        let others = filtered.filter { coin in !coin.assets.contains { held.contains($0.id) } }
        let listedIDs = Set(coins.compactMap(\.coingeckoID))
        return VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Receber")) { dismiss() }
            SearchField(prompt: String(localized: "Buscar qualquer moeda"), text: $query, surface: Palette.rail)
                .padding(.horizontal, Space.gutter).padding(.top, Space.md)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !inWallet.isEmpty {
                        sectionTitle(String(localized: "Na carteira"))
                        ForEach(inWallet) { coinRow($0) }
                    }
                    if !others.isEmpty {
                        if !inWallet.isEmpty || searching { sectionTitle(searching ? String(localized: "Verificadas") : String(localized: "Todas")) }
                        ForEach(others) { coinRow($0) }
                    }
                    if searching {
                        searchSection(listedIDs: listedIDs, nothingListed: filtered.isEmpty)
                    }
                }
                .padding(.top, Space.xs)
                .padding(.bottom, Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .task(id: CoinSearchStore.key(query)) {
            guard searching else { return }
            await search.search(query)
        }
        #if DEBUG
        // `-busca <texto>`: a busca ja preenchida, para conferir a lista completa.
        .onAppear {
            if query.isEmpty, let index = DebugDemo.arguments.firstIndex(of: "-busca"), DebugDemo.arguments.indices.contains(index + 1) {
                query = DebugDemo.arguments[index + 1]
            }
        }
        #endif
    }

    /// O que o CoinGecko achou para o texto: linhas que brilham enquanto a resposta
    /// chega, e as moedas fora da lista verificada quando ela chega.
    @ViewBuilder
    private func searchSection(listedIDs: Set<String>, nothingListed: Bool) -> some View {
        switch search.status(query) {
        case .loaded(let results)?:
            let shown = results.filter { !listedIDs.contains($0.id) }
            if !shown.isEmpty {
                sectionTitle(String(localized: "Mais moedas, fora da lista verificada"))
                ForEach(shown) { resultRow($0) }
            } else if nothingListed {
                searchNote(String(localized: "Nenhuma moeda com esse nome ou símbolo."))
            }
        case .failed?:
            VStack(alignment: .leading, spacing: Space.xs) {
                searchNote(String(localized: "O CoinGecko não respondeu agora. Aparecem só as moedas verificadas."))
                TertiaryButton(title: String(localized: "Buscar de novo")) {
                    search.retry(query)
                    Task { await search.search(query) }
                }
                    .padding(.horizontal, Space.gutter)
            }
        case .retrying?:
            sectionTitle(String(localized: "Mais moedas, fora da lista verificada"))
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
            searchNote(String(localized: "O CoinGecko pediu uma pausa. Tentando de novo."))
        case .loading?, nil:
            sectionTitle(String(localized: "Mais moedas, fora da lista verificada"))
            ForEach(0..<3, id: \.self) { _ in placeholderRow }
        }
    }

    private func searchNote(_ text: String) -> some View {
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.gutter).padding(.top, Space.md)
    }

    /// O lugar de uma moeda enquanto a busca responde.
    private var placeholderRow: some View {
        HStack(spacing: Space.sm) {
            ShimmerBar(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 6) {
                ShimmerBar(width: 72, height: 14)
                ShimmerBar(width: 140, height: 12)
            }
            Spacer()
        }
        .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
        .accessibilityHidden(true)
    }

    private func resultRow(_ result: CoinSearchResult) -> some View {
        NavigationLink(value: result) {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: result.id, symbol: result.symbol, size: 36, remoteURL: result.image, ringColor: Palette.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: result.symbol).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(verbatim: result.name).typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
            }
            .padding(.horizontal, Space.gutter).frame(minHeight: Height.row)
        }
        .buttonStyle(RowStyle(surface: .body))
    }

    /// Tocou numa moeda da busca: le as redes dela e segue para a rede, o endereco ou o
    /// aviso de que ainda nao recebe aqui.
    @ViewBuilder
    private func catalogLookup(_ result: CoinSearchResult) -> some View {
        Group {
            if let coin = search.coins[result.id] {
                let networks = freshNetworks(coin)
                if networks.count == 1, let network = networks.first, let chain = network.chain, let asset = Self.catalogAsset(coin, network) {
                    addressContent(asset: asset, chain: chain, siblings: [], key: coin.id, catalog: (coin, network))
                } else if networks.count > 1 {
                    catalogNetworkPicker(coin, networks: networks, image: result.image)
                } else {
                    notReceivable(coin, image: result.image)
                }
            } else if search.coinFailures.contains(result.id) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Receber \(result.symbol)").typeStyle(.title).foregroundStyle(Palette.ink)
                    Text("O CoinGecko não respondeu agora, e sem ele a carteira não sabe em que rede esta moeda existe.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    SecondaryButton(title: String(localized: "Tentar de novo")) { Task { await search.coin(result.id) } }
                    Spacer()
                }
                .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
            } else {
                VStack(spacing: Space.md) {
                    Spacer()
                    ProgressView().tint(Palette.inkSoft)
                    Text(search.coinRetrying.contains(result.id)
                         ? "O CoinGecko pediu uma pausa. Esperando liberar para ler as redes de \(result.symbol)."
                         : "Buscando as redes de \(result.symbol)")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).multilineTextAlignment(.center)
                        .padding(.horizontal, Space.gutter)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: result.id) { await search.coin(result.id) }
    }

    /// Moeda que so existe em rede que a carteira nao tem (ou desligada): sem endereco.
    /// Mandar para um endereco de outra rede perderia o valor.
    private func notReceivable(_ coin: CatalogCoin, image: URL?) -> some View {
        let accounts = Set(wallet?.accounts.map(\.chainID) ?? [])
        let switchedOff = coin.networks.filter { !accounts.contains($0.chainID) }.compactMap(\.chain)
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 32, remoteURL: image, ringColor: Palette.body)
                    Text("Receber \(coin.symbol)").typeStyle(.title).foregroundStyle(Palette.ink)
                }
                Text(switchedOff.isEmpty
                     ? "A Escalibur ainda não recebe \(coin.symbol): ela existe só em redes que a carteira não tem, ou em que a carteira ainda não mostra token fora da lista. Não envie \(coin.symbol) para nenhum endereço desta carteira."
                     : "\(coin.symbol) existe na \(switchedOff.map(\.name).joined(separator: ", ")), que está desligada nesta carteira. Ligue a rede em Ajustes para receber.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
        }
    }

    // MARK: Lista completa

    /// A moeda da lista completa como ativo da tela do endereco: token fora da lista, so
    /// para mostrar (o saldo so entra pelo Adicionar moeda, que le a rede). O contrato
    /// passa pela validacao completa da moeda custom; invalido, ou ja na lista, nil.
    static func catalogAsset(_ coin: CatalogCoin, _ network: CatalogCoin.Network) -> Asset? {
        guard let chain = network.chain, case .token(let contract)? = try? CustomToken.kind(chain: chain, address: network.contract) else {
            return nil
        }
        return Asset(chainID: chain.id, kind: .token(contract: contract), symbol: coin.symbol, name: coin.name, decimals: 0,
                     coingeckoID: coin.id, isStablecoin: false, origin: .discovered)
    }

    /// As redes da moeda em que esta carteira tem conta e que ainda nao estao nela (pela
    /// lista ou como moeda custom).
    private func freshNetworks(_ coin: CatalogCoin) -> [CatalogCoin.Network] {
        let accounts = Set(wallet?.accounts.map(\.chainID) ?? [])
        let known = Set(receivable.map(\.id))
        return coin.networks.filter { network in
            guard accounts.contains(network.chainID), let asset = Self.catalogAsset(coin, network) else { return false }
            return !known.contains(asset.id)
        }
    }

    /// Redes de fora da lista de uma moeda verificada (o PEPE da lista na Ethereum, e o
    /// da BNB Chain que o CoinGecko lista).
    private func extraNetworks(_ coin: ReceiveCoin) -> [CatalogCoin.Network] {
        guard let id = coin.coingeckoID, !coin.isCustom, let entry = search.coins[id] else { return [] }
        return freshNetworks(entry)
    }

    /// As formas embrulhadas da moeda que a carteira recebe (WBTC e cbBTC no BTC; WETH e o
    /// ETH da Binance no ETH). Cada uma e a sua propria moeda: tocar abre o endereco dela, e
    /// o seletor embaixo do QR so troca de rede dentro dela, nunca de volta para a nativa.
    private func otherForms(_ coin: ReceiveCoin) -> [Asset] {
        guard let id = coin.coingeckoID, coin.assets.contains(where: { $0.kind == .native }) else { return [] }
        return receivable.filter { asset in asset.coingeckoID.flatMap { ReceiveCoin.wrappedForms[$0] } == id }
    }

    private func otherFormRow(_ asset: Asset) -> some View {
        NavigationLink(value: asset) {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: asset.coingeckoID, symbol: asset.symbol, size: 32, network: asset.chain, ringColor: Palette.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(asset.symbol) na \(asset.chain?.name ?? "")").typeStyle(.row).foregroundStyle(Palette.ink)
                    Text(verbatim: [asset.name, asset.chain.map(ReceiveCoin.standard) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                }
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
            }
            .frame(minHeight: Height.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("outra-forma-\(asset.symbol)-\(asset.chainID)")
    }

    /// A rede de uma moeda fora da lista com mais de uma rede.
    private func catalogNetworkPicker(_ coin: CatalogCoin, networks: [CatalogCoin.Network], image: URL? = nil) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.sm) {
                    CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 32, remoteURL: image, ringColor: Palette.body,
                             logoAsset: networks.first.flatMap { Self.catalogAsset(coin, $0) })
                    Text("Receber \(coin.symbol)").typeStyle(.title).foregroundStyle(Palette.ink)
                }
                Text("Escolha a rede. Tem de ser a mesma que quem envia escolher: \(coin.symbol) enviado por outra rede não chega a este endereço.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(networks, id: \.self) { network in catalogNetworkRow(coin, network) }
                }
                .padding(.top, Space.md)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
        }
    }

    @ViewBuilder
    private func catalogNetworkRow(_ coin: CatalogCoin, _ network: CatalogCoin.Network) -> some View {
        if let chain = network.chain {
            NavigationLink(value: CatalogPick(coin: coin, network: network)) {
                HStack(spacing: Space.sm) {
                    NetworkBadge(chain: chain, size: 32, ring: Palette.body)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chain.name).typeStyle(.row).foregroundStyle(Palette.ink)
                        Text("\(ReceiveCoin.standard(chain)) · não verificado").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                }
                .frame(minHeight: Height.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                         logoAsset: coin.isCustom ? coin.assets.first : nil)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: coin.symbol).typeStyle(.row).foregroundStyle(Palette.ink)
                        if coin.isCustom { TokenBadge(.custom) }
                    }
                    (coin.isCustom ? Text("\(coin.name) na \(coin.assets.first?.chain?.name ?? "")") : Text(verbatim: coin.name))
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
                Spacer()
                if coin.assets.count > 1 {
                    Text("\(coin.assets.count) redes").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
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
                                    Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                                }
                                .frame(minHeight: Height.row)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, Space.md)
                let forms = otherForms(coin)
                if !forms.isEmpty {
                    Text("Outras formas de \(coin.symbol)").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
                    Text("Não são \(coin.symbol) da rede \(coin.assets.first { $0.kind == .native }?.chain?.name ?? coin.name): são tokens que valem o mesmo enquanto o emissor mantiver o lastro. Quem envia tem de escolher exatamente esta moeda e esta rede.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    VStack(spacing: 0) {
                        ForEach(forms) { asset in otherFormRow(asset) }
                    }
                    .padding(.top, Space.xs)
                }
                let extras = extraNetworks(coin)
                if !extras.isEmpty, let id = coin.coingeckoID, let entry = search.coins[id] {
                    Text("Fora da lista verificada").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
                    Text("O CoinGecko lista \(coin.symbol) também nestas redes, com o contrato de cada uma. A Escalibur ainda não conferiu esses contratos.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    VStack(spacing: 0) {
                        ForEach(extras, id: \.self) { network in catalogNetworkRow(entry, network) }
                    }
                    .padding(.top, Space.xs)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.xs)
        }
        .task(id: coin.id) { if let id = coin.coingeckoID, !coin.isCustom { await search.coin(id) } }
    }

    /// Tudo o que a carteira recebe: nativas e tokens da lista nas redes com conta, e as
    /// moedas custom (cada uma na sua linha, nunca junto de um ativo da lista).
    private var receivable: [Asset] {
        let accounts = Set(wallet?.accounts.map(\.chainID) ?? [])
        let custom = session.metadata.customTokens.filter { accounts.contains($0.chainID) }
        return Chain.all.filter { accounts.contains($0.id) }.flatMap { TokenRegistry.assets(on: $0) } + custom
    }

    // MARK: R2

    /// A tela do endereco, com a rede que o seletor escolheu (a da lista, de inicio).
    private func addressView(asset: Asset, chain: Chain) -> some View {
        let siblings = ReceiveCoin.group(receivable).first { coin in coin.assets.contains { $0.id == asset.id } }?.assets ?? [asset]
        let key = siblings.first?.id ?? asset.id
        let shown = chosenNetwork[key].flatMap { choice in siblings.first { $0.id == choice.id } } ?? asset
        return addressContent(asset: shown, chain: shown.chain ?? chain, siblings: siblings, key: key)
    }

    /// Com mais de uma rede, a rede embaixo do QR, no mesmo seletor da troca: o logo de cada rede na lista,
    /// porque escolher rede e reconhecer o logo (pedido do dono, 14/10/2026).
    @ViewBuilder
    private func addressNetworkMenu(asset: Asset, chain: Chain, siblings: [Asset], key: String) -> some View {
        if siblings.count > 1 {
            NetworkMenu(chains: siblings.compactMap(\.chain), selected: chain) { picked in
                guard let item = siblings.first(where: { $0.chain == picked }) else { return }
                withAnimation(Motion.fade) { chosenNetwork[key] = item }
            }
            .accessibilityIdentifier("receber-rede")
            .frame(maxWidth: .infinity)
        }
    }

    /// `catalog`: moeda achada na busca, fora da lista verificada. A tela mostra o
    /// contrato que quem envia tem de usar e oferece adicionar a moeda ao saldo.
    private func addressContent(asset: Asset, chain: Chain, siblings: [Asset], key: String,
                                catalog: (coin: CatalogCoin, network: CatalogCoin.Network)? = nil) -> some View {
        let address = wallet?.account(chain)?.address ?? ""
        let balance = portfolio.balance(chain)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if preselected != nil { HStack { Spacer(); closeButton } }
                Text("Receber \(asset.symbol)").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("pela rede \(chain.name)").typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)

                if wallet?.isWatchOnly == true {
                    // Golpe comum: alguem pede para "observar" o endereco dele e depositar ali.
                    // O app nao tem a chave deste endereco (auditoria 3, B3).
                    Banner(kind: .caution, title: String(localized: "Carteira só de observação"),
                           message: String(localized: "Este app não tem a chave deste endereço: o que chegar aqui não sai por este app. Se alguém pediu para você observar um endereço e depositar nele, é golpe."))
                        .padding(.top, Space.md)
                        .accessibilityIdentifier("receber-observacao")
                }

                qrPlate(address: address, chain: chain).padding(.top, Space.lg)
                addressNetworkMenu(asset: asset, chain: chain, siblings: siblings, key: key).padding(.top, Space.md)

                AddressBlocks(address: address).padding(.top, Space.base)

                warning(chain: chain, asset: asset, exists: balance?.accountExists ?? true)
                    .padding(.top, Space.md)
                if let catalog {
                    catalogBlock(asset: asset, chain: chain, coin: catalog.coin, network: catalog.network).padding(.top, Space.sm)
                }
                if asset.isCustom, let reference = CustomToken.reference(asset.kind) {
                    // Moeda custom: quem envia tem de mandar este contrato, nao outro com o
                    // mesmo simbolo.
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: 6) {
                            TokenBadge(.custom)
                            Text(CustomToken.usesIssuer(chain) ? "Quem envia tem de usar exatamente este emissor:" : "Quem envia tem de usar exatamente este contrato:")
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
                    toasts.show(String(localized: "Endereço copiado. Depois de colar, confira o endereço inteiro, inclusive o meio."))
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

    /// O contrato da lista completa e o caminho para a moeda aparecer no saldo.
    private func catalogBlock(asset: Asset, chain: Chain, coin: CatalogCoin, network: CatalogCoin.Network) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if coin.hasNotice {
                // O texto do aviso e de quem escreveu, com link: a tela so diz que existe.
                Text("O CoinGecko publicou um aviso sobre \(coin.symbol) (ataque, migração ou golpe). Confira as notícias da moeda antes de receber.")
                    .typeStyle(.note).foregroundStyle(Palette.caution).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                TokenBadge(.unverified)
                Text("Quem envia tem de usar exatamente este contrato:")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            AddressBlocks(address: CustomToken.reference(asset.kind) ?? network.contract)
            Text("Contrato listado pelo CoinGecko, fora da lista verificada da Escalibur. Para o saldo aparecer na carteira, adicione a moeda: a carteira lê nome, símbolo e casas na própria rede antes de salvar.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: String(localized: "Adicionar \(asset.symbol) à carteira")) {
                adding = AddPick(preset: AddCustomTokenView.Preset(chain: chain, kind: asset.kind))
            }
            .padding(.top, Space.xxs)
        }
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
                return String(localized: "Na exchange, escolha a rede \(chain.name). Se vier por outra rede EVM, o saldo aparece naquela rede, desde que ela esteja ligada em Ajustes.")
            case .utxo:
                return String(localized: "Envie só \(chain.nativeName), pela rede \(chain.name). Outra moeda enviada para este endereço se perde.")
            case .xrpl:
                return exists
                    ? String(localized: "Não precisa de tag de destino. Se a exchange pedir, marque que o endereço não tem tag.")
                    : String(localized: "Esta conta ainda não existe no XRP Ledger. O primeiro recebimento precisa ser de 1 XRP ou mais, e 1 XRP fica reservado pela rede.")
            case .stellar:
                return exists
                    ? String(localized: "Não precisa de memo. Se a exchange pedir, marque que o endereço não tem memo.")
                    : String(localized: "Esta conta ainda não existe na Stellar. O primeiro recebimento precisa ser de 1 XLM ou mais, e parte fica reservada pela rede.")
            case .solana:
                return String(localized: "Envie só pela rede Solana. Tokens de outras redes enviados para este endereço se perdem.")
            case .tron:
                return exists
                    ? String(localized: "Envie só pela rede Tron (TRC-20). USDT de outra rede enviado para este endereço se perde.")
                    : String(localized: "Esta conta Tron ainda não está ativa. Ela ativa no primeiro recebimento de TRX ou de token.")
            case .ton:
                return String(localized: "Envie só pela rede TON. Não precisa de comentário.")
            case .sui:
                return String(localized: "Na exchange, escolha a rede Sui. O endereço tem o mesmo formato dos endereços Aptos, e um envio pela Aptos não chega aqui.")
            case .cardano:
                return String(localized: "Na exchange, escolha a rede Cardano. Envie só ADA: tokens nativos que chegarem aqui ainda não podem ser movidos pela Escalibur.")
            case .polkadot:
                return exists
                    ? String(localized: "Na exchange, escolha a rede Polkadot Asset Hub e envie só DOT. DOT enviado pela relay chain antiga não aparece aqui.")
                    : String(localized: "Na exchange, escolha a rede Polkadot Asset Hub. O primeiro recebimento precisa ser de 0,01 DOT ou mais, o mínimo da rede para a conta existir.")
            case .near:
                return exists
                    ? String(localized: "Na exchange, escolha a rede NEAR e envie só NEAR. Esta é a conta implícita da carteira, com 64 caracteres, e não precisa de memo.")
                    : String(localized: "Na exchange, escolha a rede NEAR. Esta é a conta implícita da carteira: ela passa a existir no primeiro recebimento, de qualquer valor, e não precisa de memo.")
            case .aptos:
                return String(localized: "Na exchange, escolha a rede Aptos e envie só APT. O endereço tem o mesmo formato dos endereços Sui, e um envio pela Sui não chega aqui. A conta passa a existir no primeiro recebimento, de qualquer valor.")
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
                // Marca-texto: letra escura no amarelo, na placa clara e no fundo escuro.
                var text = AttributedString(block)
                text.backgroundColor = Palette.highlight
                text.foregroundColor = Palette.onHighlight
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

    /// Tokens que representam outra moeda, pelo id de preco: aparecem tambem dentro dela no
    /// Receber, como "Outras formas". So agrupamento de tela; saldo, preco e envio de cada
    /// um continuam os do proprio token.
    static let wrappedForms: [String: String] = [
        "wrapped-bitcoin": "bitcoin", "binance-bitcoin": "bitcoin", "coinbase-wrapped-btc": "bitcoin",
        "weth": "ethereum",
    ]

    /// O padrao do token na rede, para quem envia de uma corretora achar a opcao certa.
    static func standard(_ chain: Chain) -> String {
        switch chain.family {
        case .evm: return chain.id == "bnb" ? "BEP-20" : "ERC-20"
        case .tron: return "TRC-20"
        case .solana: return "SPL"
        case .ton: return String(localized: "Jetton")
        case .stellar, .xrpl: return String(localized: "Ativo emitido")
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
