import EscaliburCore
import Foundation

/// Por que uma transacao nao pode ser montada. Espelha o `preflight` do rippled: o
/// que a rede recusaria de cara (tem...) e recusado aqui antes de pedir assinatura.
public enum XRPLTransactionError: Error, Equatable, Sendable {
    case invalidPublicKey
    case invalidAccount(String)
    case nonPositiveAmount
    case negativeAmount
    /// temBAD_SEND_XRP_MAX: XRP para XRP nao leva SendMax.
    case xrpToXRPWithSendMax
    /// temBAD_SEND_XRP_PARTIAL: pagamento parcial de XRP para XRP.
    case xrpToXRPPartialPayment
    /// DeliverMin so existe junto de tfPartialPayment.
    case deliverMinRequiresPartialPayment
    /// DeliverMin de outro ativo, ou maior que o Amount.
    case deliverMinMismatch
    /// temREDUNDANT / temDST_IS_SRC: pagamento a si mesmo na mesma moeda, oferta que
    /// troca um ativo por ele mesmo, linha de confianca consigo.
    case redundant
    /// temBAD_OFFER: XRP dos dois lados.
    case xrpForXRPOffer
    /// temINVALID_FLAG: tfImmediateOrCancel e tfFillOrKill juntos.
    case conflictingOfferFlags
    case invalidMemo
    /// O rippled recusa Memos com mais de 1 KB serializado.
    case memosTooLarge
    case invalidFee
    case invalidSequence
}

/// A conta que assina: caminho de derivacao e a chave publica que ele tem de dar.
///
/// **Hoje so secp256k1**, a chave que sai de m/44'/144'/... Os outros formatos do XRP
/// Ledger (docs/blockchain.md §2.4) entram pelo import, sem mexer no resto:
/// - Ed25519 (`sEd...`): SigningPubKey = 0xED ‖ 32 bytes; o pedido de assinatura leva a
///   **mensagem inteira** (`signingPayload`, nao o digesto), curva e esquema `.ed25519`,
///   e a chave esperada sem o 0xED. Endereco = RIPEMD160(SHA256(0xED ‖ pub)).
/// - Family seed secp256k1 (`s...`): a chave publica ja e a comprimida de 33 bytes; o
///   que muda e so a derivacao, que mora em EscaliburKeys, nunca aqui.
public struct XRPLSigner: Sendable, Equatable {
    public enum KeyType: Sendable, Equatable {
        case secp256k1
    }

    public let path: DerivationPath
    /// 33 bytes, comprimida.
    public let publicKey: [UInt8]
    public let keyType: KeyType
    /// O endereco classico que a chave publica da. E sempre a `Account` da transacao:
    /// a carteira nao assina por conta alheia (chave regular, multisig).
    public let address: String

    public init(path: DerivationPath, publicKey: [UInt8]) throws {
        guard publicKey.count == 33, publicKey[0] == 0x02 || publicKey[0] == 0x03,
              (try? Secp256k1.reformat(publicKey: publicKey, compressed: true)) == publicKey,
              let address = try? Address.from(publicKey: publicKey, chain: .xrpl)
        else { throw XRPLTransactionError.invalidPublicKey }
        self.path = path
        self.publicKey = publicKey
        self.keyType = .secp256k1
        self.address = address
    }

    var accountID: [UInt8] { XRPLAddress.accountID(address)! }
}

/// Um memo. Tipo e formato sao texto de URL (regra do rippled); o dado e livre.
public struct XRPLMemo: Sendable, Equatable {
    public let type: [UInt8]?
    public let data: [UInt8]?
    public let format: [UInt8]?

    /// Os caracteres que o rippled aceita em MemoType e MemoFormat (isMemoOkay, STTx.cpp).
    static let urlCharacters = Set(
        "0123456789-._~:/?#[]@!$&'()*+,;=%ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8
    )

    public init(type: [UInt8]? = nil, data: [UInt8]? = nil, format: [UInt8]? = nil) throws {
        guard type != nil || data != nil || format != nil else { throw XRPLTransactionError.invalidMemo }
        for text in [type, format].compactMap({ $0 }) {
            guard text.allSatisfy(Self.urlCharacters.contains) else { throw XRPLTransactionError.invalidMemo }
        }
        self.type = type
        self.data = data
        self.format = format
    }

    /// Um memo de texto: o UTF-8 vai em MemoData, que e o que as exchanges leem.
    public static func text(_ text: String) throws -> XRPLMemo {
        guard !text.isEmpty else { throw XRPLTransactionError.invalidMemo }
        return try XRPLMemo(data: Array(text.utf8))
    }

