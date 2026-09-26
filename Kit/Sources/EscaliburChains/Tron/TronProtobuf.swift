import EscaliburCore
import Foundation

// Protobuf minimo da Tron: so o que uma transferencia de TRX e uma chamada de
// contrato TRC-20 precisam, e nada alem.
//
// O txID e SHA256 dos bytes de `Transaction.raw`, e a assinatura vai sobre ele. Se a
// serializacao daqui divergir um byte da do java-tron, a rede calcula outro txID e a
// assinatura nao confere; pior, se divergir de um jeito que a rede aceite com outro
// sentido, o dono assina uma coisa e a rede executa outra. Por isso a decodificacao e
// estrita: campo desconhecido, campo repetido, forma nao canonica e contrato fora da
// lista sao recusados, e todo decode termina reserializando e comparando byte a byte.
//
// Numeros de campo e type_url, da fonte (java-tron, commit
// d5c3d1d1fd0cad12f09c4346d6ac937ab2cbb071, 08/09/2026):
//   protocol/src/main/protos/core/Tron.proto
//     message Transaction { raw raw_data = 1; repeated bytes signature = 2; repeated Result ret = 5; }
//     message Transaction.raw { bytes ref_block_bytes = 1; int64 ref_block_num = 3;
//       bytes ref_block_hash = 4; int64 expiration = 8; repeated authority auths = 9;
//       bytes data = 10; repeated Contract contract = 11; bytes scripts = 12;
//       int64 timestamp = 14; int64 fee_limit = 18; }
//     message Transaction.Contract { ContractType type = 1; google.protobuf.Any parameter = 2;
//       bytes provider = 3; bytes ContractName = 4; int32 Permission_id = 5; }
//     enum ContractType { TransferContract = 1; TriggerSmartContract = 31;
//       AccountPermissionUpdateContract = 46; ... }
//   protocol/src/main/protos/core/contract/balance_contract.proto
//     message TransferContract { bytes owner_address = 1; bytes to_address = 2; int64 amount = 3; }
//   protocol/src/main/protos/core/contract/smart_contract.proto
//     message TriggerSmartContract { bytes owner_address = 1; bytes contract_address = 2;
//       int64 call_value = 3; bytes data = 4; int64 call_token_value = 5; int64 token_id = 6; }
// Os .proto declaram `package protocol`, entao o type_url do Any e
// "type.googleapis.com/protocol.<Mensagem>" (google/protobuf/any.proto: type_url = 1,
// value = 2).

/// Codificacao e decodificacao das mensagens da Tron que a carteira usa.
public enum TronProtobuf {
    public enum Failure: Error, Equatable, Sendable {
        case truncated
        case malformedVarint
        case unsupportedWireType(UInt8)
        /// Campo que a carteira nao produz e nao aceita decodificar.
        case unexpectedField(message: String, field: UInt32)
        case duplicateField(message: String, field: UInt32)
        case wrongWireType(message: String, field: UInt32)
        case missingField(message: String, field: UInt32)
        /// int64 negativo ou valor que nao cabe em int64.
        case valueOutOfRange
        case badLength(String)
        case badAddress
        /// Tipo de contrato fora da lista (TransferContract, TriggerSmartContract).
        /// `AccountPermissionUpdateContract` (46) cai aqui: e o golpe do multi-sig.
        case unsupportedContract(type: UInt64)
        case typeURLMismatch(String)
        /// Os bytes decodificam, mas a reserializacao nao reproduz os mesmos bytes.
        case notCanonical
        case wrongContractCount(Int)
    }

    /// Transaction { raw_data = 1, signature = 2 }, sem `ret`: a forma que
    /// `/wallet/broadcasthex` recebe (java-tron, BroadcastHexServlet.java:
    /// `Transaction.parseFrom(ByteArray.fromHexString(json.transaction))`).
    public static func signedTransaction(raw: TronRawTransaction, signatures: [[UInt8]]) -> [UInt8] {
        var w = TronProtoWriter()
        w.message(1, raw.serialized())
        for signature in signatures {
            w.message(2, signature)
        }
        return w.bytes
    }

