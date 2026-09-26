import EscaliburCore
import Foundation

// As definicoes do codec binario do XRP Ledger, so para o que a carteira monta.
//
// Fonte: XRPLF/xrpl.js, packages/ripple-binary-codec/src/enums/definitions.json,
// commit 5c41405eb361350abc2c615491c74bb3ea6b583d (main de 24/09/2026), cujo campo
// "hash" declara 0F89957938A9185335A2ACD799EDDF3965F349E2E482A0CDD97094A1E4DB9FE7.
// O arquivo e gerado a partir do rippled, entao e a mesma tabela que o validador usa.
//
// Cada linha abaixo foi copiada de la, e o XRPLCodecTests confere tipo, ordinal e as
// tres marcas de cada campo contra a copia guardada em Fixtures/xrpl/definitions.json.
// Um ordinal errado nao da erro: produz outra transacao, com outro digesto, e a
// assinatura sai valida para bytes que o dono nao viu.

/// Os tipos do codec que a carteira serializa (codigo de tipo do `TYPES`).
public enum XRPLType: UInt16, Sendable, CaseIterable {
    case uint16 = 1
    case uint32 = 2
    case uint64 = 3
    case hash128 = 4
    case hash256 = 5
    case amount = 6
    case blob = 7
    case accountID = 8
    case stObject = 14
    case stArray = 15
    case uint8 = 16
    case hash160 = 17
    case pathSet = 18
}

/// Um campo do protocolo: tipo, ordinal dentro do tipo e as marcas que decidem se ele
/// entra na serializacao e na assinatura.
public struct XRPLField: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public let type: XRPLType
    /// "nth" no definitions.json: o ordinal do campo dentro do tipo.
    public let nth: UInt16
    /// Valor com prefixo de tamanho (Blob, AccountID).
    public let isVLEncoded: Bool
    public let isSerialized: Bool
    /// Fica de fora do digesto quando falso. So a TxnSignature, entre os campos daqui.
    public let isSigningField: Bool

    init(_ name: String, _ type: XRPLType, _ nth: UInt16, vl: Bool = false, serialized: Bool = true, signing: Bool = true) {
        self.name = name
        self.type = type
        self.nth = nth
        self.isVLEncoded = vl
        self.isSerialized = serialized
        self.isSigningField = signing
    }

    public var description: String { name }

    /// O cabecalho que precede o valor: codigo de tipo e ordinal em 1, 2 ou 3 bytes.
    public var header: [UInt8] { XRPLBinary.fieldHeader(type: type.rawValue, nth: nth) }

    /// Ordem canonica: por codigo de tipo, depois por ordinal. O rippled recusa uma
    /// transacao fora desta ordem, e o digesto depende dela.
    static func canonicalOrder(_ a: XRPLField, _ b: XRPLField) -> Bool {
        (a.type.rawValue, a.nth) < (b.type.rawValue, b.nth)
    }

    // MARK: Marcadores de fim

    public static let objectEndMarker = XRPLField("ObjectEndMarker", .stObject, 1)
    public static let arrayEndMarker = XRPLField("ArrayEndMarker", .stArray, 1)

    // MARK: Comuns a toda transacao

    public static let transactionType = XRPLField("TransactionType", .uint16, 2)
    public static let networkID = XRPLField("NetworkID", .uint32, 1)
    public static let flags = XRPLField("Flags", .uint32, 2)
    public static let sourceTag = XRPLField("SourceTag", .uint32, 3)
    public static let sequence = XRPLField("Sequence", .uint32, 4)
    public static let lastLedgerSequence = XRPLField("LastLedgerSequence", .uint32, 27)
    public static let fee = XRPLField("Fee", .amount, 8)
    public static let signingPubKey = XRPLField("SigningPubKey", .blob, 3, vl: true)
    public static let txnSignature = XRPLField("TxnSignature", .blob, 4, vl: true, signing: false)
    public static let account = XRPLField("Account", .accountID, 1, vl: true)
    public static let memos = XRPLField("Memos", .stArray, 9)
    public static let memo = XRPLField("Memo", .stObject, 10)
    public static let memoType = XRPLField("MemoType", .blob, 12, vl: true)
    public static let memoData = XRPLField("MemoData", .blob, 13, vl: true)
    public static let memoFormat = XRPLField("MemoFormat", .blob, 14, vl: true)

    // MARK: Payment

    public static let amount = XRPLField("Amount", .amount, 1)
    public static let destination = XRPLField("Destination", .accountID, 3, vl: true)
    public static let destinationTag = XRPLField("DestinationTag", .uint32, 14)
    public static let sendMax = XRPLField("SendMax", .amount, 9)
    public static let deliverMin = XRPLField("DeliverMin", .amount, 10)
    /// Caminhos de um pagamento entre moedas. O codec serializa (e o vetor oficial do
    /// DeliverMin tem caminhos), mas nenhum planejamento da v1 emite: sem `Paths`, o
    /// rippled usa o caminho padrao, e caminho vindo de servidor e dado que a carteira
    /// nao tem como conferir.
    public static let paths = XRPLField("Paths", .pathSet, 1)

    // MARK: TrustSet

    public static let limitAmount = XRPLField("LimitAmount", .amount, 3)

    // MARK: OfferCreate e OfferCancel

    public static let takerPays = XRPLField("TakerPays", .amount, 4)
    public static let takerGets = XRPLField("TakerGets", .amount, 5)
    public static let expiration = XRPLField("Expiration", .uint32, 10)
    public static let offerSequence = XRPLField("OfferSequence", .uint32, 25)

    /// Todos os campos que a carteira serializa. O teste compara um a um com o oficial.
    public static let all: [XRPLField] = [
        .objectEndMarker, .arrayEndMarker,
        .transactionType, .networkID, .flags, .sourceTag, .sequence, .lastLedgerSequence,
        .fee, .signingPubKey, .txnSignature, .account,
        .memos, .memo, .memoType, .memoData, .memoFormat,
        .amount, .destination, .destinationTag, .sendMax, .deliverMin, .paths,
        .limitAmount,
        .takerPays, .takerGets, .expiration, .offerSequence,
    ]
}

