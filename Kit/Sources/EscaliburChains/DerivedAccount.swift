import Foundation

/// As contas publicas de uma carteira, derivadas uma vez na criacao ou importacao e
/// guardadas nos metadados. Mostrar saldo e receber nunca abrem a seed depois disso.
public struct DerivedAccount: Sendable, Codable, Hashable {
    public let chainID: String
    public let path: DerivationPath
    public let address: String
    public let publicKey: [UInt8]
    /// So nas redes UTXO: a xpub da conta (`m/84'/0'/0'`), para derivar enderecos
    /// de recebimento e troco sem a seed. Nunca sai do aparelho.
    public let accountXPub: ExtendedPublicKey?

    public init(chainID: String, path: DerivationPath, address: String, publicKey: [UInt8], accountXPub: ExtendedPublicKey?) {
        self.chainID = chainID
        self.path = path
        self.address = address
        self.publicKey = publicKey
        self.accountXPub = accountXPub
    }
}
