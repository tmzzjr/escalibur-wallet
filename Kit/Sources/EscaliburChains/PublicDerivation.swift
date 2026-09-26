import EscaliburCore
import Foundation

/// Derivacao publica BIP-32 (xpub): enderecos novos sem tocar a seed.
///
/// A chave publica estendida da conta (`m/84'/0'/0'`, por exemplo) e derivada uma
/// vez, na criacao da carteira, e guardada cifrada nos metadados. Daqui em diante,
/// enderecos de recebimento e de troco saem dela, e mostrar saldo nunca abre a seed.
///
/// A xpub e segredo de privacidade: ela liga todos os enderecos da conta. Nunca vai
/// para provedor nenhum; consultas sao feitas endereco por endereco.
public struct ExtendedPublicKey: Sendable, Hashable, Codable {
    public let publicKey: [UInt8]
    public let chainCode: [UInt8]

    public init(publicKey: [UInt8], chainCode: [UInt8]) throws {
        guard publicKey.count == 33, chainCode.count == 32 else { throw Secp256k1.Failure.invalidPublicKey }
        _ = try Secp256k1.reformat(publicKey: publicKey, compressed: true)
        self.publicKey = publicKey
        self.chainCode = chainCode
    }

    /// Filho nao endurecido. Endurecido e impossivel sem a chave privada.
    public func child(_ index: UInt32) throws -> ExtendedPublicKey {
        precondition(index < DerivationPath.hardenedOffset, "derivacao publica so existe para indice nao endurecido")
        let i = Hash.hmacSHA512(key: chainCode, data: publicKey + index.bigEndianByteArray)
        let childKey = try Secp256k1.tweakAdd(publicKey: publicKey, tweak: Array(i.prefix(32)))
        return try ExtendedPublicKey(publicKey: childKey, chainCode: Array(i.suffix(32)))
    }

    public func derive(_ indices: [UInt32]) throws -> ExtendedPublicKey {
        try indices.reduce(self) { try $0.child($1) }
    }
}
