import EscaliburChains
import Foundation

/// Todos os provedores de leitura e transmissao, por rede, na ordem de preferencia.
///
/// A lista e compilada e travada em `hosts.lock` pelo verificar.sh: nenhum host novo
/// entra no app sem aparecer no diff. Provedores confirmados ao vivo em 2026-09-25
/// (docs/blockchain.md §2). Quando o relay proprio existir, ele entra na frente de
/// cada lista, e estes continuam como o modo "direto aos provedores".
public enum Endpoints {
    static func url(_ text: String) -> URL { URL(string: text)! }  // swiftlint:disable:this force_unwrapping

    public static let evm: [String: [ProviderPool.Provider]] = [
        "ethereum": [
            .init(name: "publicnode", baseURL: url("https://ethereum-rpc.publicnode.com")),
            .init(name: "cloudflare", baseURL: url("https://cloudflare-eth.com")),
            .init(name: "drpc", baseURL: url("https://eth.drpc.org")),
            .init(name: "1rpc", baseURL: url("https://1rpc.io/eth")),
        ],
        "arbitrum": [
            .init(name: "arbitrum", baseURL: url("https://arb1.arbitrum.io/rpc")),
            .init(name: "publicnode", baseURL: url("https://arbitrum-one-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://arbitrum.drpc.org")),
        ],
        "base": [
            .init(name: "base", baseURL: url("https://mainnet.base.org")),
            .init(name: "publicnode", baseURL: url("https://base-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://base.drpc.org")),
        ],
        "optimism": [
            .init(name: "optimism", baseURL: url("https://mainnet.optimism.io")),
            .init(name: "publicnode", baseURL: url("https://optimism-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://optimism.drpc.org")),
        ],
        "polygon": [
            .init(name: "publicnode", baseURL: url("https://polygon-bor-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://polygon.drpc.org")),
            .init(name: "1rpc", baseURL: url("https://1rpc.io/matic")),
        ],
        "bnb": [
            .init(name: "bnbchain", baseURL: url("https://bsc-dataseed.bnbchain.org")),
            .init(name: "publicnode", baseURL: url("https://bsc-rpc.publicnode.com")),
            .init(name: "1rpc", baseURL: url("https://1rpc.io/bnb")),
        ],
        "avalanche": [
            .init(name: "avax", baseURL: url("https://api.avax.network/ext/bc/C/rpc")),
            .init(name: "publicnode", baseURL: url("https://avalanche-c-chain-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://avalanche.drpc.org")),
        ],
        // Segunda leva, conferida em 26/09/2026: em cada RPC, sem chave, `eth_chainId`,
        // `eth_getTransactionCount` pending, `eth_feeHistory`, `eth_estimateGas`,
        // `eth_getCode` e `eth_call`. Tres operadores diferentes por rede; o segundo
        // endpoint oficial da mesma empresa (xlayerrpc.okx.com) fica de fora, porque o
        // consenso de dois provedores tem de ser de dois operadores.
        // Plasma: o RPC da Plasma (docs.plasma.org, "Connect to Plasma") e os gateways
        // publicos da thirdweb e da Tenderly (parceiros em "RPC Providers"). O dRPC so
        // atende a Plasma no plano pago.
        "plasma": [
            .init(name: "plasma", baseURL: url("https://rpc.plasma.to")),
            .init(name: "thirdweb", baseURL: url("https://9745.rpc.thirdweb.com")),
            .init(name: "tenderly", baseURL: url("https://plasma.gateway.tenderly.co")),
        ],
        // X Layer: o RPC da OKX (web3.okx.com, "RPC endpoints", 100 req/s por IP), dRPC e
        // thirdweb. A PublicNode nao atende a X Layer.
        "xlayer": [
            .init(name: "okx", baseURL: url("https://rpc.xlayer.tech")),
            .init(name: "drpc", baseURL: url("https://xlayer.drpc.org")),
            .init(name: "thirdweb", baseURL: url("https://196.rpc.thirdweb.com")),
        ],
        "linea": [
            .init(name: "linea", baseURL: url("https://rpc.linea.build")),
            .init(name: "publicnode", baseURL: url("https://linea-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://linea.drpc.org")),
        ],
        // Unichain: o RPC oficial vai por ultimo. Atras dele ha nos com filas diferentes, e
        // o nonce `pending` de uma conta parada saiu milhares abaixo do `latest` em
        // 26/09/2026; na frente, o consenso de nonce recusaria o plano toda vez.
        "unichain": [
            .init(name: "publicnode", baseURL: url("https://unichain-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://unichain.drpc.org")),
            .init(name: "unichain", baseURL: url("https://mainnet.unichain.org")),
        ],
        "sonic": [
            .init(name: "soniclabs", baseURL: url("https://rpc.soniclabs.com")),
            .init(name: "publicnode", baseURL: url("https://sonic-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://sonic.drpc.org")),
        ],
        // Celo: forno da cLabs (docs.celo.org, "Network Information"), PublicNode e
        // thirdweb. O dRPC da Celo recusa `eth_blockNumber` e o nonce sem chave.
        "celo": [
            .init(name: "forno", baseURL: url("https://forno.celo.org")),
            .init(name: "publicnode", baseURL: url("https://celo-rpc.publicnode.com")),
            .init(name: "thirdweb", baseURL: url("https://42220.rpc.thirdweb.com")),
        ],
    ]

