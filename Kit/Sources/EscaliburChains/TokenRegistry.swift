import EscaliburCore
import Foundation

/// Um ativo que a carteira conhece: a moeda nativa de uma rede ou um token.
public struct Asset: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: Hashable, Codable, Sendable {
        case native
        /// ERC-20 (EVM), SPL (Solana), TRC-20 (Tron), jetton (TON): o contrato ou mint.
        case token(contract: String)
        /// XRP Ledger e Stellar: codigo mais emissor. Qualquer um emite "USD"; o emissor
        /// e o que distingue o verdadeiro.
        case issued(code: String, issuer: String)
    }

    public let chainID: String
    public let kind: Kind
    public let symbol: String
    public let name: String
    public let decimals: Int
    /// Para preco e para o logo embarcado.
    public let coingeckoID: String?
    public let isStablecoin: Bool

    public var id: String {
        switch kind {
        case .native: return "\(chainID):native"
        case .token(let contract): return "\(chainID):\(contract)"
        case .issued(let code, let issuer): return "\(chainID):\(code):\(issuer)"
        }
    }

    public var chain: Chain? { Chain.find(chainID) }

    public static func native(_ chain: Chain) -> Asset {
        Asset(
            chainID: chain.id, kind: .native, symbol: chain.nativeSymbol, name: chain.nativeName,
            decimals: chain.nativeDecimals, coingeckoID: chain.coingeckoID, isStablecoin: false
        )
    }
}