    /// Decodifica uma Transaction assinada, recusando `ret` e qualquer outro campo.
    public static func decodeSignedTransaction(_ bytes: [UInt8]) throws -> (raw: TronRawTransaction, signatures: [[UInt8]]) {
        var reader = TronProtoReader(bytes)
        var raw: TronRawTransaction?
        var signatures: [[UInt8]] = []
        while let (field, value) = try reader.next() {
            switch field {
            case 1:
                guard raw == nil else { throw Failure.duplicateField(message: "Transaction", field: 1) }
                raw = try TronRawTransaction.decode(value.bytes(message: "Transaction", field: 1))
            case 2:
                signatures.append(try value.bytes(message: "Transaction", field: 2))
            default:
                throw Failure.unexpectedField(message: "Transaction", field: field)
            }
        }
        guard let raw else { throw Failure.missingField(message: "Transaction", field: 1) }
        guard signedTransaction(raw: raw, signatures: signatures) == bytes else { throw Failure.notCanonical }
        return (raw, signatures)
    }
}

// MARK: Transaction.raw

/// Os campos de `Transaction.raw` que a carteira produz. O txID e SHA256 destes bytes.
public struct TronRawTransaction: Sendable, Equatable {
    /// Bytes 6 e 7 do numero do bloco de referencia (TaPoS), big-endian.
    public let refBlockBytes: [UInt8]
    /// Bytes 8 a 15 do id do bloco de referencia.
    public let refBlockHash: [UInt8]
    /// Milissegundos desde 1970, no relogio da rede. Passou disso, a rede recusa.
    public let expiration: Int64
    /// O campo `data` do raw: o memo. A rede cobra `getMemoFee` (1 TRX hoje) quando
    /// ele nao esta vazio.
    public let memo: [UInt8]
    public let contract: TronContract
    /// Milissegundos desde 1970, quando a transacao foi montada. Diferencia duas
    /// transferencias iguais dentro da mesma janela de validade.
    public let timestamp: Int64
    /// Teto de TRX, em sun, que a execucao do contrato pode queimar em energy. So faz
    /// sentido em TriggerSmartContract; em TransferContract fica zero e nao vai ao fio.
    public let feeLimit: BigUInt

    public init(
        refBlockBytes: [UInt8], refBlockHash: [UInt8], expiration: Int64, memo: [UInt8] = [],
        contract: TronContract, timestamp: Int64, feeLimit: BigUInt = 0
    ) throws {
        guard refBlockBytes.count == 2 else { throw TronProtobuf.Failure.badLength("ref_block_bytes") }
        guard refBlockHash.count == 8 else { throw TronProtobuf.Failure.badLength("ref_block_hash") }
        guard expiration > 0, timestamp >= 0 else { throw TronProtobuf.Failure.valueOutOfRange }
        guard feeLimit.tronInt64 != nil else { throw TronProtobuf.Failure.valueOutOfRange }
        try contract.validate()
        self.refBlockBytes = refBlockBytes
        self.refBlockHash = refBlockHash
        self.expiration = expiration
        self.memo = memo
        self.contract = contract
        self.timestamp = timestamp
        self.feeLimit = feeLimit
    }

    /// Os bytes do raw, na ordem dos numeros de campo e sem os valores padrao do
    /// proto3, que e como o java-tron e o TronWeb serializam.
    public func serialized() -> [UInt8] {
        var w = TronProtoWriter()
        w.bytes(1, refBlockBytes)
        w.bytes(4, refBlockHash)
        w.int64(8, UInt64(expiration))
        w.bytes(10, memo)
        w.message(11, contract.serialized())
        w.int64(14, UInt64(timestamp))
        // O init garantiu que cabe em int64.
        w.int64(18, UInt64(feeLimit.tronInt64 ?? 0))
        return w.bytes
    }

    /// SHA256 do raw: o id da transacao e o digesto que se assina.
    public var txID: [UInt8] { Hash.sha256(serialized()) }