/// Os tipos de transacao que a carteira monta, com o codigo do `TRANSACTION_TYPES`.
///
/// **SetRegularKey (5), SignerListSet (12), AccountSet (3) e AccountDelete (21) nao
/// existem aqui de proposito** (docs/seguranca.md §4.1): os tres primeiros entregam o
/// controle da conta a outra chave, e o ultimo apaga a conta e manda o saldo para um
/// destino. Sao os golpes classicos de "assine para verificar sua carteira". Sem o
/// caso no enum, nenhum codigo desta biblioteca consegue produzir esses bytes.
public enum XRPLTransactionType: UInt16, Sendable, CaseIterable {
    case payment = 0
    case offerCreate = 7
    case offerCancel = 8
    case trustSet = 20
}

/// Marcas de transacao (`TRANSACTION_FLAGS` do definitions.json).
public enum XRPLTransactionFlags {
    /// tfFullyCanonicalSig. Desde a emenda RequireFullyCanonicalSig (2020) o rippled
    /// exige assinatura canonica de qualquer forma; a marca continua sendo posta porque
    /// e o que toda carteira de referencia envia, e custa zero.
    public static let fullyCanonicalSig: UInt32 = 0x8000_0000

    /// Payment: tfPartialPayment. So a camada de troca pode pedir, e so com DeliverMin.
    public static let partialPayment: UInt32 = 0x0002_0000

    /// TrustSet: tfSetNoRipple. Toda linha de confianca da carteira leva, para o saldo
    /// do dono nunca virar ponte de pagamento entre terceiros.
    public static let setNoRipple: UInt32 = 0x0002_0000

    /// OfferCreate.
    public static let passive: UInt32 = 0x0001_0000
    public static let immediateOrCancel: UInt32 = 0x0002_0000
    public static let fillOrKill: UInt32 = 0x0004_0000
    public static let sell: UInt32 = 0x0008_0000
}

/// Marcas de conta (`LEDGER_ENTRY_FLAGS.AccountRoot`), lidas do `account_info`.
public enum XRPLAccountFlags {
    /// O destino exige tag: sem ela, o dinheiro chega numa conta de exchange sem dono.
    public static let requireDestTag: UInt32 = 0x0002_0000
    /// O destino pediu para nao receber XRP. O ledger nao impede; e um pedido.
    public static let disallowXRP: UInt32 = 0x0008_0000
    /// A chave mestra da conta foi desativada: so a chave regular assina.
    public static let disableMaster: UInt32 = 0x0010_0000
    /// O destino so aceita deposito de quem ele pre-autorizou.
    public static let depositAuth: UInt32 = 0x0100_0000
}

/// Prefixos de hash do rippled (include/xrpl/protocol/HashPrefix.h).
enum XRPLHashPrefix {
    /// "STX\0": o que se assina numa assinatura simples.
    static let transactionSign: [UInt8] = [0x53, 0x54, 0x58, 0x00]
    /// "TXN\0": o id da transacao assinada.
    static let transactionID: [UInt8] = [0x54, 0x58, 0x4E, 0x00]
}
