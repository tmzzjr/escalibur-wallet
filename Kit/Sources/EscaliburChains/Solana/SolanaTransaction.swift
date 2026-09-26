import EscaliburCore
import Foundation

/// Uma transacao Solana pronta para assinar: a mensagem compilada, e quem assina.
///
/// **Assinar uma vez, guardar os bytes, retransmitir os mesmos bytes.** A Solana
/// identifica a transacao pela primeira assinatura, e o Ed25519 do CryptoKit e
/// aleatorizado: assinar a mesma mensagem de novo produz outra assinatura valida e,
/// portanto, outro id. A rede nao executa duas vezes (ela deduplica pelo blockhash
/// e pela mensagem), mas a carteira perderia o rastro do envio: mostraria "nao
/// confirmada" para um id enquanto o outro ja foi executado, e o dono tentaria de
/// novo. Por isso quem transmite persiste `SignedTransaction.raw` e reenvia esses
/// bytes ate a confirmacao ou ate `lastValidBlockHeight`; nunca pede nova
/// assinatura para a mesma mensagem.
public struct SolanaTransaction: SignableTransaction {
    /// Tamanho maximo de uma transacao legada ou v0 serializada (PACKET_DATA_SIZE,
    /// 1280 de MTU IPv6 menos 48 de cabecalho).
    public static let maxSerializedSize = 1232

    public let chain: Chain
    public let message: SolanaMessage
    /// Os bytes que a assinatura cobre, calculados aqui e nunca recebidos de fora.
    public let messageBytes: [UInt8]
    public let signerPath: DerivationPath
    public let signer: SolanaPublicKey
    /// Ultima altura de bloco em que o blockhash da mensagem vale. Passou dela, a
    /// transacao nunca mais entra: parar de retransmitir e montar outra.
    public let lastValidBlockHeight: UInt64

    package init(message: SolanaMessage, signerPath: DerivationPath, signer: SolanaPublicKey, lastValidBlockHeight: UInt64) throws {
        // Esta carteira so monta transacao com um signatario, o pagador da taxa.
        guard message.header.numRequiredSignatures == 1, message.feePayer == signer else {
            throw SolanaMessage.Problem.malformed
        }
        self.chain = .solana
        self.message = message
        self.messageBytes = message.serialize()
        self.signerPath = signerPath
        self.signer = signer
        self.lastValidBlockHeight = lastValidBlockHeight
        guard serializedSize <= Self.maxSerializedSize else { throw SolanaTransactionProblem.tooLarge(serializedSize) }
    }

    /// compact(1) + 64 bytes de assinatura + mensagem.
    public var serializedSize: Int { 1 + 64 + messageBytes.count }

    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: signerPath, curve: .ed25519, scheme: .ed25519, payload: messageBytes, expectedPublicKey: signer.bytes)]
    }

    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let signature = signatures[0].bytes
        // O assinador ja verificou; conferir de novo aqui custa microssegundos e
        // impede que uma assinatura trocada no caminho vire um id de transacao.
        guard signature.count == 64, signatures[0].recoveryID == nil,
              Ed25519.verify(signature: signature, message: messageBytes, publicKey: signer.bytes)
        else { throw SigningError.malformedSignature }
        let raw = SolanaShortVec.encode(1) + signature + messageBytes
        return SignedTransaction(
            chainID: chain.id,
            raw: raw,
            // `sendTransaction` com `encoding: "base64"`. O base58 esta deprecado no RPC.
            encoded: Data(raw).base64EncodedString(),
            id: Base58.bitcoin.encode(signature)
        )
    }
}

public enum SolanaTransactionProblem: Error, Equatable, Sendable {
    case tooLarge(Int)
    case signatureCountMismatch
    case malformed
}

/// Uma transacao no formato de rede, lida de bytes: as assinaturas e a mensagem.
/// Serve para conferir transacao vinda de fora e para os testes contra transacoes
/// reais; a carteira nunca assina a partir daqui sem passar pelo verificador.
public struct SolanaWireTransaction: Sendable, Equatable {
    public let signatures: [[UInt8]]
    public let message: SolanaMessage
    /// Os bytes da mensagem exatamente como vieram (o que as assinaturas cobrem).
    public let messageBytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        var reader = SolanaByteReader(bytes)
        do {
            let count = try reader.shortVecLength()
            var signatures = [[UInt8]]()
            for _ in 0..<count { signatures.append(try reader.take(64)) }
            let start = reader.offset
            let message = try SolanaMessage.read(from: &reader)
            guard reader.isAtEnd else { throw SolanaMessage.Problem.trailingBytes }
            guard signatures.count == Int(message.header.numRequiredSignatures) else {
                throw SolanaTransactionProblem.signatureCountMismatch
            }
            self.signatures = signatures
            self.message = message
            self.messageBytes = Array(bytes[start...])
        } catch let problem as SolanaMessage.Problem {
            throw problem
        } catch let problem as SolanaTransactionProblem {
            throw problem
        } catch {
            throw SolanaTransactionProblem.malformed
        }
    }

    public init(base64 text: String) throws {
        guard let data = Data(base64Encoded: text) else { throw SolanaTransactionProblem.malformed }
        try self.init(bytes: Array(data))
    }

    /// O id que o explorador mostra: a primeira assinatura em Base58.
    public var id: String? { signatures.first.map { Base58.bitcoin.encode($0) } }

    /// Cada assinatura confere com a chave do signatario na mesma posicao.
    public func verifySignatures() -> Bool {
        guard signatures.count <= message.staticAccountKeys.count else { return false }
        for (index, signature) in signatures.enumerated() {
            guard Ed25519.verify(signature: signature, message: messageBytes, publicKey: message.staticAccountKeys[index].bytes) else {
                return false
            }
        }
        return true
    }
}
