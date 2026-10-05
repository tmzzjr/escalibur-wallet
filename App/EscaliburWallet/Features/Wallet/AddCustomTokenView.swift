import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import SwiftUI

/// Adicionar moeda: escolher a rede, colar o contrato (ou mint, mestre, codigo e
/// emissor), ler nome, simbolo e casas na propria rede com dois provedores concordando,
/// ver a previa com o contrato inteiro e o aviso de nao verificado, e so entao salvar.
struct AddCustomTokenView: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @Environment(ToastCenter.self) private var toasts

    /// Vindo de um token de "Outros tokens": a rede e o contrato ja preenchidos.
    struct Preset {
        let chain: Chain?
        let kind: Asset.Kind
    }

    var preset: Preset? = nil
    let onDone: () -> Void

    @State private var chain: Chain?
    @State private var address = ""
    @State private var code = ""
    @State private var issuer = ""
    @State private var reading = false
    @State private var facts: TokenFacts?
    @State private var error: String?
    @State private var started = false

    /// As redes com moeda custom em que esta carteira tem conta.
    private var chains: [Chain] {
        let accounts = Set(session.selectedWallet?.accounts.map(\.chainID) ?? [])
        let all = Chain.all.filter(CustomToken.supports)
        let mine = all.filter { accounts.contains($0.id) }
        return mine.isEmpty ? all : mine
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("topo")
                    if let facts {
                        preview(facts)
                    } else {
                        form
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xl)
            }
            // A previa comeca do topo: o nome e o selo antes do contrato.
            .onChange(of: facts) { proxy.scrollTo("topo", anchor: .top) }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle(facts == nil ? "Adicionar moeda" : "Conferir moeda")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear(perform: applyPreset)
    }

    // MARK: Formulario

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rede").typeStyle(.heading).foregroundStyle(Palette.ink)
            Text("A rede onde o token existe. O mesmo contrato em outra rede é outro token.")
                .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.xxs)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Space.xs)], alignment: .leading, spacing: Space.xs) {
                ForEach(chains, id: \.id) { item in
                    NetworkChoice(chain: item, selected: chain?.id == item.id) {
                        chain = item
                        error = nil
                    }
                }
            }
            .padding(.top, Space.sm)

            if let chain {
                if CustomToken.usesIssuer(chain) {
                    field(title: "Código da moeda", id: "campo-codigo", text: $code, prompt: chain.family == .xrpl ? "USD, SOLO ou 40 caracteres hex" : "AQUA, USDC...")
                        .padding(.top, Space.lg)
                    field(title: "Emissor", id: "campo-emissor", text: $issuer, prompt: chain.family == .xrpl ? "Endereço r..." : "Endereço G...")
                        .padding(.top, Space.md)
                } else {
                    field(title: CustomToken.addressLabel(chain), id: "campo-endereco", text: $address, prompt: prompt(chain))
                        .padding(.top, Space.lg)
                }
                Text("Copie o endereço da fonte oficial do token, não de um site que apareceu num anúncio ou no nome de outro token.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.sm)
            }

            if let error {
                Banner(kind: .failure, title: error).padding(.top, Space.md)
            }

            PrimaryButton(title: "Ler na rede", enabled: canRead, loading: reading) { Task { await read() } }
                .padding(.top, Space.lg)
                .accessibilityIdentifier("ler-na-rede")
        }
    }

    private func field(title: String, id: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            TextField("", text: text, prompt: Text(prompt).foregroundColor(Palette.inkDead), axis: .vertical)
                .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                .lineLimit(1...3)
                .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                .onChange(of: text.wrappedValue) { error = nil }
                .accessibilityIdentifier(id)
        }
    }

    private func prompt(_ chain: Chain) -> String {
        switch chain.family {
        case .evm: return "0x..."
        case .solana: return "Endereço do mint"
        case .tron: return "T..."
        case .ton: return "EQ... ou UQ..."
        default: return ""
        }
    }

    private var canRead: Bool {
        guard let chain else { return false }
        if CustomToken.usesIssuer(chain) { return !code.isEmpty && !issuer.isEmpty }
        return !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyPreset() {
        guard !started else { return }
        started = true
        guard let preset, let presetChain = preset.chain else {
            if chains.count == 1 { chain = chains.first }
            return
        }
        chain = presetChain
        switch preset.kind {
        case .token(let contract): address = contract
        case .issued(let presetCode, let presetIssuer):
            code = presetCode
            issuer = presetIssuer
        case .native: break
        }
        Task { await read() }
    }

    // MARK: Leitura

    private func read() async {
        guard let chain else { return }
        error = nil
        let kind: Asset.Kind
        do {
            kind = CustomToken.usesIssuer(chain)
                ? try CustomToken.kind(chain: chain, code: code, issuer: issuer)
                : try CustomToken.kind(chain: chain, address: address)
        } catch let problem as CustomToken.Problem {
            error = Self.message(problem, chain: chain)
            return
        } catch {
            self.error = "Endereço inválido para a rede \(chain.name)."
            return
        }
        if session.metadata.customTokens.contains(where: { $0.chainID == chain.id && $0.kind == kind }) {
            error = "Esta moeda já está na carteira."
            return
        }
        reading = true
        defer { reading = false }
        do {
            facts = try await TokenInspector.shared.inspect(chain: chain, kind: kind)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Não foi possível ler a moeda na rede agora."
        }
    }

    static func message(_ problem: CustomToken.Problem, chain: Chain) -> String {
        switch problem {
        case .unsupportedChain: return "A rede \(chain.name) ainda não aceita moeda custom."
        case .empty: return "Cole o endereço do token."
        case .invalidAddress: return "Este não é um endereço válido na rede \(chain.name). Confira se copiou inteiro e se a rede é essa."
        case .invalidCode: return "Este código de moeda não vale na rede \(chain.name)."
        case .alreadyListed(let listed): return "\(listed.symbol) com este contrato já está na lista verificada. Ele aparece sozinho na Carteira quando houver saldo."
        case .notAToken: return "Este endereço é de um programa da rede, não de um token."
        }
    }

    // MARK: Previa

    private func preview(_ facts: TokenFacts) -> some View {
        let asset = facts.asset
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: nil, symbol: asset.symbol, size: 48, network: asset.chain, ringColor: Palette.void, unverified: true,
                         contractLogo: TokenLogos.url(for: asset))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: asset.symbol).typeStyle(.title).foregroundStyle(Palette.ink).lineLimit(1)
                        TokenBadge(.custom)
                        TokenBadge(facts.reasons.isEmpty ? .unverified : .suspicious)
                    }
                    Text(verbatim: asset.name).typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(2)
                }
            }

            VStack(spacing: 0) {
                infoRow("Rede", asset.chain?.name ?? asset.chainID)
                infoRow("Casas decimais", "\(asset.decimals)")
                infoRow("Conferido em", facts.sources.joined(separator: " e "))
            }
            .padding(.top, Space.md)
            if let note = facts.decimalsNote {
                Text(note).typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
            } else {
                Text("As duas fontes leram as mesmas casas decimais no contrato. É nessa escala que o valor de um envio é lido.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
            }

            ContractPanel(asset: asset).padding(.top, Space.md)

            Banner(kind: .caution, title: "Não verificado pela Escalibur", message: TokenReasonText.anyoneCanCreate)
                .padding(.top, Space.md)

            if !facts.reasons.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Sinais de golpe neste token").typeStyle(.heading).foregroundStyle(Palette.ink)
                    ForEach(facts.reasons, id: \.self) { reason in
                        bullet(TokenReasonText.text(reason), icon: "exclamationmark.triangle", color: Palette.caution)
                    }
                }
                .padding(.top, Space.md)
            }
            if !facts.notes.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(facts.notes, id: \.self) { note in bullet(note, icon: "info.circle", color: Palette.ink) }
                }
                .padding(.top, Space.md)
            }
            if let chain = asset.chain, let reason = CustomToken.sendUnavailableReason(chain) {
                bullet(reason, icon: "arrow.up.circle", color: Palette.ink).padding(.top, Space.md)
            }

            PrimaryButton(title: "Adicionar à carteira") { save(asset) }
                .padding(.top, Space.lg)
                .accessibilityIdentifier("adicionar-a-carteira")
            TertiaryButton(title: "Voltar e corrigir") {
                self.facts = nil
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Space.xs)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).typeStyle(.body).foregroundStyle(Palette.inkSoft)
            Spacer(minLength: Space.sm)
            Text(verbatim: value).typeStyle(.body).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 36)
    }

    private func bullet(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).frame(width: 18)
            Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save(_ asset: Asset) {
        var list = session.metadata.customTokens
        guard !list.contains(where: { $0.id == asset.id }) else { onDone(); return }
        list.append(asset)
        session.metadata.customAssets = list
        do {
            try session.persist()
        } catch {
            session.metadata.customAssets = list.filter { $0.id != asset.id }
            self.error = "Não foi possível salvar agora. Tente de novo."
            self.facts = nil
            return
        }
        portfolio.customChanged(session.selectedWallet, session: session)
        toasts.show("\(asset.symbol) adicionada. Ela aparece na Carteira, em Receber e em Enviar.")
        Task { await portfolio.refresh(session.selectedWallet, session: session) }
        onDone()
    }
}

/// Uma rede para escolher: selo branco no cinza escuro e o nome; a escolhida em vidro.
struct NetworkChoice: View {
    let chain: Chain
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                NetworkBadge(chain: chain, size: 22, ring: Palette.void)
                Text(chain.name).typeStyle(.note).foregroundStyle(selected ? Palette.ink : Palette.inkSoft).lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.sm)
            .frame(height: 40)
            .background {
                if !selected { Capsule(style: .continuous).stroke(Palette.edge, lineWidth: 1) }
            }
            .modifier(SelectionGlass(active: selected))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}
