import EscaliburCore
import Foundation

/// `TimeBounds`: a transacao so vale entre `minTime` e `maxTime` (segundos Unix;
/// `maxTime` 0 significa sem fim, e a carteira nunca monta assim).
public struct StellarTimeBounds: Hashable, Sendable {
    public let minTime: UInt64
    public let maxTime: UInt64

    public init(minTime: UInt64, maxTime: UInt64) {
        self.minTime = minTime
        self.maxTime = maxTime
    }
}

/// Uma operacao, com a fonte opcional (sem fonte, vale a da transacao).
///
/// So existem aqui as seis operacoes que a carteira monta. **SetOptions** (troca
/// signatarios e pesos, o golpe classico de tomar a conta) e **AccountMerge**
/// (esvazia a conta inteira para outra) nao tem caso neste tipo, entao nao ha como
/// constru-las; o decodificador recusa as duas com `forbiddenOperation`.
public struct StellarOperation: Hashable, Sendable {
    public let source: StellarMuxedAccount?
    public let body: Body

    public enum Body: Hashable, Sendable {
        /// Cria a conta de destino, que nao existe, com saldo inicial em XLM.
        case createAccount(destination: StellarAccountID, startingBalance: Int64)
        case payment(destination: StellarMuxedAccount, asset: StellarAsset, amount: Int64)
        /// Recebe exatamente `destAmount`, gastando no maximo `sendMax`.
        case pathPaymentStrictReceive(
            sendAsset: StellarAsset, sendMax: Int64, destination: StellarMuxedAccount,
            destAsset: StellarAsset, destAmount: Int64, path: [StellarAsset]
        )
        /// Gasta exatamente `sendAmount`, recebendo no minimo `destMin`.
        case pathPaymentStrictSend(
            sendAsset: StellarAsset, sendAmount: Int64, destination: StellarMuxedAccount,
            destAsset: StellarAsset, destMin: Int64, path: [StellarAsset]
        )
        /// Cria (offerID 0), altera ou, com `amount` 0, cancela uma oferta.
        case manageSellOffer(selling: StellarAsset, buying: StellarAsset, amount: Int64, price: StellarPrice, offerID: Int64)
        /// Abre (ou, com `limit` 0, fecha) a linha de confianca num ativo.
        case changeTrust(asset: StellarAsset, limit: Int64)
    }

    public init(_ body: Body, source: StellarMuxedAccount? = nil) {
        self.source = source
        self.body = body
    }

    /// `OperationType` do Stellar-transaction.x.
    enum TypeCode: Int32 {
        case createAccount = 0
        case payment = 1
        case pathPaymentStrictReceive = 2
        case manageSellOffer = 3
        case setOptions = 5
        case changeTrust = 6
        case accountMerge = 8
        case pathPaymentStrictSend = 13
    }

    /// O teto de saltos do caminho no XDR (`Asset path<5>`).
    static let maxPathLength = 5

    /// As regras de `doCheckValid` do stellar-core que dependem so da operacao.
    /// Conferidas na montagem e na decodificacao, para uma operacao que a rede
    /// recusaria nunca chegar a tela.
    func validate() throws {
        switch body {
        case .createAccount(_, let balance):
            guard balance >= 0 else { throw StellarXDRError.invalidAmount(field: "startingBalance") }
        case .payment(_, _, let amount):
            guard amount > 0 else { throw StellarXDRError.invalidAmount(field: "amount") }
        case .pathPaymentStrictReceive(_, let sendMax, _, _, let destAmount, let path):
            guard sendMax > 0, destAmount > 0 else { throw StellarXDRError.invalidAmount(field: "pathPaymentStrictReceive") }
            guard path.count <= Self.maxPathLength else { throw StellarXDRError.lengthExceeded(field: "path") }
        case .pathPaymentStrictSend(_, let sendAmount, _, _, let destMin, let path):
            guard sendAmount > 0, destMin > 0 else { throw StellarXDRError.invalidAmount(field: "pathPaymentStrictSend") }
            guard path.count <= Self.maxPathLength else { throw StellarXDRError.lengthExceeded(field: "path") }
        case .manageSellOffer(let selling, let buying, let amount, let price, let offerID):
            guard amount >= 0, offerID >= 0 else { throw StellarXDRError.invalidAmount(field: "manageSellOffer") }
            guard price.n > 0, price.d > 0 else { throw StellarXDRError.invalidPrice }
            guard selling != buying else { throw StellarXDRError.invalidOffer }
        case .changeTrust(let asset, let limit):
            guard !asset.isNative else { throw StellarXDRError.invalidAssetCode }
            guard limit >= 0 else { throw StellarXDRError.invalidAmount(field: "limit") }
        }
    }

