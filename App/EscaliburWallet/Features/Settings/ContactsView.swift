import EscaliburChains
import SwiftUI

/// S6: enderecos salvos. Guarda nome, endereco, rede e a tag ou o memo junto, para o
/// envio seguinte preencher os dois de uma vez.
struct ContactsView: View {
    @Environment(AppSession.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @State private var adding = false
    @State private var removing: Contact?

    private var contacts: [Contact] {
        session.metadata.contacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            if contacts.isEmpty {
                empty
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(contacts) { contact in card(contact) }
                    Text("Endereço salvo vira atalho no envio e entra na conferência de endereço parecido. Salvar pede \(KeyServices.biometryName) ou PIN.")
                        .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.sm)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
            }
        }
        .safeAreaInset(edge: .bottom) {
            ActionFooter { PrimaryButton(title: "Salvar um endereço") { adding = true } }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Endereços salvos")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { AddContactSheet() }
        .alert("Apagar \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Apagar", role: .destructive) {
                if let removing {
                    session.metadata.contacts.removeAll { $0.id == removing.id }
                    try? session.persist()
                }
                removing = nil
            }
            Button("Cancelar", role: .cancel) { removing = nil }
        } message: {
            Text("O endereço sai da lista. Nada muda na rede.")
        }
    }

    private var empty: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "book.closed")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Palette.control))
            Text("Nenhum endereço salvo").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.xs)
            Text("Salve os endereços para onde você envia sempre, com a tag de destino junto quando houver. No envio, é só escolher.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.xl)
        .frame(maxWidth: .infinity)
    }

    private func card(_ contact: Contact) -> some View {
        let chain = Chain.find(contact.chainID)
        return HStack(spacing: Space.sm) {
            if let chain { NetworkBadge(chain: chain, size: 36, ring: Palette.body) }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: contact.name).typeStyle(.row).foregroundStyle(Palette.ink).lineLimit(1)
                Text(verbatim: (chain?.name ?? contact.chainID) + (contact.tag.map { " · tag \($0)" } ?? ""))
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).lineLimit(1)
                Text(verbatim: Fmt.address(contact.address, head: 8, tail: 6))
                    .typeStyle(.monoSmall).foregroundStyle(Palette.inkMuted).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            Menu {
                Button {
                    Pasteboard.copyAddress(contact.address)
                    toasts.show("Endereço copiado.")
                } label: { Label("Copiar endereço", systemImage: "doc.on.doc") }
                Button(role: .destructive) { removing = contact } label: { Label("Apagar", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.inkSoft)
                    .frame(width: Height.touch, height: Height.touch)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Opções de \(contact.name)")
        }
        .padding(.leading, Space.md)
        .padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
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
    @State private var scanning = false

    private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validation: Result<Address.Destination, Address.Problem> { Address.validate(trimmed, for: chain) }
    private var isValid: Bool { (try? validation.get()) != nil }
    /// O endereco colado parece de outra rede: o app sugere, nao troca sozinho.
    private var suggestion: Chain? {
        guard !trimmed.isEmpty, !isValid, let guess = Address.guessChain(trimmed), guess.id != chain.id else { return nil }
        return guess
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    labeled("Nome") {
                        TextField("", text: $name, prompt: Text("Ex.: Minha conta na corretora").foregroundColor(Palette.inkDead))
                            .typeStyle(.row).foregroundStyle(Palette.ink)
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, Space.md).frame(height: Height.field)
                            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
                    }
                    labeled("Rede") {
                        HStack {
                            NetworkMenu(chains: Chain.all, selected: chain) { chain = $0 }
                            Spacer()
                        }
                    }
                    labeled("Endereço") {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack(spacing: Space.xs) {
                                TextField("", text: $address, prompt: Text("Cole ou escaneie").foregroundColor(Palette.inkDead), axis: .vertical)
                                    .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .lineLimit(1...3)
                                PasteButton(payloadType: String.self) { strings in
                                    Task { @MainActor in address = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                                }
                                .labelStyle(.iconOnly)
                                .buttonBorderShape(.circle)
                                .tint(Palette.control)
                                Button { scanning = true } label: {
                                    Image(systemName: "qrcode.viewfinder").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                                        .frame(width: 36, height: 36).background(Circle().fill(Palette.control))
                                }
                                .accessibilityLabel("Escanear QR")
                            }
                            .padding(.leading, Space.md).padding(.trailing, Space.xs).padding(.vertical, Space.xs)
                            .frame(minHeight: Height.field)
                            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail)
                                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                    .stroke(isValid ? Palette.up.opacity(0.6) : Color.clear, lineWidth: 1)))
                            if let suggestion {
                                Button { chain = suggestion } label: {
                                    HStack(spacing: Space.xs) {
                                        NetworkBadge(chain: suggestion, size: 18, ring: Palette.body)
                                        Text("Parece um endereço da \(suggestion.name). Usar a \(suggestion.name)?")
                                            .typeStyle(.note).fontWeight(.semibold).foregroundStyle(Palette.ink)
                                    }
                                }
                                .buttonStyle(.plain)
                            } else if !trimmed.isEmpty, case .failure(let problem) = validation {
                                Text(SendStages.message(problem, chain: chain)).typeStyle(.note).foregroundStyle(Palette.down)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if isValid {
                                Label("Endereço válido na \(chain.name)", systemImage: "checkmark.circle.fill")
                                    .typeStyle(.note).foregroundStyle(Palette.up)
                            }
                        }
                    }
                    if chain.destinationTag != .none {
                        labeled(chain.destinationTag == .stellarMemo ? "Memo, se houver" : "Tag de destino, se houver") {
                            TextField("", text: $tag)
                                .font(TypeStyle.mono.font).foregroundStyle(Palette.ink)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(.horizontal, Space.md).frame(height: Height.field)
                                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.rail))
                        }
                    }
                }
                .padding(Space.gutter)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                ActionFooter {
                    PrimaryButton(title: "Salvar", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && isValid) { Task { await save() } }
                }
            }
            .background(Palette.body.ignoresSafeArea())
            .navigationTitle("Salvar endereço")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanning) {
                QRScannerSheet { text in
                    address = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    scanning = false
                }
            }
        }
        .presentationBackground(Palette.body)
        .presentationCornerRadius(Radius.sheet)
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).typeStyle(.note).foregroundStyle(Palette.inkSoft)
            content()
        }
    }

    /// Um endereco salvo vira endereco de confianca: aparece como atalho no envio e entra
    /// na conferencia de endereco parecido. Por isso gravar pede Face ID ou PIN, como
    /// qualquer operacao que muda para onde o dinheiro pode ir.
    private func save() async {
        guard case .success(let destination) = validation else { return }
        let finalTag = destination.tag.map(String.init) ?? (tag.isEmpty ? nil : tag)
        let title = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        guard (try? await auth.perform(session, reason: "Salvar o endereço de \(title)", { _ in true })) == true else { return }
        session.metadata.contacts.append(Contact(id: UUID(), name: title, chainID: chain.id, address: destination.address, tag: finalTag))
        do {
            try session.persist()
            dismiss()
        } catch {
            session.metadata.contacts.removeAll { $0.address == destination.address && $0.chainID == chain.id && $0.name == title }
        }
    }
}

/// P4: gerenciar ativos.
struct ManageAssetsView: View {
    @Environment(AppSession.self) private var session
    @Environment(Portfolio.self) private var portfolio

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let wallet = session.selectedWallet {
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
                                    CoinLogo(coingeckoID: row.coingeckoID, symbol: row.symbol, size: 28, ringColor: Palette.body)
                                    Text(row.symbol).typeStyle(.body).foregroundStyle(Palette.ink)
                                }
                            }
                            .tint(Palette.lime)
                            .padding(.horizontal, Space.md).frame(minHeight: Height.rowCompact)
                        }
                    }
                    .padding(.top, Space.md)
                }
                if portfolio.unknownTokens > 0 {
                    Text("\(portfolio.unknownTokens) tokens chegaram sem você pedir e não estão na lista verificada. Muitos são golpe: o nome aponta para um site que pede a senha da carteira. Eles ficam escondidos.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Gerenciar ativos")
        .navigationBarTitleDisplayMode(.inline)
    }
}
