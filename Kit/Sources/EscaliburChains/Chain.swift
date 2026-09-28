import EscaliburCore
import Foundation

/// A familia de uma rede: decide curva, formato de endereco e de transacao.
public enum ChainFamily: String, Codable, Sendable, CaseIterable {
    case utxo      // Bitcoin, Litecoin, Dogecoin
    case evm       // Ethereum e compativeis
    case solana
    case xrpl
    case stellar
    case tron
    case ton
    case sui
    case cardano
    case polkadot

    public var curve: Curve {
        switch self {
        case .utxo, .evm, .xrpl, .tron: return .secp256k1
        case .solana, .stellar, .ton: return .ed25519
        case .sui: return .ed25519
        // Cardano: a curva e a mesma, a derivacao nao (BIP32-Ed25519, chave mestra Icarus).
        case .cardano: return .ed25519
        // Polkadot: Ed25519 por SLIP-10, como a Trust Wallet. O sr25519 padrao das
        // carteiras do ecossistema nao tem implementacao auditada vendorizada aqui.
        case .polkadot: return .ed25519
        }
    }
}

/// Uma rede suportada. Tudo aqui e dado publico e fixo no codigo: nenhuma rede e
/// adicionada por resposta de servidor, porque uma rede injetada com chainId trocado
/// e o jeito mais simples de fazer alguem assinar para a rede errada.
public struct Chain: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let family: ChainFamily
    /// Numero SLIP-44 da moeda nativa.
    public let coinType: UInt32
    public let nativeSymbol: String
    public let nativeName: String
    public let nativeDecimals: Int
    /// Identificador da moeda nativa no CoinGecko, para preco e logo.
    public let coingeckoID: String
    /// chainId EIP-155, so para EVM.
    public let evmChainID: UInt64?
    /// Explorador de blocos, com `{tx}` e `{address}` no lugar dos valores.
    public let explorerTx: String
    public let explorerAddress: String
    public let explorerName: String
    /// Tempo tipico ate a confirmacao que a interface anuncia, em segundos.
    public let typicalConfirmationSeconds: Int
    /// A rede exige ou aceita um identificador de destino alem do endereco.
    public let destinationTag: DestinationTagKind

    public enum DestinationTagKind: String, Codable, Sendable {
        case none
        /// XRP Ledger: inteiro de 32 bits.
        case xrplTag
        /// Stellar: memo de texto (28 bytes), id (64 bits) ou hash.
        case stellarMemo
        /// TON: comentario de texto na mensagem.
        case tonComment
    }

    public func explorerURL(tx hash: String) -> URL? {
        URL(string: explorerTx.replacingOccurrences(of: "{tx}", with: hash))
    }

    public func explorerURL(address: String) -> URL? {
        URL(string: explorerAddress.replacingOccurrences(of: "{address}", with: address))
    }
}