    func element() throws -> XRPLArrayElement {
        var object = XRPLObject()
        if let type { try object.set(.memoType, .blob(type)) }
        if let data { try object.set(.memoData, .blob(data)) }
        if let format { try object.set(.memoFormat, .blob(format)) }
        return XRPLArrayElement(.memo, object)
    }
}

// MARK: Corpos

/// Payment: XRP ou token para um destino.
public struct XRPLPayment: Sendable, Equatable {
    public let destination: String
    public let amount: XRPLAmount
    public let destinationTag: UInt32?
    public let sendMax: XRPLAmount?
    public let deliverMin: XRPLAmount?
    /// tfPartialPayment. **So a camada de troca pede**, e so com DeliverMin: o envio
    /// comum nunca e parcial, porque pagamento parcial e o que o golpe do "recebi 1.000
    /// XRP" usa, e a carteira nao produz esse tipo de transacao sem motivo.
    public let partialPayment: Bool

    public init(
        destination: String, amount: XRPLAmount, destinationTag: UInt32? = nil,
        sendMax: XRPLAmount? = nil, deliverMin: XRPLAmount? = nil, partialPayment: Bool = false
    ) throws {
        guard XRPLAddress.accountID(destination) != nil else { throw XRPLTransactionError.invalidAccount(destination) }
        try Self.requirePositive(amount)
        if let sendMax { try Self.requirePositive(sendMax) }
        if amount.isXRP, sendMax == nil || sendMax?.isXRP == true {
            guard sendMax == nil else { throw XRPLTransactionError.xrpToXRPWithSendMax }
            guard !partialPayment else { throw XRPLTransactionError.xrpToXRPPartialPayment }
        }
        if let deliverMin {
            guard partialPayment else { throw XRPLTransactionError.deliverMinRequiresPartialPayment }
            try Self.requirePositive(deliverMin)
            guard Self.sameAsset(deliverMin, amount), !Self.greater(deliverMin, than: amount) else {
                throw XRPLTransactionError.deliverMinMismatch
            }
        }
        self.destination = destination
        self.amount = amount
        self.destinationTag = destinationTag
        self.sendMax = sendMax
        self.deliverMin = deliverMin
        self.partialPayment = partialPayment
    }

    static func requirePositive(_ amount: XRPLAmount) throws {
        guard !amount.isZero else { throw XRPLTransactionError.nonPositiveAmount }
        if case .issued(let issued) = amount, issued.value.isNegative { throw XRPLTransactionError.negativeAmount }
    }

    static func sameAsset(_ a: XRPLAmount, _ b: XRPLAmount) -> Bool {
        switch (a, b) {
        case (.xrp, .xrp): return true
        case (.issued(let x), .issued(let y)): return x.currency == y.currency && x.issuer == y.issuer
        default: return false
        }
    }

    /// Compara dois valores positivos do mesmo ativo.
    static func greater(_ a: XRPLAmount, than b: XRPLAmount) -> Bool {
        switch (a, b) {
        case (.xrp(let x), .xrp(let y)): return x > y
        case (.issued(let x), .issued(let y)):
            // Normalizados e positivos: expoente maior e numero maior.
            if x.value.exponent != y.value.exponent { return x.value.exponent > y.value.exponent }
            return x.value.mantissa > y.value.mantissa
        default: return false
        }
    }

    /// Codigo de moeda do lado que sai (SendMax, ou o proprio Amount) e do que chega.
    var currencies: (source: [UInt8], destination: [UInt8]) {
        func code(_ amount: XRPLAmount) -> [UInt8] {
            if case .issued(let issued) = amount { return issued.currency.bytes }
            return [UInt8](repeating: 0, count: 20)
        }
        return (code(sendMax ?? amount), code(amount))
    }
}

/// TrustSet: aceitar um token de um emissor, ate um limite.
public struct XRPLTrustSet: Sendable, Equatable {
    public let limit: XRPLIssuedAmount

    public init(limit: XRPLIssuedAmount) throws {
        guard !limit.value.isNegative else { throw XRPLTransactionError.negativeAmount }
        self.limit = limit
    }
}

/// Como a oferta executa. So as quatro marcas que docs/seguranca.md §4.5 permite.
public struct XRPLOfferOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let passive = XRPLOfferOptions(rawValue: XRPLTransactionFlags.passive)
    public static let immediateOrCancel = XRPLOfferOptions(rawValue: XRPLTransactionFlags.immediateOrCancel)
    public static let fillOrKill = XRPLOfferOptions(rawValue: XRPLTransactionFlags.fillOrKill)
    public static let sell = XRPLOfferOptions(rawValue: XRPLTransactionFlags.sell)

    static let allowed: XRPLOfferOptions = [.passive, .immediateOrCancel, .fillOrKill, .sell]
}

