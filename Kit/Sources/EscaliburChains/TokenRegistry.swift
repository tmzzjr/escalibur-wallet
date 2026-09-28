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
        // XRP Ledger (Ripple). Emissor conferido em 27/09/2026 em quatro fontes: a pagina de
        // enderecos do token em docs.ripple.com, o Domain da conta na rede (https://ripple.com/,
        // igual em dois servidores no mesmo ledger), o xrp-ledger.toml de ripple.com e o
        // CoinGecko. O emissor pode congelar e recuperar saldo (clawback), como stablecoin
        // regulada; sem taxa de transferencia e sem autorizacao previa.
        Asset(chainID: "xrpl", kind: .issued(code: "524C555344000000000000000000000000000000", issuer: "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"),
              symbol: "RLUSD", name: "Ripple USD", decimals: 6, coingeckoID: "ripple-usd", isStablecoin: true),
        // TON (jetton master)
        Asset(chainID: "ton", kind: .token(contract: "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"), symbol: "USDT", name: "Tether",
              decimals: 6, coingeckoID: "tether", isStablecoin: true),
        // Terceira leva, conferida em 27/09/2026: as maiores moedas do ranking do CoinGecko
        // do dia que existem como token nas redes da carteira, os stablecoins de uso amplo
        // e os derivativos sem rebase de maior valor (wstETH, cbBTC, weETH, sUSDS, sUSDe,
        // JitoSOL, rETH, cbETH), em ordem de valor de mercado. Cada contrato passou por:
        // - duas fontes independentes: a do emissor (documentacao, site ou repositorio
        //   oficial, anotada em cada grupo) e o campo `platforms` do CoinGecko; nas pontes
        //   que o CoinGecko cadastra com id proprio, a consulta de contrato do CoinGecko;
        // - EVM: `symbol()` e `decimals()` iguais em dois RPCs de Endpoints.evm, e uma
        //   transferencia simulada (`eth_call` com state override) que tira do remetente e
        //   entrega ao destino exatamente o valor pedido: sem taxa na transferencia e sem
        //   rebase;
        // - Solana: o mint lido em dois RPCs, programa Token classico, as mesmas casas e
        //   nenhuma extensao Token-2022;
        // - XRP Ledger e Stellar: o emissor lido em dois servidores, com o dominio do
        //   emissor e sem taxa de transferencia.
        // So entra a rede onde o emissor publica o endereco; ponte que o emissor nao lista
        // fica de fora. Nenhum token novo na Tron nem na TON: os motores dessas redes so
        // enviam USDT e o historico so reconhece o USDT, entao outro token recebido ali
        // apareceria como desconhecido e nao sairia pelo app.
        // Tether (USDT), Optimism. Fonte do emissor: USDT0 da Tether na Optimism
        // (docs.usdt0.to, "Deployments"; no CoinGecko, usdt0). `symbol()` devolve "USD₮0".
        erc20("optimism", "0x01bFF41798a0BcF287b996046Ca68b395DbC1071", "USDT", "Tether", 6, "tether", stable: true),
        // USD Coin (USDC), XRP Ledger. Fonte do emissor: USDC da Circle no XRP Ledger
        // (developers.circle.com, "USDC contract addresses"; CoinGecko). Emissor com Domain
        // https://circle.com igual em tres servidores no mesmo ledger, sem TransferRate e
        // sem RequireAuth.
        issued("xrpl", code: "5553444300000000000000000000000000000000", issuer: "rGm7WCVp9gb4jZHWTEtGUr4dd74z2XuWhE", "USDC", "USD Coin", 6, "usd-coin", stable: true),
        // Lido Wrapped Staked ETH (wstETH), Ethereum, Base, Arbitrum, Optimism, Polygon,
        // BNB Chain, Linea, Unichain. Fonte do emissor: docs.lido.fi/deployed-contracts;
        // nas L2, o wstETH das pontes que a Lido lista (no CoinGecko cada ponte tem id
        // proprio, com o mesmo preco; aqui vale o id do wstETH para o ativo ser um so). O
        // stETH, que faz rebase, nunca entra.
        erc20("ethereum", "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0", "wstETH", "Lido Wrapped Staked ETH", 18, "wrapped-steth"),
        erc20("base", "0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452", "wstETH", "Lido Wrapped Staked ETH", 18, "wrapped-steth"),
        erc20("arbitrum", "0x5979D7b546E38E414F7E9822514be443A4800529", "wstETH", "Lido Wrapped Staked ETH", 18, "wrapped-steth"),
        erc20("optimism", "0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb", "wstETH", "Lido Wrapped Staked ETH", 18, "wrapped-steth"),
        erc20("polygon", "0x03b54A6e9a984069379fae1a4fC4dBAE93B3bCCD", "wstETH", "Lido Wrapped Staked ETH", 18, "wrapped-steth"),
        erc20("bnb", "0x26c5e01524d2E6280A48F2c50fF6De7e52E9611C", "wstETH", "Lido Wrapped Staked ETH", 18, "wrapped-steth"),
        erc20("linea", "0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F", "wstETH", "Lido Wrapped Staked ETH", 18, "wrapped-steth"),
        erc20("unichain", "0xc02fE7317D4eb8753a02c35fe019786854A92001", "wstETH", "Lido Wrapped Staked ETH", 18, "wrapped-steth"),
        // Chainlink (LINK), Base, Arbitrum, Optimism, Avalanche, Plasma, X Layer, Linea,
        // Unichain, Sonic, Celo, Solana. Fonte do emissor:
        // docs.chain.link/resources/link-token-contracts. Na Avalanche e o LINK.e da ponte
        // da Avalanche, o que a Chainlink lista. Fora: Polygon e BNB Chain, onde a
        // Chainlink lista o LINK ERC-677 e o CoinGecko so conhece o da ponte.
        erc20("base", "0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196", "LINK", "Chainlink", 18, "chainlink"),
        erc20("arbitrum", "0xf97f4df75117a78c1A5a0DBb814Af92458539FB4", "LINK", "Chainlink", 18, "chainlink"),
        erc20("optimism", "0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6", "LINK", "Chainlink", 18, "chainlink"),
        erc20("avalanche", "0x5947BB275c521040051D82396192181b413227A3", "LINK", "Chainlink", 18, "chainlink"),
        erc20("plasma", "0x76a443768A5e3B8d1AED0105FC250877841Deb40", "LINK", "Chainlink", 18, "chainlink"),
        erc20("xlayer", "0x8aF9711B44695a5A081F25AB9903DDB73aCf8FA9", "LINK", "Chainlink", 18, "chainlink"),
        erc20("linea", "0xa18152629128738a5c081eb226335FEd4B9C95e9", "LINK", "Chainlink", 18, "chainlink"),
        erc20("unichain", "0xEF66491eab4bbB582c57b14778afd8dFb70D8A1A", "LINK", "Chainlink", 18, "chainlink"),
        erc20("sonic", "0x71052BAe71C25C78E37fD12E5ff1101A71d9018F", "LINK", "Chainlink", 18, "chainlink"),
        erc20("celo", "0xd07294e6E917e07dfDcee882dd1e2565085C2ae0", "LINK", "Chainlink", 18, "chainlink"),
        spl("LinkhB3afbBKb2EQQu7s7umdZceV3wcvAUJhQAfQ23L", "LINK", "Chainlink", 9, "chainlink"),
        // USDS (USDS), Ethereum, Base, Solana. Fonte do emissor: chainlog.sky.money
        // (Ethereum) e developers.skyeco.com, guias da SkyLink (Base e Solana).
        erc20("ethereum", "0xdC035D45d973E3EC169d2276DDab16f1e407384F", "USDS", "USDS", 18, "usds", stable: true),
        erc20("base", "0x820C137fa70C8691f0e44Dc420a5e53c168921Dc", "USDS", "USDS", 18, "usds", stable: true),
        spl("USDSwr9ApdHk5bvJKMjzff41FfuX8bSxdKcR81vTwcA", "USDS", "USDS", 6, "usds", stable: true),
        // UNUS SED LEO (LEO), Ethereum. Fonte do emissor: repositorio da Bitfinex
        // (bitfinexcom/bitfinex-terminal, campo erc20Contract do LEO).
        erc20("ethereum", "0x2AF5D2aD76741191D15Dfe7bF6aC92d4Bd912Ca3", "LEO", "UNUS SED LEO", 18, "leo-token"),
        // Coinbase Wrapped BTC (cbBTC), Ethereum, Base. Fonte do emissor: repositorio da
        // Coinbase (coinbase/agentkit, constantes ERC-20 de Ethereum e Base).
        erc20("ethereum", "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf", "cbBTC", "Coinbase Wrapped BTC", 8, "coinbase-wrapped-btc"),
        erc20("base", "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf", "cbBTC", "Coinbase Wrapped BTC", 8, "coinbase-wrapped-btc"),
        // Wrapped eETH (weETH), Ethereum, Base, Arbitrum, Optimism, BNB Chain, Avalanche,
        // Plasma, Linea, Unichain, Sonic. Fonte do emissor: etherfi.gitbook.io, "Deployed
        // Contracts"; na Arbitrum o CoinGecko lista a ponte com id proprio.
        erc20("ethereum", "0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        erc20("base", "0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        erc20("arbitrum", "0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        erc20("optimism", "0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        erc20("bnb", "0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        erc20("avalanche", "0xA3D68b74bF0528fdD07263c60d6488749044914b", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        erc20("plasma", "0xA3D68b74bF0528fdD07263c60d6488749044914b", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        erc20("linea", "0x1Bf74C010E6320bab11e2e5A532b5AC15e0b8aA6", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        erc20("unichain", "0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        erc20("sonic", "0xA3D68b74bF0528fdD07263c60d6488749044914b", "weETH", "Wrapped eETH", 18, "wrapped-eeth"),
        // Uniswap (UNI), Unichain. Fonte do emissor: developers.uniswap.org, "Contract
        // Addresses" da Unichain. Nas outras L2 o UNI e de ponte sem lista do emissor, e
        // fica de fora.
        erc20("unichain", "0x8f187aA05619a017077f5308904739877ce9eA21", "UNI", "Uniswap", 18, "uniswap"),
        // Ethena USDe (USDe), Ethereum, Base, Arbitrum, Optimism, BNB Chain, X Layer,
        // Linea, Solana. Fonte do emissor: docs.ethena.fi, "Key Addresses": o mesmo OFT nas
        // L2 da lista. Avalanche e Plasma ficam de fora (o CoinGecko lista, a Ethena nao).
        erc20("ethereum", "0x4c9EDD5852cd905f086C759E8383e09bff1E68B3", "USDe", "Ethena USDe", 18, "ethena-usde"),
        erc20("base", "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", "USDe", "Ethena USDe", 18, "ethena-usde"),
        erc20("arbitrum", "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", "USDe", "Ethena USDe", 18, "ethena-usde"),
        erc20("optimism", "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", "USDe", "Ethena USDe", 18, "ethena-usde"),
        erc20("bnb", "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", "USDe", "Ethena USDe", 18, "ethena-usde"),
        erc20("xlayer", "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", "USDe", "Ethena USDe", 18, "ethena-usde"),
        erc20("linea", "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34", "USDe", "Ethena USDe", 18, "ethena-usde"),
        spl("DEkqHyPN7GMRJ5cArtQFAWefqbZb33Hyf6s5iCwjEonT", "USDe", "Ethena USDe", 9, "ethena-usde"),
        // Savings USDS (sUSDS), Ethereum, Base. Fonte do emissor: chainlog.sky.money
        // (Ethereum) e o guia da SkyLink para a Base.
        erc20("ethereum", "0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD", "sUSDS", "Savings USDS", 18, "susds"),
        erc20("base", "0x5875eEE11Cf8398102FdAd704C9E96607675467a", "sUSDS", "Savings USDS", 18, "susds"),
        // World Liberty Financial USD (USD1), Ethereum, BNB Chain, Solana. Fonte do
        // emissor: docs.worldlibertyfinancial.com, "Contract Addresses". Fora: X Layer (sem
        // CoinGecko) e Tron (motor).
        erc20("ethereum", "0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d", "USD1", "World Liberty Financial USD", 18, "usd1-wlfi", stable: true),
        erc20("bnb", "0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d", "USD1", "World Liberty Financial USD", 18, "usd1-wlfi", stable: true),
        spl("USD1ttGY1N17NEEHLmELoaybftRBUSErhqYiQzvEmuB", "USD1", "World Liberty Financial USD", 6, "usd1-wlfi", stable: true),
        // Cronos (CRO), Ethereum. Fonte do emissor: repositorio da Crypto.com
        // (crypto-com/swap-token-list, mainnet.json).
        erc20("ethereum", "0xA0b73E1Ff0B80914AB6fe0444E65848C4C34450b", "CRO", "Cronos", 8, "crypto-com-chain"),
        // Global Dollar (USDG), Ethereum, Arbitrum, X Layer. Fonte do emissor:
        // docs.paxos.com, USDG "Mainnet". Solana fora: Token-2022 com taxa de transferencia
        // e hook configuraveis pelo emissor.
        erc20("ethereum", "0xe343167631d89B6Ffc58B88d6b7fB0228795491D", "USDG", "Global Dollar", 6, "global-dollar", stable: true),
        erc20("arbitrum", "0x004B506865409877C9fA29bfb1ebA929984B9bbC", "USDG", "Global Dollar", 6, "global-dollar", stable: true),
        erc20("xlayer", "0x4ae46a509F6b1D9056937BA4500cb143933D2dc8", "USDG", "Global Dollar", 6, "global-dollar", stable: true),
        // Ethena (ENA), Ethereum, Base, Arbitrum, Optimism, Solana. Fonte do emissor:
        // docs.ethena.fi, "Key Addresses". Fora: BNB Chain, Linea e X Layer (a Ethena
        // lista, o CoinGecko nao).
        erc20("ethereum", "0x57e114B691Db790C35207b2e685D4A43181e6061", "ENA", "Ethena", 18, "ethena"),
        erc20("base", "0x58538e6A46E07434d7E7375Bc268D3cb839C0133", "ENA", "Ethena", 18, "ethena"),
        erc20("arbitrum", "0x58538e6A46E07434d7E7375Bc268D3cb839C0133", "ENA", "Ethena", 18, "ethena"),
        erc20("optimism", "0x58538e6A46E07434d7E7375Bc268D3cb839C0133", "ENA", "Ethena", 18, "ethena"),
        spl("72QvBVwpxqmheEPfaCwWSWqEFsUy3rhWt6JhQBMNTwD1", "ENA", "Ethena", 9, "ethena"),
        // PayPal USD (PYUSD), Ethereum, Arbitrum, Polygon, X Layer. Fonte do emissor:
        // docs.paxos.com, PYUSD "Mainnet". Solana fora: Token-2022 com taxa de
        // transferencia e hook configuraveis pelo emissor.
        erc20("ethereum", "0x6c3ea9036406852006290770BEdFcAbA0e23A0e8", "PYUSD", "PayPal USD", 6, "paypal-usd", stable: true),
        erc20("arbitrum", "0x46850aD61C2B7d64d08c9C754F45254596696984", "PYUSD", "PayPal USD", 6, "paypal-usd", stable: true),
        erc20("polygon", "0x99aF3EeA856556646C98c8B9b2548Fe815240750", "PYUSD", "PayPal USD", 6, "paypal-usd", stable: true),
        erc20("xlayer", "0x87b4a8176B3Df6b71e26CC095edcAf4Db07506B4", "PYUSD", "PayPal USD", 6, "paypal-usd", stable: true),
        // Ondo (ONDO), Ethereum. Fonte do emissor: docs.ondo.foundation/ondo-token.
        erc20("ethereum", "0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3", "ONDO", "Ondo", 18, "ondo-finance"),
        // Tether Gold (XAUT), Ethereum, BNB Chain. Fonte do emissor: tether.to, "Supported
        // Protocols". Na BNB Chain e o XAUt0 da rede USDT0 (no CoinGecko,
        // tether-gold-tokens).
        erc20("ethereum", "0x68749665FF8D2d112Fa859AA293F07A622782F38", "XAUT", "Tether Gold", 6, "tether-gold"),
        erc20("bnb", "0x21cAef8A43163Eea865baeE23b9C2E327696A3bf", "XAUT", "Tether Gold", 6, "tether-gold"),
        // OKB (OKB), Ethereum. Fonte do emissor: repositorio da OKX (okx/xlayer-docs,
        // contratos da rede): o OKB ERC-20 na Ethereum, a mesma moeda que e nativa na X
        // Layer.
        erc20("ethereum", "0x75231F58b43240C9718Dd58B4967c5114342a86c", "OKB", "OKB", 18, "okb"),
        // Ripple USD (RLUSD), Ethereum. Fonte do emissor: docs.ripple.com, "RLUSD token
        // addresses". Base, Optimism e Unichain ficam de fora (a Ripple lista, o CoinGecko
        // nao).
        erc20("ethereum", "0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD", "RLUSD", "Ripple USD", 18, "ripple-usd", stable: true),
        // Aave (AAVE), Ethereum. Fonte do emissor: repositorio da Aave (aave/aave-token).
        erc20("ethereum", "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9", "AAVE", "Aave", 18, "aave"),
        // Mantle (MNT), Ethereum. Fonte do emissor: docs.mantle.xyz, "Tokenomics".
        erc20("ethereum", "0x3c3a81e81dc49A522A592e7622A7E711c06bf354", "MNT", "Mantle", 18, "mantle"),
        // Aster (ASTER), BNB Chain. Fonte do emissor: documentacao da API da Aster
        // (asterdex/api-docs), chainId 56.
        erc20("bnb", "0x000Ae314E2A2172a039B26378814C252734f556A", "ASTER", "Aster", 18, "aster-2"),
        // Sky (SKY), Ethereum. Fonte do emissor: chainlog.sky.money.
        erc20("ethereum", "0x56072C95FAA701256059aa122697B133aDEd9279", "SKY", "Sky", 18, "sky"),
        // Morpho (MORPHO), Ethereum, Base, Arbitrum. Fonte do emissor: docs.morpho.org,
        // "Addresses".
        erc20("ethereum", "0x58D97B57BB95320F9a05dC918Aef65434969c2B2", "MORPHO", "Morpho", 18, "morpho"),
        erc20("base", "0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842", "MORPHO", "Morpho", 18, "morpho"),
        erc20("arbitrum", "0x40BD670A58238e6E230c430BBb5cE6ec0d40df48", "MORPHO", "Morpho", 18, "morpho"),
        // PAX Gold (PAXG), Ethereum. Fonte do emissor: docs.paxos.com, PAXG "Mainnet". O
        // contrato atual nao cobra taxa de transferencia (a simulacao entrega o valor
        // inteiro).
        erc20("ethereum", "0x45804880De22913dAFE09f4980848ECE6EcbAf78", "PAXG", "PAX Gold", 18, "pax-gold"),
        // Pepe (PEPE), Ethereum. Fonte do emissor: pepe.vip.
        erc20("ethereum", "0x6982508145454Ce325dDbE47a25d4ec3d2311933", "PEPE", "Pepe", 18, "pepe"),
        // USDD (USDD), Ethereum, BNB Chain. Fonte do emissor: docs.usdd.io, "Contract
        // Addresses". Fica fora da paridade automatica de 1 dolar da troca. Tron fora
        // (motor).
        erc20("ethereum", "0x4f8e5DE400DE08B164E7421B3EE387f461beCD1A", "USDD", "USDD", 18, "usdd"),
        erc20("bnb", "0x45E51bc23D592EB2DBA86da3985299f7895d66Ba", "USDD", "USDD", 18, "usdd"),
        // Arbitrum (ARB), Ethereum. Fonte do emissor: docs.arbitrum.foundation, "Deployment
        // addresses" (o ARB da ponte na Ethereum).
        erc20("ethereum", "0xB50721BCf8d664c30412Cfbc6cf7a15145234ad1", "ARB", "Arbitrum", 18, "arbitrum"),
        // Bitget Token (BGB), Ethereum. Fonte do emissor: anuncio da Bitget do contrato
        // novo (bitget.com/support/articles/12560603811970).
        erc20("ethereum", "0x54D2252757e1672EEaD234D27B1270728fF90581", "BGB", "Bitget Token", 18, "bitget-token"),
        // Ethena Staked USDe (sUSDe), Ethereum, Base, Arbitrum, Optimism, BNB Chain, X
        // Layer, Linea, Solana. Fonte do emissor: docs.ethena.fi, "Key Addresses". Cota de
        // cofre ERC-4626, sem rebase.
        erc20("ethereum", "0x9D39A5DE30e57443BfF2A8307A4256c8797A3497", "sUSDe", "Ethena Staked USDe", 18, "ethena-staked-usde"),
        erc20("base", "0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2", "sUSDe", "Ethena Staked USDe", 18, "ethena-staked-usde"),
        erc20("arbitrum", "0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2", "sUSDe", "Ethena Staked USDe", 18, "ethena-staked-usde"),
        erc20("optimism", "0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2", "sUSDe", "Ethena Staked USDe", 18, "ethena-staked-usde"),
        erc20("bnb", "0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2", "sUSDe", "Ethena Staked USDe", 18, "ethena-staked-usde"),
        erc20("xlayer", "0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2", "sUSDe", "Ethena Staked USDe", 18, "ethena-staked-usde"),
        erc20("linea", "0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2", "sUSDe", "Ethena Staked USDe", 18, "ethena-staked-usde"),
        spl("Eh6XEPhSwoLv5wFApukmnaVSHQ6sAnoD9BmgmwQoN2sN", "sUSDe", "Ethena Staked USDe", 9, "ethena-staked-usde"),
        // Polygon (POL), Ethereum. Fonte do emissor: polygon.technology, anuncio do POL na
        // Ethereum. O mesmo POL que e nativo na Polygon.
        erc20("ethereum", "0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6", "POL", "Polygon", 18, "polygon-ecosystem-token"),
        // Jito Staked SOL (JitoSOL), Solana. Fonte do emissor: repositorio da Jito
        // (jito-foundation/jito-tip-router, JITOSOL_MINT). Sem rebase: a cota valoriza.
        spl("J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn", "JitoSOL", "Jito Staked SOL", 9, "jito-staked-sol"),
        // PancakeSwap (CAKE), BNB Chain. Fonte do emissor: docs.pancakeswap.finance, "CAKE
        // Tokenomics". `symbol()` devolve "Cake".
        erc20("bnb", "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82", "CAKE", "PancakeSwap", 18, "pancakeswap-token"),
        // Render (RENDER), Solana. Fonte do emissor: know.rendernetwork.com, "Official
        // Links and Channels" (o RENDER da Solana; o RNDR antigo da Ethereum fica de fora).
        spl("rndrizKT3MK1iimdxRdWabcF7Zg7AR5T4nud4EkHBof", "RENDER", "Render", 8, "render-token"),
        // Rocket Pool ETH (rETH), Ethereum. Fonte do emissor: repositorio da Rocket Pool
        // (rocket-pool/RPIPs, RPIP-2). Sem rebase.
        erc20("ethereum", "0xae78736Cd615f374D3085123A210448E74Fc6393", "rETH", "Rocket Pool ETH", 18, "rocket-pool-eth"),
        // Nexo (NEXO), Ethereum. Fonte do emissor: repositorio da Nexo
        // (nexofinance/NEXO-Token).
        erc20("ethereum", "0xB62132e35a6c13ee1EE0f84dC5d40bad8d815206", "NEXO", "Nexo", 18, "nexo"),
        // Aerodrome (AERO), Base. Fonte do emissor: repositorio da Aerodrome
        // (aerodrome-finance/contracts).
        erc20("base", "0x940181a94A35A4569E4529A3CDfB74e38FD98631", "AERO", "Aerodrome", 18, "aerodrome-finance"),
        // Injective (INJ), Ethereum. Fonte do emissor: repositorio da Injective
        // (InjectiveLabs/injective-token-contract).
        erc20("ethereum", "0xe28b3B32B6c345A34Ff64674606124Dd5Aceca30", "INJ", "Injective", 18, "injective-protocol"),
        // GHO (GHO), Ethereum, Base, Arbitrum, Avalanche, Plasma. Fonte do emissor:
        // aave.com/docs/ecosystem/gho, "Deployed Contracts". Stablecoin do protocolo: fica
        // fora da paridade automatica de 1 dolar da troca.
        erc20("ethereum", "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f", "GHO", "GHO", 18, "gho"),
        erc20("base", "0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee", "GHO", "GHO", 18, "gho"),
        erc20("arbitrum", "0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33", "GHO", "GHO", 18, "gho"),
        erc20("avalanche", "0xfc421aD3C883Bf9E7C4f42dE845C4e4405799e73", "GHO", "GHO", 18, "gho"),
        erc20("plasma", "0xb77E872A68C62CfC0dFb02C067Ecc3DA23B4bbf3", "GHO", "GHO", 18, "gho"),
        // ether.fi (ETHFI), Ethereum, Base, Arbitrum. Fonte do emissor: etherfi.gitbook.io,
        // "Deployed Contracts". Optimism fora (sem CoinGecko).
        erc20("ethereum", "0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB", "ETHFI", "ether.fi", 18, "ether-fi"),
        erc20("base", "0x6C240DDA6b5c336DF09A4D011139beAAa1eA2Aa2", "ETHFI", "ether.fi", 18, "ether-fi"),
        erc20("arbitrum", "0x7189fb5B6504bbfF6a852B13B7B82a3c118fDc27", "ETHFI", "ether.fi", 18, "ether-fi"),
        // Pyth Network (PYTH), Solana. Fonte do emissor: repositorio da Pyth
        // (pyth-network/governance, PYTH_TOKEN).
        spl("HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3", "PYTH", "Pyth Network", 6, "pyth-network"),
        // Official Trump (TRUMP), Solana. Fonte do emissor: gettrumpmemes.com.
        spl("6p6xgHyF7AeE6TZkSmFsko444wqoP15icUSqi2jfGiPN", "TRUMP", "Official Trump", 6, "official-trump"),
        // Raydium (RAY), Solana. Fonte do emissor: docs.raydium.io/ray.
        spl("4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R", "RAY", "Raydium", 6, "raydium"),
        // Artificial Superintelligence Alliance (FET), Ethereum. Fonte do emissor:
        // repositorio da Fetch.ai (fetchai/fetch-ethereum-bridge-v1, ERC20Address).
        erc20("ethereum", "0xaea46A60368A7bD060eec7DF8CBa43b7EF41Ad85", "FET", "Artificial Superintelligence Alliance", 18, "fetch-ai"),
        // Curve DAO (CRV), Ethereum, Base, Arbitrum, Optimism, Polygon. Fonte do emissor:
        // docs.curve.finance, "Supported Chains & Assets" (pontes oficiais das L2).
        erc20("ethereum", "0xD533a949740bb3306d119CC777fa900bA034cd52", "CRV", "Curve DAO", 18, "curve-dao-token"),
        erc20("base", "0x8Ee73c484A26e0A5df2Ee2a4960B789967dd0415", "CRV", "Curve DAO", 18, "curve-dao-token"),
        erc20("arbitrum", "0x11cDb42B0EB46D95f990BeDD4695A6e3fA034978", "CRV", "Curve DAO", 18, "curve-dao-token"),
        erc20("optimism", "0x0994206dfE8De6Ec6920FF4D779B0d950605Fb53", "CRV", "Curve DAO", 18, "curve-dao-token"),
        erc20("polygon", "0x172370d5Cd63279eFa6d502DAB29171933a610AF", "CRV", "Curve DAO", 18, "curve-dao-token"),
        // Virtuals Protocol (VIRTUAL), Base. Fonte do emissor: repositorio da Virtuals
        // (Virtual-Protocol/vp-trade-sdk, VIRTUALS_TOKEN_ADDR).
        erc20("base", "0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b", "VIRTUAL", "Virtuals Protocol", 18, "virtual-protocol"),
        // Coinbase Wrapped Staked ETH (cbETH), Ethereum, Base. Fonte do emissor:
        // repositorio da Coinbase (coinbase/agentkit). Sem rebase.
        erc20("ethereum", "0xBe9895146f7AF43049ca1c1AE358B0541Ea49704", "cbETH", "Coinbase Wrapped Staked ETH", 18, "coinbase-wrapped-staked-eth"),
        erc20("base", "0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22", "cbETH", "Coinbase Wrapped Staked ETH", 18, "coinbase-wrapped-staked-eth"),
        // TrueUSD (TUSD), Ethereum, BNB Chain, Avalanche. Fonte do emissor: tusd.io, redes
        // com emissao nativa. Fica fora da paridade automatica de 1 dolar da troca. Tron
        // fora (motor).
        erc20("ethereum", "0x0000000000085d4780B73119b644AE5ecd22b376", "TUSD", "TrueUSD", 18, "true-usd"),
        erc20("bnb", "0x40af3827F39D0EAcBF4A168f8D4ee67c121D11c9", "TUSD", "TrueUSD", 18, "true-usd"),
        erc20("avalanche", "0x1C20E891Bab6b1727d14Da358FAe2984Ed9B59EB", "TUSD", "TrueUSD", 18, "true-usd"),
        // USDtb (USDtb), Ethereum. Fonte do emissor: docs.usdtb.money, "Key Addresses".
        // Solana fora: Token-2022 com taxa, hook e pausa.
        erc20("ethereum", "0xC139190F447e929f090Edeb554D95AbB8b18aC1C", "USDtb", "USDtb", 18, "usdtb", stable: true),
        // Euro Coin (EURC), Ethereum, Base, Avalanche, Plasma, Solana, Stellar. Fonte do
        // emissor: developers.circle.com, "EURC contract addresses". Euro: nao entra como
        // stablecoin de dolar.
        erc20("ethereum", "0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c", "EURC", "Euro Coin", 6, "euro-coin"),
        erc20("base", "0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42", "EURC", "Euro Coin", 6, "euro-coin"),
        erc20("avalanche", "0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD", "EURC", "Euro Coin", 6, "euro-coin"),
        erc20("plasma", "0x3EE196E78d4d4248b849B8E1C7F44C5457FAFD2C", "EURC", "Euro Coin", 6, "euro-coin"),
        spl("HzwqbKZw8HxMN6bF2yFZNrht3c2iXXzpKcFu7uBEDKtr", "EURC", "Euro Coin", 6, "euro-coin"),
        issued("stellar", code: "EURC", issuer: "GDHU6WRG4IEQXM5NZ4BMPKOXHW76MZM4Y2IEMFDVXBSDP6SJY4ITNPP2", "EURC", "Euro Coin", 7, "euro-coin"),
        // Pendle (PENDLE), Ethereum. Fonte do emissor: docs.pendle.finance, "Bridging
        // PENDLE".
        erc20("ethereum", "0x808507121B80c02388fAd14726482e061B8da827", "PENDLE", "Pendle", 18, "pendle"),
        // Lido DAO (LDO), Ethereum. Fonte do emissor: docs.lido.fi/deployed-contracts.
        erc20("ethereum", "0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32", "LDO", "Lido DAO", 18, "lido-dao"),
        // The Graph (GRT), Ethereum, Arbitrum. Fonte do emissor: thegraph.com/docs,
        // "Contracts".
        erc20("ethereum", "0xc944E90C64B2c07662A292be6244BDf05Cda44a7", "GRT", "The Graph", 18, "the-graph"),
        erc20("arbitrum", "0x9623063377AD1B27544C965cCd7342f7EA7e88C7", "GRT", "The Graph", 18, "the-graph"),
        // Gnosis (GNO), Ethereum. Fonte do emissor: docs.gnosischain.com, "GNO".
        erc20("ethereum", "0x6810e776880C02933D47DB1b9fc05908e5386b96", "GNO", "Gnosis", 18, "gnosis"),
        // Jito (JTO), Solana. Fonte do emissor: repositorio da Jito Foundation
        // (jito-foundation/jito-omnidocs, estatuto que define o mint do JTO).
        spl("jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL", "JTO", "Jito", 9, "jito-governance-token"),
        // Starknet (STRK), Ethereum. Fonte do emissor: repositorio da Starknet
        // (starknet-io/starknet-website, anuncio do STRK na Ethereum).
        erc20("ethereum", "0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766", "STRK", "Starknet", 18, "starknet"),
        // Ethereum Name Service (ENS), Ethereum. Fonte do emissor:
        // basics.ensdao.org/ens-token.
        erc20("ethereum", "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72", "ENS", "Ethereum Name Service", 18, "ethereum-name-service"),
        // Maple Finance (SYRUP), Ethereum. Fonte do emissor: repositorio da Maple
        // (maple-labs/maple-docs, enderecos do SYRUP).
        erc20("ethereum", "0x643C4E15d7d62Ad0aBeC4a9BD4b001aA3Ef52d66", "SYRUP", "Maple Finance", 18, "syrup"),
        // EigenCloud (EIGEN), Ethereum. Fonte do emissor: repositorio da EigenLayer
        // (Layr-Labs/eigenlayer-contracts, README).
        erc20("ethereum", "0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83", "EIGEN", "EigenCloud", 18, "eigenlayer"),
        // Trust Wallet (TWT), BNB Chain. Fonte do emissor: repositorio da Trust Wallet
        // (trustwallet/assets, info.json do TWT).
        erc20("bnb", "0x4B0F1812e5Df2A09796481Ff14017e6005508003", "TWT", "Trust Wallet", 18, "trust-wallet-token"),
        // Compound (COMP), Ethereum. Fonte do emissor: docs.compound.finance, "Governance".
        erc20("ethereum", "0xc00e94Cb662C3520282E6f5717214004A7f26888", "COMP", "Compound", 18, "compound-governance-token"),
        // Curve USD (crvUSD), Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain. Fonte
        // do emissor: docs.curve.finance, "Supported Chains & Assets". Fica fora da
        // paridade automatica de 1 dolar da troca.
        erc20("ethereum", "0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E", "crvUSD", "Curve USD", 18, "crvusd"),
        erc20("base", "0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93", "crvUSD", "Curve USD", 18, "crvusd"),
        erc20("arbitrum", "0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5", "crvUSD", "Curve USD", 18, "crvusd"),
        erc20("optimism", "0xC52D7F23a2e460248Db6eE192Cb23dD12bDDCbf6", "crvUSD", "Curve USD", 18, "crvusd"),
        erc20("polygon", "0xc4Ce1D6F5D98D65eE25Cf85e9F2E9DcFEe6Cb5d6", "crvUSD", "Curve USD", 18, "crvusd"),
        erc20("bnb", "0xe2fb3F127f5450DeE44afe054385d74C392BdeF4", "crvUSD", "Curve USD", 18, "crvusd"),
        // Agora Dollar (AUSD), Ethereum, Base, Arbitrum, Polygon, Avalanche. Fonte do
        // emissor: docs.agora.finance, "Contract Deployments". Fora: BNB Chain (o CoinGecko
        // lista, a Agora nao) e Solana (Token-2022 com taxa e hook).
        erc20("ethereum", "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", "AUSD", "Agora Dollar", 6, "agora-dollar", stable: true),
        erc20("base", "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", "AUSD", "Agora Dollar", 6, "agora-dollar", stable: true),
        erc20("arbitrum", "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", "AUSD", "Agora Dollar", 6, "agora-dollar", stable: true),
        erc20("polygon", "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", "AUSD", "Agora Dollar", 6, "agora-dollar", stable: true),
        erc20("avalanche", "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", "AUSD", "Agora Dollar", 6, "agora-dollar", stable: true),
        // Convex Finance (CVX), Ethereum. Fonte do emissor: docs.convexfinance.com,
        // "Contract Addresses".
        erc20("ethereum", "0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B", "CVX", "Convex Finance", 18, "convex-finance"),
        // Immutable (IMX), Ethereum. Fonte do emissor: repositorio da Immutable
        // (immutable/zkevm-bridge-contracts, README).
        erc20("ethereum", "0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF", "IMX", "Immutable", 18, "immutable-x"),
        // Synthetix (SNX), Ethereum. Fonte do emissor: synthetix.io.
        erc20("ethereum", "0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F", "SNX", "Synthetix", 18, "havven"),
        // Basic Attention Token (BAT), Ethereum. Fonte do emissor:
        // basicattentiontoken.org/faq. Solana fora: o BAT de la e da ponte Wormhole.
        erc20("ethereum", "0x0D8775F648430679A709E98d2b0Cb6250d2887EF", "BAT", "Basic Attention Token", 18, "basic-attention-token"),
        // The Sandbox (SAND), Ethereum. Fonte do emissor: repositorio da Sandbox
        // (thesandboxgame/sandbox-smart-contracts, deployments/mainnet/Sand.json).
        erc20("ethereum", "0x3845badAde8e6dFF049820680d1F14bD3903a5d0", "SAND", "The Sandbox", 18, "the-sandbox"),
        // Golem (GLM), Ethereum. Fonte do emissor: golem.network/glm.
        erc20("ethereum", "0x7DD9c5Cba05E151C895FDe1CF355C9A1D5DA6429", "GLM", "Golem", 18, "golem"),
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

    private static func issued(
        _ chain: String, code: String, issuer: String, _ symbol: String, _ name: String, _ decimals: Int, _ gecko: String, stable: Bool = false
    ) -> Asset {
        Asset(chainID: chain, kind: .issued(code: code, issuer: issuer), symbol: symbol, name: name, decimals: decimals, coingeckoID: gecko, isStablecoin: stable)
    }
}