    /// Decodifica um `raw_data_hex`. Recusa qualquer campo que a carteira nao produz
    /// (ref_block_num, auths, scripts), contrato fora da lista e forma nao canonica.
    public static func decode(_ bytes: [UInt8]) throws -> TronRawTransaction {
        let name = "Transaction.raw"
        var reader = TronProtoReader(bytes)
        var seen = Set<UInt32>()
        var refBlockBytes: [UInt8] = []
        var refBlockHash: [UInt8] = []
        var expiration: UInt64 = 0
        var memo: [UInt8] = []
        var contracts: [TronContract] = []
        var timestamp: UInt64 = 0
        var feeLimit: UInt64 = 0
        while let (field, value) = try reader.next() {
            if field != 11 {
                guard seen.insert(field).inserted else { throw TronProtobuf.Failure.duplicateField(message: name, field: field) }
            }
            switch field {
            case 1: refBlockBytes = try value.bytes(message: name, field: field)
            case 4: refBlockHash = try value.bytes(message: name, field: field)
            case 8: expiration = try value.int64(message: name, field: field)
            case 10: memo = try value.bytes(message: name, field: field)
            case 11: contracts.append(try TronContract.decode(value.bytes(message: name, field: field)))
            case 14: timestamp = try value.int64(message: name, field: field)
            case 18: feeLimit = try value.int64(message: name, field: field)
            default: throw TronProtobuf.Failure.unexpectedField(message: name, field: field)
            }
        }
        // java-tron: "only support size = 1, repeated list here for extension".
        guard contracts.count == 1 else { throw TronProtobuf.Failure.wrongContractCount(contracts.count) }
        let raw = try TronRawTransaction(
            refBlockBytes: refBlockBytes, refBlockHash: refBlockHash, expiration: Int64(expiration),
            memo: memo, contract: contracts[0], timestamp: Int64(timestamp), feeLimit: BigUInt(feeLimit)
        )
        guard raw.serialized() == bytes else { throw TronProtobuf.Failure.notCanonical }
        return raw
    }
}

// MARK: Contract

/// Os dois contratos que a carteira assina. Qualquer outro, em especial
/// `AccountPermissionUpdateContract`, nao tem representacao aqui: nao ha como montar.
public enum TronContract: Sendable, Equatable {
    /// TransferContract: TRX, `amount` em sun.
    case transfer(owner: TronAddress, to: TronAddress, amount: BigUInt)
    /// TriggerSmartContract: chamada de contrato. `callValue` em sun (TRX junto com a
    /// chamada; zero numa transferencia TRC-20), `data` e a calldata da ABI.
    case triggerSmartContract(owner: TronAddress, contract: TronAddress, callValue: BigUInt, data: [UInt8])

    /// `Transaction.Contract.ContractType` do Tron.proto.
    public static let transferType: UInt64 = 1
    public static let triggerSmartContractType: UInt64 = 31

    public static let transferTypeURL = "type.googleapis.com/protocol.TransferContract"
    public static let triggerSmartContractTypeURL = "type.googleapis.com/protocol.TriggerSmartContract"

    public var owner: TronAddress {
        switch self {
        case .transfer(let owner, _, _), .triggerSmartContract(let owner, _, _, _): return owner
        }
    }

    public var typeNumber: UInt64 {
        switch self {
        case .transfer: return Self.transferType
        case .triggerSmartContract: return Self.triggerSmartContractType
        }
    }

    public var typeURL: String {
        switch self {
        case .transfer: return Self.transferTypeURL
        case .triggerSmartContract: return Self.triggerSmartContractTypeURL
        }
    }

    func validate() throws {
        switch self {
        case .transfer(_, _, let amount):
            guard amount.tronInt64 != nil else { throw TronProtobuf.Failure.valueOutOfRange }
        case .triggerSmartContract(_, _, let callValue, _):
            guard callValue.tronInt64 != nil else { throw TronProtobuf.Failure.valueOutOfRange }
        }
    }

    /// A mensagem interna (TransferContract ou TriggerSmartContract).
    func parameterValue() -> [UInt8] {
        var w = TronProtoWriter()
        switch self {
        case .transfer(let owner, let to, let amount):
            w.bytes(1, owner.bytes)
            w.bytes(2, to.bytes)
            w.int64(3, UInt64(amount.tronInt64 ?? 0))
        case .triggerSmartContract(let owner, let contract, let callValue, let data):
            w.bytes(1, owner.bytes)
            w.bytes(2, contract.bytes)
            w.int64(3, UInt64(callValue.tronInt64 ?? 0))
            w.bytes(4, data)
        }
        return w.bytes
    }

