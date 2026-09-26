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

    public static let dogecoin: [ProviderPool.Provider] = [
        .init(name: "blockcypher", baseURL: url("https://api.blockcypher.com/v1/doge/main")),
        .init(name: "blockchair", baseURL: url("https://api.blockchair.com/dogecoin")),
    ]

    public static let solana: [ProviderPool.Provider] = [
        .init(name: "publicnode", baseURL: url("https://solana-rpc.publicnode.com")),
        .init(name: "solana", baseURL: url("https://api.mainnet.solana.com")),
        .init(name: "tatum", baseURL: url("https://solana-mainnet.gateway.tatum.io")),
    ]

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
