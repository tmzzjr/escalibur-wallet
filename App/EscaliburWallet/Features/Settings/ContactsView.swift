import EscaliburChains
import SwiftUI

/// S6: contatos. Guarda nome, endereco, rede e a tag ou o memo junto, para o envio
/// seguinte preencher os dois de uma vez.
struct ContactsView: View {
    @Environment(AppSession.self) private var session
    @State private var adding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if session.metadata.contacts.isEmpty {
                    Text("Salve os endereços para onde você envia sempre, com a tag de destino junto quando houver.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                        .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SettingsGroup {
                        ForEach(session.metadata.contacts) { contact in
                            HStack(spacing: Space.sm) {
                                if let chain = Chain.find(contact.chainID) { NetworkBadge(chain: chain, size: 28, ring: Palette.body) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: contact.name).typeStyle(.row).foregroundStyle(Palette.ink)
                                    Text(verbatim: Fmt.address(contact.address, head: 8, tail: 6) + (contact.tag.map { " · tag \($0)" } ?? ""))
                                        .typeStyle(.monoSmall).foregroundStyle(Palette.inkSoft)
                                }
                                Spacer()
                                Button {
                                    session.metadata.contacts.removeAll { $0.id == contact.id }
                                    try? session.persist()
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(Palette.inkMuted)
                                        .frame(width: Height.touch, height: Height.touch)
                                }
                                .accessibilityLabel("Apagar endereço salvo")
                            }
                            .padding(.horizontal, Space.md).frame(minHeight: Height.row)
                        }
                    }
                    .padding(.top, Space.md)
                }
                SecondaryButton(title: "Salvar um endereço") { adding = true }
                    .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Endereços salvos")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { AddContactSheet() }
    }
}

struct AddContactSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var tag = ""
    @State private var chain: Chain = .bitcoin

    private var validation: Result<Address.Destination, Address.Problem> { Address.validate(address, for: chain) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    field("Nome", text: $name, mono: false)
                    Text("Rede").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    Picker("Rede", selection: $chain) {
                        ForEach(Chain.all) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Palette.ink)
                    field("Endereço", text: $address, mono: true)
                    if !address.isEmpty, case .failure(let problem) = validation {
                        Text(SendStages.message(problem, chain: chain)).typeStyle(.note).foregroundStyle(Palette.down)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if chain.destinationTag != .none {
                        field(chain.destinationTag == .stellarMemo ? "Memo, se houver" : "Tag de destino, se houver", text: $tag, mono: true)
                    }
                }
                .padding(Space.gutter)
            }
            .safeAreaInset(edge: .bottom) {
                ActionFooter {
                    PrimaryButton(title: "Salvar", enabled: !name.isEmpty && (try? validation.get()) != nil) { Task { await save() } }
                }
            }
            .background(Palette.body.ignoresSafeArea())
            .navigationTitle("Salvar endereço")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
    }

    private func field(_ label: String, text: Binding<String>, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            TextField("", text: text)
                .font(mono ? TypeStyle.mono.font : TypeStyle.row.font)
                .foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, Space.md).frame(height: Height.field)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
        }
    }

    /// Um contato vira endereco de confianca: aparece como atalho no envio e entra na
    /// conferencia de endereco parecido. Por isso gravar pede Face ID ou PIN, como
    /// qualquer operacao que muda para onde o dinheiro pode ir.
    private func save() async {
        guard case .success(let destination) = validation else { return }
        let finalTag = destination.tag.map(String.init) ?? (tag.isEmpty ? nil : tag)
        guard (try? await auth.perform(session, reason: "Salvar o endereço de \(String(name.prefix(40)))", { _ in true })) == true else { return }
        session.metadata.contacts.append(Contact(id: UUID(), name: String(name.prefix(40)), chainID: chain.id, address: destination.address, tag: finalTag))
        do {
            try session.persist()
            dismiss()
        } catch {
            session.metadata.contacts.removeAll { $0.address == destination.address && $0.chainID == chain.id && $0.name == String(name.prefix(40)) }
        }
    }
}