    /// Transaction.Contract { type = 1, parameter = 2: Any { type_url = 1, value = 2 } }.
    func serialized() -> [UInt8] {
        var any = TronProtoWriter()
        any.bytes(1, Array(typeURL.utf8))
        any.bytes(2, parameterValue())
        var w = TronProtoWriter()
        w.int64(1, typeNumber)
        w.message(2, any.bytes)
        return w.bytes
    }

    static func decode(_ bytes: [UInt8]) throws -> TronContract {
        let name = "Transaction.Contract"
        var reader = TronProtoReader(bytes)
        var type: UInt64?
        var parameter: [UInt8]?
        while let (field, value) = try reader.next() {
            switch field {
            case 1:
                guard type == nil else { throw TronProtobuf.Failure.duplicateField(message: name, field: field) }
                type = try value.varint(message: name, field: field)
            case 2:
                guard parameter == nil else { throw TronProtobuf.Failure.duplicateField(message: name, field: field) }
                parameter = try value.bytes(message: name, field: field)
            default:
                // provider, ContractName e Permission_id: a carteira nunca produz.
                // Permission_id diferente de zero e assinatura por permissao ativa de
                // multi-sig, fora do escopo da v1.
                throw TronProtobuf.Failure.unexpectedField(message: name, field: field)
            }
        }
        // type = 0 (AccountCreateContract) nao vai ao fio; ausencia tambem e recusa.
        guard let type else { throw TronProtobuf.Failure.unsupportedContract(type: 0) }
        guard type == transferType || type == triggerSmartContractType else {
            throw TronProtobuf.Failure.unsupportedContract(type: type)
        }
        guard let parameter else { throw TronProtobuf.Failure.missingField(message: name, field: 2) }

        var anyReader = TronProtoReader(parameter)
        var typeURL: String?
        var value: [UInt8] = []
        var anySeen = Set<UInt32>()
        while let (field, item) = try anyReader.next() {
            guard anySeen.insert(field).inserted else { throw TronProtobuf.Failure.duplicateField(message: "Any", field: field) }
            switch field {
            case 1: typeURL = String(decoding: try item.bytes(message: "Any", field: field), as: UTF8.self)
            case 2: value = try item.bytes(message: "Any", field: field)
            default: throw TronProtobuf.Failure.unexpectedField(message: "Any", field: field)
            }
        }
        let expectedURL = type == transferType ? transferTypeURL : triggerSmartContractTypeURL
        guard typeURL == expectedURL else { throw TronProtobuf.Failure.typeURLMismatch(typeURL ?? "") }

        return type == transferType ? try decodeTransfer(value) : try decodeTrigger(value)
    }

    private static func decodeTransfer(_ bytes: [UInt8]) throws -> TronContract {
        let name = "TransferContract"
        var reader = TronProtoReader(bytes)
        var seen = Set<UInt32>()
        var owner: [UInt8] = []
        var to: [UInt8] = []
        var amount: UInt64 = 0
        while let (field, value) = try reader.next() {
            guard seen.insert(field).inserted else { throw TronProtobuf.Failure.duplicateField(message: name, field: field) }
            switch field {
            case 1: owner = try value.bytes(message: name, field: field)
            case 2: to = try value.bytes(message: name, field: field)
            case 3: amount = try value.int64(message: name, field: field)
            default: throw TronProtobuf.Failure.unexpectedField(message: name, field: field)
            }
        }
        guard let ownerAddress = TronAddress(bytes: owner), let toAddress = TronAddress(bytes: to) else {
            throw TronProtobuf.Failure.badAddress
        }
        return .transfer(owner: ownerAddress, to: toAddress, amount: BigUInt(amount))
    }

    private static func decodeTrigger(_ bytes: [UInt8]) throws -> TronContract {
        let name = "TriggerSmartContract"
        var reader = TronProtoReader(bytes)
        var seen = Set<UInt32>()
        var owner: [UInt8] = []
        var contract: [UInt8] = []
        var callValue: UInt64 = 0
        var data: [UInt8] = []
        while let (field, value) = try reader.next() {
            guard seen.insert(field).inserted else { throw TronProtobuf.Failure.duplicateField(message: name, field: field) }
            switch field {
            case 1: owner = try value.bytes(message: name, field: field)
            case 2: contract = try value.bytes(message: name, field: field)
            case 3: callValue = try value.int64(message: name, field: field)
            case 4: data = try value.bytes(message: name, field: field)
            // call_token_value e token_id: TRC-10 junto com a chamada. Nunca.
            default: throw TronProtobuf.Failure.unexpectedField(message: name, field: field)
            }
        }
        guard let ownerAddress = TronAddress(bytes: owner), let contractAddress = TronAddress(bytes: contract) else {
            throw TronProtobuf.Failure.badAddress
        }
        return .triggerSmartContract(owner: ownerAddress, contract: contractAddress, callValue: BigUInt(callValue), data: data)
    }
}

