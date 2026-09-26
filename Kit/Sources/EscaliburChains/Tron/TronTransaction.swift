import EscaliburCore
import Foundation

// MARK: TaPoS

/// Um bloco recente da Tron, lido pelo chamador (`/wallet/getnowblock`): numero, id e
/// hora do cabecalho. A transacao aponta para ele (TaPoS) e so vale enquanto esse
/// bloco estiver entre os 65.536 mais recentes da rede, e ate a expiracao.
public struct TronBlockReference: Sendable, Equatable {
    /// `block_header.raw_data.number`.
    public let number: UInt64
    /// `blockID`: 32 bytes, cujos 8 primeiros sao o proprio numero do bloco.
    public let id: [UInt8]
    /// `block_header.raw_data.timestamp`, em milissegundos: o relogio da rede.
    public let timestamp: Int64

    /// Janela de validade: 60 segundos. E o padrao do java-tron ao montar transacao
    /// (Wallet.java, `setTransaction`: expiration = headBlockTimeStamp +
    /// trxExpirationTimeInMilliseconds, 60.000 por padrao), e casa com a vida de 60 s
    /// do `SigningPlan`: assinatura sobre dado velho nao sai.
    public static let expirationWindow: Int64 = 60_000

    /// Recusa id que nao comeca pelo numero do bloco. O java-tron monta o id assim
    /// (BlockCapsule.BlockId: os 8 primeiros bytes do hash trocados pelo numero), e um
    /// provedor que mande numero de um bloco e id de outro faria a transacao nascer
    /// morta, com TaPoS que nenhum no aceita.
    public init(number: UInt64, id: [UInt8], timestamp: Int64) throws {
        guard id.count == 32, Array(id.prefix(8)) == number.bigEndianByteArray, timestamp > 0 else {
            throw TronPlanError.invalidBlockReference
        }
        self.number = number
        self.id = id
        self.timestamp = timestamp
    }

    public init(number: UInt64, idHex: String, timestamp: Int64) throws {
        guard let id = Hex.decode(idHex) else { throw TronPlanError.invalidBlockReference }
        try self.init(number: number, id: id, timestamp: timestamp)
    }

    /// Bytes 6 e 7 do numero em big-endian de 8 bytes. Fonte: java-tron,
    /// TransactionCapsule.setReference: `ByteArray.subArray(refBlockNum, 6, 8)`.
    public var refBlockBytes: [UInt8] { Array(number.bigEndianByteArray[6..<8]) }

    /// Bytes 8 a 15 do id do bloco. Fonte: java-tron, TransactionCapsule.setReference:
    /// `ByteArray.subArray(blockHash, 8, 16)`.
    public var refBlockHash: [UInt8] { Array(id[8..<16]) }

    /// 60 s a partir do mais tardio entre a hora do bloco e o relogio do aparelho
    /// (`now`, em milissegundos).
    ///
    /// So a hora do bloco, como o java-tron faz, deixa a transacao nascer quase vencida
    /// quando o provedor devolve um bloco de alguns segundos atras; so o relogio do
    /// aparelho, atrasado, a faria nascer vencida. O no aceita qualquer expiracao em
    /// (hora do bloco de cabeca, mais 24 h] (Manager.java, validateCommon:
    /// `MAXIMUM_TIME_UNTIL_EXPIRATION`), entao o maximo dos dois nunca e recusado.
    public func expiration(now: Int64) -> Int64 {
        max(timestamp, now) + Self.expirationWindow
    }
}

// MARK: Transacao assinavel

/// Uma transacao Tron pronta para assinar: o raw, o caminho da chave e a chave publica
/// que ela tem de ter.
///
/// So nasce das funcoes de planejamento (`TronPlanner`), dentro de um `SigningPlan`.
public struct TronTransaction: SignableTransaction {
    public let chain: Chain = .tron
    public let raw: TronRawTransaction
    public let path: DerivationPath
    /// Chave publica secp256k1 comprimida (33 bytes) do dono.
    public let publicKey: [UInt8]
    /// SHA256 do raw. Calculado aqui, a partir dos campos, nunca recebido de fora.
    public let txID: [UInt8]

    /// Recusa montar se a chave publica nao for a dona do contrato: uma transacao
    /// assinada por outra chave e recusada pela rede, mas antes disso ela teria saido
    /// assinada por uma chave da carteira que nao era a pretendida.
    package init(raw: TronRawTransaction, path: DerivationPath, publicKey: [UInt8]) throws {
        guard publicKey.count == 33, (try? TronAddress(publicKey: publicKey)) == raw.contract.owner else {
            throw TronPlanError.ownerKeyMismatch
        }
        self.raw = raw
        self.path = path
        self.publicKey = publicKey
        self.txID = raw.txID
    }

    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: path, curve: .secp256k1, scheme: .ecdsaRecoverable, payload: txID, expectedPublicKey: publicKey)]
    }

    /// Monta a Transaction assinada.
    ///
    /// A assinatura sai em 65 bytes r ‖ s ‖ v com **v = recid + 27** (0x1b ou 0x1c),
    /// como o TronWeb (src/utils/crypto.ts, `ECKeySign`: `const v = signature.recovery + 27`,
    /// commit 974ea0bcd98c2a10f2e94addd55d4fa3b199f98a). O java-tron aceita as duas
    /// formas: `Rsv.fromSignature` soma 27 quando v < 27 (crypto/.../Rsv.java), e o
    /// proprio java-tron grava v = recid (ECKey.ECDSASignature.toByteArray, `fixedV`).
    /// Os vetores de mainnet em Fixtures/tron tem as duas.
    ///
    /// Antes de devolver, recupera a chave publica da assinatura e compara com a
    /// esperada: assinatura de outra chave, ou de outro digesto, nao sai daqui.
    ///
    /// `encoded` e o hex da Transaction { raw_data, signature } para
    /// `POST /wallet/broadcasthex` com `{"transaction": encoded}`. Nao usamos
    /// `/wallet/broadcasttransaction`: ele recebe o JSON do raw e o no reconstroi o
    /// protobuf a partir dele, e qualquer divergencia nessa conversao muda o txID.
    /// Com o hex, o no recebe exatamente os bytes que foram assinados.
    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let signature = signatures[0]
        guard signature.bytes.count == 64, let recoveryID = signature.recoveryID, recoveryID < 4 else {
            throw SigningError.malformedSignature
        }
        guard let recovered = try? Secp256k1.recover(digest: txID, compact: signature.bytes, recoveryID: recoveryID, compressed: true),
              recovered == publicKey
        else {
            throw SigningError.malformedSignature
        }
        let full = signature.bytes + [recoveryID + 27]
        let bytes = TronProtobuf.signedTransaction(raw: raw, signatures: [full])
        return SignedTransaction(chainID: chain.id, raw: bytes, encoded: Hex.encode(bytes), id: Hex.encode(txID))
    }

    /// Tamanho em bandwidth: a Transaction assinada (sem `ret`) mais 64 bytes por
    /// contrato. Fonte: java-tron, BandwidthProcessor.consume:
    /// `bytesSize = trx...clearRet().build().getSerializedSize()` e
    /// `bytesSize += Constant.MAX_RESULT_SIZE_IN_TX` (64).
    public static func bandwidthBytes(of raw: TronRawTransaction) -> UInt64 {
        let placeholder = [UInt8](repeating: 0, count: 65)
        return UInt64(TronProtobuf.signedTransaction(raw: raw, signatures: [placeholder]).count) + 64
    }
}