/// OfferCreate: o dono entrega `takerGets` e quer receber `takerPays`.
public struct XRPLOfferCreate: Sendable, Equatable {
    /// O que o dono entrega (o que quem aceitar a oferta recebe).
    public let takerGets: XRPLAmount
    /// O que o dono recebe.
    public let takerPays: XRPLAmount
    /// Segundos desde 01/01/2000 00:00 UTC (epoca do XRP Ledger).
    public let expiration: UInt32?
    public let options: XRPLOfferOptions

    public init(takerGets: XRPLAmount, takerPays: XRPLAmount, expiration: UInt32?, options: XRPLOfferOptions) throws {
        try XRPLPayment.requirePositive(takerGets)
        try XRPLPayment.requirePositive(takerPays)
        guard !(takerGets.isXRP && takerPays.isXRP) else { throw XRPLTransactionError.xrpForXRPOffer }
        guard !XRPLPayment.sameAsset(takerGets, takerPays) else { throw XRPLTransactionError.redundant }
        guard options.isSubset(of: .allowed), !options.isSuperset(of: [.immediateOrCancel, .fillOrKill]) else {
            throw XRPLTransactionError.conflictingOfferFlags
        }
        self.takerGets = takerGets
        self.takerPays = takerPays
        self.expiration = expiration
        self.options = options
    }
}

/// OfferCancel: tira do livro a oferta criada pela transacao de numero `offerSequence`.
public struct XRPLOfferCancel: Sendable, Equatable {
    public let offerSequence: UInt32

    public init(offerSequence: UInt32) throws {
        guard offerSequence > 0 else { throw XRPLTransactionError.invalidSequence }
        self.offerSequence = offerSequence
    }
}

public enum XRPLTransactionBody: Sendable, Equatable {
    case payment(XRPLPayment)
    case trustSet(XRPLTrustSet)
    case offerCreate(XRPLOfferCreate)
    case offerCancel(XRPLOfferCancel)

    public var type: XRPLTransactionType {
        switch self {
        case .payment: return .payment
        case .trustSet: return .trustSet
        case .offerCreate: return .offerCreate
        case .offerCancel: return .offerCancel
        }
    }

    var flags: UInt32 {
        switch self {
        case .payment(let p): return p.partialPayment ? XRPLTransactionFlags.partialPayment : 0
        case .trustSet: return XRPLTransactionFlags.setNoRipple
        case .offerCreate(let o): return o.options.rawValue
        case .offerCancel: return 0
        }
    }
}

// MARK: Transacao

/// Uma transacao do XRP Ledger, montada e pronta para o assinador.
///
/// Tudo o que vai ser assinado e calculado no `init`: os campos, a ordem, o digesto.
/// O assinador so recebe o digesto e a chave esperada, e `assemble` confere a
/// assinatura contra esse mesmo digesto antes de produzir os bytes de transmissao.
public struct XRPLTransaction: SignableTransaction {
    public let signer: XRPLSigner
    public let body: XRPLTransactionBody
    /// Taxa em drops, queimada pela rede.
    public let fee: BigUInt
    public let sequence: UInt32
    public let lastLedgerSequence: UInt32
    public let sourceTag: UInt32?
    public let memos: [XRPLMemo]
    public let networkID: UInt32
    public let flags: UInt32
    /// "STX\0" ‖ campos de assinatura: a mensagem que a assinatura cobre.
    public let signingPayload: [UInt8]
    /// SHA512Half da mensagem: o que a secp256k1 assina.
    public let signingDigest: [UInt8]
    let unsigned: XRPLObject

    public var chain: Chain { .xrpl }

    /// `NetworkID` so vai para a transacao em rede com id acima de 1024: na rede
    /// principal (0) e na de testes (1) o campo e proibido, e incluir derruba a
    /// transacao com telNETWORK_ID_MAKES_TX_NON_CANONICAL.
    public static let networkIDThreshold: UInt32 = 1024