    /// API no estilo Esplora (mempool.space e forks).
    public static let esplora: [String: [ProviderPool.Provider]] = [
        "bitcoin": [
            .init(name: "mempool", baseURL: url("https://mempool.space/api")),
            .init(name: "blockstream", baseURL: url("https://blockstream.info/api")),
            .init(name: "emzy", baseURL: url("https://mempool.emzy.de/api")),
        ],
        "litecoin": [
            .init(name: "litecoinspace", baseURL: url("https://litecoinspace.org/api")),
        ],
    ]

    /// Litecoin fora do Esplora: segunda e terceira fonte de taxa, rotas extras de
    /// transmissao e contingencia de leitura (so ha um Esplora publico de LTC).
    public static let litecoinExtra: [ProviderPool.Provider] = [
        .init(name: "blockcypher", baseURL: url("https://api.blockcypher.com/v1/ltc/main")),
        .init(name: "blockchair", baseURL: url("https://api.blockchair.com/litecoin")),
    ]

    public static let dogecoin: [ProviderPool.Provider] = [
        .init(name: "blockcypher", baseURL: url("https://api.blockcypher.com/v1/doge/main")),
        .init(name: "blockchair", baseURL: url("https://api.blockchair.com/dogecoin")),
    ]

    public static let solana: [ProviderPool.Provider] = [
        .init(name: "publicnode", baseURL: url("https://solana-rpc.publicnode.com")),
        .init(name: "solana", baseURL: url("https://api.mainnet.solana.com")),
        .init(name: "tatum", baseURL: url("https://solana-mainnet.gateway.tatum.io")),
    ]

    /// Jupiter Swap API v2, so leitura de cotacao e instrucoes: a transacao e
    /// montada e conferida no app (docs/seguranca.md §4.6). Sem chave: 30
    /// requisicoes por minuto por IP (confirmado em 26/09/2026). O `lite-api` esta
    /// sendo aposentado em favor do acesso sem chave a este host.
    public static let jupiterSwap = url("https://api.jup.ag/swap/v2")

    public static let xrpl: [ProviderPool.Provider] = [
        .init(name: "xrplcluster", baseURL: url("https://xrplcluster.com")),
        .init(name: "ripple-s2", baseURL: url("https://s2.ripple.com:51234")),
        .init(name: "ripple-s1", baseURL: url("https://s1.ripple.com:51234")),
    ]

    public static let stellar: [ProviderPool.Provider] = [
        .init(name: "sdf", baseURL: url("https://horizon.stellar.org")),
        .init(name: "lobstr", baseURL: url("https://horizon.stellar.lobstr.co")),
    ]

    public static let tron: [ProviderPool.Provider] = [
        .init(name: "trongrid", baseURL: url("https://api.trongrid.io")),
        .init(name: "publicnode", baseURL: url("https://tron-rpc.publicnode.com")),
    ]

    public static let ton: [ProviderPool.Provider] = [
        .init(name: "tonapi", baseURL: url("https://tonapi.io/v2")),
        .init(name: "toncenter", baseURL: url("https://toncenter.com/api/v3")),
    ]

    // MARK: Leitores de estado, transmissao e historico

    /// Transmissao com protecao de MEV na Ethereum, so quando o chamador pede (troca).
    /// A transacao vai direto a construtores de bloco, sem passar pelo mempool publico,
    /// onde um robo a veria e faria sanduiche. Fontes: docs.flashbots.net ("Flashbots
    /// Protect RPC", `https://rpc.flashbots.net`) e docs.cow.fi ("MEV Blocker",
    /// `https://rpc.mevblocker.io`); `eth_chainId` = 0x1 nos dois, conferido em 25/09/2026.
    public static let ethereumPrivateRelays: [ProviderPool.Provider] = [
        .init(name: "flashbots", baseURL: url("https://rpc.flashbots.net")),
        .init(name: "mevblocker", baseURL: url("https://rpc.mevblocker.io")),
    ]

