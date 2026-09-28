import EscaliburCore
import Foundation

// A transacao de envio de ADA da Cardano, era Conway (conway.cddl do cardano-ledger):
//
//   transaction = [corpo, testemunhas, true, null]
//   corpo       = {0: 258([entrada, ...]), 1: [saida, ...], 2: taxa, 3: ttl}
//   entrada     = [id da transacao (32 bytes), indice]
//   saida       = [endereco (bytes), lovelace]          (saida legada, sem datum)
//   testemunhas = {0: 258([[chave publica, assinatura], ...])}
//
// O id e o BLAKE2b-256 dos bytes do corpo, e e ele que a chave de pagamento assina. A tag
// 258 marca conjunto: opcional na Conway, e o formato que as carteiras atuais escrevem
// (cardano-serialization-lib 12 em diante). Os testes leem transacoes reais aceitas pela
// rede nos dois formatos, com e sem a tag, e reescrevem os mesmos bytes.

/// Uma entrada: a saida `index` da transacao `transactionID`.
public struct CardanoInput: Hashable, Sendable, Comparable {
    public let transactionID: [UInt8]
    public let index: UInt32

    public init(transactionID: [UInt8], index: UInt32) {
        self.transactionID = transactionID
        self.index = index
    }

    /// A ordem canonica de conjunto: id em bytes, depois o indice.
    public static func < (a: CardanoInput, b: CardanoInput) -> Bool {
        a.transactionID == b.transactionID ? a.index < b.index : a.transactionID.lexicographicallyPrecedes(b.transactionID)
    }

    var cbor: CBOR { .array([.bytes(transactionID), .unsigned(UInt64(index))]) }
}

/// Uma saida so de ADA, no formato legado `[endereco, lovelace]`.
public struct CardanoOutput: Equatable, Sendable {
    public let address: [UInt8]
    public let lovelace: UInt64

    public init(address: [UInt8], lovelace: UInt64) {
        self.address = address
        self.lovelace = lovelace
    }

    var cbor: CBOR { .array([.bytes(address), .unsigned(lovelace)]) }

    /// Bytes desta saida serializada: entram no minimo de ADA por saida.
    public var serializedSize: Int { cbor.encoded.count }
}

public struct CardanoTransactionBody: Equatable, Sendable {
    public let inputs: [CardanoInput]
    public let outputs: [CardanoOutput]
    public let fee: UInt64
    /// Ultimo slot em que a transacao ainda entra.
    public let ttl: UInt64
    /// Conjuntos com a tag 258. A carteira sempre escreve com ela; sem ela, so ao reler
    /// transacao antiga nos testes.
    public let taggedSets: Bool

    public init(inputs: [CardanoInput], outputs: [CardanoOutput], fee: UInt64, ttl: UInt64, taggedSets: Bool = true) {
        self.inputs = inputs
        self.outputs = outputs
        self.fee = fee
        self.ttl = ttl
        self.taggedSets = taggedSets
    }

    var cbor: CBOR {
        let inputs = CBOR.array(self.inputs.map(\.cbor))
        return .map([
            CBOR.Pair(key: .unsigned(0), value: taggedSets ? .tag(258, inputs) : inputs),
            CBOR.Pair(key: .unsigned(1), value: .array(outputs.map(\.cbor))),
            CBOR.Pair(key: .unsigned(2), value: .unsigned(fee)),
            CBOR.Pair(key: .unsigned(3), value: .unsigned(ttl)),
        ])
    }

    public var bytes: [UInt8] { cbor.encoded }

    /// O id da transacao: BLAKE2b-256 do corpo. E o que se assina.
    public var hash: [UInt8] { Blake2b.hash(bytes, outputLength: 32) }

    public enum ParseError: Error, Equatable {
        case malformed
        /// Um campo que o envio de ADA nao usa (certificado, saque, mint, datum, token).
        case unexpectedField
    }

    /// Le um corpo no formato acima, e so nele: qualquer outro campo, saida com token ou
    /// no formato de mapa, e recusado.
    static func parse(_ cbor: CBOR) throws -> CardanoTransactionBody {
        guard let pairs = cbor.pairs, pairs.count == 4,
              pairs.map({ $0.key.unsigned }) == [0, 1, 2, 3]
        else { throw ParseError.unexpectedField }
        let (inputItems, tagged) = try Self.set(pairs[0].value)
        let inputs: [CardanoInput] = try inputItems.map { item in
            guard let parts = item.items, parts.count == 2, let id = parts[0].byteString, id.count == 32,
                  let index = parts[1].unsigned, index <= UInt64(UInt32.max)
            else { throw ParseError.malformed }
            return CardanoInput(transactionID: id, index: UInt32(index))
        }
        guard let outputItems = pairs[1].value.items else { throw ParseError.malformed }
        let outputs: [CardanoOutput] = try outputItems.map { item in
            guard let parts = item.items else { throw ParseError.unexpectedField }
            guard parts.count == 2, let address = parts[0].byteString, let coin = parts[1].unsigned else {
                throw ParseError.unexpectedField
            }
            return CardanoOutput(address: address, lovelace: coin)
        }
        guard let fee = pairs[2].value.unsigned, let ttl = pairs[3].value.unsigned, !inputs.isEmpty, !outputs.isEmpty else {
            throw ParseError.malformed
        }
        return CardanoTransactionBody(inputs: inputs, outputs: outputs, fee: fee, ttl: ttl, taggedSets: tagged)
    }

