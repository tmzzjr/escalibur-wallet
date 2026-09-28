import EscaliburCore
import Foundation

/// Os campos de uma transferencia de DOT (`Balances::transfer_keep_alive`) na Polkadot
/// Asset Hub, e as tres formas que saem deles: a chamada, o que a chave assina e a
/// extrinsic v4 assinada.
///
/// `transfer_keep_alive` nunca deixa a conta de origem abaixo do deposito existencial: a
/// rede recusa o envio que mataria a conta, em vez de apagar o resto do saldo.
public struct PolkadotTransferFields: Equatable, Sendable {
    public let sender: PolkadotAddress
    public let destination: PolkadotAddress
    /// Em planck (10^-10 DOT).
    public let amount: BigUInt
    public let nonce: UInt32
    public let era: PolkadotEra
    /// Numero e hash do bloco de nascimento da era.
    public let blockNumber: UInt64
    public let blockHash: [UInt8]
    public let specVersion: UInt32
    public let transactionVersion: UInt32
    /// Sempre `PolkadotRuntime.genesisHash` em producao; os testes usam o da Kusama Asset
    /// Hub para conferir um vetor transmitido.
    let genesisHash: [UInt8]

    init(
        sender: PolkadotAddress, destination: PolkadotAddress, amount: BigUInt, nonce: UInt32, blockNumber: UInt64,
        blockHash: [UInt8], specVersion: UInt32, transactionVersion: UInt32, eraPeriod: UInt64 = PolkadotRuntime.eraPeriod,
        genesisHash: [UInt8] = PolkadotRuntime.genesisHash
    ) {
        self.sender = sender
        self.destination = destination
        self.amount = amount
        self.nonce = nonce
        self.era = PolkadotEra(period: eraPeriod, current: blockNumber)
        self.blockNumber = blockNumber
        self.blockHash = blockHash
        self.specVersion = specVersion
        self.transactionVersion = transactionVersion
        self.genesisHash = genesisHash
    }

    /// `Balances(transfer_keep_alive { dest: MultiAddress::Id, value: Compact<u128> })`.
    public var call: [UInt8] {
        [PolkadotRuntime.balancesPallet, PolkadotRuntime.transferKeepAliveCall, PolkadotRuntime.multiAddressID]
            + destination.accountID + PolkadotSCALE.compact(amount)
    }

    /// O que vai na transacao depois da assinatura: era, nonce, gorjeta zero, taxa em DOT
    /// e o modo desligado do CheckMetadataHash.
    var explicitExtensions: [UInt8] {
        era.encoded + PolkadotSCALE.compact(BigUInt(nonce)) + PolkadotSCALE.compact(BigUInt(0))
            + [PolkadotRuntime.feeInNativeAsset, PolkadotRuntime.metadataHashDisabled]
    }

    /// O que so entra no que se assina: versoes, genese, bloco da era e o hash de
    /// metadados ausente.
    var implicitExtensions: [UInt8] {
        Array(specVersion.littleEndianByteArray) + Array(transactionVersion.littleEndianByteArray)
            + genesisHash + blockHash + [0x00]
    }

    /// `SignedPayload`: chamada, extensoes e o que elas acrescentam.
    public var payload: [UInt8] { call + explicitExtensions + implicitExtensions }

    /// O que a chave Ed25519 assina: o payload, ou o BLAKE2b-256 dele se passar de 256
    /// bytes (uma transferencia nunca passa, mas a regra e da rede).
    public var signingMessage: [UInt8] {
        let payload = payload
        return payload.count > PolkadotRuntime.payloadHashThreshold ? Blake2b.hash(payload, outputLength: 32) : payload
    }

    /// A extrinsic v4 com esta assinatura, com o prefixo de tamanho: exatamente o que a
    /// rede recebe e o que da o id.
    func extrinsic(signature: [UInt8]) -> [UInt8] {
        let body = [PolkadotRuntime.signedExtrinsicVersion, PolkadotRuntime.multiAddressID] + sender.accountID
            + [PolkadotRuntime.ed25519Signature] + signature + explicitExtensions + call
        return PolkadotSCALE.compact(BigUInt(body.count)) + body
    }
}

/// Uma transferencia de DOT pronta para o assinador. So nasce do `PolkadotPlanner`.
public struct PolkadotTransfer: SignableTransaction {
    public var chain: Chain { .polkadot }
    public let fields: PolkadotTransferFields
    public let path: DerivationPath

