import EscaliburCore
import Foundation

// A transacao da Aptos em BCS, so o subconjunto que a carteira monta: uma chamada a
// `0x1::aptos_account::transfer(destino, valor)`, com numero de sequencia, sem tipo
// generico, sem multiagente e sem pagador de taxa. BCS e a mesma especificacao da Sui
// (github.com/diem/bcs, a Aptos herdou da Diem), entao o escritor e o leitor sao os da Sui.
//
// Layout (aptos-core, `types/src/transaction/mod.rs`, `RawTransaction`): remetente (32
// bytes), sequencia (u64), payload (enum; 2 = EntryFunction: ModuleId {endereco, nome},
// funcao, argumentos de tipo, argumentos em BCS cada um com prefixo de tamanho), gas
// maximo (u64), preco do gas (u64), validade em segundos Unix (u64) e chain id (u8).
// Conferido byte a byte contra o vetor do wallet-core e contra transacoes reais da rede
// principal, remontadas dos campos e com o hash igual ao da rede (AptosTransactionTests).

typealias AptosBCSWriter = SuiBCSWriter
typealias AptosBCSReader = SuiBCSReader

public enum AptosTransactionError: Error, Equatable, Sendable {
    /// Bytes fora do subconjunto da carteira, assinatura que nao verifica, chave que nao
    /// da o remetente ou id diferente do hash.
    case malformed
}

/// Uma transferencia de APT, antes da assinatura.
public struct AptosRawTransaction: Hashable, Sendable {
    public let sender: AptosAddress
    public let sequenceNumber: UInt64
    public let recipient: AptosAddress
    /// Em octas (10^-8 APT).
    public let amount: UInt64
    /// Teto de unidades de gas: a rede cobra o gas usado, nunca mais que isto.
    public let maxGasAmount: UInt64
    /// Octas por unidade de gas.
    public let gasUnitPrice: UInt64
    /// Segundos Unix: depois disso, na hora do bloco, a rede nao executa mais.
    public let expirationTimestampSecs: UInt64
    public let chainID: UInt8

    public init(
        sender: AptosAddress, sequenceNumber: UInt64, recipient: AptosAddress, amount: UInt64,
        maxGasAmount: UInt64, gasUnitPrice: UInt64, expirationTimestampSecs: UInt64, chainID: UInt8
    ) {
        self.sender = sender
        self.sequenceNumber = sequenceNumber
        self.recipient = recipient
        self.amount = amount
        self.maxGasAmount = maxGasAmount
        self.gasUnitPrice = gasUnitPrice
        self.expirationTimestampSecs = expirationTimestampSecs
        self.chainID = chainID
    }

    static let module = "aptos_account"
    static let function = "transfer"
    /// `TransactionPayload::EntryFunction`.
    static let entryFunctionVariant: UInt64 = 2

    /// A transacao em BCS.
    public func bcs() -> [UInt8] {
        var w = AptosBCSWriter()
        w.fixed(sender.bytes)
        w.u64(sequenceNumber)
        w.uleb128(Self.entryFunctionVariant)
        w.fixed(AptosAddress.framework.bytes)
        w.vector(Array(Self.module.utf8))
        w.vector(Array(Self.function.utf8))
        w.uleb128(0)                       // sem argumentos de tipo
        w.uleb128(2)                       // dois argumentos, cada um em BCS
        w.vector(recipient.bytes)
        w.vector(amount.littleEndianByteArray)
        w.u64(maxGasAmount)
        w.u64(gasUnitPrice)
        w.u64(expirationTimestampSecs)
        w.u8(chainID)
        return w.bytes
    }

    /// Le de volta, recusando qualquer coisa fora do subconjunto (outro modulo, outra
    /// funcao, argumento de tipo, outro tamanho) e qualquer grafia que nao seja a que
    /// `bcs()` escreveria.
    public static func decode(_ bytes: [UInt8]) throws -> AptosRawTransaction {
        var r = AptosBCSReader(bytes)
        do {
            guard let sender = AptosAddress(bytes: try r.take(32)) else { throw AptosTransactionError.malformed }
            let sequence = try r.u64()
            guard try r.uleb128() == entryFunctionVariant,
                  try r.take(32) == AptosAddress.framework.bytes,
                  try r.vector(max: 128) == Array(module.utf8),
                  try r.vector(max: 128) == Array(function.utf8),
                  try r.uleb128() == 0, try r.uleb128() == 2,
                  let recipient = AptosAddress(bytes: try r.vector(max: 32))
            else { throw AptosTransactionError.malformed }
            let amountBytes = try r.vector(max: 8)
            guard amountBytes.count == 8 else { throw AptosTransactionError.malformed }
            let amount = amountBytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            let transaction = AptosRawTransaction(
                sender: sender, sequenceNumber: sequence, recipient: recipient, amount: amount,
                maxGasAmount: try r.u64(), gasUnitPrice: try r.u64(), expirationTimestampSecs: try r.u64(), chainID: try r.u8()
            )
            try r.finish()
            guard transaction.bcs() == bytes else { throw AptosTransactionError.malformed }
            return transaction
        } catch is AptosBCSReader.Failure {
            throw AptosTransactionError.malformed
        }
    }

    /// O prefixo de dominio do que se assina: SHA3-256("APTOS::RawTransaction")
    /// (aptos-core, `aptos_crypto_derive::CryptoHasher`; `RAW_TRANSACTION_SALT` no SDK em
    /// TypeScript).
    static let signingSalt = Hash.sha3_256(Array("APTOS::RawTransaction".utf8))

    /// O que a chave assina com Ed25519: o prefixo e a transacao em BCS, inteiros, sem
    /// hash por cima.
    public var signingMessage: [UInt8] { Self.signingSalt + bcs() }
}