public extension Chain {
    static let bitcoin = Chain(
        id: "bitcoin", name: "Bitcoin", family: .utxo, coinType: 0,
        nativeSymbol: "BTC", nativeName: "Bitcoin", nativeDecimals: 8, coingeckoID: "bitcoin",
        evmChainID: nil,
        explorerTx: "https://mempool.space/tx/{tx}", explorerAddress: "https://mempool.space/address/{address}",
        explorerName: "mempool.space", typicalConfirmationSeconds: 600, destinationTag: .none
    )
    static let litecoin = Chain(
        id: "litecoin", name: "Litecoin", family: .utxo, coinType: 2,
        nativeSymbol: "LTC", nativeName: "Litecoin", nativeDecimals: 8, coingeckoID: "litecoin",
        evmChainID: nil,
        explorerTx: "https://litecoinspace.org/tx/{tx}", explorerAddress: "https://litecoinspace.org/address/{address}",
        explorerName: "litecoinspace.org", typicalConfirmationSeconds: 150, destinationTag: .none
    )
    static let dogecoin = Chain(
        id: "dogecoin", name: "Dogecoin", family: .utxo, coinType: 3,
        nativeSymbol: "DOGE", nativeName: "Dogecoin", nativeDecimals: 8, coingeckoID: "dogecoin",
        evmChainID: nil,
        explorerTx: "https://blockchair.com/dogecoin/transaction/{tx}", explorerAddress: "https://blockchair.com/dogecoin/address/{address}",
        explorerName: "Blockchair", typicalConfirmationSeconds: 60, destinationTag: .none
    )
    static let ethereum = evm("ethereum", "Ethereum", chainID: 1, symbol: "ETH", nativeName: "Ether", gecko: "ethereum",
                              explorer: "https://etherscan.io", explorerName: "Etherscan", seconds: 12)
    static let arbitrum = evm("arbitrum", "Arbitrum", chainID: 42161, symbol: "ETH", nativeName: "Ether", gecko: "ethereum",
                              explorer: "https://arbiscan.io", explorerName: "Arbiscan", seconds: 2)
    static let base = evm("base", "Base", chainID: 8453, symbol: "ETH", nativeName: "Ether", gecko: "ethereum",
                          explorer: "https://basescan.org", explorerName: "Basescan", seconds: 2)
    static let optimism = evm("optimism", "Optimism", chainID: 10, symbol: "ETH", nativeName: "Ether", gecko: "ethereum",
                              explorer: "https://optimistic.etherscan.io", explorerName: "Etherscan", seconds: 2)
    static let polygon = evm("polygon", "Polygon", chainID: 137, symbol: "POL", nativeName: "Polygon", gecko: "polygon-ecosystem-token",
                             explorer: "https://polygonscan.com", explorerName: "Polygonscan", seconds: 5)
    static let bnb = evm("bnb", "BNB Chain", chainID: 56, symbol: "BNB", nativeName: "BNB", gecko: "binancecoin",
                         explorer: "https://bscscan.com", explorerName: "BscScan", seconds: 3)
    static let avalanche = evm("avalanche", "Avalanche", chainID: 43114, symbol: "AVAX", nativeName: "Avalanche", gecko: "avalanche-2",
                               explorer: "https://snowtrace.io", explorerName: "Snowtrace", seconds: 2)

    // Redes EVM da segunda leva. Em cada uma: chainId, simbolo e explorador pela
    // documentacao oficial, `eth_chainId` conferido em cada RPC de Endpoints.evm, 18
    // casas no saldo nativo e tempo de bloco medido nos ultimos 1.000 blocos, tudo em
    // 26/09/2026. Transacoes tipo 0 e tipo 2 comuns, chave secp256k1 em m/44'/60'/0'/0/0.