/// P4: gerenciar ativos: o que aparece na Carteira e as moedas custom.
struct ManageAssetsView: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio
    @State private var adding = false
    @State private var removing: Asset?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let wallet = session.selectedWallet, !portfolio.allRows.isEmpty {
                    SettingsGroup {
                        ForEach(portfolio.allRows) { row in
                            Toggle(isOn: Binding(
                                get: { !wallet.hiddenAssetIDs.contains(row.id) },
                                set: { visible in
                                    var updated = wallet
                                    if visible { updated.hiddenAssetIDs.remove(row.id) } else { updated.hiddenAssetIDs.insert(row.id) }
                                    session.update(updated)
                                    portfolio.show(updated, session: session, force: true)
                                }
                            )) {
                                HStack(spacing: Space.sm) {
                                    CoinLogo(coingeckoID: row.coingeckoID, symbol: row.symbol, size: 28, ringColor: Palette.body, unverified: row.origin != nil)
                                    Text(verbatim: row.symbol).typeStyle(.body).foregroundStyle(Palette.ink)
                                    if row.isCustom { TokenBadge(.custom) }
                                }
                            }
                            .tint(Palette.lime)
                            .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                        }
                    }
                    .padding(.top, Space.md)
                }

                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Moedas custom").typeStyle(.heading).foregroundStyle(Palette.ink)
                    Text("Um token que não está na lista verificada e que você quer ver, receber e enviar. A carteira lê nome, símbolo e casas decimais na própria rede antes de salvar.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.gutter).padding(.top, Space.xl)

                if !session.metadata.customTokens.isEmpty {
                    SettingsGroup {
                        ForEach(session.metadata.customTokens, id: \.id) { asset in
                            HStack(spacing: Space.sm) {
                                CoinLogo(coingeckoID: nil, symbol: asset.symbol, size: 28, network: asset.chain, ringColor: Palette.body, unverified: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: asset.symbol).typeStyle(.body).foregroundStyle(Palette.ink).lineLimit(1)
                                    Text(verbatim: "\(asset.chain?.name ?? asset.chainID) · \(Fmt.address(CustomToken.reference(asset.kind) ?? ""))")
                                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                                }
                                Spacer()
                                Button { removing = asset } label: {
                                    Text("Remover").typeStyle(.note).foregroundStyle(Palette.inkSoft).frame(minHeight: Height.touch)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remover \(asset.symbol)")
                            }
                            .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                        }
                    }
                    .padding(.top, Space.sm)
                }

                SecondaryButton(title: "Adicionar moeda", systemImage: "plus") { adding = true }
                    .padding(.horizontal, Space.gutter).padding(.top, Space.md)
                    .accessibilityIdentifier("adicionar-moeda")

                if portfolio.unknownTokens > 0 {
                    Text("\(portfolio.unknownTokens) \(portfolio.unknownTokens == 1 ? "token chegou" : "tokens chegaram") numa rede em que a carteira ainda só conta quantos são, sem ler nome e contrato. Eles ficam escondidos.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, Space.xl)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Gerenciar ativos")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) {
            NavigationStack { AddCustomTokenView { adding = false } }
                .presentationBackground(Palette.void)
        }
        .alert("Remover \(removing?.symbol ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancelar", role: .cancel) { removing = nil }
            Button("Remover", role: .destructive) { remove() }
        } message: {
            Text("A moeda some da Carteira, de Receber e de Enviar. O saldo continua na rede, e você pode adicionar de novo.")
        }
    }

    private func remove() {
        guard let asset = removing else { return }
        removing = nil
        session.metadata.customAssets = session.metadata.customTokens.filter { $0.id != asset.id }
        try? session.persist()
        portfolio.customChanged(session.selectedWallet, session: session)
        Task { await portfolio.refresh(session.selectedWallet, session: session) }
    }
}