    /// Indexadores de historico EVM sem chave. RPC nao da historico (docs/blockchain.md
    /// §2.2). Blockscout (codigo aberto, instancias da equipe Blockscout e, na OP, da OP
    /// Labs: `optimism.blockscout.com` redireciona para `explorer.optimism.io`, e o
    /// cliente nao segue redirecionamento). Avalanche: Routescan, API no formato
    /// Etherscan, sem chave (`api.routescan.io/v2/network/mainnet/evm/43114/etherscan`).
    /// BNB Chain: nenhum indexador publico sem chave (BscScan e Etherscan v2 exigem
    /// plano pago para a rede 56, conferido em 25/09/2026); fica sem historico ate o relay.
    /// Todos conferidos ao vivo em 25/09/2026.
    ///
    /// Segunda leva, conferida em 26/09/2026 (`/addresses/{a}/transactions` e
    /// `/token-transfers` sem chave; os hosts vem do registro chains.blockscout.com):
    /// Linea pela API do Blockscout em `api-explorer.linea.build` (o explorer.linea.build
    /// so serve a pagina); Unichain e Celo pela equipe Blockscout; Plasma pelo Routescan
    /// (`txlist` e `tokentx` da rede 9745). X Layer e Sonic nao tem indexador sem chave
    /// (OKLink e Etherscan v2 pedem chave; nem Blockscout nem Routescan atendem) e ficam
    /// sem historico, como a BNB Chain.
    public static let evmHistory: [String: [ProviderPool.Provider]] = [
        "ethereum": [.init(name: "blockscout", baseURL: url("https://eth.blockscout.com/api/v2"))],
        "base": [.init(name: "blockscout", baseURL: url("https://base.blockscout.com/api/v2"))],
        "optimism": [.init(name: "blockscout", baseURL: url("https://explorer.optimism.io/api/v2"))],
        "arbitrum": [.init(name: "blockscout", baseURL: url("https://arbitrum.blockscout.com/api/v2"))],
        "polygon": [.init(name: "blockscout", baseURL: url("https://polygon.blockscout.com/api/v2"))],
        "avalanche": [.init(name: "routescan", baseURL: url("https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api"))],
        "plasma": [.init(name: "routescan", baseURL: url("https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan/api"))],
        "linea": [.init(name: "blockscout", baseURL: url("https://api-explorer.linea.build/api/v2"))],
        "unichain": [.init(name: "blockscout", baseURL: url("https://unichain.blockscout.com/api/v2"))],
        "celo": [.init(name: "blockscout", baseURL: url("https://celo.blockscout.com/api/v2"))],
    ]

    /// Reservas de RPC EVM para os leitores de estado, somadas as listas de `evm`. BNB
    /// Chain: o `1rpc.io` gratuito esgota a cota diaria, e o consenso de dois provedores
    /// ficava com um so. Fonte: docs.bnbchain.org, "BSC JSON-RPC Endpoint" (data seeds
    /// publicos, operados pela Defibit e pela Ninicoin, independentes da bnbchain.org);
    /// `eth_chainId` 0x38, nonce `pending` e `eth_feeHistory` conferidos em 25/09/2026.
    public static let evmContingency: [String: [ProviderPool.Provider]] = [
        "bnb": [
            .init(name: "defibit", baseURL: url("https://bsc-dataseed1.defibit.io")),
            .init(name: "ninicoin", baseURL: url("https://bsc-dataseed1.ninicoin.io")),
        ],
    ]

    /// Terceiro no da Tron para os leitores de estado: com a TronGrid sem chave
    /// devolvendo 429 acima de ~2 requisicoes por segundo, o consenso de dois provedores
    /// precisa de um reserva. Fonte: docs/blockchain.md §2.6 ("`api.tronstack.io`",
    /// conferido ao vivo); em 25/09/2026 responde sem chave a `/wallet/*` e
    /// `/walletsolidity/*`, e recusa rajada com 503 (o leitor espaca as chamadas).
    public static let tronContingency: [ProviderPool.Provider] = [
        .init(name: "tronstack", baseURL: url("https://api.tronstack.io")),
    ]

