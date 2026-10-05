import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import SwiftUI

/// "Outros tokens" na Carteira: o que a conta tem e nao esta na lista conferida nem nas
/// moedas custom. Aparece, marcado, sem preco inventado; os de cara de golpe ficam atras
/// de "Mostrar suspeitos".
struct OtherTokensSection: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @State private var showSuspicious = false

    private var hide: Bool { session.metadata.settings.hideBalances }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !portfolio.others.isEmpty {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Outros tokens").typeStyle(.heading).foregroundStyle(Palette.ink)
                    Text("Fora da lista verificada. Sem preço confiável, ficam fora do saldo total.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.gutter)
                LazyVStack(spacing: 0) {
                    ForEach(portfolio.others) { token in
                        NavigationLink(value: token.holding) {
                            OtherTokenRow(token: token, currency: session.currency, hidden: hide)
                        }
                        .buttonStyle(RowStyle())
                    }
                }
                .padding(.top, Space.xs)
            }
            if !portfolio.suspicious.isEmpty {
                Button {
                    withAnimation(Motion.select) { showSuspicious.toggle() }
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: showSuspicious ? "eye.slash" : "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Palette.control))
                        Text(showSuspicious ? "Esconder suspeitos" : "Mostrar suspeitos (\(portfolio.suspicious.count))")
                            .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                        Spacer()
                        Image(systemName: showSuspicious ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                    }
                    .padding(.horizontal, Space.gutter)
                    .frame(minHeight: Height.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, portfolio.others.isEmpty ? 0 : Space.sm)
                .accessibilityIdentifier("mostrar-suspeitos")
                if showSuspicious {
                    Text("Chegaram sem você pedir e têm cara de golpe. Não abra os sites dos nomes.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.gutter).padding(.bottom, Space.xxs)
                    LazyVStack(spacing: 0) {
                        ForEach(portfolio.suspicious) { token in
                            NavigationLink(value: token.holding) {
                                OtherTokenRow(token: token, currency: session.currency, hidden: hide)
                            }
                            .buttonStyle(RowStyle())
                        }
                    }
                }
            }
        }
    }
}

/// Uma linha de token fora da lista: logo neutro, simbolo limpo, selo, rede e valor so
/// com preco por contrato.
struct OtherTokenRow: View {
    let token: OtherToken
    let currency: Fmt.Currency
    var hidden: Bool = false

    var body: some View {
        HStack(spacing: Space.sm) {
            CoinLogo(coingeckoID: nil, symbol: token.asset.symbol, size: 40, network: token.asset.chain, unverified: true,
                     logoAsset: token.isSuspicious ? nil : token.asset)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: token.asset.symbol).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                HStack(spacing: 6) {
                    TokenBadge(token.isSuspicious ? .suspicious : .unverified)
                    Text("na \(token.asset.chain?.name ?? token.asset.chainID)").typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Space.sm)
            VStack(alignment: .trailing, spacing: 2) {
                if hidden {
                    Text(Redaction.fiat).typeStyle(.row).foregroundStyle(Palette.ink)
                } else if let value = token.fiatValue {
                    Text(Fmt.fiat(value, currency)).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    Text("sem preço").typeStyle(.note).foregroundStyle(Palette.inkMuted).lineLimit(1)
                }
                Text(hidden ? Redaction.short : Fmt.crypto(token.holding.amount, decimals: token.asset.decimals))
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, Space.gutter)
        .frame(minHeight: Height.row)
        .contentShape(Rectangle())
    }
}

