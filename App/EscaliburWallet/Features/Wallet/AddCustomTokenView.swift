import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import SwiftUI

/// Adicionar moeda: colar o contrato (ou mint, mestre, codigo e emissor) e a rede vem
/// dele, ler nome, simbolo e casas na propria rede com dois provedores concordando,
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
    /// Moeda emitida (XRP Ledger ou Stellar): codigo e emissor no lugar do contrato.
    @State private var issuedMode = false
    /// O mesmo contrato achado em mais de uma rede: o dono escolhe a da moeda.
    @State private var found: [Found] = []

    struct Found: Identifiable {
        let chain: Chain
        let facts: TokenFacts
        var id: String { chain.id }
    }

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

    /// So o contrato: a rede vem do formato e da leitura nas redes da carteira (pedido do dono,
    /// 17/10/2026). Com a rede ja escolhida (vindo do Receber ou da troca), o campo dela.
    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let chain {
                Text(chain.name).typeStyle(.heading).foregroundStyle(Palette.ink)
                if CustomToken.usesIssuer(chain) {
                    issuedFields(chain)
                } else {
                    field(title: CustomToken.addressLabel(chain), id: "campo-endereco", text: $address, prompt: prompt(chain))
                        .padding(.top, Space.md)
                }
            } else if issuedMode {
                Text("Moeda emitida").typeStyle(.heading).foregroundStyle(Palette.ink)
                Text("No XRP Ledger e na Stellar, a moeda é o código mais o emissor. A rede sai do emissor: r... é XRP Ledger, G... é Stellar.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xxs)
                field(title: String(localized: "Código da moeda"), id: "campo-codigo", text: $code, prompt: "USD, SOLO, AQUA...")
                    .padding(.top, Space.md)
                field(title: String(localized: "Emissor"), id: "campo-emissor", text: $issuer, prompt: String(localized: "Endereço r... ou G..."))
                    .padding(.top, Space.md)
                TertiaryButton(title: String(localized: "Voltar para o contrato")) { issuedMode = false; error = nil }
                    .padding(.top, Space.xs)
            } else {
                Text("Contrato do token").typeStyle(.heading).foregroundStyle(Palette.ink)
                Text("Cole o endereço do contrato. A Escalibur acha a rede da moeda sozinha.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xxs)
                field(title: String(localized: "Contrato"), id: "campo-endereco", text: $address, prompt: "0x..., T..., EQ...")
                    .padding(.top, Space.md)
                TertiaryButton(title: String(localized: "É uma moeda do XRP Ledger ou da Stellar?")) { issuedMode = true; error = nil; found = [] }
                    .padding(.top, Space.xs)
                    .accessibilityIdentifier("moeda-emitida")
                if found.count > 1 {
                    Text("Este contrato existe em mais de uma rede. Escolha a da moeda:")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.md)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Space.xs)], alignment: .leading, spacing: Space.xs) {
                        ForEach(found) { item in
                            NetworkChoice(chain: item.chain, selected: false) { facts = item.facts }
                        }
                    }
                    .padding(.top, Space.sm)
                }
            }
            Text("Copie o endereço da fonte oficial do token, não de um site que apareceu num anúncio ou no nome de outro token.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.sm)

            if let error {
                Banner(kind: .failure, title: error).padding(.top, Space.md)
            }

            PrimaryButton(title: chain == nil && !issuedMode ? String(localized: "Encontrar a moeda") : String(localized: "Ler na rede"),
                          enabled: canRead, loading: reading) { Task { await chain == nil && !issuedMode ? find() : read() } }
                .padding(.top, Space.lg)
                .accessibilityIdentifier("ler-na-rede")
        }
    }

    private func issuedFields(_ chain: Chain) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            field(title: String(localized: "Código da moeda"), id: "campo-codigo", text: $code, prompt: chain.family == .xrpl ? String(localized: "USD, SOLO ou 40 caracteres hex") : "AQUA, USDC...")
                .padding(.top, Space.md)
            field(title: String(localized: "Emissor"), id: "campo-emissor", text: $issuer, prompt: chain.family == .xrpl ? String(localized: "Endereço r...") : String(localized: "Endereço G..."))
                .padding(.top, Space.md)
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
        case .solana: return String(localized: "Endereço do mint")
        case .tron: return "T..."
        case .ton: return String(localized: "EQ... ou UQ...")
        default: return ""
        }
    }

    private var canRead: Bool {
        if let chain, CustomToken.usesIssuer(chain) { return !code.isEmpty && !issuer.isEmpty }
        if chain == nil, issuedMode { return !code.isEmpty && !issuer.isEmpty }
        return !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyPreset() {
        guard !started else { return }
        started = true
        guard let preset, let presetChain = preset.chain else { return }
        chain = presetChain
        switch preset.kind {
        case .token(let contract): address = contract
        case .issued(let presetCode, let presetIssuer):
            code = presetCode
            issuer = presetIssuer
        // So a rede (vindo da troca): o dono cola o contrato.
        case .native: return
        }
        Task { await read() }
    }

    // MARK: Leitura

    /// A rede pelo contrato: as redes da carteira em que o formato vale, lidas ao mesmo tempo;
    /// fica a que tem o token. Mais de uma (o mesmo endereco em varias EVM), o dono escolhe.
    private func find() async {
        error = nil
        found = []
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var listed: String?
        var candidates: [(Chain, Asset.Kind)] = []
        for item in chains where !CustomToken.usesIssuer(item) {
            do {
                candidates.append((item, try CustomToken.kind(chain: item, address: text)))
            } catch let problem as CustomToken.Problem {
                if case .alreadyListed = problem { listed = Self.message(problem, chain: item) }
            } catch {}
        }
        guard !candidates.isEmpty else {
            error = listed ?? String(localized: "Este endereço não parece o contrato de uma moeda em nenhuma rede da carteira. Confira se copiou inteiro.")
            return
        }
        let mine = candidates.filter { candidate in
            !session.metadata.customTokens.contains { $0.chainID == candidate.0.id && $0.kind == candidate.1 }
        }
        guard !mine.isEmpty else {
            error = String(localized: "Esta moeda já está na carteira.")
            return
        }
        reading = true
        defer { reading = false }
        var hits: [Found] = []
        // Uma rede que nao respondeu nao e uma rede sem o token: sem nenhum achado, o aviso diz
        // para tentar de novo em vez de dizer que o contrato nao existe.
        var unreachable = false
        await withTaskGroup(of: Result<Found, TokenInspectionError>.self) { group in
            for (item, kind) in mine {
                group.addTask {
                    do {
                        return .success(Found(chain: item, facts: try await TokenInspector.shared.inspect(chain: item, kind: kind)))
                    } catch {
                        return .failure(error as? TokenInspectionError ?? .notEnoughSources)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let hit): hits.append(hit)
                case .failure(.notAToken), .failure(.unsupported): break
                case .failure: unreachable = true
                }
            }
        }
        let order = Dictionary(Chain.all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        hits.sort { (order[$0.chain.id] ?? .max) < (order[$1.chain.id] ?? .max) }
        if hits.count == 1, let only = hits.first {
            facts = only.facts
        } else if hits.count > 1 {
            found = hits
        } else if let listed {
            error = listed
        } else if unreachable {
            error = TokenInspectionError.notEnoughSources.errorDescription
        } else {
            error = String(localized: "Não achamos este contrato nas redes da carteira. Confira se copiou inteiro e se a rede é uma das que a carteira usa.")
        }
    }

    private func read() async {
        // Moeda emitida sem rede escolhida: a rede sai do emissor.
        var target = chain
        if target == nil, issuedMode {
            let trimmed = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
            target = trimmed.hasPrefix("r") ? Chain.find("xrpl") : (trimmed.hasPrefix("G") ? Chain.find("stellar") : nil)
            guard target != nil else {
                error = String(localized: "O emissor começa com r (XRP Ledger) ou G (Stellar).")
                return
            }
        }
        guard let chain = target else { return }
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
            self.error = String(localized: "Endereço inválido para a rede \(chain.name).")
            return
        }
        if session.metadata.customTokens.contains(where: { $0.chainID == chain.id && $0.kind == kind }) {
            error = String(localized: "Esta moeda já está na carteira.")
            return
        }
        reading = true
        defer { reading = false }
        do {
            facts = try await TokenInspector.shared.inspect(chain: chain, kind: kind)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Não foi possível ler a moeda na rede agora.")
        }
    }

    static func message(_ problem: CustomToken.Problem, chain: Chain) -> String {
        switch problem {
        case .unsupportedChain: return String(localized: "A rede \(chain.name) ainda não aceita moeda custom.")
        case .empty: return String(localized: "Cole o endereço do token.")
        case .invalidAddress: return String(localized: "Este não é um endereço válido na rede \(chain.name). Confira se copiou inteiro e se a rede é essa.")
        case .invalidCode: return String(localized: "Este código de moeda não vale na rede \(chain.name).")
        case .alreadyListed(let listed): return String(localized: "\(listed.symbol) com este contrato já está na lista verificada. Ele aparece sozinho na Carteira quando houver saldo.")
        case .notAToken: return String(localized: "Este endereço é de um programa da rede, não de um token.")
        }
    }

    // MARK: Previa

    private func preview(_ facts: TokenFacts) -> some View {
        let asset = facts.asset
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                CoinLogo(coingeckoID: nil, symbol: asset.symbol, size: 48, network: asset.chain, ringColor: Palette.void, unverified: true,
                         logoAsset: asset)
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
                infoRow(String(localized: "Rede"), asset.chain?.name ?? asset.chainID)
                infoRow(String(localized: "Casas decimais"), "\(asset.decimals)")
                infoRow(String(localized: "Conferido em"), facts.sources.formatted(.list(type: .and).locale(Fmt.locale)))
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

            Banner(kind: .caution, title: String(localized: "Não verificado pela Escalibur"), message: TokenReasonText.anyoneCanCreate)
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

            PrimaryButton(title: String(localized: "Adicionar à carteira")) { save(asset) }
                .padding(.top, Space.lg)
                .accessibilityIdentifier("adicionar-a-carteira")
            TertiaryButton(title: String(localized: "Voltar e corrigir")) {
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
            self.error = String(localized: "Não foi possível salvar agora. Tente de novo.")
            self.facts = nil
            return
        }
        portfolio.customChanged(session.selectedWallet, session: session)
        toasts.show(String(localized: "\(asset.symbol) adicionada. Ela aparece na Carteira, em Receber e em Enviar."))
        let wallet = session.selectedWallet
        Task {
            if let chain = asset.chain { await portfolio.refreshChain(chain, wallet: wallet, session: session) }
            await portfolio.refresh(wallet, session: session)
        }
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
