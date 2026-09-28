import EscaliburCore
import Foundation

/// O Borsh que uma transferencia NEAR precisa: inteiros little-endian, texto com o
/// tamanho em u32 na frente, bytes fixos crus (borsh.io, "Specification").
enum NEARBorsh {
    enum Failure: Error, Equatable {
        /// Os bytes nao sao exatamente o que a carteira monta.
        case nonCanonical
    }

    struct Writer {
        private(set) var bytes: [UInt8] = []

        mutating func u8(_ value: UInt8) { bytes.append(value) }
        mutating func u32(_ value: UInt32) { bytes += value.littleEndianByteArray }
        mutating func u64(_ value: UInt64) { bytes += value.littleEndianByteArray }

        /// u128: o valor tem de caber em 16 bytes.
        mutating func u128(_ value: BigUInt) throws {
            guard let big = value.bigEndianBytes(padTo: 16) else { throw Failure.nonCanonical }
            bytes += big.reversed()
        }

        mutating func string(_ text: String) {
            let utf8 = Array(text.utf8)
            u32(UInt32(utf8.count))
            bytes += utf8
        }

        mutating func fixed(_ data: [UInt8]) { bytes += data }
    }

    struct Reader {
        let bytes: [UInt8]
        private(set) var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { throw Failure.nonCanonical }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func u8() throws -> UInt8 { try take(1)[0] }

        mutating func u32() throws -> UInt32 {
            try take(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }

        mutating func u64() throws -> UInt64 {
            try take(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        mutating func u128() throws -> BigUInt { BigUInt(bigEndian: try take(16).reversed()) }

        /// Texto de conta: no maximo 64 bytes, UTF-8 valido.
        mutating func string() throws -> String {
            let count = Int(try u32())
            guard count <= NEARAccountID.maxLength, let text = String(bytes: try take(count), encoding: .utf8) else {
                throw Failure.nonCanonical
            }
            return text
        }

        func requireEnd() throws {
            guard offset == bytes.count else { throw Failure.nonCanonical }
        }
    }
}

/// Os campos de uma transferencia de NEAR: uma `Transaction` (v0) com uma unica acao
/// `Transfer`, e as formas que saem dela.
///
/// ```
/// Transaction { signer_id: string, public_key: PublicKey, nonce: u64,
///               receiver_id: string, block_hash: [u8; 32], actions: Vec<Action> }
/// PublicKey   = 0 (ED25519) || 32 bytes
/// Action      = 3 (Transfer) || deposit: u128
/// SignedTransaction = Transaction || Signature (0 || 64 bytes)
/// ```
///
/// O que a chave assina e o id sao o SHA-256 da `Transaction` em Borsh; o id vai em
/// base58, como o NearBlocks e os nos mostram (nomicon.io, "Transaction"; conferido em
/// transferencias reais aceitas pela rede, `transferencias-reais.json` nos testes).
public struct NEARTransferFields: Equatable, Sendable {
    public let signer: NEARAccountID
    /// A chave Ed25519 que assina: a da conta implicita do dono.
    public let publicKey: [UInt8]
    /// O nonce da chave de acesso lido na rede, mais um.
    public let nonce: UInt64
    public let receiver: NEARAccountID
    /// Um bloco recente: a transacao so vale enquanto ele estiver a menos de
    /// `NEARRules.validityBlocks` blocos da ponta.
    public let blockHash: [UInt8]
    /// Em yoctoNEAR (10^-24 NEAR).
    public let deposit: BigUInt

    static let ed25519KeyType: UInt8 = 0
    static let transferAction: UInt8 = 3

    init(signer: NEARAccountID, publicKey: [UInt8], nonce: UInt64, receiver: NEARAccountID, blockHash: [UInt8], deposit: BigUInt) {
        self.signer = signer
        self.publicKey = publicKey
        self.nonce = nonce
        self.receiver = receiver
        self.blockHash = blockHash
        self.deposit = deposit
    }

    /// A `Transaction` em Borsh.
    public func serialized() throws -> [UInt8] {
        guard publicKey.count == 32, blockHash.count == 32 else { throw NEARBorsh.Failure.nonCanonical }
        var writer = NEARBorsh.Writer()
        writer.string(signer.text)
        writer.u8(Self.ed25519KeyType)
        writer.fixed(publicKey)
        writer.u64(nonce)
        writer.string(receiver.text)
        writer.fixed(blockHash)
        writer.u32(1)
        writer.u8(Self.transferAction)
        try writer.u128(deposit)
        return writer.bytes
    }

    /// O SHA-256 da transacao: o que a chave assina e o id.
    public func hash() throws -> [UInt8] { Hash.sha256(try serialized()) }

    /// A `SignedTransaction` em Borsh: a transacao e a assinatura Ed25519.
    func signed(with signature: [UInt8]) throws -> [UInt8] {
        guard signature.count == 64 else { throw NEARBorsh.Failure.nonCanonical }
        return try serialized() + [Self.ed25519KeyType] + signature
    }
}

/// Uma transferencia de NEAR pronta para o assinador. So nasce do `NEARPlanner`.
public struct NEARTransfer: SignableTransaction {
    public var chain: Chain { .near }
    public let fields: NEARTransferFields
    public let path: DerivationPath
    let digest: [UInt8]

    init(fields: NEARTransferFields, path: DerivationPath) throws {
        self.fields = fields
        self.path = path
        digest = try fields.hash()
    }

    /// Ed25519 sobre os 32 bytes do SHA-256 da transacao, calculado aqui.
    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: path, curve: .ed25519, scheme: .ed25519, payload: digest, expectedPublicKey: fields.publicKey)]
    }

