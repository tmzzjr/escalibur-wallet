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

    public var curve: HDKey.Curve {
        switch self {
        case .utxo, .evm, .xrpl, .tron: return .secp256k1
        case .solana, .stellar, .ton: return .ed25519
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

    /// Todas as redes da v1, na ordem em que aparecem na interface.
    static let all: [Chain] = [
        .bitcoin, .ethereum, .solana, .xrpl, .stellar, .tron, .ton,
        .base, .arbitrum, .optimism, .polygon, .bnb, .avalanche,
        .litecoin, .dogecoin,
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