/// A lista curada de tokens, compilada no app.
///
/// Por que compilada: um token com nome "USDC" e contrato de golpe e a isca mais
/// comum que existe, e a lista de quais contratos sao os verdadeiros nao pode vir de
/// resposta de servidor. Cada endereco aqui foi conferido na fonte oficial do emissor
/// e por chamada `symbol()`/`decimals()` a dois nos (ver
/// Tests/EscaliburNetworkTests/TokenRegistryLiveTests.swift), e mudancas nesta lista
/// passam por revisao dupla (CODEOWNERS).
public enum TokenRegistry {
    public static let tokens: [Asset] = [
        // Ethereum
        erc20("ethereum", "0xdAC17F958D2ee523a2206206994597C13D831ec7", "USDT", "Tether", 6, "tether", stable: true),
        erc20("ethereum", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        erc20("ethereum", "0x6B175474E89094C44Da98b954EedeAC495271d0F", "DAI", "Dai", 18, "dai", stable: true),
        erc20("ethereum", "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", "WBTC", "Wrapped Bitcoin", 8, "wrapped-bitcoin"),
        erc20("ethereum", "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "WETH", "Wrapped Ether", 18, "weth"),
        erc20("ethereum", "0x514910771AF9Ca656af840dff83E8264EcF986CA", "LINK", "Chainlink", 18, "chainlink"),
        erc20("ethereum", "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984", "UNI", "Uniswap", 18, "uniswap"),
        // Base
        erc20("base", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        erc20("base", "0x4200000000000000000000000000000000000006", "WETH", "Wrapped Ether", 18, "weth"),
        // Arbitrum
        erc20("arbitrum", "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        erc20("arbitrum", "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", "USDT", "Tether", 6, "tether", stable: true),
        erc20("arbitrum", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", "WETH", "Wrapped Ether", 18, "weth"),
        erc20("arbitrum", "0x912CE59144191C1204E64559FE8253a0e49E6548", "ARB", "Arbitrum", 18, "arbitrum"),
        // Optimism
        erc20("optimism", "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        erc20("optimism", "0x4200000000000000000000000000000000000006", "WETH", "Wrapped Ether", 18, "weth"),
        erc20("optimism", "0x4200000000000000000000000000000000000042", "OP", "Optimism", 18, "optimism"),
        // Polygon
        erc20("polygon", "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        erc20("polygon", "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", "USDT", "Tether", 6, "tether", stable: true),
        // BNB Chain: os stablecoins da Binance-Peg tem 18 casas, nao 6.
        erc20("bnb", "0x55d398326f99059fF775485246999027B3197955", "USDT", "Tether", 18, "tether", stable: true),
        erc20("bnb", "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d", "USDC", "USD Coin", 18, "usd-coin", stable: true),
        // Avalanche
        erc20("avalanche", "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        erc20("avalanche", "0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7", "USDT", "Tether", 6, "tether", stable: true),
        // Segunda leva, conferida em 26/09/2026. USDC: tabela "USDC contract addresses"
        // da Circle (developers.circle.com/stablecoins/usdc-contract-addresses), so o
        // emitido pela Circle (na X Layer o USDC.e da ponte fica de fora). USDT: o USDT0
        // da Tether pela rede OFT (docs.usdt0.to, "Deployments", contrato "Token"), com
        // o mesmo nome curto da Arbitrum, onde o contrato tambem e USDT0 (`symbol()`
        // devolve "USDT0" ou "USD₮0"); na Celo, o USD₮ da lista "Supported Protocols" de
        // tether.to. `symbol()` e `decimals()` lidos em dois RPCs de cada rede. O que
        // vem de ponte e o emissor nao reconhece fica de fora: o USDT da Linea, da Sonic
        // e da X Layer e o USDC.e da X Layer.
        // Plasma
        erc20("plasma", "0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb", "USDT", "Tether", 6, "tether", stable: true),
        erc20("plasma", "0x2d661C89D812261039AF9764eceaAee884f5F67F", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        // X Layer
        erc20("xlayer", "0x779Ded0c9e1022225f8E0630b35a9b54bE713736", "USDT", "Tether", 6, "tether", stable: true),
        erc20("xlayer", "0xB6CEceAB302E2E4948951eE7843FC24E92933061", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        // Linea
        erc20("linea", "0x176211869cA2b568f2A7D4EE941E073a821EE1ff", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        // Unichain
        erc20("unichain", "0x078D782b760474a361dDA0AF3839290b0EF57AD6", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        erc20("unichain", "0x9151434b16b9763660705744891fA906F660EcC5", "USDT", "Tether", 6, "tether", stable: true),
        // Sonic
        erc20("sonic", "0x29219dd400f2Bf60E5a23d13Be72B486D4038894", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        // Celo
        erc20("celo", "0xcebA9300f2b948710d2653dD7B07f33A8B32118C", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        erc20("celo", "0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e", "USDT", "Tether", 6, "tether", stable: true),
        // Solana (mints)
        spl("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        spl("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", "USDT", "Tether", 6, "tether", stable: true),
        spl("JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN", "JUP", "Jupiter", 6, "jupiter-exchange-solana"),
        // Tron
        Asset(chainID: "tron", kind: .token(contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"), symbol: "USDT", name: "Tether",
              decimals: 6, coingeckoID: "tether", isStablecoin: true),
        // Stellar (Circle)
        Asset(chainID: "stellar", kind: .issued(code: "USDC", issuer: "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"),
              symbol: "USDC", name: "USD Coin", decimals: 7, coingeckoID: "usd-coin", isStablecoin: true),
        // TON (jetton master)
        Asset(chainID: "ton", kind: .token(contract: "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"), symbol: "USDT", name: "Tether",
              decimals: 6, coingeckoID: "tether", isStablecoin: true),
    ]

    /// Todos os ativos de uma rede: a moeda nativa e os tokens da lista.
    public static func assets(on chain: Chain) -> [Asset] {
        [Asset.native(chain)] + tokens.filter { $0.chainID == chain.id }
    }

    public static func find(chainID: String, contract: String) -> Asset? {
        tokens.first {
            guard $0.chainID == chainID, case .token(let c) = $0.kind else { return false }
            return c.lowercased() == contract.lowercased()
        }
    }

    private static func erc20(_ chain: String, _ contract: String, _ symbol: String, _ name: String, _ decimals: Int, _ gecko: String, stable: Bool = false) -> Asset {
        Asset(chainID: chain, kind: .token(contract: contract), symbol: symbol, name: name, decimals: decimals, coingeckoID: gecko, isStablecoin: stable)
    }

    private static func spl(_ mint: String, _ symbol: String, _ name: String, _ decimals: Int, _ gecko: String, stable: Bool = false) -> Asset {
        Asset(chainID: "solana", kind: .token(contract: mint), symbol: symbol, name: name, decimals: decimals, coingeckoID: gecko, isStablecoin: stable)
    }
}