    /// O CryptoKit aleatoriza a assinatura, mas na NEAR o id e o hash da transacao sem a
    /// assinatura: assinar de novo nao muda o id, e o nonce impede a execucao dupla.
    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let signature = signatures[0].bytes
        guard signature.count == 64, signatures[0].recoveryID == nil,
              Ed25519.verify(signature: signature, message: digest, publicKey: fields.publicKey)
        else { throw SigningError.malformedSignature }
        return NEARSignedTransaction.pack(try fields.signed(with: signature), id: digest)
    }
}

/// A transacao assinada, lida de volta antes de sair para a rede.
///
/// `SignedTransaction.raw` e a `SignedTransaction` em Borsh; `encoded`, a mesma em
/// base64 (o que o `send_tx` recebe); o id, o SHA-256 da parte sem assinatura em base58.
public struct NEARSignedTransaction: Equatable, Sendable {
    public let fields: NEARTransferFields
    public let signature: [UInt8]

    static func pack(_ raw: [UInt8], id digest: [UInt8]) -> SignedTransaction {
        SignedTransaction(chainID: Chain.near.id, raw: raw, encoded: Data(raw).base64EncodedString(), id: Base58.bitcoin.encode(digest))
    }

    /// Le e confere: rede, as duas formas iguais, e exatamente o formato que a carteira
    /// monta (chave e assinatura Ed25519, uma acao `Transfer`, contas validas, nada
    /// sobrando), o id igual ao hash e a assinatura valida para a chave. Qualquer
    /// diferenca e recusa: nada que nao foi montado aqui chega a um provedor.
    public static func parse(_ signed: SignedTransaction) throws -> NEARSignedTransaction {
        guard signed.chainID == Chain.near.id, Data(base64Encoded: signed.encoded).map([UInt8].init) == signed.raw else {
            throw NEARBorsh.Failure.nonCanonical
        }
        let decoded = try decode(signed.raw)
        let digest = try decoded.fields.hash()
        guard Base58.bitcoin.encode(digest) == signed.id,
              Ed25519.verify(signature: decoded.signature, message: digest, publicKey: decoded.fields.publicKey)
        else { throw NEARBorsh.Failure.nonCanonical }
        return decoded
    }

    static func decode(_ raw: [UInt8]) throws -> NEARSignedTransaction {
        var reader = NEARBorsh.Reader(raw)
        guard case .success(let signer) = NEARAccountID.parse(try reader.string()), signer.kind == .implicit,
              try reader.u8() == NEARTransferFields.ed25519KeyType
        else { throw NEARBorsh.Failure.nonCanonical }
        let publicKey = try reader.take(32)
        guard signer.implicitPublicKey == publicKey else { throw NEARBorsh.Failure.nonCanonical }
        let nonce = try reader.u64()
        guard case .success(let receiver) = NEARAccountID.parse(try reader.string()) else { throw NEARBorsh.Failure.nonCanonical }
        let blockHash = try reader.take(32)
        guard try reader.u32() == 1, try reader.u8() == NEARTransferFields.transferAction else { throw NEARBorsh.Failure.nonCanonical }
        let deposit = try reader.u128()
        guard try reader.u8() == NEARTransferFields.ed25519KeyType else { throw NEARBorsh.Failure.nonCanonical }
        let signature = try reader.take(64)
        try reader.requireEnd()
        let fields = NEARTransferFields(signer: signer, publicKey: publicKey, nonce: nonce, receiver: receiver, blockHash: blockHash, deposit: deposit)
        // Remontar da o mesmo texto: nenhuma grafia alternativa passa.
        guard try fields.signed(with: signature) == raw else { throw NEARBorsh.Failure.nonCanonical }
        return NEARSignedTransaction(fields: fields, signature: signature)
    }
}