    func encode(to writer: inout StellarXDRWriter) {
        if let source {
            writer.bool(true)
            source.encode(to: &writer)
        } else {
            writer.bool(false)
        }
        switch body {
        case let .createAccount(destination, balance):
            writer.int32(TypeCode.createAccount.rawValue)
            destination.encode(to: &writer)
            writer.int64(balance)
        case let .payment(destination, asset, amount):
            writer.int32(TypeCode.payment.rawValue)
            destination.encode(to: &writer)
            asset.encode(to: &writer)
            writer.int64(amount)
        case let .pathPaymentStrictReceive(sendAsset, sendMax, destination, destAsset, destAmount, path):
            writer.int32(TypeCode.pathPaymentStrictReceive.rawValue)
            sendAsset.encode(to: &writer)
            writer.int64(sendMax)
            destination.encode(to: &writer)
            destAsset.encode(to: &writer)
            writer.int64(destAmount)
            Self.encodePath(path, to: &writer)
        case let .pathPaymentStrictSend(sendAsset, sendAmount, destination, destAsset, destMin, path):
            writer.int32(TypeCode.pathPaymentStrictSend.rawValue)
            sendAsset.encode(to: &writer)
            writer.int64(sendAmount)
            destination.encode(to: &writer)
            destAsset.encode(to: &writer)
            writer.int64(destMin)
            Self.encodePath(path, to: &writer)
        case let .manageSellOffer(selling, buying, amount, price, offerID):
            writer.int32(TypeCode.manageSellOffer.rawValue)
            selling.encode(to: &writer)
            buying.encode(to: &writer)
            writer.int64(amount)
            price.encode(to: &writer)
            writer.int64(offerID)
        case let .changeTrust(asset, limit):
            writer.int32(TypeCode.changeTrust.rawValue)
            // ChangeTrustAsset tem os mesmos tres primeiros casos de Asset.
            asset.encode(to: &writer)
            writer.int64(limit)
        }
    }

    private static func encodePath(_ path: [StellarAsset], to writer: inout StellarXDRWriter) {
        writer.uint32(UInt32(path.count))
        for asset in path { asset.encode(to: &writer) }
    }

    static func decode(from reader: inout StellarXDRReader) throws -> StellarOperation {
        let source = try reader.bool() ? try StellarMuxedAccount.decode(from: &reader) : nil
        let raw = try reader.int32()
        guard let type = TypeCode(rawValue: raw) else {
            throw StellarXDRError.unsupported("operacao de tipo \(raw)")
        }
        let body: Body
        switch type {
        case .setOptions:
            throw StellarXDRError.forbiddenOperation("SetOptions")
        case .accountMerge:
            throw StellarXDRError.forbiddenOperation("AccountMerge")
        case .createAccount:
            body = .createAccount(destination: try StellarAccountID.decode(from: &reader), startingBalance: try reader.int64())
        case .payment:
            body = .payment(
                destination: try StellarMuxedAccount.decode(from: &reader),
                asset: try StellarAsset.decode(from: &reader),
                amount: try reader.int64()
            )
        case .pathPaymentStrictReceive:
            body = .pathPaymentStrictReceive(
                sendAsset: try StellarAsset.decode(from: &reader),
                sendMax: try reader.int64(),
                destination: try StellarMuxedAccount.decode(from: &reader),
                destAsset: try StellarAsset.decode(from: &reader),
                destAmount: try reader.int64(),
                path: try decodePath(from: &reader)
            )
        case .pathPaymentStrictSend:
            body = .pathPaymentStrictSend(
                sendAsset: try StellarAsset.decode(from: &reader),
                sendAmount: try reader.int64(),
                destination: try StellarMuxedAccount.decode(from: &reader),
                destAsset: try StellarAsset.decode(from: &reader),
                destMin: try reader.int64(),
                path: try decodePath(from: &reader)
            )
        case .manageSellOffer:
            body = .manageSellOffer(
                selling: try StellarAsset.decode(from: &reader),
                buying: try StellarAsset.decode(from: &reader),
                amount: try reader.int64(),
                price: try StellarPrice.decode(from: &reader),
                offerID: try reader.int64()
            )
        case .changeTrust:
            body = .changeTrust(asset: try StellarAsset.decode(from: &reader), limit: try reader.int64())
        }
        let operation = StellarOperation(body, source: source)
        try operation.validate()
        return operation
    }

    private static func decodePath(from reader: inout StellarXDRReader) throws -> [StellarAsset] {
        let count = try reader.arrayCount(max: maxPathLength, field: "path")
        return try (0..<count).map { _ in try StellarAsset.decode(from: &reader) }
    }
}

