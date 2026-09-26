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
    public static let evmHistory: [String: [ProviderPool.Provider]] = [
        "ethereum": [.init(name: "blockscout", baseURL: url("https://eth.blockscout.com/api/v2"))],
        "base": [.init(name: "blockscout", baseURL: url("https://base.blockscout.com/api/v2"))],
        "optimism": [.init(name: "blockscout", baseURL: url("https://explorer.optimism.io/api/v2"))],
        "arbitrum": [.init(name: "blockscout", baseURL: url("https://arbitrum.blockscout.com/api/v2"))],
        "polygon": [.init(name: "blockscout", baseURL: url("https://polygon.blockscout.com/api/v2"))],
        "avalanche": [.init(name: "routescan", baseURL: url("https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api"))],
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
    ]
}
