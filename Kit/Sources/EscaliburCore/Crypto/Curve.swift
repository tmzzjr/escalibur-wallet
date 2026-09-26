import Foundation

/// As duas curvas que a carteira usa.
public enum Curve: String, Sendable, Codable, Hashable {
    /// Bitcoin, Litecoin, Dogecoin, EVM, XRP Ledger e Tron.
    case secp256k1
    /// Solana, Stellar e TON.
    case ed25519
}