/// A `Transaction` do XDR (a v1, `ENVELOPE_TYPE_TX`): o que o dono assina.
///
/// Construir ja valida: de 1 a 100 operacoes, memo dentro do tamanho, cada operacao
/// dentro das regras do core. Um valor deste tipo sempre serializa.
public struct StellarTx: Hashable, Sendable {
    public let source: StellarMuxedAccount
    /// Teto de taxa da transacao inteira, em stroops (taxa por operacao x operacoes).
    public let fee: UInt32
    /// O sequence da transacao: o da conta mais 1.
    public let sequence: Int64
    /// `nil` e `PRECOND_NONE`; preenchido e `PRECOND_TIME`.
    public let timeBounds: StellarTimeBounds?
    public let memo: StellarMemo
    public let operations: [StellarOperation]

    /// `MAX_OPS_PER_TX`.
    public static let maxOperations = 100

    public init(
        source: StellarMuxedAccount, fee: UInt32, sequence: Int64, timeBounds: StellarTimeBounds?,
        memo: StellarMemo, operations: [StellarOperation]
    ) throws {
        guard (1...Self.maxOperations).contains(operations.count) else { throw StellarXDRError.invalidOperationCount }
        guard memo.isValid else { throw StellarXDRError.invalidMemo }
        guard sequence >= 0 else { throw StellarXDRError.invalidAmount(field: "seqNum") }
        for operation in operations { try operation.validate() }
        self.source = source
        self.fee = fee
        self.sequence = sequence
        self.timeBounds = timeBounds
        self.memo = memo
        self.operations = operations
    }

    static let preconditionNone: Int32 = 0
    static let preconditionTime: Int32 = 1
    static let preconditionV2: Int32 = 2

    /// `XDR(Transaction)`.
    public var xdr: [UInt8] {
        var writer = StellarXDRWriter()
        source.encode(to: &writer)
        encodeBody(to: &writer, legacyTimeBounds: false)
        return writer.bytes
    }

    /// Tudo depois da conta de origem. Na v1 as precondicoes sao uma uniao
    /// (NONE/TIME); na v0 legada eram `TimeBounds*` (bool + valor). Os bytes sao os
    /// mesmos, e e por isso que uma v0 vira v1 so trocando a origem.
    fileprivate func encodeBody(to writer: inout StellarXDRWriter, legacyTimeBounds: Bool) {
        writer.uint32(fee)
        writer.int64(sequence)
        if let timeBounds {
            if legacyTimeBounds { writer.bool(true) } else { writer.int32(Self.preconditionTime) }
            writer.uint64(timeBounds.minTime)
            writer.uint64(timeBounds.maxTime)
        } else {
            if legacyTimeBounds { writer.bool(false) } else { writer.int32(Self.preconditionNone) }
        }
        memo.encode(to: &writer)
        writer.uint32(UInt32(operations.count))
        for operation in operations { operation.encode(to: &writer) }
        writer.int32(0)  // ext v0: nada de Soroban
    }

    fileprivate static func decodeBody(
        from reader: inout StellarXDRReader, source: StellarMuxedAccount, legacyTimeBounds: Bool
    ) throws -> StellarTx {
        let fee = try reader.uint32()
        let sequence = try reader.int64()
        let timeBounds: StellarTimeBounds?
        let hasTimeBounds: Bool
        if legacyTimeBounds {
            hasTimeBounds = try reader.bool()
        } else {
            let type = try reader.int32()
            switch type {
            case preconditionNone: hasTimeBounds = false
            case preconditionTime: hasTimeBounds = true
            case preconditionV2: throw StellarXDRError.unsupported("precondicoes V2")
            default: throw StellarXDRError.unknownDiscriminant(field: "Preconditions", value: type)
            }
        }
        timeBounds = hasTimeBounds ? StellarTimeBounds(minTime: try reader.uint64(), maxTime: try reader.uint64()) : nil
        let memo = try StellarMemo.decode(from: &reader)
        let count = try reader.arrayCount(max: maxOperations, field: "operations")
        let operations = try (0..<count).map { _ in try StellarOperation.decode(from: &reader) }
        let ext = try reader.int32()
        switch ext {
        case 0: break
        case 1 where !legacyTimeBounds: throw StellarXDRError.unsupported("transacao Soroban")
        default: throw StellarXDRError.unknownDiscriminant(field: "Transaction.ext", value: ext)
        }
        return try StellarTx(
            source: source, fee: fee, sequence: sequence, timeBounds: timeBounds, memo: memo, operations: operations
        )
    }

    /// `XDR(TransactionSignaturePayload)`: networkId, `ENVELOPE_TYPE_TX` (int32 2) e
    /// a transacao. E isso que o SHA-256 resume e a chave assina.
    func signaturePayload(networkID: [UInt8]) -> [UInt8] {
        var writer = StellarXDRWriter()
        writer.fixedOpaque(networkID)
        writer.int32(StellarEnvelope.typeTx)
        return writer.bytes + xdr
    }