    init(fields: PolkadotTransferFields, path: DerivationPath) {
        self.fields = fields
        self.path = path
    }

    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: path, curve: .ed25519, scheme: .ed25519, payload: fields.signingMessage, expectedPublicKey: fields.sender.accountID)]
    }

    /// O CryptoKit aleatoriza a assinatura Ed25519, e na Polkadot o id da transacao e o
    /// hash da extrinsic inteira, com a assinatura: assinar de novo muda o id. Quem
    /// transmite reenvia sempre estes mesmos bytes. O nonce impede a execucao dupla.
    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let signature = signatures[0].bytes
        // O assinador ja verificou; conferir de novo custa pouco e impede que uma
        // assinatura de outra mensagem saia junto desta.
        guard signature.count == 64, signatures[0].recoveryID == nil,
              Ed25519.verify(signature: signature, message: fields.signingMessage, publicKey: fields.sender.accountID)
        else { throw SigningError.malformedSignature }
        return PolkadotSignedExtrinsic.pack(fields.extrinsic(signature: signature))
    }
}

/// A extrinsic assinada, lida de volta antes de sair para a rede.
///
/// `SignedTransaction.raw` e a extrinsic com o prefixo de tamanho; `encoded`, a mesma em
/// hex com 0x (o que o `author_submitExtrinsic` recebe); o id, o BLAKE2b-256 dela, em hex
/// com 0x, o hash que o Subscan e os nos mostram.
public struct PolkadotSignedExtrinsic: Equatable, Sendable {
    public let sender: PolkadotAddress
    public let signature: [UInt8]
    public let era: PolkadotEra
    public let nonce: UInt32
    public let destination: PolkadotAddress
    public let amount: BigUInt

    static func pack(_ raw: [UInt8]) -> SignedTransaction {
        SignedTransaction(chainID: Chain.polkadot.id, raw: raw, encoded: Hex.encode(raw, prefix: true), id: id(of: raw))
    }

    public static func id(of raw: [UInt8]) -> String {
        Hex.encode(Blake2b.hash(raw, outputLength: 32), prefix: true)
    }

    /// Le e confere: rede, as duas formas iguais, id igual ao hash, e a extrinsic
    /// exatamente no formato que a carteira monta (v4 assinada com Ed25519, era mortal,
    /// sem gorjeta, taxa em DOT, modo de metadados desligado, `transfer_keep_alive` para
    /// `MultiAddress::Id`, nada sobrando). Qualquer diferenca e recusa: nada que nao foi
    /// montado e revisado aqui chega a um provedor.
    public static func parse(_ signed: SignedTransaction) throws -> PolkadotSignedExtrinsic {
        guard signed.chainID == Chain.polkadot.id, signed.encoded.lowercased() == Hex.encode(signed.raw, prefix: true),
              signed.id.lowercased() == id(of: signed.raw)
        else { throw PolkadotSCALE.Failure.nonCanonical }
        return try decode(signed.raw)
    }

    static func decode(_ raw: [UInt8]) throws -> PolkadotSignedExtrinsic {
        var reader = PolkadotSCALE.Reader(raw)
        guard try reader.compact() == BigUInt(reader.remaining) else { throw PolkadotSCALE.Failure.nonCanonical }
        guard try reader.byte() == PolkadotRuntime.signedExtrinsicVersion, try reader.byte() == PolkadotRuntime.multiAddressID,
              let sender = PolkadotAddress(accountID: try reader.take(32)),
              try reader.byte() == PolkadotRuntime.ed25519Signature
        else { throw PolkadotSCALE.Failure.nonCanonical }
        let signature = try reader.take(64)
        let era = try PolkadotEra.decode(&reader)
        guard let nonce = UInt32(exactly: try reader.compact().uint64 ?? .max) else { throw PolkadotSCALE.Failure.nonCanonical }
        guard try reader.compact().isZero, try reader.byte() == PolkadotRuntime.feeInNativeAsset,
              try reader.byte() == PolkadotRuntime.metadataHashDisabled,
              try reader.take(3) == [PolkadotRuntime.balancesPallet, PolkadotRuntime.transferKeepAliveCall, PolkadotRuntime.multiAddressID],
              let destination = PolkadotAddress(accountID: try reader.take(32))
        else { throw PolkadotSCALE.Failure.nonCanonical }
        let amount = try reader.compact()
        try reader.requireEnd()
        return PolkadotSignedExtrinsic(sender: sender, signature: signature, era: era, nonce: nonce, destination: destination, amount: amount)
    }
}
