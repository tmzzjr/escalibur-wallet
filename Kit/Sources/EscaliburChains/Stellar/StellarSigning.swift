import EscaliburCore
import Foundation

/// A rede principal da Stellar, compilada.
///
/// A passphrase entra no hash de toda transacao. Se ela viesse de servidor, um
/// servidor malicioso poderia trocar pela da testnet ou de uma rede privada e colher
/// uma assinatura que vale em outro lugar; aqui ela e literal, e o `networkId` sai
/// dela na hora (seguranca.md §4.5 e §4.11).
public enum StellarNetwork {
    /// Fonte: developers.stellar.org/docs/networks, e o `network_passphrase` de
    /// horizon.stellar.org conferido ao vivo em 25/09/2026 (blockchain.md §2.5).
    public static let passphrase = "Public Global Stellar Network ; September 2015"

    /// `SHA256(passphrase)` = 7ac33997544e3175d266bd022439b22cdb16508c01163f26e5cb2a3e1045a979.
    public static let networkID: [UInt8] = Hash.sha256(Array(passphrase.utf8))
}

/// Uma transacao Stellar pronta para o assinador.
///
/// Diz o que assinar (o hash de 32 bytes do `TransactionSignaturePayload`, com a
/// passphrase compilada) e, com a assinatura de volta, monta o envelope v1 em
/// base64. So nasce do planejamento (`StellarPlanner`), dentro de um `SigningPlan`.
public struct StellarTransaction: SignableTransaction {
    public let tx: StellarTx
    /// O caminho da conta que assina (`m/44'/148'/i'`).
    public let path: DerivationPath
    public let signer: StellarAccountID
    /// Sempre `StellarNetwork.networkID` em producao. O parametro existe so para os
    /// testes conferirem vetores oficiais gerados na testnet; nao e publico.
    let networkID: [UInt8]

    init(tx: StellarTx, path: DerivationPath, signer: StellarAccountID, networkID: [UInt8] = StellarNetwork.networkID) {
        self.tx = tx
        self.path = path
        self.signer = signer
        self.networkID = networkID
    }

    public var chain: Chain { .stellar }

    /// O id da transacao e o que a chave assina.
    public var hash: [UInt8] { tx.hash(networkID: networkID) }

    /// Uma assinatura Ed25519 sobre o hash. Na Stellar a "mensagem inteira" que o
    /// Ed25519 assina ja e o SHA-256 do payload, calculado aqui.
    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: path, curve: .ed25519, scheme: .ed25519, payload: hash, expectedPublicKey: signer.publicKey)]
    }

    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let signature = signatures[0]
        let digest = hash
        // O assinador ja verificou; conferir de novo custa microssegundos e impede
        // que um envelope com assinatura de outra chave va para a rede.
        guard signature.bytes.count == 64, signature.recoveryID == nil,
              Ed25519.verify(signature: signature.bytes, message: digest, publicKey: signer.publicKey)
        else { throw SigningError.malformedSignature }
        if let maxTime = tx.timeBounds?.maxTime, maxTime != 0, UInt64(max(0, Date.now.timeIntervalSince1970)) > maxTime {
            throw SigningError.expired
        }
        let envelope = try StellarEnvelope(
            tx: tx,
            signatures: [try StellarDecoratedSignature(publicKey: signer.publicKey, signature: signature.bytes)]
        )
        let raw = envelope.xdr
        return SignedTransaction(chainID: Chain.stellar.id, raw: raw, encoded: Data(raw).base64EncodedString(), id: Hex.encode(digest))
    }
}