    public init(
        signer: XRPLSigner, body: XRPLTransactionBody, fee: BigUInt, sequence: UInt32,
        lastLedgerSequence: UInt32, sourceTag: UInt32? = nil, memos: [XRPLMemo] = [], networkID: UInt32 = 0
    ) throws {
        guard !fee.isZero, fee <= XRPLAmount.maxDrops else { throw XRPLTransactionError.invalidFee }
        guard sequence > 0, lastLedgerSequence > 0 else { throw XRPLTransactionError.invalidSequence }
        let account = signer.accountID
        let flags = XRPLTransactionFlags.fullyCanonicalSig | body.flags

        var object = XRPLObject()
        try object.set(.transactionType, .uint16(body.type.rawValue))
        try object.set(.flags, .uint32(flags))
        if let sourceTag { try object.set(.sourceTag, .uint32(sourceTag)) }
        try object.set(.sequence, .uint32(sequence))
        try object.set(.lastLedgerSequence, .uint32(lastLedgerSequence))
        if networkID > Self.networkIDThreshold { try object.set(.networkID, .uint32(networkID)) }
        try object.set(.fee, .amount(.xrp(drops: fee)))
        try object.set(.signingPubKey, .blob(signer.publicKey))
        try object.set(.account, .accountID(account))
        if !memos.isEmpty {
            let value = XRPLValue.array(try memos.map { try $0.element() })
            guard try XRPLBinary.encode(value, field: .memos).count <= 1024 else { throw XRPLTransactionError.memosTooLarge }
            try object.set(.memos, value)
        }

        switch body {
        case .payment(let payment):
            let destination = XRPLAddress.accountID(payment.destination)!
            let currencies = payment.currencies
            // temREDUNDANT: pagar a si mesmo na mesma moeda, sem caminho, nao faz nada.
            if destination == account, currencies.source == currencies.destination { throw XRPLTransactionError.redundant }
            try object.set(.destination, .accountID(destination))
            try object.set(.amount, .amount(payment.amount))
            if let tag = payment.destinationTag { try object.set(.destinationTag, .uint32(tag)) }
            if let sendMax = payment.sendMax { try object.set(.sendMax, .amount(sendMax)) }
            if let deliverMin = payment.deliverMin { try object.set(.deliverMin, .amount(deliverMin)) }
        case .trustSet(let trust):
            guard trust.limit.issuer != account else { throw XRPLTransactionError.redundant }
            try object.set(.limitAmount, .amount(.issued(trust.limit)))
        case .offerCreate(let offer):
            try object.set(.takerGets, .amount(offer.takerGets))
            try object.set(.takerPays, .amount(offer.takerPays))
            if let expiration = offer.expiration { try object.set(.expiration, .uint32(expiration)) }
        case .offerCancel(let cancel):
            try object.set(.offerSequence, .uint32(cancel.offerSequence))
        }

        let payload = XRPLHashPrefix.transactionSign + (try object.serialized(signingFieldsOnly: true))
        self.signer = signer
        self.body = body
        self.fee = fee
        self.sequence = sequence
        self.lastLedgerSequence = lastLedgerSequence
        self.sourceTag = sourceTag
        self.memos = memos
        self.networkID = networkID
        self.flags = flags
        self.unsigned = object
        self.signingPayload = payload
        self.signingDigest = Hash.sha512Half(payload)
    }

    public var signingRequests: [SigningRequest] {
        switch signer.keyType {
        case .secp256k1:
            return [SigningRequest(
                path: signer.path, curve: .secp256k1, scheme: .ecdsaDER,
                payload: signingDigest, expectedPublicKey: signer.publicKey
            )]
        }
    }

    /// Insere a TxnSignature, serializa e calcula o id.
    ///
    /// A assinatura e conferida de novo aqui, contra o digesto que esta transacao
    /// calculou e a chave publica da conta. `verifyDER` so aceita DER estrito e low-S,
    /// que e o "totalmente canonico" que o rippled exige; uma assinatura que nao passa
    /// nunca vira bytes de transmissao.
    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let der = signatures[0].bytes
        guard (8...72).contains(der.count),
              Secp256k1.verifyDER(signature: der, digest: signingDigest, publicKey: signer.publicKey)
        else { throw SigningError.malformedSignature }
        var signed = unsigned
        try signed.set(.txnSignature, .blob(der))
        let blob = try signed.serialized()
        let id = Hash.sha512Half(XRPLHashPrefix.transactionID + blob)
        return SignedTransaction(
            chainID: chain.id, raw: blob, encoded: XRPLBinary.hexUpper(blob), id: XRPLBinary.hexUpper(id)
        )
    }

    /// Os bytes sem assinatura, com todos os campos. So para inspecao e teste.
    public var unsignedBlob: [UInt8] { (try? unsigned.serialized()) ?? [] }
}