    /// Plasma: L1 de stablecoin (PlasmaBFT, execucao Reth), blocos de 1 s. Fonte:
    /// docs.plasma.org, "Connect to Plasma" e "Mainnet Details" (chainId 9745, XPL,
    /// plasmascan.to).
    static let plasma = evm("plasma", "Plasma", chainID: 9745, symbol: "XPL", nativeName: "Plasma", gecko: "plasma",
                            explorer: "https://plasmascan.to", explorerName: "Plasmascan", seconds: 2)
    /// X Layer: L2 da OKX em OP Stack com AggLayer, blocos de 1 s, gas em OKB. Fonte:
    /// web3.okx.com/onchainos/dev-docs/xlayer, "Network information" (chainId 196, OKB,
    /// explorador da OKX) e "RPC endpoints".
    static let xlayer = evm("xlayer", "X Layer", chainID: 196, symbol: "OKB", nativeName: "OKB", gecko: "okb",
                            explorer: "https://www.okx.com/web3/explorer/xlayer", explorerName: "OKX Explorer", seconds: 2)
    /// Linea: zkEVM da Consensys, gas em ETH. Fonte: docs.linea.build, "Connect"
    /// (chainId 59144, ETH, lineascan.build). O sequenciador so fecha bloco com
    /// transacao: medimos de 4 a 18 s entre blocos.
    static let linea = evm("linea", "Linea", chainID: 59144, symbol: "ETH", nativeName: "Ether", gecko: "ethereum",
                           explorer: "https://lineascan.build", explorerName: "Lineascan", seconds: 4)
    /// Unichain: L2 da Uniswap em OP Stack, blocos de 1 s. Fonte:
    /// developers.uniswap.org/docs/unichain, "Network Information" (chainId 130, ETH,
    /// uniscan.xyz).
    static let unichain = evm("unichain", "Unichain", chainID: 130, symbol: "ETH", nativeName: "Ether", gecko: "ethereum",
                              explorer: "https://uniscan.xyz", explorerName: "Uniscan", seconds: 2)
    /// Sonic: L1 da Sonic Labs, blocos de ~1,7 s. Fonte: docs.soniclabs.com, "Getting
    /// Started" (chainId 146, S, sonicscan.org).
    static let sonic = evm("sonic", "Sonic", chainID: 146, symbol: "S", nativeName: "Sonic", gecko: "sonic-3",
                           explorer: "https://sonicscan.org", explorerName: "SonicScan", seconds: 2)
    /// Celo: L2 em OP Stack desde 2025, blocos de 1 s. Fonte: docs.celo.org, "Network
    /// Information" (chainId 42220, CELO com 18 casas, celoscan.io). O CELO nativo
    /// tambem e o ERC-20 `0x471E...a438` (dualidade de token); a carteira so trata o
    /// saldo nativo.
    static let celo = evm("celo", "Celo", chainID: 42220, symbol: "CELO", nativeName: "Celo", gecko: "celo",
                          explorer: "https://celoscan.io", explorerName: "Celoscan", seconds: 2)
    static let solana = Chain(
        id: "solana", name: "Solana", family: .solana, coinType: 501,
        nativeSymbol: "SOL", nativeName: "Solana", nativeDecimals: 9, coingeckoID: "solana",
        evmChainID: nil,
        explorerTx: "https://solscan.io/tx/{tx}", explorerAddress: "https://solscan.io/account/{address}",
        explorerName: "Solscan", typicalConfirmationSeconds: 2, destinationTag: .none
    )
    static let xrpl = Chain(
        id: "xrpl", name: "XRP Ledger", family: .xrpl, coinType: 144,
        nativeSymbol: "XRP", nativeName: "XRP", nativeDecimals: 6, coingeckoID: "ripple",
        evmChainID: nil,
        explorerTx: "https://xrpscan.com/tx/{tx}", explorerAddress: "https://xrpscan.com/account/{address}",
        explorerName: "XRPScan", typicalConfirmationSeconds: 4, destinationTag: .xrplTag
    )
    static let stellar = Chain(
        id: "stellar", name: "Stellar", family: .stellar, coinType: 148,
        nativeSymbol: "XLM", nativeName: "Stellar", nativeDecimals: 7, coingeckoID: "stellar",
        evmChainID: nil,
        explorerTx: "https://stellar.expert/explorer/public/tx/{tx}", explorerAddress: "https://stellar.expert/explorer/public/account/{address}",
        explorerName: "StellarExpert", typicalConfirmationSeconds: 6, destinationTag: .stellarMemo
    )
    static let tron = Chain(
        id: "tron", name: "Tron", family: .tron, coinType: 195,
        nativeSymbol: "TRX", nativeName: "Tron", nativeDecimals: 6, coingeckoID: "tron",
        evmChainID: nil,
        explorerTx: "https://tronscan.org/#/transaction/{tx}", explorerAddress: "https://tronscan.org/#/address/{address}",
        explorerName: "Tronscan", typicalConfirmationSeconds: 3, destinationTag: .none
    )
    static let ton = Chain(
        id: "ton", name: "TON", family: .ton, coinType: 607,
        nativeSymbol: "TON", nativeName: "Toncoin", nativeDecimals: 9, coingeckoID: "the-open-network",
        evmChainID: nil,
        explorerTx: "https://tonviewer.com/transaction/{tx}", explorerAddress: "https://tonviewer.com/{address}",
        explorerName: "Tonviewer", typicalConfirmationSeconds: 5, destinationTag: .tonComment
    )
    /// Sui: SLIP-44 784, 9 casas (MIST), explorador Suiscan (o mesmo do wallet-core da
    /// Trust Wallet). Finalidade em menos de um segundo.
    static let sui = Chain(
        id: "sui", name: "Sui", family: .sui, coinType: 784,
        nativeSymbol: "SUI", nativeName: "Sui", nativeDecimals: 9, coingeckoID: "sui",
        evmChainID: nil,
        explorerTx: "https://suiscan.xyz/mainnet/tx/{tx}", explorerAddress: "https://suiscan.xyz/mainnet/account/{address}",
        explorerName: "Suiscan", typicalConfirmationSeconds: 1, destinationTag: .none
    )

