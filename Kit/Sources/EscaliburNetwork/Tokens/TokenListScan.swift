import EscaliburChains
import EscaliburCore
import Foundation

/// Descobrir tokens nas redes EVM sem indexador sem chave (X Layer e Sonic): conferir o
/// saldo de todos os tokens que o CoinGecko lista naquela rede. Na BNB Chain, que tem a
/// Alchemy (`Endpoints.evmTokenIndex`), so de reserva, quando a Alchemy nao responde.
///
/// - Nenhum RPC publico dessas redes devolve as transferencias recebidas por um endereco
///   sem chave (conferido em 11/10/2026: o publicnode pede o contrato, o dataseed da BNB
///   Chain recusa por limite, o dRPC gratis recusa a faixa, o 1rpc aceita 50 blocos).
/// - A lista vem de `tokens.coingecko.com/{plataforma}/all.json`, o token list publico do
///   CoinGecko servido por CDN, sem a cota da API: 4.466 tokens na BNB Chain, 787 na X
///   Layer e 98 na Sonic. So a lista, igual para todo mundo; o saldo e lido no RPC da
///   rede, como o dos tokens conferidos.
/// - Varredura inteira em lotes grandes do Multicall3 (cerca de 15 chamadas na BNB
///   Chain), no maximo a cada `scanLifetime`; no intervalo, so os que tinham saldo sao
///   relidos. Token fora da lista do CoinGecko (o spam que chega sozinho) nao aparece.
/// - Nome, simbolo e casas da lista so servem de partida: as casas exibidas sao relidas
///   na rede, e o token passa pelas mesmas regras de suspeita dos outros descobertos.
enum TokenListScan {
    static let host = URL(string: "https://tokens.coingecko.com")!
    static let listLifetime: TimeInterval = 24 * 3600
    static let scanLifetime: TimeInterval = 6 * 3600
    /// `balanceOf` por `eth_call` na varredura: 300 gastam menos de 10 milhoes de gas,
    /// abaixo do teto de `eth_call` dos RPCs publicos.
    static let scanBatch = 300

    /// As redes EVM sem indexador sem chave (`Endpoints.evmTokenIndex`), e a BNB Chain como
    /// reserva da Alchemy.
    static let platforms: [String: String] = ["bnb": "binance-smart-chain", "xlayer": "x-layer", "sonic": "sonic"]

    static func url(_ chain: Chain) -> URL? {
        platforms[chain.id].map { host.appendingPathComponent("\($0)/all.json") }
    }

    /// Os tokens da lista da rede, conferidos: rede certa, endereco valido, casas na faixa.
    static func parse(_ data: Data, chain: Chain) throws -> [IndexedToken] {
        struct List: Decodable {
            struct Token: Decodable {
                let chainId: UInt64
                let address: String
                let name: String?
                let symbol: String?
                let decimals: Int?
                let logoURI: String?
            }
            let tokens: [Token]
        }
        let list: List
        do { list = try JSONDecoder().decode(List.self, from: data) } catch { throw ReaderError.malformed(field: "tokenlist") }
        var seen = Set<String>()
        return list.tokens.compactMap { token in
            guard token.chainId == chain.evmChainID, let address = try? EVMAddress(token.address),
                  seen.insert(address.checksummed.lowercased()).inserted
            else { return nil }
            let decimals = token.decimals.flatMap { (0...36).contains($0) ? $0 : nil }
            return IndexedToken(contract: address, name: token.name ?? "", symbol: token.symbol ?? "", decimals: decimals, flagged: false,
                                logo: logo(token.logoURI))
        }
    }

    /// A logo da lista, no tamanho grande (a lista aponta para a miniatura de 25 px, que
    /// fica borrada no circulo de 40 pt), e so no host de imagens do CoinGecko.
    static func logo(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text.replacingOccurrences(of: "/thumb/", with: "/large/")),
              url.host == "assets.coingecko.com" || url.host == "coin-images.coingecko.com", ImageLoader.isAllowed(url)
        else { return nil }
        return url
    }
}