    /// Um conjunto: lista, com ou sem a tag 258.
    static func set(_ value: CBOR) throws -> (items: [CBOR], tagged: Bool) {
        if case .tag(258, let inner) = value, let items = inner.items { return (items, true) }
        if let items = value.items { return (items, false) }
        throw ParseError.malformed
    }
}

/// Testemunha de chave: a chave publica Ed25519 e a assinatura do id.
public struct CardanoWitness: Equatable, Sendable {
    public let publicKey: [UInt8]
    public let signature: [UInt8]

    public init(publicKey: [UInt8], signature: [UInt8]) {
        self.publicKey = publicKey
        self.signature = signature
    }
}

/// A transacao inteira, como vai para a rede.
public struct CardanoSignedTransaction: Equatable, Sendable {
    public let body: CardanoTransactionBody
    public let witnesses: [CardanoWitness]

    public init(body: CardanoTransactionBody, witnesses: [CardanoWitness]) {
        self.body = body
        self.witnesses = witnesses
    }

    var cbor: CBOR {
        let list = CBOR.array(witnesses.map { .array([.bytes($0.publicKey), .bytes($0.signature)]) })
        let set: CBOR = body.taggedSets ? .tag(258, list) : list
        return .array([body.cbor, .map([CBOR.Pair(key: .unsigned(0), value: set)]), .bool(true), .null])
    }

    public var bytes: [UInt8] { cbor.encoded }

    /// Le uma transacao de envio de ADA assinada so por chaves: corpo no formato do envio,
    /// testemunhas so de chave, valida (`true`) e sem metadados. Os bytes relidos e
    /// reescritos tem de ser os mesmos.
    public static func parse(_ bytes: [UInt8]) throws -> CardanoSignedTransaction {
        guard let cbor = try? CBOR.decode(bytes), let parts = cbor.items, parts.count == 4,
              parts[2] == .bool(true), parts[3] == .null,
              let witnessPairs = parts[1].pairs, witnessPairs.count == 1, witnessPairs[0].key == .unsigned(0)
        else { throw CardanoTransactionBody.ParseError.malformed }
        let body = try CardanoTransactionBody.parse(parts[0])
        let (items, tagged) = try CardanoTransactionBody.set(witnessPairs[0].value)
        guard tagged == body.taggedSets else { throw CardanoTransactionBody.ParseError.malformed }
        let witnesses: [CardanoWitness] = try items.map { item in
            guard let pair = item.items, pair.count == 2, let key = pair[0].byteString, key.count == 32,
                  let signature = pair[1].byteString, signature.count == 64
            else { throw CardanoTransactionBody.ParseError.malformed }
            return CardanoWitness(publicKey: key, signature: signature)
        }
        let parsed = CardanoSignedTransaction(body: body, witnesses: witnesses)
        guard parsed.bytes == bytes else { throw CardanoTransactionBody.ParseError.malformed }
        return parsed
    }

    /// Cada testemunha assina o id do corpo.
    public var signaturesVerify: Bool {
        let id = body.hash
        return !witnesses.isEmpty && witnesses.allSatisfy {
            Ed25519.verify(signature: $0.signature, message: id, publicKey: $0.publicKey)
        }
    }
}

/// O envio pronto para assinar: um pedido de assinatura, da chave de pagamento, sobre o
/// id do corpo.
public struct CardanoTransfer: SignableTransaction {
    public let chain: Chain = .cardano
    public let body: CardanoTransactionBody
    public let path: DerivationPath
    public let publicKey: [UInt8]

    init(body: CardanoTransactionBody, path: DerivationPath, publicKey: [UInt8]) {
        self.body = body
        self.path = path
        self.publicKey = publicKey
    }

    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: path, curve: .ed25519, scheme: .ed25519Cardano, payload: body.hash, expectedPublicKey: publicKey)]
    }

    /// A transacao assinada, conferida antes de sair: a assinatura verifica contra o id e
    /// a chave, e os bytes releem na mesma transacao.
    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let signature = signatures[0].bytes
        let id = body.hash
        guard signature.count == 64, Ed25519.verify(signature: signature, message: id, publicKey: publicKey) else {
            throw SigningError.malformedSignature
        }
        let signed = CardanoSignedTransaction(body: body, witnesses: [CardanoWitness(publicKey: publicKey, signature: signature)])
        let raw = signed.bytes
        guard (try? CardanoSignedTransaction.parse(raw)) == signed else { throw SigningError.malformedSignature }
        return SignedTransaction(chainID: chain.id, raw: raw, encoded: Hex.encode(raw), id: Hex.encode(id))
    }
}