/// Uma transferencia de APT pronta para assinar.
///
/// O Ed25519 do CryptoKit e aleatorizado, e na Aptos o hash da transacao inclui a
/// assinatura: assinar de novo muda o id. O numero de sequencia impede execucao dupla, e
/// quem transmite reenvia os mesmos bytes, como em toda rede da carteira.
public struct AptosTransfer: SignableTransaction {
    public var chain: Chain { .aptos }
    public let raw: AptosRawTransaction
    public let signingMessage: [UInt8]
    public let path: DerivationPath
    public let publicKey: [UInt8]

    init(raw: AptosRawTransaction, path: DerivationPath, publicKey: [UInt8]) throws {
        guard try AptosAddress(ed25519PublicKey: publicKey) == raw.sender else { throw AptosPlanError.keyMismatch }
        self.raw = raw
        self.signingMessage = raw.signingMessage
        self.path = path
        self.publicKey = publicKey
    }

    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: path, curve: .ed25519, scheme: .ed25519, payload: signingMessage, expectedPublicKey: publicKey)]
    }

    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let signature = signatures[0].bytes
        // O assinador ja verificou; conferir de novo custa pouco e impede que uma
        // assinatura de outra mensagem saia junto desta.
        guard signature.count == 64, signatures[0].recoveryID == nil,
              Ed25519.verify(signature: signature, message: signingMessage, publicKey: publicKey)
        else { throw SigningError.malformedSignature }
        return AptosSignedTransaction.pack(raw: raw.bcs(), publicKey: publicKey, signature: signature)
    }
}

/// A transacao assinada, como a carteira guarda e transmite.
///
/// `SignedTransaction.raw` e o `SignedTransaction` da Aptos em BCS: a transacao e o
/// autenticador Ed25519 (variante 0, chave publica e assinatura com prefixo de tamanho),
/// exatamente os bytes que o `POST /v1/transactions` recebe em
/// `application/x.aptos.signed_transaction+bcs`. `encoded` sao os mesmos bytes em hex. O id
/// e o hash da transacao: SHA3-256(SHA3-256("APTOS::Transaction") || 0x00 || bytes), o 0x00
/// sendo a variante `Transaction::UserTransaction`. E o hash que a rede e o explorador
/// mostram.
public struct AptosSignedTransaction: Sendable, Equatable {
    public let raw: AptosRawTransaction
    public let publicKey: [UInt8]
    public let signature: [UInt8]
    public let bytes: [UInt8]

    static let transactionSalt = Hash.sha3_256(Array("APTOS::Transaction".utf8))

    static func signedBytes(raw: [UInt8], publicKey: [UInt8], signature: [UInt8]) -> [UInt8] {
        var w = AptosBCSWriter()
        w.uleb128(UInt64(AptosAuthenticationScheme.ed25519))
        w.vector(publicKey)
        w.vector(signature)
        return raw + w.bytes
    }

    /// O hash da transacao assinada, com "0x", como a rede escreve.
    public static func hash(of signedBytes: [UInt8]) -> String {
        Hex.encode(Hash.sha3_256(transactionSalt + [0x00] + signedBytes), prefix: true)
    }

    static func pack(raw: [UInt8], publicKey: [UInt8], signature: [UInt8]) -> SignedTransaction {
        let bytes = signedBytes(raw: raw, publicKey: publicKey, signature: signature)
        return SignedTransaction(chainID: Chain.aptos.id, raw: bytes, encoded: Hex.encode(bytes), id: hash(of: bytes))
    }

    /// A transacao com a assinatura zerada, para o `POST /v1/transactions/simulate`: a rede
    /// so simula transacao com assinatura que nao verifica, e confere a chave publica
    /// contra a chave de autenticacao da conta. Nunca vai para a rede como envio.
    public static func simulationBytes(_ raw: AptosRawTransaction, publicKey: [UInt8]) -> [UInt8] {
        signedBytes(raw: raw.bcs(), publicKey: publicKey, signature: [UInt8](repeating: 0, count: 64))
    }

    /// Le e confere uma transacao assinada antes de ela sair para a rede: rede, as duas
    /// formas iguais, transacao do subconjunto da carteira, rede principal no chain id,
    /// assinatura Ed25519 que verifica sobre a mensagem calculada aqui, chave que da o
    /// remetente, e id igual ao hash. Qualquer diferenca e recusa.
    public static func parse(_ signed: SignedTransaction) throws -> AptosSignedTransaction {
        guard signed.chainID == Chain.aptos.id, let decoded = Hex.decode(signed.encoded), decoded == signed.raw,
              signed.raw.count > 99
        else { throw AptosTransactionError.malformed }
        // Autenticador: variante (1), tamanho e chave (1 + 32), tamanho e assinatura (1 + 64).
        let tail = Array(signed.raw.suffix(99))
        guard tail[0] == AptosAuthenticationScheme.ed25519, tail[1] == 32, tail[34] == 64 else { throw AptosTransactionError.malformed }
        let publicKey = Array(tail[2..<34])
        let signature = Array(tail[35..<99])
        let raw = try AptosRawTransaction.decode(Array(signed.raw.dropLast(99)))
        guard raw.chainID == AptosPlanner.mainnetChainID,
              Ed25519.verify(signature: signature, message: raw.signingMessage, publicKey: publicKey),
              try AptosAddress(ed25519PublicKey: publicKey) == raw.sender,
              hash(of: signed.raw) == signed.id.lowercased()
        else { throw AptosTransactionError.malformed }
        return AptosSignedTransaction(raw: raw, publicKey: publicKey, signature: signature, bytes: signed.raw)
    }
}
