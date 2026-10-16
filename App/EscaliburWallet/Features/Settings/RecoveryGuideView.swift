import EscaliburChains
import SwiftUI

/// "Abrir em outro app" (auditoria 4, C7-09): como as mesmas palavras abrem o mesmo saldo
/// fora da Escalibur, rede por rede. A promessa antiga, "qualquer carteira BIP-39", era
/// falsa em varios casos: no Polkadot so a Trust Wallet abre a mesma conta, na Trust a
/// Solana mostra outro endereco, a Yoroi recusa 12 palavras, e com passphrase a TON, o
/// Polkadot e a NEAR nao abrem em nenhuma carteira comum conhecida.
///
/// Nada de segredo aqui: nem palavra, nem passphrase, nem chave estendida (a xpub liga
/// todos os enderecos passados e futuros). So o caminho, os apps e o comeco e o fim do
/// endereco de cada rede, para conferir que o outro app abriu a mesma conta. O
/// levantamento, com as fontes, esta em docs/blockchain.md.
struct RecoveryGuideView: View {
    let wallet: WalletMeta

    private var wordCount: Int {
        if case .phrase(let count) = wallet.kind { return count }
        return 12
    }

    /// As redes desta carteira, com as EVM juntas numa linha so: o endereco e o mesmo.
    private var groups: [(chains: [Chain], address: String)] {
        var out: [(chains: [Chain], address: String)] = []
        var evm: [Chain] = []
        var evmAddress = ""
        for account in wallet.accounts {
            guard let chain = Chain.find(account.chainID) else { continue }
            if chain.family == .evm {
                evm.append(chain)
                evmAddress = account.address
            } else {
                out.append(([chain], account.address))
            }
        }
        if !evm.isEmpty { out.insert((evm, evmAddress), at: min(1, out.count)) }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Palette.control))
                Text("Abrir em outro app").typeStyle(.title).foregroundStyle(Palette.ink).padding(.top, Space.md)
                Text("As \(wordCount) palavras de \(wallet.name) abrem o mesmo saldo em outros apps, se você não tiver mais a Escalibur. Cada rede tem os apps que abrem a mesma conta.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Space.md) {
                    rule("1.circle", String(localized: "Use sempre a primeira conta do outro app. Digite as palavras em minúsculas, com um espaço entre elas."))
                    if wallet.hasPassphrase {
                        rule("key.horizontal", String(localized: "Esta carteira tem passphrase: sem ela, ou com uma letra diferente, abre outra carteira, vazia."))
                    }
                    rule("checkmark.circle", String(localized: "Antes de mover tudo, confira se o endereço que o outro app mostra começa e termina como o daqui. Mova um valor pequeno primeiro."))
                    rule("exclamationmark.shield", String(localized: "Baixe o outro app só da loja oficial. Nunca digite as palavras num site nem as mande a ninguém: quem oferece recuperar saldo quer o saldo."), caution: true)
                }
                .padding(Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                .padding(.top, Space.lg)

                Text("Rede por rede").typeStyle(.row).foregroundStyle(Palette.ink)
                    .padding(.top, Space.lg).padding(.bottom, Space.xs)
                VStack(spacing: Space.xs) {
                    ForEach(groups, id: \.address) { group in
                        network(group.chains, address: group.address)
                    }
                }

                Text("Tem um envelope Escalibur? O programa público decifrar.py, no código da Escalibur, abre o envelope num computador, sem o iPhone, e devolve as palavras e a passphrase.")
                    .typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.lg)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Conferido em outubro de 2026, no código e na documentação de cada app. Os apps mudam: confira o endereço antes de mover.")
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted).padding(.top, Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func network(_ chains: [Chain], address: String) -> some View {
        let first = chains[0]
        let guide = Self.guide(first, wordCount: wordCount)
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                NetworkBadge(chain: first, size: 28, ring: Palette.body)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chains.count > 1 ? String(localized: "Redes EVM (\(chains.count))") : first.name)
                        .typeStyle(.row).foregroundStyle(Palette.ink)
                    // O comeco e o fim, para conferir; o endereco inteiro esta em Receber.
                    Text(verbatim: Fmt.address(address, head: 6, tail: 6)).typeStyle(.monoSmall).foregroundStyle(Palette.inkSoft)
                }
            }
            if chains.count > 1 {
                Text(chains.map(\.name).joined(separator: ", "))
                    .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            line(String(localized: "Abre em"), guide.apps)
            if let note = guide.note { line(String(localized: "Atenção"), note) }
            if wallet.hasPassphrase {
                line(String(localized: "Com passphrase"), guide.passphrase ?? String(localized: "Nenhum app comum conhecido aceita a passphrase nesta rede. O saldo daqui só sai pela Escalibur ou por ferramenta técnica."),
                     caution: guide.passphrase == nil)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
    }

    private func line(_ label: String, _ text: String, caution: Bool = false) -> some View {
        (Text(label + ": ").bold().foregroundColor(caution ? Palette.caution : Palette.ink) + Text(text).foregroundColor(Palette.inkSoft))
            .typeStyle(.note)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rule(_ icon: String, _ text: String, caution: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(caution ? Palette.caution : Palette.inkSoft)
                .frame(width: 32, height: 32)
                .background(Circle().fill(caution ? Palette.caution.opacity(0.16) : Palette.control))
            Text(text).typeStyle(.note).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    /// O que vale em cada rede: os apps que abrem a mesma conta, a armadilha, e quem aceita
    /// a passphrase (nil: nenhum app comum conhecido).
    static func guide(_ chain: Chain, wordCount: Int) -> (apps: String, note: String?, passphrase: String?) {
        if chain.family == .evm {
            return (String(localized: "MetaMask, Rabby ou Trust Wallet, na primeira conta."),
                    String(localized: "O endereço é o mesmo em todas as redes EVM. Se a rede não aparece, adicione pelo número da rede; se um token não aparece, importe pelo contrato."),
                    String(localized: "A Rabby aceita; a MetaMask não."))
        }
        switch chain.id {
        case "bitcoin":
            return (String(localized: "Sparrow, Electrum ou BlueWallet, no tipo Native SegWit (bc1q)."),
                    String(localized: "O troco fica em endereços próprios da carteira, e esses três os encontram. Em Taproot, Legacy ou Nested, o app mostra outra conta."),
                    String(localized: "Sparrow, Electrum e BlueWallet aceitam."))
        case "litecoin":
            return (String(localized: "Trust Wallet, endereço ltc1q."), nil, nil)
        case "dogecoin":
            return (String(localized: "Trust Wallet."), nil, nil)
        case "solana":
            return (String(localized: "Phantom."),
                    String(localized: "Na Trust Wallet e no Ledger Live, a mesma frase mostra outro endereço."),
                    String(localized: "Só pela linha de comando (solana-keygen)."))
        case "xrpl":
            return (String(localized: "Xaman, em Importar com frase, ou Trust Wallet."),
                    String(localized: "Se a Xaman perguntar a curva, escolha secp256k1. A conta guarda 1 XRP de reserva."),
                    String(localized: "A Xaman aceita."))
        case "stellar":
            return (String(localized: "Freighter, LOBSTR ou Trust Wallet."),
                    String(localized: "Parte do XLM fica reservada pela rede."), nil)
        case "tron":
            return (String(localized: "Trust Wallet ou TronLink."),
                    String(localized: "Para mover USDT é preciso ter TRX."), nil)
        case "ton":
            return (String(localized: "Tonkeeper, MyTonWallet ou Trust Wallet."),
                    String(localized: "Na Tonkeeper, escolha a versão V4R2: a W5 da mesma frase é outro endereço."), nil)
        case "sui":
            return (String(localized: "Slush ou Trust Wallet."), nil, nil)
        case "cardano":
            return (wordCount == 24 ? String(localized: "Eternl, Yoroi ou Trust Wallet.") : String(localized: "Eternl ou Trust Wallet. A Yoroi só aceita 15 ou 24 palavras."),
                    String(localized: "Na Ledger, a mesma frase abre outra conta."),
                    String(localized: "Só a Trezor e a ferramenta cardano-address."))
        case "polkadot":
            return (String(localized: "Só a Trust Wallet."),
                    String(localized: "Polkadot.js, Nova, Talisman e Ledger mostram outra conta, vazia. O saldo está na Polkadot Asset Hub."), nil)
        case "near":
            return (String(localized: "MyNearWallet ou Trust Wallet."),
                    String(localized: "A conta é o código de 64 caracteres, não um nome .near."), nil)
        case "aptos":
            return (String(localized: "Petra ou Trust Wallet."), nil, nil)
        default:
            return (String(localized: "Trust Wallet."), nil, nil)
        }
    }
}
