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

    /// Litecoin e Dogecoin alem do Esplora, conferidos ao vivo em 04/10/2026, sem chave:
    /// - Blockbook da Atomic Wallet (`litecoin.atomicwallet.io`, `dogecoin.atomicwallet.io`,
    ///   "indexer for AtomicWallet, used with Trezor's consent"): status, endereco, moedas,
    ///   transacao com hex, historico, `estimatefee` e `sendtx`, todos em menos de 1 s;
    /// - Bitcore da BitPay (`api.bitcore.io`): moedas, saldo, altura, taxa e transmissao;
    ///   sem transacao crua (as moedas dele sao conferidas pelo hex de outro provedor);
    /// - Blockcypher e Blockchair por ultimo: cortam por IP (429 "Limits reached." e 430
    ///   "IP temporary blacklisted" em 04/10/2026).
    /// Ficaram de fora: os Blockbook da Trezor (`ltc1`/`doge1.trezor.io` respondem 403 a
    /// apps, e `litecoinblockexplorer.net`, que e da Trezor, pede "do not use for any other
    /// purpose"); a SoChain (API v2 desligada, v3 com chave); o gateway da Tatum (5
    /// requisicoes por minuto sem chave); a Bitaps (timeout de 12 s no endereco); o
    /// cryptoID (Cloudflare e chave).
    public static let litecoinExtra: [ProviderPool.Provider] = [
        .init(name: "bitcore", baseURL: url("https://api.bitcore.io/api/LTC/mainnet")),
        .init(name: "blockcypher", baseURL: url("https://api.blockcypher.com/v1/ltc/main")),
        .init(name: "blockchair", baseURL: url("https://api.blockchair.com/litecoin")),
    ]

    /// O Blockbook vai na frente do litecoinspace: os dois repartem os enderecos de cada
    /// leitura, e o litecoinspace ficou fora do ar (timeout de 15 s) em 04/10/2026.
    public static let litecoinBlockbook: [ProviderPool.Provider] = [
        .init(name: "atomic", baseURL: url("https://litecoin.atomicwallet.io/api/v2")),
    ]

    public static let dogecoin: [ProviderPool.Provider] = [
        .init(name: "atomic", baseURL: url("https://dogecoin.atomicwallet.io/api/v2")),
        .init(name: "bitcore", baseURL: url("https://api.bitcore.io/api/DOGE/mainnet")),
        .init(name: "blockcypher", baseURL: url("https://api.blockcypher.com/v1/doge/main")),
        .init(name: "blockchair", baseURL: url("https://api.blockchair.com/dogecoin")),
    ]

    /// Intervalo minimo entre requisicoes por host nas redes UTXO, para o processo
    /// inteiro (`HostPacer`). Blockcypher sem chave: 3 por segundo; Blockchair sem chave:
    /// 30 por minuto. Os outros nao publicam limite; um respiro curto evita rajada.
    public static let utxoPacing: [String: TimeInterval] = [
        "api.blockcypher.com": 0.4,
        "api.blockchair.com": 2.0,
        "api.bitcore.io": 0.15,
        "litecoin.atomicwallet.io": 0.1,
        "dogecoin.atomicwallet.io": 0.1,
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

    /// Sui pelo gRPC-Web (`sui.rpc.v2`), sem chave, tres operadores com no proprio:
    /// Sui Foundation (no publico, "limites estritos", docs.sui.io "RPC and Data
    /// Providers"), Suiscan (Blockberry, atras da Cloudflare) e NodeInfra (Caddy numa
    /// maquina propria). Conferido em 27/09/2026 nos tres: `GetServiceInfo` com o
    /// `chain_id` da rede principal e versoes de build e checkpoint mais antigo
    /// diferentes, `GetBalance`, `ListOwnedObjects`, `GetEpoch`, `SimulateTransaction`,
    /// `BatchGetTransactions` e `ListTransactions`, tambem em HTTP/1.1. O JSON-RPC ficou
    /// de fora: desligado nos nos da Sui Foundation desde 27/07/2026, com o codigo removido
    /// em meados de outubro de 2026. PublicNode e BlockPI so atendem gRPC nativo ou pedem
    /// chave; os outros da lista oficial pedem chave.
    public static let sui: [ProviderPool.Provider] = [
        .init(name: "suifoundation", baseURL: url("https://fullnode.mainnet.sui.io")),
        .init(name: "suiscan", baseURL: url("https://rpc-mainnet.suiscan.xyz")),
        .init(name: "nodeinfra", baseURL: url("https://sui-mainnet.nodeinfra.com")),
    ]

    /// GraphQL da Sui Foundation, so para o historico: o unico indexador sem chave com o
    /// historico inteiro (os nos gRPC guardam cerca de duas semanas). Conferido em
    /// 27/09/2026; o endereco vai nas variaveis do corpo, nunca na URL.
    public static let suiGraphQL = url("https://graphql.mainnet.sui.io/graphql")

    /// Cardano, duas fontes independentes e sem chave, conferidas em 27/09/2026:
    /// - Koios (`api.koios.rest`), a API comunitaria da Cardano Community Guild, camada
    ///   publica sem chave (5.000 requisicoes por dia por IP, koios.rest "Pricing");
    /// - o backend da Yoroi, da Emurgo (`api.yoroiwallet.com` para moedas, ponta,
    ///   transmissao e estado; `zero.yoroiwallet.com` para os parametros de protocolo), o
    ///   mesmo que os apps da Yoroi usam, sem chave e sem documentacao publica de limite.
    /// Blockfrost, Maestro, Cardanoscan, NOWNodes e GetBlock pedem chave. As duas fontes
    /// deram as mesmas moedas, a mesma ponta e os mesmos parametros (44, 155.381, 4.310,
    /// 16.384) no mesmo endereco. O endereco vai no corpo do POST, nunca na URL.
    public static let cardanoKoios = url("https://api.koios.rest/api/v1")
    public static let cardanoYoroi = url("https://api.yoroiwallet.com/api")
    public static let cardanoYoroiZero = url("https://zero.yoroiwallet.com")

    /// Polkadot Asset Hub, onde o DOT mora desde a migracao de 4/11/2025. JSON-RPC por
    /// POST, sem chave, quatro operadores independentes com no proprio: Parity (o RPC
    /// oficial), LuckyFriday, Dwellir e OnFinality (camada publica). Conferido em
    /// 28/09/2026 nos quatro, no mesmo bloco finalizado: genese da Asset Hub, runtime
    /// `statemint` 2005000 com `transactionVersion` 15, `System.Account` e a taxa
    /// (`TransactionPaymentApi_query_info`) iguais. Rotko e Stakeworld tambem respondem,
    /// e ficam de fora para a lista nao crescer sem necessidade.
    public static let polkadot: [ProviderPool.Provider] = [
        .init(name: "parity", baseURL: url("https://polkadot-asset-hub-rpc.polkadot.io")),
        .init(name: "luckyfriday", baseURL: url("https://rpc-asset-hub-polkadot.luckyfriday.io")),
        .init(name: "dwellir", baseURL: url("https://asset-hub-polkadot-rpc.n.dwellir.com")),
        .init(name: "onfinality", baseURL: url("https://statemint.api.onfinality.io/public")),
    ]

    /// Sidecar publico da Parity para a Asset Hub, so para o acompanhamento: diz se a
    /// extrinsic que o leitor achou num bloco finalizado deu certo (`success`), o que o
    /// JSON-RPC so diria decodificando os eventos com os metadados inteiros. A URL leva
    /// so o numero do bloco. Conferido em 28/09/2026.
    public static let polkadotSidecar = url("https://polkadot-asset-hub-public-sidecar.parity-chains.parity.io")

    /// Historico da Polkadot Asset Hub: o indexador SubQuery da Nova Wallet, o que o app
    /// dela usa, GraphQL sem chave com o endereco nas variaveis do corpo. O Subscan passou
    /// a exigir chave (403 sem ela, 28/09/2026); nenhum outro indexador sem chave foi
    /// achado.
    public static let polkadotHistory = url("https://subquery-history-polkadot-ah-prod.novasama-tech.org")

    /// NEAR: JSON-RPC por POST, sem chave, quatro operadores com no proprio (a chave de
    /// no do `status` e diferente em cada um): FastNEAR (camada gratuita), dRPC, Shitzu e
    /// Intear (sem chave cada resposta espera 1 s). Conferido em 28/09/2026 nos quatro:
    /// `chain_id` mainnet, a mesma genese, `view_account`, `view_access_key`, `gas_price`,
    /// `EXPERIMENTAL_protocol_config` e `block` por altura iguais no mesmo bloco, e o
    /// `send_tx` recusando assinatura invalida. O RPC oficial (`rpc.mainnet.near.org`) foi
    /// descontinuado e demorou de 3 a 26 s; o da Tatum sem chave aceita 5 chamadas por
    /// minuto; Lava, BlockPI, Ankr e 1RPC pedem chave, cairam ou nao tem os metodos.
    public static let near: [ProviderPool.Provider] = [
        .init(name: "fastnear", baseURL: url("https://free.rpc.fastnear.com")),
        .init(name: "drpc", baseURL: url("https://near.drpc.org")),
        .init(name: "shitzu", baseURL: url("https://rpc.shitzuapes.xyz")),
        .init(name: "intear", baseURL: url("https://rpc.intea.rs")),
    ]

    /// Historico da NEAR: a API de transacoes da FastNEAR, sem chave, com a conta no corpo
    /// do POST (`/v0/account`, as ultimas 200 transacoes da conta; `/v0/transactions`, ate
    /// 20 por vez com recibos e resultados). O RPC nao lista transacoes por conta, e o
    /// NearBlocks devolve valores como numero de ponto flutuante. Conferido em 28/09/2026.
    public static let nearHistory = url("https://tx.main.fastnear.com")

    /// Aptos: a API REST de fullnode (`/v1`) de tres operadores independentes, sem chave,
    /// conferidos em 28/09/2026: a PublicNode (Allnodes, no podado em 100 milhoes de
    /// versoes), a Sentio (no de arquivo, versao mais antiga 0) e a Aptos Labs (podado em
    /// 150 milhoes). Nos tres, `chain_id` 1, views numa versao fixa do ledger, simulacao e
    /// transmissao em BCS. A Aptos Labs vai por ultimo: sem chave ela limita a 40.000
    /// unidades de computo a cada 5 minutos por IP, e o historico usa o indexador dela.
    /// Fora: o 1RPC (a origem nao e publicada, e o erro de versao podada aponta o arquivo
    /// da Aptos Labs, entao nao conta como operador independente dela), Ankr, dRPC,
    /// NodeReal, Nodit, BlockPI e GetBlock (pedem chave ou plano pago), Blast (encerrado) e
    /// OnFinality (recusa por limite na segunda requisicao).
    public static let aptos: [ProviderPool.Provider] = [
        .init(name: "publicnode", baseURL: url("https://aptos-rest.publicnode.com/v1")),
        .init(name: "sentio", baseURL: url("https://rpc.sentio.xyz/aptos/v1")),
        .init(name: "aptoslabs", baseURL: url("https://api.mainnet.aptoslabs.com/v1")),
    ]

    /// Indexador GraphQL da Aptos Labs, o unico sem chave com o historico de transferencias
    /// de uma conta (a API do fullnode so lista o que a conta enviou). Informativo: nada
    /// dali entra num plano.
    public static let aptosIndexer = url("https://api.mainnet.aptoslabs.com/v1/graphql")

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

    /// Quais ERC-20 uma conta tem, sem chave (`TokenIndex`). As mesmas instancias do
    /// Blockscout do historico e, na Avalanche e na Plasma, a API propria do Routescan.
    /// Conferido ao vivo em 04/10/2026 com a conta publica de teste do BIP-39: `200` e a
    /// lista de tokens em todas (de 0 a 50 itens, a maioria isca de golpe). BNB Chain, X
    /// Layer e Sonic ficam de fora: nenhum indexador sem chave atende (Blockscout e
    /// Routescan respondem 404 e "chain not supported"; Ankr pede chave).
    public static let evmTokenIndex: [String: ProviderPool.Provider] = [
        "ethereum": .init(name: "blockscout", baseURL: url("https://eth.blockscout.com/api/v2")),
        "base": .init(name: "blockscout", baseURL: url("https://base.blockscout.com/api/v2")),
        "optimism": .init(name: "blockscout", baseURL: url("https://explorer.optimism.io/api/v2")),
        "arbitrum": .init(name: "blockscout", baseURL: url("https://arbitrum.blockscout.com/api/v2")),
        "polygon": .init(name: "blockscout", baseURL: url("https://polygon.blockscout.com/api/v2")),
        "linea": .init(name: "blockscout", baseURL: url("https://api-explorer.linea.build/api/v2")),
        "unichain": .init(name: "blockscout", baseURL: url("https://unichain.blockscout.com/api/v2")),
        "celo": .init(name: "blockscout", baseURL: url("https://celo.blockscout.com/api/v2")),
        "avalanche": .init(name: "routescan", baseURL: url("https://api.routescan.io/v2/network/mainnet/evm/43114")),
        "plasma": .init(name: "routescan", baseURL: url("https://api.routescan.io/v2/network/mainnet/evm/9745")),
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