    /// API JSON-RPC v2 da toncenter: aceita o endereco no corpo do POST (estado da conta,
    /// get-methods, estimativa de taxa, transmissao), enquanto a tonapi e a v3 da
    /// toncenter pedem o endereco no caminho ou na query (docs/seguranca.md §5.3). Sem
    /// chave o limite e de 1 requisicao por segundo; o leitor espaca as chamadas.
    /// Conferido em 25/09/2026.
    public static let tonJSONRPC: [ProviderPool.Provider] = [
        .init(name: "toncenter-v2", baseURL: url("https://toncenter.com/api/v2/jsonRPC")),
    ]

    /// Agregadores de troca sem API key e a CoW (docs/blockchain.md 3.1), conferidos ao
    /// vivo em 26/09/2026. Provedores com key (1inch, 0x, OKX, Uniswap) entram pelo relay.
    public static let trade: [String: ProviderPool.Provider] = [
        "velora": .init(name: "velora", baseURL: url("https://api.velora.xyz")),
        "kyberSwap": .init(name: "kyberSwap", baseURL: url("https://aggregator-api.kyberswap.com")),
        "lifi": .init(name: "lifi", baseURL: url("https://li.quest/v1")),
        "de1": .init(name: "de1", baseURL: url("https://open-api.de1.exchange/v4")),
        "cow": .init(name: "cow", baseURL: url("https://api.cow.fi")),
    ]

    /// RPCs que respondem `eth_simulateV1` com `traceTransfers` (conferido ao vivo em
    /// 26/09/2026). A troca exige duas fontes (docs/seguranca.md 4.9). Avalanche: nenhum
    /// RPC publico implementa o metodo hoje (api.avax.network, publicnode e drpc devolvem
    /// "method does not exist"), entao troca na Avalanche fica bloqueada ate o relay.
    ///
    /// Segunda leva (26/09/2026, envio nativo e `transfer` de USDC simulados, com o log
    /// sintetico de 0xEeee e o `Transfer` do token): Plasma pelo RPC da Plasma e pela
    /// thirdweb (a Tenderly devolve 429 no metodo); Linea e Unichain pela PublicNode e
    /// pelo dRPC (o RPC oficial recusa o metodo); Sonic nos tres. Sem troca: X Layer
    /// (nenhum agregador da lista cota a rede: KyberSwap, Velora e De¹ nao atendem, e a
    /// LI.FI nao devolve rota) e Celo (o CELO nativo e tambem ERC-20, e nenhum agregador
    /// da lista cota a moeda nativa pelo endereco 0xEeee ou 0x0; so ficaria troca entre
    /// tokens).
    public static let tradeSimulation: [String: [ProviderPool.Provider]] = [
        "ethereum": [
            .init(name: "publicnode", baseURL: url("https://ethereum-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://eth.drpc.org")),
            .init(name: "1rpc", baseURL: url("https://1rpc.io/eth")),
        ],
        "arbitrum": [
            .init(name: "publicnode", baseURL: url("https://arbitrum-one-rpc.publicnode.com")),
            .init(name: "1rpc", baseURL: url("https://1rpc.io/arb")),
            .init(name: "meowrpc", baseURL: url("https://arbitrum.meowrpc.com")),
        ],
        "base": [
            .init(name: "base", baseURL: url("https://mainnet.base.org")),
            .init(name: "publicnode", baseURL: url("https://base-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://base.drpc.org")),
        ],
        "optimism": [
            .init(name: "optimism", baseURL: url("https://mainnet.optimism.io")),
            .init(name: "publicnode", baseURL: url("https://optimism-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://optimism.drpc.org")),
        ],
        "polygon": [
            .init(name: "publicnode", baseURL: url("https://polygon-bor-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://polygon.drpc.org")),
        ],
        "bnb": [
            .init(name: "bnbchain", baseURL: url("https://bsc-dataseed.bnbchain.org")),
            .init(name: "publicnode", baseURL: url("https://bsc-rpc.publicnode.com")),
            .init(name: "1rpc", baseURL: url("https://1rpc.io/bnb")),
        ],
        "avalanche": [],
        "plasma": [
            .init(name: "plasma", baseURL: url("https://rpc.plasma.to")),
            .init(name: "thirdweb", baseURL: url("https://9745.rpc.thirdweb.com")),
        ],
        "linea": [
            .init(name: "publicnode", baseURL: url("https://linea-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://linea.drpc.org")),
        ],
        "unichain": [
            .init(name: "publicnode", baseURL: url("https://unichain-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://unichain.drpc.org")),
        ],
        "sonic": [
            .init(name: "soniclabs", baseURL: url("https://rpc.soniclabs.com")),
            .init(name: "publicnode", baseURL: url("https://sonic-rpc.publicnode.com")),
            .init(name: "drpc", baseURL: url("https://sonic.drpc.org")),
        ],
    ]
}