/// Tocar num token fora da lista: o contrato inteiro e o aviso de que qualquer um cria
/// token com qualquer nome. Sem enviar e sem trocar daqui; o caminho para enviar e
/// adicionar como moeda custom, que le o token de novo na rede.
struct OtherTokenDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @Environment(ToastCenter.self) private var toasts
    let holding: UnlistedHolding
    @State private var adding = false

    private var asset: Asset { holding.asset }
    private var chain: Chain? { asset.chain }
    private var quote: Quote? { holding.isSuspicious ? nil : portfolio.tokenQuotes[asset.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.sm) {
                    CoinLogo(coingeckoID: nil, symbol: asset.symbol, size: 48, network: chain, ringColor: Palette.void, unverified: true,
                             logoAsset: holding.isSuspicious ? nil : asset)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: asset.symbol).typeStyle(.title).foregroundStyle(Palette.ink).lineLimit(1)
                            TokenBadge(holding.isSuspicious ? .suspicious : .unverified)
                        }
                        Text(verbatim: asset.name).typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(2)
                    }
                }

                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Nesta carteira").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    Text(session.metadata.settings.hideBalances ? Redaction.short
                         : Fmt.crypto(holding.amount, decimals: asset.decimals, symbol: asset.symbol, style: .full))
                        .typeStyle(.figure).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.5)
                    Text(priceLine).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Space.lg)

                Banner(kind: .caution, title: holding.isSuspicious ? "Este token tem cara de golpe" : "Token não verificado",
                       message: TokenReasonText.anyoneCanCreate)
                    .padding(.top, Space.lg)

                if holding.isSuspicious {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Por que está em suspeitos").typeStyle(.heading).foregroundStyle(Palette.ink)
                        ForEach(holding.reasons, id: \.self) { reason in
                            HStack(alignment: .top, spacing: Space.xs) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.caution).frame(width: 18)
                                Text(TokenReasonText.text(reason)).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, Space.lg)
                }

                ContractPanel(asset: asset).padding(.top, Space.lg)

                if !holding.isSuspicious, let chain, CustomToken.supports(chain) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Se você conhece este token e confere o contrato com a fonte oficial dele, pode adicioná-lo como moeda custom. A carteira lê o token de novo na rede antes de salvar.")
                            .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                        SecondaryButton(title: "Adicionar como moeda custom") { adding = true }
                    }
                    .padding(.top, Space.lg)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $adding) {
            NavigationStack {
                AddCustomTokenView(preset: AddCustomTokenView.Preset(chain: chain, kind: asset.kind)) { adding = false }
            }
            .presentationBackground(Palette.void)
        }
    }

    private var priceLine: String {
        if holding.isSuspicious { return "Sem preço: token suspeito nunca entra no saldo total." }
        guard let quote else { return "Sem preço confiável por contrato. Fica fora do saldo total." }
        let value = Fmt.double(holding.amount, decimals: asset.decimals) * quote.price
        return "\(Fmt.fiat(value, session.currency)) pelo preço do contrato, \(Fmt.price(quote.price, session.currency)) cada."
    }
}

/// O contrato inteiro (ou o emissor e o codigo), para o dono conferir com a fonte
/// oficial, com copiar e ver no explorador.
struct ContractPanel: View {
    @Environment(ToastCenter.self) private var toasts
    let asset: Asset

    var body: some View {
        if let chain = asset.chain, let reference = CustomToken.reference(asset.kind) {
            VStack(alignment: .leading, spacing: Space.xs) {
                if case .issued(let code, _) = asset.kind {
                    Text("Código da moeda").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    Text(verbatim: code).typeStyle(.monoSmall).foregroundStyle(Palette.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Emissor \(chain.id == "xrpl" ? "no" : "na") \(chain.name)").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                        .padding(.top, Space.xxs)
                } else {
                    Text("\(CustomToken.addressLabel(chain)) \(chain.id == "xrpl" ? "no" : "na") \(chain.name)")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
                if reference.count >= 26, reference.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                    AddressBlocks(address: reference)
                } else {
                    // Conta com nome (NEAR), tipo de moeda da Sui, numero de ativo: inteiro,
                    // sem quebrar em blocos que nao existem nele.
                    Text(verbatim: reference).font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.sm) {
                    Button {
                        Pasteboard.copyAddress(reference)
                        toasts.show("Copiado. Confira o endereço inteiro com a fonte oficial do token.")
                    } label: {
                        Label("Copiar", systemImage: "doc.on.doc").typeStyle(.note).foregroundStyle(Palette.ink)
                            .frame(minHeight: Height.touch)
                    }
                    if CustomToken.explorerShowsToken(chain), let url = chain.explorerURL(address: reference) {
                        Link(destination: url) {
                            Label("Ver no \(chain.explorerName)", systemImage: "arrow.up.right").typeStyle(.note).foregroundStyle(Palette.ink)
                                .frame(minHeight: Height.touch)
                        }
                    }
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1)))
        }
    }
}
