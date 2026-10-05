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

/// De onde vem a logo de um token fora da lista, em ordem: a pasta do contrato no
/// repositorio da Trust Wallet e, sem ela, a moeda que o CoinGecko lista com o mesmo
/// contrato (imagem no host de imagens do CoinGecko, que o app ja usa).
///
/// Ficam de fora, de proposito: a imagem que o proprio token declara (de qualquer host,
/// escolhido por quem criou o token) e o WebP do proxy da tonapi (o decodificador de
/// WebP foi a porta do BLASTPASS em 2023; o app so abre PNG e JPEG). Token sem nenhuma
/// das duas fontes fica com as letras do simbolo.
///
/// As perguntas ao CoinGecko saem uma a cada 3 s: sem chave, ele corta a rajada, e a
/// mesma cota serve o Mercado.
/// O resultado fica so na memoria; "nao listado" vale ate o app fechar.
public actor TokenLogoResolver {
    public static let shared = TokenLogoResolver()

    private let market: MarketService
    private var resolved: [String: URL?] = [:]
    private var running: [String: Task<URL?, Never>] = [:]
    private var gate: Task<Void, Never>?
    static let spacing: Duration = .seconds(3)

    public init(market: MarketService = .shared) {
        self.market = market
    }

    public func logo(for asset: Asset) async -> URL? {
        if let done = resolved[asset.id] { return done }
        if let task = running[asset.id] { return await task.value }
        let task = Task { await self.lookup(asset) }
        running[asset.id] = task
        let value = await task.value
        running[asset.id] = nil
        return value
    }

    private func lookup(_ asset: Asset) async -> URL? {
        if let trust = TokenLogos.url(for: asset), await ImageLoader.shared.data(for: trust) != nil {
            resolved[asset.id] = trust
            return trust
        }
        await waitTurn()
        do {
            let found = try await market.tokenImage(asset)
            resolved[asset.id] = .some(found)
            return found
        } catch {
            return nil
        }
    }

    /// A vez na fila do CoinGecko: cada pergunta espera a anterior e mais 3 s.
    private func waitTurn() async {
        let previous = gate
        let mine = Task {
            await previous?.value
            try? await Task.sleep(for: Self.spacing)
        }
        gate = mine
        await previous?.value
    }
}
