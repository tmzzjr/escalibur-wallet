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

    /// O chamado de suporte, para mandar pelo e-mail que a pessoa usa quando nenhum app de
    /// e-mail abre (SupportView). Dez minutos: o tempo de abrir o e-mail e colar.
    static func copyTicket(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(600),
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
        /// Nil: o "+" do topo, a moeda pelo contrato colado, sem rede escolhida antes.
        let preset: AddCustomTokenView.Preset?
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
                    // Direto para o QR so a moeda custom (ou sem id de preco) de uma rede: a moeda
                    // conhecida passa pela escolha de rede, que busca as redes das duas fontes (o
                    // SHIB da BNB so aparece no CoinPaprika; pedido do dono, 17/10/2026).
                    if coin.assets.count == 1, coin.coingeckoID == nil || coin.isCustom, extraNetworks(coin).isEmpty, otherForms(coin).isEmpty,
                       let only = coin.assets.first, let chain = only.chain {
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
            if let wallet { BackupNowFlow(wallet: wallet) { backingUp = false } }
        }
    }

    private var blocked: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); closeButton }
            BackupFirstArt(height: 280)
            VStack(spacing: Space.sm) {
                if wallet?.wordsConfirmed == true {
                    Text("Confira a passphrase antes de receber").typeStyle(.title).foregroundStyle(Palette.ink)
                    Text("Você ainda não conferiu a passphrase desta carteira. Se ela estiver anotada errado, o que chegar aqui se perde.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Grave a senha da carteira antes de receber").typeStyle(.title).foregroundStyle(Palette.ink)
                    Text("Você ainda não confirmou que anotou as palavras desta carteira. Se o iPhone sumir antes disso, o que chegar aqui se perde.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                Label("Leva 2 minutos", systemImage: "clock")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .padding(.top, Space.xxs)
            }
            .multilineTextAlignment(.center)
            .padding(.top, Space.md)
            Spacer(minLength: Space.md)
            PrimaryButton(title: wallet?.wordsConfirmed == true ? String(localized: "Conferir agora") : String(localized: "Gravar agora")) { backingUp = true }
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
            // A moeda que nao esta na lista, pelo contrato colado (pedido do dono, 17/10/2026).
            SheetHeader(title: String(localized: "Receber"), close: { dismiss() },
                        extra: ("plus", String(localized: "Adicionar moeda pelo contrato"), "receber-adicionar", { adding = AddPick(preset: nil) }))
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
                    SecondaryButton(title: String(localized: "Tentar de novo")) { Task { await search.coin(result.id, symbol: result.symbol, name: result.name) } }
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
        .task(id: result.id) { await search.coin(result.id, symbol: result.symbol, name: result.name) }
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
        // Achada pelo CoinPaprika (reserva da busca): o id dele nao e id de preco do CoinGecko.
        let priceID = coin.id.hasPrefix(CoinCatalog.paprikaPrefix) ? nil : coin.id
        return Asset(chainID: chain.id, kind: .token(contract: contract), symbol: coin.symbol, name: coin.name, decimals: 0,
                     coingeckoID: priceID, isStablecoin: false, origin: .discovered)
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
    /// ETH da Binance no ETH). Cada uma e a sua propria moeda no saldo: tocar abre o endereco
    /// dela, e o seletor embaixo do QR passa por todas as formas (`forms(of:)`).
    private func otherForms(_ coin: ReceiveCoin) -> [Asset] {
        guard let id = coin.coingeckoID, coin.assets.contains(where: { $0.kind == .native }) else { return [] }
        return receivable.filter { asset in asset.coingeckoID.flatMap { ReceiveCoin.wrappedForms[$0] } == id }
    }

    private func otherFormRow(_ asset: Asset) -> some View {
        NavigationLink(value: asset) {
            HStack(spacing: Space.sm) {
                if let chain = asset.chain { NetworkBadge(chain: chain, size: 32, ring: Palette.body) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: asset.chain?.name ?? "").typeStyle(.row).foregroundStyle(Palette.ink)
                    Text(verbatim: [asset.chain.map(ReceiveCoin.standard) ?? "", "\(asset.symbol) · \(asset.name)"].filter { !$0.isEmpty }.joined(separator: " · "))
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
                // As versoes em token contam como rede: o BTC recebe na Bitcoin e, como WBTC,
                // cbBTC ou BTCB, nas redes delas (pedido do dono, 16/10/2026).
                let networks = coin.assets.count + otherForms(coin).count
                if networks > 1 {
                    Text("\(networks) redes").typeStyle(.note).foregroundStyle(Palette.inkMuted)
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
                    // As versoes em token entram na mesma lista, como mais uma rede: quem
                    // quer receber SOL pela BEP-20 escolhe a BNB Chain aqui (pedido do dono,
                    // 15/10/2026). A linha diz qual token e.
                    ForEach(otherForms(coin)) { asset in otherFormRow(asset) }
                }
                .padding(.top, Space.md)
                if !otherForms(coin).isEmpty {
                    Text("As redes com o nome de um token recebem a versão de \(coin.symbol) emitida naquela rede, que vale o mesmo enquanto o emissor mantiver o lastro. Quem envia tem de escolher exatamente a mesma rede.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true).padding(.top, Space.sm)
                }
                let extras = extraNetworks(coin)
                if !extras.isEmpty, let id = coin.coingeckoID, let entry = search.coins[id] {
                    Text("Fora da lista verificada").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
                    Text("O CoinGecko e o CoinPaprika listam \(coin.symbol) também nestas redes, com o contrato de cada uma. A Escalibur ainda não conferiu esses contratos.")
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
        .task(id: coin.id) { if let id = coin.coingeckoID, !coin.isCustom { await search.coin(id, symbol: coin.symbol, name: coin.name) } }
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
    @ViewBuilder
    private func addressView(asset: Asset, chain: Chain) -> some View {
        let siblings = forms(of: asset)
        // A escolha vale para a moeda por onde se entrou: voltar e tocar noutra rede abre
        // a rede tocada, e nao a escolhida antes no seletor.
        let key = asset.id
        let shown = chosenNetwork[key].flatMap { choice in siblings.first { $0.id == choice.id } } ?? asset
        let network = shown.chain ?? chain
        if network.family == .tron, wallet?.tronForeignControl == true {
            tronForeignBlocked
        } else {
            addressContent(asset: shown, chain: network, siblings: siblings, key: key)
        }
    }

    /// A conta da Tron desta carteira tem outra chave no controle, visto na importacao
    /// (revisao da auditoria 4, C7-05): o endereco nao aparece.
    private var tronForeignBlocked: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if preselected != nil { HStack { Spacer(); closeButton } }
            Text("Esta conta na Tron é controlada por outra chave").typeStyle(.title).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Quando esta carteira foi importada, a rede mostrou outra chave no controle da conta na Tron. É o golpe da frase com saldo: o que entrar nela, quem controla essa chave leva. Por isso o app não mostra este endereço.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.md)
        .accessibilityIdentifier("receber-tron-outra-chave")
    }

    /// Todas as formas da moeda que a carteira recebe: a nativa e o token nas outras redes
    /// (USDT na Tron e na Ethereum), e as versoes embrulhadas (WBTC e cbBTC no BTC). Do
    /// WBTC tambem se chega ao BTC e as outras formas: e a mesma moeda para quem recebe
    /// (pedido do dono, 16/10/2026). Cada endereco ainda so recebe o que a rede dele aceita.
    private func forms(of asset: Asset) -> [Asset] {
        let coins = ReceiveCoin.group(receivable)
        guard let own = coins.first(where: { coin in coin.assets.contains { $0.id == asset.id } }) else { return [asset] }
        let base = asset.coingeckoID.flatMap { ReceiveCoin.wrappedForms[$0] }.flatMap { id in coins.first { $0.coingeckoID == id } } ?? own
        let all = base.assets + otherForms(base)
        return all.contains { $0.id == asset.id } ? all : own.assets
    }

    /// A moeda que a forma representa, para o logo no meio do QR: o BTC no WBTC da Ethereum,
    /// com a rede no selo embaixo.
    private func baseCoin(_ asset: Asset) -> (id: String?, symbol: String) {
        guard let wrapped = asset.coingeckoID, let id = ReceiveCoin.wrappedForms[wrapped],
              let coin = ReceiveCoin.group(receivable).first(where: { $0.coingeckoID == id }) else {
            return (asset.coingeckoID, asset.symbol)
        }
        return (id, coin.symbol)
    }

    /// Com mais de uma rede, a rede embaixo do QR, com o logo de cada rede na lista, porque
    /// escolher rede e reconhecer o logo (pedido do dono, 14/10/2026). A linha de um token
    /// diz qual e: na Ethereum, o BTC chega como WBTC ou como cbBTC.
    @ViewBuilder
    private func addressNetworkMenu(asset: Asset, chain: Chain, siblings: [Asset], key: String) -> some View {
        if siblings.count > 1 {
            ReceiveFormMenu(forms: siblings, selected: asset) { item in
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
                if preselected != nil {
                    // Aberta direto, sem barra de navegacao: o contrato no topo, ao lado do fechar.
                    HStack(spacing: Space.xs) {
                        Spacer()
                        contractButton(asset: asset, chain: chain, inBar: false)
                        closeButton
                    }
                }
                // A rede e o token ao lado do titulo (pedido do dono, 17/10/2026); sem espaco
                // (nome longo, texto grande), embaixo, como antes.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Space.md) {
                        receiveTitle(asset)
                        Spacer(minLength: 0)
                        receiveSubtitle(asset: asset, chain: chain, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        receiveTitle(asset)
                        receiveSubtitle(asset: asset, chain: chain, alignment: .leading)
                    }
                }

                if wallet?.isWatchOnly == true {
                    // Golpe comum: alguem pede para "observar" o endereco dele e depositar ali.
                    // O app nao tem a chave deste endereco (auditoria 3, B3).
                    Banner(kind: .caution, title: String(localized: "Carteira só de observação"),
                           message: String(localized: "Este app não tem a chave deste endereço: o que chegar aqui não sai por este app. Se alguém pediu para você observar um endereço e depositar nele, é golpe."))
                        .padding(.top, Space.md)
                        .accessibilityIdentifier("receber-observacao")
                }

                qrPlate(address: address, chain: chain, asset: asset).padding(.top, Space.lg)
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
                    contractCard(reference, badge: .custom,
                                 title: CustomToken.usesIssuer(chain) ? String(localized: "Emissor que quem envia tem de usar") : String(localized: "Contrato que quem envia tem de usar"))
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
        .toolbar {
            // Empilhada na navegacao: o contrato no topo direito da barra (pedido do dono, 17/10/2026).
            if preselected == nil {
                ToolbarItem(placement: .topBarTrailing) { contractButton(asset: asset, chain: chain, inBar: true) }
            }
        }
    }

    private func receiveTitle(_ asset: Asset) -> some View {
        Text("Receber \(asset.symbol)").typeStyle(.title).foregroundStyle(Palette.ink).lineLimit(1).fixedSize()
    }

    /// "pela rede X" e, no token, qual e pelo nome da lista: "XRP" sozinho nao diz que e o
    /// da Binance.
    private func receiveSubtitle(asset: Asset, chain: Chain, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("pela rede \(chain.name)").typeStyle(.body).foregroundStyle(Palette.inkSoft).lineLimit(1)
            if asset.kind != .native {
                Text(verbatim: "\(asset.name) · \(ReceiveCoin.standard(chain))").typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
            }
        }
        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        .fixedSize()
    }

    /// O contrato do token (ou o emissor, no XRP Ledger e na Stellar), para copiar com um
    /// toque. Moeda nativa nao tem: o botao some. Na barra de navegacao o fundo e o vidro do
    /// sistema, como o do voltar; fora dela, a capsula propria, na altura do fechar.
    @ViewBuilder
    private func contractButton(asset: Asset, chain: Chain, inBar: Bool) -> some View {
        if asset.kind != .native, let contract = CustomToken.reference(asset.kind) {
            let label = Label(CustomToken.usesIssuer(chain) ? String(localized: "Emissor do token") : String(localized: "Contrato do token"),
                              systemImage: "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .typeStyle(.label).foregroundStyle(Palette.ink)
            Button {
                Pasteboard.copyAddress(contract)
                toasts.show(CustomToken.usesIssuer(chain) ? String(localized: "Emissor do token copiado.") : String(localized: "Contrato do token copiado."))
            } label: {
                if inBar {
                    label.padding(.horizontal, Space.xs)
                } else {
                    label.padding(.horizontal, Space.sm).frame(height: 36)
                        .background(Capsule(style: .continuous).fill(Palette.rail))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("receber-copiar-contrato")
        }
    }

    /// O contrato da lista completa e o caminho para a moeda aparecer no saldo.
    private func catalogBlock(asset: Asset, chain: Chain, coin: CatalogCoin, network: CatalogCoin.Network) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if coin.hasNotice {
                // O texto do aviso e de quem escreveu, com link: a tela so diz que existe.
                Text("O CoinGecko publicou um aviso sobre \(coin.symbol) (ataque, migração ou golpe). Confira as notícias da moeda antes de receber.")
                    .typeStyle(.note).foregroundStyle(Palette.caution).fixedSize(horizontal: false, vertical: true)
            }
            contractCard(CustomToken.reference(asset.kind) ?? network.contract, badge: .unverified,
                         title: String(localized: "Contrato que quem envia tem de usar"))
            Text("Contrato listado pelo CoinGecko ou pelo CoinPaprika, fora da lista verificada da Escalibur. Para o saldo aparecer na carteira, adicione a moeda: a carteira lê nome, símbolo e casas na própria rede antes de salvar.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            // Ja adicionada, o botao sai (pedido do dono, 17/10/2026).
            if !alreadyAdded(asset, chain: chain) {
                SecondaryButton(title: String(localized: "Adicionar \(asset.symbol) à carteira")) {
                    adding = AddPick(preset: AddCustomTokenView.Preset(chain: chain, kind: asset.kind))
                }
                .padding(.top, Space.xxs)
            }
        }
    }

    /// A moeda ja esta entre as custom desta carteira: o mesmo contrato na mesma rede (na EVM,
    /// sem olhar a caixa).
    private func alreadyAdded(_ asset: Asset, chain: Chain) -> Bool {
        guard let reference = CustomToken.reference(asset.kind) else { return false }
        return session.metadata.customTokens.contains { token in
            guard token.chainID == chain.id, let saved = CustomToken.reference(token.kind) else { return false }
            return chain.family == .evm ? saved.lowercased() == reference.lowercased() : saved == reference
        }
    }

    /// O contrato do token, num desenho que nao se confunde com o endereco de deposito (pedido
    /// do dono, 17/10/2026): cartao tracejado e letra menor; copiar e pelo botao do topo.
    private func contractCard(_ contract: String, badge: TokenBadge.Kind, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TokenBadge(badge)
                Text(title).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: contract)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(Palette.edgeStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("receber-contrato")
    }

    /// No meio do QR, o logo da moeda e, no selo embaixo, a rede: o BTC com a Ethereum no
    /// WBTC, o USDT com a Tron (pedido do dono, 16/10/2026). Na rede da propria moeda, so o logo.
    private func qrPlate(address: String, chain: Chain, asset: Asset) -> some View {
        let coin = baseCoin(asset)
        return ZStack {
            if let image = QRCode.image(address, size: 232, scale: displayScale) {
                Image(uiImage: image).interpolation(.none).resizable().frame(width: 232, height: 232)
            }
            CoinLogo(coingeckoID: coin.id, symbol: coin.symbol, size: 48, network: chain, ringColor: Palette.live,
                     unverified: asset.origin != nil && coin.id == asset.coingeckoID,
                     logoAsset: asset.origin != nil ? asset : nil)
                .padding(5)
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
                // Forma embrulhada (XRP da Binance, WBTC): o mesmo token em outra rede EVM e
                // outro contrato, e chega como token fora da lista (revisao de seguranca, M2).
                if let origin = asset.coingeckoID.flatMap({ ReceiveCoin.wrappedForms[$0] }),
                   let home = Chain.all.first(where: { $0.coingeckoID == origin }) {
                    return String(localized: "Envie só pela rede \(chain.name) (\(ReceiveCoin.standard(chain))). Não é \(home.nativeSymbol) da rede \(home.name): por outra rede, não chega como este token.")
                }
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

/// O seletor de rede embaixo do QR, por forma da moeda: a rede, e o token quando nao e
/// a moeda nativa da rede ("Ethereum · WBTC").
struct ReceiveFormMenu: View {
    let forms: [Asset]
    let selected: Asset
    let onSelect: (Asset) -> Void
    @State private var open = false

    private func title(_ asset: Asset) -> String {
        let network = asset.chain?.name ?? ""
        return asset.kind == .native ? network : "\(network) · \(asset.symbol)"
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                if let chain = selected.chain { NetworkBadge(chain: chain, size: 20, ring: .clear) }
                Text(verbatim: title(selected)).typeStyle(.label).foregroundStyle(Palette.ink).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.inkSoft)
            }
            .padding(.leading, 6).padding(.trailing, 12)
            .frame(minHeight: 36)
            .background(Capsule(style: .continuous).fill(Palette.body)
                .overlay(Capsule(style: .continuous).strokeBorder(Palette.edge, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rede: \(title(selected))")
        .popover(isPresented: $open, arrowEdge: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(forms) { asset in
                        Button {
                            open = false
                            onSelect(asset)
                        } label: {
                            HStack(spacing: Space.sm) {
                                if let chain = asset.chain { NetworkBadge(chain: chain, size: 28, ring: .clear) }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: asset.chain?.name ?? "").typeStyle(.row).foregroundStyle(Palette.ink)
                                    if asset.kind != .native, let chain = asset.chain {
                                        Text(verbatim: [asset.symbol, ReceiveCoin.standard(chain)].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                    }
                                }
                                Spacer(minLength: Space.sm)
                                if asset.id == selected.id {
                                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                                }
                            }
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowStyle())
                        .accessibilityLabel(title(asset))
                        .accessibilityIdentifier("forma-\(asset.symbol)-\(asset.chainID)")
                        .accessibilityAddTraits(asset.id == selected.id ? .isSelected : [])
                    }
                }
                .padding(.vertical, Space.xs)
            }
            .frame(width: 260)
            .frame(maxHeight: 460)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Palette.body)
        }
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
        "binance-peg-xrp": "ripple", "binance-peg-dogecoin": "dogecoin", "binance-peg-cardano": "cardano",
        "binance-peg-polkadot": "polkadot", "binance-peg-litecoin": "litecoin", "binance-peg-avalanche": "avalanche-2",
        "binance-peg-near-protocol": "near", "binance-peg-sol": "solana", "sol-wormhole": "solana",
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