    /// O hash da transacao, que e ao mesmo tempo o que se assina e o id que o
    /// explorador mostra. A assinatura fica fora dele (§1.4 do blockchain.md).
    func hash(networkID: [UInt8]) -> [UInt8] {
        Hash.sha256(signaturePayload(networkID: networkID))
    }
}

/// `DecoratedSignature`: a assinatura e a dica de quem assinou (4 ultimos bytes da
/// chave publica), que o no usa para achar o signatario sem testar todos.
public struct StellarDecoratedSignature: Hashable, Sendable {
    public let hint: [UInt8]
    public let signature: [UInt8]

    public init(hint: [UInt8], signature: [UInt8]) throws {
        guard hint.count == 4, signature.count <= 64 else { throw StellarXDRError.lengthExceeded(field: "DecoratedSignature") }
        self.hint = hint
        self.signature = signature
    }

    public init(publicKey: [UInt8], signature: [UInt8]) throws {
        guard publicKey.count == 32 else { throw StellarXDRError.invalidAccount }
        try self.init(hint: Array(publicKey.suffix(4)), signature: signature)
    }
}

/// `TransactionEnvelope`: a transacao e as assinaturas, a forma que vai para a rede.
///
/// A carteira monta so a v1 (`ENVELOPE_TYPE_TX`). A leitura aceita tambem a v0
/// legada, porque parte dos vetores oficiais do js-stellar-base e v0, e o hash dela
/// e o da v1 equivalente. Fee bump, precondicoes V2 e Soroban sao recusados.
public struct StellarEnvelope: Hashable, Sendable {
    public let tx: StellarTx
    public let signatures: [StellarDecoratedSignature]
    /// Lida como `ENVELOPE_TYPE_TX_V0`; reescrita no mesmo formato.
    public let isLegacyV0: Bool

    static let typeTxV0: Int32 = 0
    static let typeTx: Int32 = 2
    static let typeTxFeeBump: Int32 = 5
    static let maxSignatures = 20

    public init(tx: StellarTx, signatures: [StellarDecoratedSignature]) throws {
        guard signatures.count <= Self.maxSignatures else { throw StellarXDRError.lengthExceeded(field: "signatures") }
        self.tx = tx
        self.signatures = signatures
        self.isLegacyV0 = false
    }

    private init(legacy tx: StellarTx, signatures: [StellarDecoratedSignature]) {
        self.tx = tx
        self.signatures = signatures
        self.isLegacyV0 = true
    }

    public var xdr: [UInt8] {
        var writer = StellarXDRWriter()
        if isLegacyV0 {
            writer.int32(Self.typeTxV0)
            writer.fixedOpaque(tx.source.account.publicKey)
            tx.encodeBody(to: &writer, legacyTimeBounds: true)
        } else {
            writer.int32(Self.typeTx)
            tx.source.encode(to: &writer)
            tx.encodeBody(to: &writer, legacyTimeBounds: false)
        }
        writer.uint32(UInt32(signatures.count))
        for signature in signatures {
            writer.fixedOpaque(signature.hint)
            writer.variableOpaque(signature.signature)
        }
        return writer.bytes
    }

    public var base64: String { Data(xdr).base64EncodedString() }

    /// O hash na rede principal, com a passphrase compilada.
    public var hash: [UInt8] { tx.hash(networkID: StellarNetwork.networkID) }

    public static func decode(base64: String) throws -> StellarEnvelope {
        guard let data = Data(base64Encoded: base64) else { throw StellarXDRError.invalidBase64 }
        return try decode(Array(data))
    }

    public static func decode(_ bytes: [UInt8]) throws -> StellarEnvelope {
        var reader = StellarXDRReader(bytes)
        let type = try reader.int32()
        let tx: StellarTx
        switch type {
        case typeTx:
            let source = try StellarMuxedAccount.decode(from: &reader)
            tx = try StellarTx.decodeBody(from: &reader, source: source, legacyTimeBounds: false)
        case typeTxV0:
            let source = StellarMuxedAccount(account: try StellarAccountID(publicKey: try reader.fixedOpaque(32)))
            tx = try StellarTx.decodeBody(from: &reader, source: source, legacyTimeBounds: true)
        case typeTxFeeBump:
            throw StellarXDRError.unsupported("fee bump")
        default:
            throw StellarXDRError.unknownDiscriminant(field: "TransactionEnvelope", value: type)
        }
        let count = try reader.arrayCount(max: maxSignatures, field: "signatures")
        let signatures = try (0..<count).map { _ in
            try StellarDecoratedSignature(
                hint: try reader.fixedOpaque(4),
                signature: try reader.variableOpaque(max: 64, field: "signature")
            )
        }
        try reader.finish()
        return type == typeTxV0
            ? StellarEnvelope(legacy: tx, signatures: signatures)
            : try StellarEnvelope(tx: tx, signatures: signatures)
    }
}
