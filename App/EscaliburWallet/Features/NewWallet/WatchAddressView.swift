import EscaliburChains
import EscaliburCore
import SwiftUI

/// O8: observar um endereco, sem poder enviar.
struct WatchAddressView: View {
    /// "Ethereum, Base, ... e Celo", na ordem da interface: a lista acompanha as redes
    /// compiladas.
    static var evmNetworkNames: String {
        let names = Chain.evmChains.map(\.name)
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " e " + last
    }

    @Environment(AppSession.self) private var session
    let onFinished: () -> Void
    @State private var address = ""
    @State private var name = "Carteira fria"
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case address, name }

    private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var detected: Chain? { Address.guessChain(trimmed) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    label("Endereço").padding(.top, Space.lg)
                    addressField.padding(.top, Space.xs)
                    detection
                        .padding(.top, Space.sm)
                        .animation(Motion.select, value: detected?.id)
                    label("Nome da carteira").padding(.top, Space.lg)
                    nameField.padding(.top, Space.xs)
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Image(systemName: "eye").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.inkMuted)
                            .accessibilityHidden(true)
                        Text("Desta carteira você vê saldo e histórico. Enviar e trocar ficam desligados.")
                            .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Space.sm)
                    if let error {
                        Banner(kind: .failure, title: error).padding(.top, Space.md)
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            ActionFooter {
                PrimaryButton(title: "Observar", enabled: detected != nil) { save() }
            }
        }
        .background(Palette.void.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: "eye")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Palette.control))
                .accessibilityHidden(true)
            Text("Observar um endereço")
                .typeStyle(.title).foregroundStyle(Palette.ink)
                .padding(.top, Space.xs)
            Text("Acompanhe o saldo de um endereço sem guardar chave nenhuma neste iPhone.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func label(_ text: String) -> some View {
        Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft)
    }

    /// O campo e o colar dentro dele: vazio, o botao cola; preenchido, limpa.
    private var addressField: some View {
        HStack(alignment: .center, spacing: Space.xs) {
            TextField("", text: $address, prompt: Text("Cole ou digite o endereço").foregroundColor(Palette.inkDead), axis: .vertical)
                // Mono so para o endereco; o convite vazio fica na fonte do texto.
                .font(address.isEmpty ? TypeStyle.body.font : TypeStyle.mono.font).foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .lineLimit(1...4)
                .focused($focus, equals: .address)
                .submitLabel(.next)
                .onSubmit { focus = .name }
                .accessibilityIdentifier("campo-endereco")
            if address.isEmpty {
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        address = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        focus = nil
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(Palette.control)
            } else {
                Button { address = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.inkMuted)
                        .frame(width: Height.touch, height: Height.touch)
                }
                .accessibilityLabel("Apagar o endereço")
            }
        }
        .padding(.leading, Space.md)
        .padding(.trailing, Space.xs)
        .padding(.vertical, Space.xxs)
        .frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(focus == .address ? Palette.edgeStrong : Palette.edge, lineWidth: 1)))
        .contentShape(Rectangle())
        .onTapGesture { focus = .address }
    }

    /// A rede reconhecida, com o logo; endereco EVM mostra as redes onde vale.
    @ViewBuilder
    private var detection: some View {
        if let detected {
            HStack(spacing: Space.sm) {
                if detected.family == .evm {
                    evmBadges
                } else {
                    NetworkBadge(chain: detected, size: 32, ring: Palette.body)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(detected.family == .evm ? "Endereço EVM" : "Endereço \(detected.name)")
                        .typeStyle(.row).foregroundStyle(Palette.ink)
                    Text(detected.family == .evm ? "Vale em \(Self.evmNetworkNames)." : "Rede reconhecida.")
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(Palette.up)
                    .accessibilityHidden(true)
            }
            .padding(Space.sm)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
            .accessibilityElement(children: .combine)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if !trimmed.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.down)
                    .accessibilityHidden(true)
                Text("Não reconheci este endereço em nenhuma rede ligada. Confira se copiou inteiro.")
                    .typeStyle(.note).foregroundStyle(Palette.down)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        }
    }

    /// Os logos das redes EVM, sobrepostos; passou de quatro, o resto vira numero.
    private var evmBadges: some View {
        let chains = Chain.evmChains
        let shown = Array(chains.prefix(4))
        return HStack(spacing: -10) {
            ForEach(shown, id: \.id) { chain in
                NetworkBadge(chain: chain, size: 28, ring: Palette.body)
            }
            if chains.count > shown.count {
                Text("+\(chains.count - shown.count)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSoft)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Palette.control))
                    .overlay(Circle().stroke(Palette.body, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }

    private var nameField: some View {
        HStack {
            TextField("", text: $name)
                .typeStyle(.row).foregroundStyle(Palette.ink)
                .focused($focus, equals: .name)
                .submitLabel(.done)
            Image(systemName: "pencil").font(.system(size: 15)).foregroundStyle(Palette.inkMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Space.md).frame(height: Height.field)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(focus == .name ? Palette.edgeStrong : Palette.edge, lineWidth: 1)))
    }

    private func save() {
        guard let chain = detected, case .success(let destination) = Address.validate(address, for: chain) else { return }
        do {
            _ = try session.addWatchWallet(chain: chain, address: destination.address, name: String(name.prefix(40)))
            onFinished()
        } catch {
            self.error = "Não foi possível guardar."
        }
    }
}