// MARK: Fio

/// Tipos de fio do protobuf. A Tron so usa varint (0) e length-delimited (2) nos
/// campos que a carteira toca; os outros sao recusados na leitura.
enum TronWireType: UInt8 {
    case varint = 0
    case lengthDelimited = 2
}

struct TronProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func tag(_ field: UInt32, _ wire: TronWireType) {
        varint(UInt64(field) << 3 | UInt64(wire.rawValue))
    }

    /// int64 escalar do proto3. Zero e o valor padrao e nao vai ao fio.
    mutating func int64(_ field: UInt32, _ value: UInt64) {
        guard value != 0 else { return }
        tag(field, .varint)
        varint(value)
    }

    /// bytes ou string escalar do proto3. Vazio e o valor padrao e nao vai ao fio.
    mutating func bytes(_ field: UInt32, _ value: [UInt8]) {
        guard !value.isEmpty else { return }
        message(field, value)
    }

    /// Mensagem embutida ou elemento de campo repetido: vai sempre, mesmo vazio.
    mutating func message(_ field: UInt32, _ body: [UInt8]) {
        tag(field, .lengthDelimited)
        varint(UInt64(body.count))
        bytes.append(contentsOf: body)
    }
}

struct TronProtoReader {
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])

        func bytes(message: String, field: UInt32) throws -> [UInt8] {
            guard case .bytes(let b) = self else { throw TronProtobuf.Failure.wrongWireType(message: message, field: field) }
            return b
        }

        func varint(message: String, field: UInt32) throws -> UInt64 {
            guard case .varint(let v) = self else { throw TronProtobuf.Failure.wrongWireType(message: message, field: field) }
            return v
        }

        /// int64 do proto3 que a carteira aceita: nunca negativo.
        func int64(message: String, field: UInt32) throws -> UInt64 {
            let v = try varint(message: message, field: field)
            guard v <= UInt64(Int64.max) else { throw TronProtobuf.Failure.valueOutOfRange }
            return v
        }
    }

    private let data: [UInt8]
    private var offset = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < data.count else { throw TronProtobuf.Failure.truncated }
            let byte = data[offset]
            offset += 1
            // O decimo byte so pode carregar o bit 63.
            if shift == 63, byte > 1 { throw TronProtobuf.Failure.malformedVarint }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift <= 63 else { throw TronProtobuf.Failure.malformedVarint }
        }
    }

    /// O proximo campo, ou `nil` no fim exato da mensagem.
    mutating func next() throws -> (UInt32, Value)? {
        guard offset < data.count else { return nil }
        let key = try readVarint()
        let wire = UInt8(key & 0x07)
        let fieldNumber = key >> 3
        guard fieldNumber >= 1, fieldNumber <= 0x1FFF_FFFF else { throw TronProtobuf.Failure.malformedVarint }
        let field = UInt32(fieldNumber)
        switch wire {
        case TronWireType.varint.rawValue:
            return (field, .varint(try readVarint()))
        case TronWireType.lengthDelimited.rawValue:
            let length = try readVarint()
            guard length <= UInt64(data.count - offset) else { throw TronProtobuf.Failure.truncated }
            let end = offset + Int(length)
            let body = Array(data[offset..<end])
            offset = end
            return (field, .bytes(body))
        default:
            throw TronProtobuf.Failure.unsupportedWireType(wire)
        }
    }
}

extension BigUInt {
    /// O valor, se couber num int64 do protobuf (0 a 2^63 - 1).
    var tronInt64: Int64? {
        guard let v = uint64, v <= UInt64(Int64.max) else { return nil }
        return Int64(v)
    }
}
