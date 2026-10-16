import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import SwiftUI

/// O que a carteira importada vai ser, mostrado antes de guardar: os primeiros
/// enderecos e a impressao digital.
///
/// Frase com uma palavra trocada que ainda fecha o checksum, ou 25a palavra diferente,
/// abrem outra carteira, valida e vazia, sem aviso nenhum. Quem ja usou a carteira
/// reconhece os enderecos; a impressao digital e a mesma que carteiras de hardware e
/// o Sparrow mostram.
struct ImportPreview: Sendable {
    let fingerprint: String
    let addresses: [(chain: Chain, address: String)]
    /// O endereco na Tron, so para conferir quem controla a conta (o golpe da "frase com
    /// saldo"); nao aparece na lista.
    let tronAddress: String?

    static let chains: [Chain] = [.bitcoin, .ethereum, .solana]

    /// Deriva fora da thread principal. O segredo nao e zerado aqui: quem chama
    /// ainda vai guarda-lo ou descarta-lo.
    static func make(_ secret: WalletSecret) async throws -> ImportPreview {
        try await Offload.run {
            let (accounts, fingerprint) = try AccountDeriver.derive(secret, chains: chains + [.tron])
            let addresses = chains.compactMap { chain in accounts.first { $0.chainID == chain.id }.map { (chain, $0.address) } }
            let tron = accounts.first { $0.chainID == Chain.tron.id }?.address
            return ImportPreview(fingerprint: fingerprint.hex.uppercased(), addresses: addresses, tronAddress: tron)
        }
    }
}

/// A conferencia antes de guardar uma carteira que veio de fora (auditoria 4, C7-05): a
/// frase digitada ou o envelope aberto pode ser de outra pessoa. No golpe da "frase com
/// saldo" (ou do falso suporte), o golpista entrega as palavras de uma carteira com USDT
/// que ele controla por outra chave, e quem deposita a taxa perde o deposito. A tela diz
/// isso com aceite, e na Tron confere na rede quem controla a conta.
struct ImportPreviewView: View {
    enum Source { case phrase, envelope }

    let preview: ImportPreview
    let hasPassphrase: Bool
    var source: Source = .phrase
    let saving: Bool
    /// Guarda, dizendo se a conta da Tron tem outra chave no controle: a carteira grava a
    /// marca, e o Receber da Tron nela fica fechado.
    let onSave: (_ tronForeign: Bool) -> Void
    let onBack: () -> Void

    @State private var accepted = false
    /// A conta da Tron com outra chave no controle: nil enquanto nao se sabe (sem rede,
    /// conta nova), e a conferencia nunca segura o Guardar.
    @State private var tronForeign = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Confira antes de guardar").typeStyle(.title).foregroundStyle(Palette.ink)
                Text(hasPassphrase
                     ? "Se esta carteira já recebeu antes, estes endereços são os que você conhece. Se não baterem, a frase ou a passphrase está diferente, e o que abriria aqui é outra carteira, vazia."
                     : "Se esta carteira já recebeu antes, estes endereços são os que você conhece. Se não baterem, alguma palavra está diferente, e o que abriria aqui é outra carteira, vazia.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.sm)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(preview.addresses, id: \.chain.id) { item in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack(spacing: Space.xs) {
                                NetworkBadge(chain: item.chain, size: 20, ring: Palette.body)
                                Text(item.chain.name).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                            }
                            AddressBlocks(address: item.address)
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Impressão digital da carteira").typeStyle(.note).foregroundStyle(Palette.inkSoft)
                        Text(verbatim: preview.fingerprint).typeStyle(.row).foregroundStyle(Palette.ink)
                        Text("A mesma que carteiras de hardware mostram para esta frase.")
                            .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    }
                }
                .padding(.top, Space.lg)

                if tronForeign {
                    Banner(kind: .failure, title: String(localized: "Na Tron, esta conta é controlada por outra chave"),
                           message: String(localized: "É o golpe da frase com saldo: o que entrar nela, quem controla a outra chave leva. Não deposite nada nesta carteira."))
                        .padding(.top, Space.lg)
                        .accessibilityIdentifier("importar-tron-outra-chave")
                }

            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
        }
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                // O aceite fica junto do Guardar, sempre a vista: no fim da lista, abaixo do
                // aviso da Tron, ele ficava atras do rodape.
                consent
                PrimaryButton(title: String(localized: "Guardar esta carteira"), enabled: accepted, loading: saving) { onSave(tronForeign) }
                TertiaryButton(title: String(localized: "Voltar e conferir"), action: onBack)
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .task { await checkTron() }
    }

    /// O aceite: quem tem as palavras (ou o envelope e a senha dele) tem a carteira.
    private var consent: some View {
        Button { accepted.toggle() } label: {
            HStack(alignment: .top, spacing: Space.sm) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accepted ? Palette.control : Palette.void)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(accepted ? Palette.inkSoft : Palette.edgeStrong, lineWidth: 1.5))
                    .overlay {
                        if accepted {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)
                Text(source == .envelope
                     ? String(localized: "Entendo que quem me mandou este envelope e a senha dele controla esta carteira e pode levar o que entrar nela. Só deposito aqui se o envelope for meu.")
                     : String(localized: "Entendo que quem me deu estas palavras controla esta carteira e pode levar o que entrar nela. Só deposito aqui se as palavras forem só minhas."))
                    .typeStyle(.note).foregroundStyle(accepted ? Palette.ink : Palette.inkSoft)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.body)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(accepted ? Palette.edgeStrong : Palette.edge, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(accepted ? "Marcado" : "Desmarcado")
        .accessibilityAddTraits(accepted ? .isSelected : [])
        .accessibilityIdentifier("importar-aceite")
        .sensoryFeedback(.selection, trigger: accepted)
    }

    /// As permissoes da conta na Tron, como docs/blockchain.md §2.6 promete para a
    /// importacao. Sem rede ou com a conta ainda nao ativada, nada a dizer: o envio na Tron
    /// confere de novo antes de qualquer saldo (`TronSendEngine`).
    private func checkTron() async {
        guard let text = preview.tronAddress, let address = TronAddress(text) else { return }
        guard let control = try? await TronReader.shared.ownerControl(owner: address) else { return }
        tronForeign = control.isCompromised
    }
}