    /// Cardano: SLIP-44 1815, 6 casas (lovelace), explorador Cardanoscan. Um bloco a cada
    /// 20 s em media (coeficiente de slot ativo 0,05 com slot de 1 s, genese Shelley).
    static let cardano = Chain(
        id: "cardano", name: "Cardano", family: .cardano, coinType: 1815,
        nativeSymbol: "ADA", nativeName: "Cardano", nativeDecimals: 6, coingeckoID: "cardano",
        evmChainID: nil,
        explorerTx: "https://cardanoscan.io/transaction/{tx}", explorerAddress: "https://cardanoscan.io/address/{address}",
        explorerName: "Cardanoscan", typicalConfirmationSeconds: 20, destinationTag: .none
    )

    /// Polkadot: SLIP-44 354, 10 casas (planck). O DOT mora na Polkadot Asset Hub desde a
    /// migracao de 4/11/2025, e o explorador e o da Asset Hub no Subscan (o mesmo do
    /// wallet-core da Trust Wallet). Blocos de cerca de 2 s; a tela considera o envio
    /// feito com o bloco finalizado, uns 14 blocos depois (medido em 28/09/2026).
    static let polkadot = Chain(
        id: "polkadot", name: "Polkadot", family: .polkadot, coinType: 354,
        nativeSymbol: "DOT", nativeName: "Polkadot", nativeDecimals: 10, coingeckoID: "polkadot",
        evmChainID: nil,
        explorerTx: "https://assethub-polkadot.subscan.io/extrinsic/{tx}",
        explorerAddress: "https://assethub-polkadot.subscan.io/account/{address}",
        explorerName: "Subscan", typicalConfirmationSeconds: 30, destinationTag: .none
    )

    /// Todas as redes, na ordem em que aparecem na interface.
    static let all: [Chain] = [
        .bitcoin, .ethereum, .solana, .xrpl, .stellar, .tron, .ton,
        .base, .arbitrum, .optimism, .polygon, .bnb, .avalanche,
        .plasma, .xlayer, .linea, .unichain, .sonic, .celo,
        .litecoin, .dogecoin,
        .sui,
        .cardano,
        .polkadot,
    ]

    static func find(_ id: String) -> Chain? { all.first { $0.id == id } }

    static var evmChains: [Chain] { all.filter { $0.family == .evm } }

    private static func evm(
        _ id: String, _ name: String, chainID: UInt64, symbol: String, nativeName: String, gecko: String,
        explorer: String, explorerName: String, seconds: Int
    ) -> Chain {
        Chain(
            id: id, name: name, family: .evm, coinType: 60,
            nativeSymbol: symbol, nativeName: nativeName, nativeDecimals: 18, coingeckoID: gecko,
            evmChainID: chainID,
            explorerTx: "\(explorer)/tx/{tx}", explorerAddress: "\(explorer)/address/{address}",
            explorerName: explorerName, typicalConfirmationSeconds: seconds, destinationTag: .none
        )
    }
}
