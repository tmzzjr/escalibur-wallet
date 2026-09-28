import EscaliburCore
import Foundation

/// Uma transacao da Sui pronta para assinar.
///
/// A chave assina, com Ed25519, o BLAKE2b-256 da mensagem com intencao (tres bytes 0 e
/// a transacao em BCS), calculado aqui a partir dos campos. A assinatura que sai para a
/// rede e a serializada da Sui: a flag do esquema (0x00), os 64 bytes da assinatura e os
/// 32 da chave publica (`flag || sig || pk`, 97 bytes).
///
/// O Ed25519 do CryptoKit e aleatorizado, mas na Sui o id da transacao nao inclui a
/// assinatura: assinar de novo nao muda o id. Mesmo assim, quem transmite reenvia os
/// mesmos bytes, como em toda rede da carteira.
public struct SuiTransfer: SignableTransaction {
    public var chain: Chain { .sui }
    public let data: SuiTransactionData
    /// A transacao em BCS, exatamente como vai para a rede.
    public let transactionBytes: [UInt8]
    /// O que a chave assina.
    public let signingDigest: [UInt8]
    public let path: DerivationPath
    public let publicKey: [UInt8]

    init(data: SuiTransactionData, path: DerivationPath, publicKey: [UInt8]) throws {
        guard try SuiAddress(ed25519PublicKey: publicKey) == data.sender, data.gas.owner == data.sender else {
            throw SuiPlanError.keyMismatch
        }
        self.data = data
        self.transactionBytes = data.bcs()
        self.signingDigest = SuiTransactionData.signingDigest(of: transactionBytes)
        self.path = path
        self.publicKey = publicKey
    }

    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: path, curve: .ed25519, scheme: .ed25519, payload: signingDigest, expectedPublicKey: publicKey)]
    }

    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let signature = signatures[0].bytes
        // O assinador ja verificou; conferir de novo custa pouco e impede que uma
        // assinatura de outra mensagem saia junto desta.
        guard signature.count == 64, signatures[0].recoveryID == nil,
              Ed25519.verify(signature: signature, message: signingDigest, publicKey: publicKey)
        else { throw SigningError.malformedSignature }
        return SuiSignedTransaction.pack(transactionBytes: transactionBytes, signature: [SuiSignatureFlag.ed25519] + signature + publicKey)
    }
}

/// A transacao assinada, como a carteira guarda e transmite.
///
/// `SignedTransaction.raw` e a transacao em BCS seguida da assinatura serializada (97
/// bytes); `encoded` sao as duas partes em base64, separadas por um ponto, que e o que o
/// `ExecuteTransaction` recebe (transacao e assinatura em campos separados). O id e o
/// digesto da transacao em base58.
public struct SuiSignedTransaction: Sendable, Equatable {
    public static let signatureLength = 97

    public let data: SuiTransactionData
    public let transactionBytes: [UInt8]
    /// `flag || sig || pk`.
    public let signature: [UInt8]

    static func pack(transactionBytes: [UInt8], signature: [UInt8]) -> SignedTransaction {
        SignedTransaction(
            chainID: Chain.sui.id,
            raw: transactionBytes + signature,
            encoded: Data(transactionBytes).base64EncodedString() + "." + Data(signature).base64EncodedString(),
            id: Base58.bitcoin.encode(Blake2b.hash(Array("TransactionData::".utf8) + transactionBytes, outputLength: 32))
        )
    }

    /// Le e confere uma transacao assinada antes de ela sair para a rede: rede, as duas
    /// formas iguais, transacao do subconjunto da carteira, assinatura Ed25519 que
    /// verifica sobre o digesto calculado aqui, chave que da o remetente, e id igual ao
    /// digesto. Qualquer diferenca e recusa: nada que nao foi montado e revisado aqui
    /// chega a um provedor.
    public static func parse(_ signed: SignedTransaction) throws -> SuiSignedTransaction {
        guard signed.chainID == Chain.sui.id, signed.raw.count > signatureLength else { throw SuiTransactionError.malformed }
        let parts = signed.encoded.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let tx = Data(base64Encoded: String(parts[0])), let sig = Data(base64Encoded: String(parts[1])),
              [UInt8](tx) + [UInt8](sig) == signed.raw, sig.count == signatureLength
        else { throw SuiTransactionError.malformed }
        let transactionBytes = [UInt8](tx)
        let signature = [UInt8](sig)
        let data = try SuiTransactionData.decode(transactionBytes)
        let publicKey = Array(signature.suffix(32))
        guard signature[0] == SuiSignatureFlag.ed25519,
              Ed25519.verify(signature: Array(signature[1..<65]), message: SuiTransactionData.signingDigest(of: transactionBytes), publicKey: publicKey),
              try SuiAddress(ed25519PublicKey: publicKey) == data.sender,
              data.digestBase58 == signed.id
        else { throw SuiTransactionError.malformed }
        return SuiSignedTransaction(data: data, transactionBytes: transactionBytes, signature: signature)
    }
}
