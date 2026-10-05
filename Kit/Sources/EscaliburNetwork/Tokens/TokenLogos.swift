import EscaliburChains
import Foundation

/// A logo de um token fora da lista, do repositorio publico de logos da Trust Wallet
/// (github.com/trustwallet/assets), o mesmo de onde as carteiras grandes tiram.
///
/// A logo fica na pasta do contrato exato (endereco EIP-55, mint, coin type), nunca do
/// nome ou do simbolo: um token de golpe chamado "USDT" nao ganha a logo do USDT, porque
/// o contrato dele nao tem pasta la. A Trust Wallet revisa cada pasta antes de aceitar.
/// O que nao tem logo continua com as letras do simbolo.
///
/// Conferido em 05/10/2026: as pastas de cada rede e o formato do identificador
/// (`blockchains/<rede>/assets/<id>/logo.png`). Unichain e X Layer nao tem pasta.
public enum TokenLogos {
    static let base = URL(string: "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains")!
    /// O unico caminho servido por este host que o app pede.
    static let pathPrefix = "/trustwallet/assets/master/blockchains/"

    /// A pasta de cada rede no repositorio.
    static let folders: [String: String] = [
        "ethereum": "ethereum", "base": "base", "arbitrum": "arbitrum", "optimism": "optimism", "polygon": "polygon",
        "bnb": "smartchain", "avalanche": "avalanchec", "celo": "celo", "linea": "linea", "sonic": "sonic", "plasma": "plasma",
        "solana": "solana", "tron": "tron", "ton": "ton", "stellar": "stellar", "xrpl": "ripple", "sui": "sui", "aptos": "aptos",
    ]

    /// O endereco da logo, ou nil quando a rede nao tem pasta ou o ativo nao e token.
    public static func url(for asset: Asset) -> URL? {
        guard let folder = folders[asset.chainID], let id = identifier(asset), isSafe(id) else { return nil }
        return base.appendingPathComponent(folder).appendingPathComponent("assets").appendingPathComponent(id).appendingPathComponent("logo.png")
    }

    /// O nome da pasta do ativo, no formato do repositorio.
    static func identifier(_ asset: Asset) -> String? {
        switch asset.kind {
        case .token(let contract):
            guard let chain = Chain.find(asset.chainID) else { return nil }
            if chain.family == .evm {
                return (try? EVMAddress(contract.lowercased()))?.checksummed
            }
            return contract
        case .issued(let code, let issuer):
            switch asset.chainID {
            case "stellar": return "\(code)-\(issuer)"
            case "xrpl": return "\(code).\(issuer)"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// So letras, numeros e os separadores dos formatos acima: nada de barra, ponto
    /// duplo ou espaco vindo de um nome de token montado para escapar do caminho.
    static func isSafe(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 200, !id.contains("..") else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || ":-_.".unicodeScalars.contains(scalar)
        }
    }

    /// Este endereco e uma logo do repositorio, e nao outra coisa do mesmo host.
    static func isLogo(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == base.host && url.path.hasPrefix(pathPrefix) && url.lastPathComponent == "logo.png"
            && !url.path.contains("..")
    }
}
